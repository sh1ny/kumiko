import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'close_reason.dart';
import 'fair_writer.dart';
import 'frame_codec.dart';
import 'messages.dart';

/// Adapts an [IOSink] (a child's stdin, or this process's stdout).
class IOSinkAdapter implements ByteSink {
  IOSinkAdapter(this._sink);
  final IOSink _sink;

  @override
  void add(List<int> data) => _sink.add(data);

  @override
  Future<void> flush() => _sink.flush();
}

/// The connection ended before the answer came.
class ConnectionClosedException implements Exception {
  ConnectionClosedException(this.reason);
  final CloseReason reason;

  @override
  String toString() => 'ConnectionClosedException: $reason';
}

/// Answers a request after `hello`. Throw [RpcException] to answer an error.
typedef RequestHandler = FutureOr<Object?> Function(String method, Json params);
typedef NotificationHandler = void Function(String method, Json params);

/// Answers `hello` on the side that serves it. The negotiation itself is done
/// by the connection; the handler adds the host's identity and state, or
/// throws [RpcException] (`profile-locked`, ...).
typedef HelloHandler = FutureOr<HelloInfo> Function(
  HelloParams params,
  Negotiated negotiated,
);

class _Pending {
  _Pending(this.method);
  final String method;
  final Completer<Object?> completer = Completer();
}

class _Inbound {
  _Inbound(this.id, this._connection) {
    controller = StreamController<Uint8List>(
      onListen: pump,
      onResume: pump,
      onCancel: () => _connection._dropInbound(id),
    );
  }

  final int id;
  final Connection _connection;
  late final StreamController<Uint8List> controller;
  final Queue<Uint8List> _queue = Queue();

  /// Bytes the sender may still send.
  int outstanding = channelWindow;

  /// Bytes the consumer has taken since the last grant.
  int _consumed = 0;

  void receive(Uint8List payload) {
    if (payload.isEmpty) throw ProtocolViolation('empty data frame on $id');
    if (payload.length > outstanding) {
      throw ProtocolViolation(
        'channel $id sent ${payload.length} bytes with $outstanding granted',
      );
    }
    outstanding -= payload.length;
    _queue.add(payload);
    pump();
  }

  /// Hands queued data to the consumer while it is listening and not paused,
  /// and tops the credit up once it has taken half the window.
  void pump() {
    while (_queue.isNotEmpty && !controller.isClosed && !controller.isPaused) {
      final bytes = _queue.removeFirst();
      controller.add(bytes);
      _consumed += bytes.length;
      if (_consumed * 2 >= channelWindow) {
        outstanding += _consumed;
        _connection._writer.sendCredit(id, _consumed);
        _consumed = 0;
      }
    }
  }

  void close() {
    _queue.clear();
    if (!controller.isClosed) unawaited(controller.close());
  }
}

/// One desktop-host session over a byte stream pair: JSON-RPC on channel 0,
/// credit-controlled data channels, and the `hello` negotiation.
///
/// The reader never pauses [input]. Violations and losses end the connection;
/// the owner observes why through [closed].
class Connection {
  Connection({
    required Stream<List<int>> input,
    required ByteSink output,
    this.versions = const VersionRange(1, 1),
    this.capabilities = const {},
    this.onHello,
    this.onRequest,
    this.onNotification,
  }) {
    _writer = FairWriter(output, onFatal: _shutdown);
    _subscription = input.listen(
      _onBytes,
      onDone: () => _shutdown(const CloseReason(CloseReason.inputClosed)),
      onError: (Object e) =>
          _shutdown(CloseReason(CloseReason.inputClosed, '$e')),
      cancelOnError: true,
    );
  }

  final VersionRange versions;
  final Set<String> capabilities;
  final HelloHandler? onHello;
  final RequestHandler? onRequest;
  final NotificationHandler? onNotification;

  late final FairWriter _writer;
  late final StreamSubscription<List<int>> _subscription;
  final FrameDecoder _decoder = FrameDecoder();
  final MessageAssembler _assembler = MessageAssembler();
  final Map<int, _Inbound> _inbound = {};
  final Map<int, _Pending> _pending = {};
  final Completer<CloseReason> _closed = Completer();
  Negotiated? _negotiated;
  bool _helloReceived = false;
  int _nextRequestId = 1;
  int _inFlight = 0;
  int _highestChannel = 0;
  CloseReason? _reason;

  /// Completes (never with an error) when the connection ends, with why.
  Future<CloseReason> get closed => _closed.future;
  bool get isClosed => _reason != null;

  /// Set once `hello` has completed.
  Negotiated? get negotiated => _negotiated;

  // --- control -----------------------------------------------------------

  /// Sends the `hello` request with this connection's ranges.
  Future<HelloResult> hello({
    PriorHost? priorHost,
    int? desktopPid,
    int? desktopStartTime,
    bool? outerJobHeld,
  }) async {
    final params = HelloParams(
      versions: versions,
      capabilities: capabilities,
      priorHost: priorHost,
      desktopPid: desktopPid,
      desktopStartTime: desktopStartTime,
      outerJobHeld: outerJobHeld,
    );
    final result = await request(Method.hello, params.toJson());
    return HelloResult.fromJson(_asJson(result));
  }

  /// Sends a request and returns its result. An error answer throws
  /// [RpcException]; a connection that ends first throws
  /// [ConnectionClosedException].
  Future<Object?> request(String method, [Object? params]) {
    final reason = _reason;
    if (reason != null) return Future.error(ConnectionClosedException(reason));
    final id = _nextRequestId++;
    final pending = _pending[id] = _Pending(method);
    _send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': ?params});
    return pending.completer.future;
  }

  /// Completes once everything queued on the control channel has been
  /// written.
  Future<void> drain() => _writer.drain();

  void notify(String method, [Object? params]) {
    if (isClosed) return;
    _send({'jsonrpc': '2.0', 'method': method, 'params': ?params});
  }

  void _send(Json message) =>
      _writer.sendControl(utf8.encode(jsonEncode(message)));

  // --- data channels -----------------------------------------------------

  void _checkCap() {
    if (_writer.channelCount + _inbound.length >= maxChannels) {
      throw RpcException(
        ErrorCode.channelCap,
        'at most $maxChannels data channels may be open',
      );
    }
  }

  /// Opens a channel this side sends on. The receiver attaches with
  /// [attachInbound]; nothing is sent until it grants credit. Throws
  /// [RpcException] (`channel-cap`) beyond the cap.
  ChannelWriter openOutbound() {
    _checkCap();
    return _writer.openChannel(++_highestChannel);
  }

  /// Starts receiving channel [id] and grants the full window. Data is queued
  /// (at most the window) until the stream's listener takes it.
  Stream<Uint8List> attachInbound(int id) {
    _checkCap();
    _highestChannel = math.max(_highestChannel, id);
    final inbound = _inbound[id] = _Inbound(id, this);
    _writer.sendCredit(id, channelWindow);
    return inbound.controller.stream;
  }

  /// Closes channel [id] here and asks the peer to close it too.
  Future<void> closeChannel(int id) async {
    _closeLocalChannel(id);
    if (isClosed) return;
    await request(Method.channelClose, ChannelCloseParams(id).toJson());
  }

  void _closeLocalChannel(int id) {
    _writer.closeChannel(id);
    _inbound.remove(id)?.close();
  }

  void _dropInbound(int id) {
    if (_inbound.remove(id) != null && !isClosed) {
      // The consumer cancelled: stop the sender.
      unawaited(
        request(
          Method.channelClose,
          ChannelCloseParams(id).toJson(),
        ).then<void>((_) {}, onError: (Object _) {}),
      );
    }
  }

  // --- reading -----------------------------------------------------------

  void _onBytes(List<int> chunk) {
    try {
      for (final frame in _decoder.add(chunk)) {
        if (isClosed) return;
        _onFrame(frame);
      }
    } on ProtocolViolation catch (violation) {
      _shutdown(CloseReason(CloseReason.protocolViolation, violation.detail));
    }
  }

  void _onFrame(Frame frame) {
    if (frame.channel == controlChannel) {
      if (frame.kind != FrameKind.data) {
        throw ProtocolViolation('credit frame on the control channel');
      }
      final message = _assembler.add(frame);
      if (message != null) _onMessage(message);
      return;
    }
    final id = frame.channel;
    if (frame.kind == FrameKind.credit) {
      if (_writer.grant(id, frame.creditBytes)) return;
      _expectClosed(id);
      return;
    }
    final inbound = _inbound[id];
    if (inbound != null) {
      inbound.receive(frame.payload);
      return;
    }
    _expectClosed(id);
  }

  /// A frame for a channel that is not open is discarded if it was open
  /// before, and a violation if it never was.
  void _expectClosed(int id) {
    if (id > _highestChannel ||
        _writer.hasChannel(id) ||
        _inbound.containsKey(id)) {
      throw ProtocolViolation('frame for channel $id, which was never opened');
    }
  }

  void _onMessage(Uint8List bytes) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException catch (e) {
      throw ProtocolViolation('control message is not JSON: ${e.message}');
    }
    if (decoded is! Map<String, Object?> || decoded['jsonrpc'] != '2.0') {
      throw ProtocolViolation('control message is not a JSON-RPC object');
    }
    final method = decoded['method'];
    if (method is String) {
      final params = decoded['params'];
      final json = params is Map<String, Object?>
          ? params
          : <String, Object?>{};
      if (decoded.containsKey('id')) {
        final id = decoded['id'];
        if (id is! int && id is! String) {
          throw ProtocolViolation('request id must be a number or string');
        }
        _onRequest(id!, method, json);
      } else {
        if (_negotiated == null) {
          throw ProtocolViolation('notification $method before hello');
        }
        onNotification?.call(method, json);
      }
    } else if (decoded.containsKey('id')) {
      _onResponse(decoded);
    } else {
      throw ProtocolViolation('control message has no method or id');
    }
  }

  void _onResponse(Json message) {
    final id = message['id'];
    final pending = id is int ? _pending.remove(id) : null;
    if (pending == null) return;
    final error = message['error'];
    if (error is Map<String, Object?>) {
      pending.completer.completeError(RpcException.fromJson(error));
      return;
    }
    final result = message['result'];
    if (pending.method == Method.hello) {
      // Set synchronously: whatever the host sent after the answer is already
      // in this chunk and must find the session open.
      try {
        final parsed = HelloResult.fromJson(_asJson(result));
        _negotiated = Negotiated(parsed.version, parsed.capabilities);
      } on RpcException catch (e) {
        pending.completer.completeError(e);
        return;
      }
    }
    pending.completer.complete(result);
  }

  // --- serving -----------------------------------------------------------

  void _reply(Object id, {Object? result, RpcException? error}) {
    if (isClosed) return;
    _send({
      'jsonrpc': '2.0',
      'id': id,
      if (error != null) 'error': error.toJson() else 'result': result ?? {},
    });
  }

  void _onRequest(Object id, String method, Json params) {
    if (method == Method.hello) {
      unawaited(_serveHello(id, params));
      return;
    }
    final negotiated = _negotiated;
    if (negotiated == null) {
      _reply(
        id,
        error: RpcException(
          ErrorCode.protocolError,
          'request $method before hello',
        ),
      );
      return;
    }
    if (_inFlight >= maxInboundRequests) {
      _reply(id, error: RpcException(ErrorCode.busy, 'too many requests'));
      return;
    }
    final needed = methodCapability[method];
    if (needed != null && !negotiated.capabilities.contains(needed)) {
      _reply(id, error: RpcException(ErrorCode.methodNotAvailable, method));
      return;
    }
    unawaited(_serve(id, method, params));
  }

  Future<void> _serve(Object id, String method, Json params) async {
    _inFlight++;
    try {
      final Object? result;
      if (method == Method.channelClose) {
        result = _serveChannelClose(params);
      } else {
        final handler = onRequest;
        if (handler == null) {
          throw RpcException(ErrorCode.methodNotAvailable, method);
        }
        result = await handler(method, params);
      }
      _reply(id, result: result);
    } on RpcException catch (e) {
      _reply(id, error: e);
    } on Object catch (e) {
      _reply(id, error: RpcException(ErrorCode.internalError, '$e'));
    } finally {
      _inFlight--;
    }
  }

  Object? _serveChannelClose(Json params) {
    final close = ChannelCloseParams.fromJson(params);
    if (close.channel > _highestChannel) {
      throw RpcException(ErrorCode.invalidParams, 'channel was never opened');
    }
    _closeLocalChannel(close.channel);
    return null;
  }

  Future<void> _serveHello(Object id, Json params) async {
    if (_helloReceived) {
      _shutdown(
        const CloseReason(CloseReason.protocolViolation, 'second hello'),
      );
      return;
    }
    _helloReceived = true;
    try {
      final handler = onHello;
      if (handler == null) {
        throw RpcException(
          ErrorCode.methodNotAvailable,
          'this side does not serve hello',
        );
      }
      final remote = HelloParams.fromJson(params);
      final negotiated = negotiate(versions, capabilities, remote);
      if (negotiated == null) {
        throw incompatibleVersions(remote.versions, versions);
      }
      final info = await handler(remote, negotiated);
      _negotiated = negotiated;
      _reply(
        id,
        result: HelloResult(
          version: negotiated.version,
          capabilities: negotiated.capabilities,
          instanceId: info.instanceId,
          hostVersion: info.hostVersion,
          state: info.state,
        ).toJson(),
      );
    } on RpcException catch (e) {
      _reply(id, error: e);
    }
  }

  // --- ending ------------------------------------------------------------

  /// Closes the connection from the owner's side.
  Future<void> close() async {
    _shutdown(const CloseReason(CloseReason.closedLocally));
    await _closed.future;
  }

  void _shutdown(CloseReason reason) {
    if (_reason != null) return;
    _reason = reason;
    unawaited(_subscription.cancel());
    _writer.close();
    for (final inbound in _inbound.values.toList()) {
      inbound.close();
    }
    _inbound.clear();
    for (final pending in _pending.values) {
      pending.completer.completeError(ConnectionClosedException(reason));
    }
    _pending.clear();
    _closed.complete(reason);
  }
}

Json _asJson(Object? value) => value is Map<String, Object?>
    ? value
    : throw RpcException(ErrorCode.invalidParams, 'result is not an object');
