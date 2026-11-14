import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';

import '../native_io.dart';
import '../runtime_transport.dart';

class CodexProtocolException implements Exception {
  CodexProtocolException(String message) : message = clampUtf8(message, 4096);
  final String message;
  @override
  String toString() => 'codex-protocol: $message';
}

class CodexOptionalUnsupported implements Exception {
  CodexOptionalUnsupported(this.feature, this.reason, {this.rejected = false});
  final String feature;

  /// The native runtime definitely refused the request (it was not applied).
  final bool rejected;
  final String reason;
  @override
  String toString() => '$feature unavailable: $reason';
}

class CodexRemoteException implements Exception {
  CodexRemoteException(
    this.code,
    String message, {
    this.isAuthenticationRequired = false,
  }) : message = clampUtf8(message, 4096),
       messageTruncated = clampUtf8(message, 4096) != message;
  final bool messageTruncated;
  final int? code;
  final bool isAuthenticationRequired;
  final String message;
  @override
  String toString() => 'Codex error${code == null ? '' : ' $code'}: $message';
}

class CodexInitialization {
  CodexInitialization(this.userAgent, {this.version, this.codexHome});
  final String? codexHome;
  final String? version;
  final String userAgent;
}

/// Native App Server wire client, never an ACP translation. Owns bounded
/// correlation and admission only, never a process, draft, target or turn.
/// AgentService/AgentSession retain lifecycle. Native operation mapping is
/// connected by shared-start integration after additive controls are present.
/// Decoders/normalizers reduce raw envelopes under the global large-line permit;
/// awaited consumption then propagates backpressure outside that permit.
class CodexClient implements RuntimeTransport {
  CodexClient({
    required Stream<List<int>> input,
    required Future<void> Function(List<int>) write,
    LargeLinePermit? largeLinePermit,
  }) {
    _writer = NativeWriteAdmission(write, _fail, _closedError);
    _reader = NativeLineReader(
      input: input,
      permit: largeLinePermit ?? LargeLinePermit.shared,
      normalize: _decode,
      consume: _consume,
      protocolError: CodexProtocolException.new,
      onEof: () => _fail(CodexProtocolException('native output closed')),
      onError: (e) => _fail(
        e is CodexProtocolException
            ? e
            : CodexProtocolException(
                e is FormatException ? 'malformed native JSON or UTF-8' : '$e',
              ),
      ),
    )..start();
  }
  factory CodexClient.pipes(
    UnitPipes pipes, {
    LargeLinePermit? largeLinePermit,
  }) => CodexClient(
    input: pipes.stdout,
    write: pipes.stdin.write,
    largeLinePermit: largeLinePermit,
  );
  late final NativeLineReader _reader;
  late final NativeWriteAdmission _writer;
  final _pending = <Object, _Pending<Object?>>{};
  final _interrupts = <void Function()>{};
  final _done = Completer<void>();
  int _nextId = 1;
  bool _closed = false;
  bool _consuming = false;
  Object? _failure;
  Future<CodexInitialization>? _initializing;
  // Native shape classification belongs to the driver, before Json casts.
  FutureOr<Object?> Function(String method, Object? params)?
  normalizeNotification;
  @override
  FutureOr<void> Function(Object value)? consumeNotification;
  Object? Function(Object id, String method, Object? params)? onRequest;
  @override
  void Function(Object error)? onFailure;
  Object? Function(String feature, String reason)? onUnsupported;
  Object? Function()? takeBuffered;
  @override
  bool get isClosed => _closed;
  bool get largeLineOwned => _reader.largeLineOwned;
  bool get largeLineWaiting => _reader.largeLineWaiting;
  @override
  Object? get failure => _failure;
  @override
  Future<void> get done => _done.future;
  Object _closedError() =>
      _failure ?? CodexProtocolException('transport closed');
  Future<CodexInitialization> initialize() => _initializing ??= _initialize();
  Future<CodexInitialization> _initialize() async {
    final identity = await request(
      'initialize',
      {
        'clientInfo': {'name': 'kumiko', 'version': '0'},
        'capabilities': {'experimentalApi': true},
      },
      decodeResult: (result) {
        if (result is! Json) {
          throw CodexProtocolException('invalid initialize object');
        }
        for (final key in [
          'userAgent',
          'platformFamily',
          'platformOs',
          'codexHome',
        ]) {
          final value = result[key];
          if (value is! String || clampJsonString(value, 4096) != value) {
            throw CodexProtocolException('invalid initialize $key');
          }
        }
        final userAgent = result['userAgent']! as String;
        // Exact 0.166.0 server builds userAgent's first product with its native
        // build version. Platform/client suffixes and additive fields are not
        // identities. Unknown future UA grammar leaves the probe authoritative.
        final first = RegExp(
          r'^[^/\s]+/((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)(?:\s|$)',
        ).firstMatch(userAgent);
        return CodexInitialization(
          userAgent,
          version: first?.group(1),
          codexHome: result['codexHome']! as String,
        );
      },
    );
    await notify('initialized', {});
    return identity;
  }

  /// Admission refuses before correlation mutation or observable writes.
  /// The decoder must return bounded typed data, never the raw native envelope.
  Future<T> request<T>(
    String method,
    Json params, {
    required T Function(Object? result) decodeResult,
    Duration timeout = const Duration(seconds: 60),
    bool requireAdmission = false,
    List<Json> preceding = const [],
    bool pauseForOutput = true,
  }) {
    try {
      if (_closed) throw _closedError();
      if (_pending.length >= 32) {
        throw RpcException('busy', '32 native requests pending');
      }
      final id = _nextId;
      final bytes = <int>[
        for (final reply in preceding) ..._encode(reply),
        ..._encode({'id': id, 'method': method, 'params': params}),
      ];
      final pending = _Pending<T>(decodeResult, timeout, () {
        _pending
            .remove(id)
            ?.completeError(
              TimeoutException('Codex $method timed out', timeout),
            );
      }, pauseForOutput: pauseForOutput);
      _writer
          .admit(
            bytes,
            beforeWrite: () {
              _nextId++;
              _pending[id] = pending;
              if (!_consuming || !pauseForOutput) pending.resume();
            },
          )
          .ignore();
      return pending.result.future;
    } on Object catch (e, st) {
      if (requireAdmission) rethrow;
      return Future.error(e, st);
    }
  }

  Future<void> notify(String method, Json params) =>
      _send({'method': method, 'params': params});

  /// All addressed interrupts and cancellation replies share one admission.
  /// Correlation is installed for every request before the first byte is written.
  Future<void> interruptBatch(
    Map<String, String> turns,
    List<Json> replies,
    void Function(String, Object) onRejected,
  ) {
    if (_closed) throw _closedError();
    if (_pending.length + turns.length > 32) {
      throw RpcException(
        ErrorCode.busy,
        '32 native requests pending; interruption batch refused',
      );
    }
    final pending = <int, _Pending<void>>{};
    final bytes = <int>[for (final reply in replies) ..._encode(reply)];
    final completions = <Future<void>>[];
    var next = _nextId;
    for (final turn in turns.entries) {
      final id = next++;
      final request = _Pending<void>(
        (result) {
          if (result is! Json) {
            throw CodexProtocolException('invalid interrupt acknowledgement');
          }
        },
        const Duration(seconds: 10),
        () {
          _pending
              .remove(id)
              ?.completeError(
                TimeoutException('Codex turn/interrupt timed out'),
              );
        },
        pauseForOutput: false,
      );
      pending[id] = request;
      completions.add(
        request.result.future.catchError((Object error) {
          onRejected(turn.key, error);
        }),
      );
      bytes.addAll(
        _encode({
          'id': id,
          'method': 'turn/interrupt',
          'params': {'threadId': turn.key, 'turnId': turn.value},
        }),
      );
    }
    _writer
        .admit(
          bytes,
          beforeWrite: () {
            _nextId = next;
            _pending.addAll(pending);
            for (final request in pending.values) {
              request.resume();
            }
          },
        )
        .ignore();
    return Future.wait(completions).then((_) {});
  }

  Future<void> replyAdmitted(Object id, Json result) {
    if (_closed) throw _closedError();
    return _writer.admit(_encode({'id': id, 'result': result}));
  }

  Future<void> reply(Object id, Json result) =>
      _send({'id': id, 'result': result});
  Future<void> replyError(Object id, int code, String message) => _send({
    'id': id,
    'error': {'code': code, 'message': message},
  });
  List<int> _encode(Json value) => utf8.encode('${jsonEncode(value)}\n');
  Future<void> _send(Json value) {
    try {
      if (_closed) throw _closedError();
      return _writer.admit(_encode(value));
    } on Object catch (e, st) {
      return Future.error(e, st);
    }
  }

  FutureOr<Object?> _decode(Uint8List bytes) {
    final message = jsonDecode(utf8.decode(bytes));
    if (message is! Json) {
      throw CodexProtocolException('envelope must be an object');
    }
    final method = message['method'];
    final id = message['id'];
    if (message.containsKey('method')) {
      if (method is! String ||
          (message.containsKey('id') && id is! String && id is! int) ||
          message.containsKey('result') ||
          message.containsKey('error')) {
        throw CodexProtocolException('invalid request envelope');
      }
      if (id is String && clampJsonString(id, 4096) != id) {
        throw CodexProtocolException(
          'native request id exceeds 4096 encoded bytes',
        );
      }
      final params = message['params'];
      if (id != null) {
        final handler = onRequest;
        if (handler == null) {
          _deny(id, -32601, 'method not found');
          return null;
        }
        try {
          return handler(id, method, params);
        } on CodexOptionalUnsupported catch (error) {
          final notice = _unsupported(error);
          _deny(id, -32602, 'unsupported optional request');
          return notice;
        }
      }
      try {
        final value = normalizeNotification?.call(method, params);
        return value is Future<Object?> ? _optional(value) : value;
      } on CodexOptionalUnsupported catch (e) {
        return _unsupported(e);
      }
    }
    if ((id is! String && id is! int) ||
        message.containsKey('result') == message.containsKey('error')) {
      throw CodexProtocolException('invalid response envelope');
    }
    final error = message['error'];
    final result = message['result'];
    if (message.containsKey('error') &&
        (error is! Json ||
            error['code'] is! int ||
            error['message'] is! String)) {
      throw CodexProtocolException('invalid native error');
    }
    final pending = _pending.remove(id);
    if (pending == null) return null;
    pending.pause();
    if (error is Json) {
      pending.completeError(
        CodexRemoteException(
          error['code']! as int,
          error['message']! as String,
        ),
      );
    } else {
      try {
        pending.complete(result);
      } on CodexOptionalUnsupported catch (e) {
        // This request no longer belongs to _pending. Settle it before a
        // notice callback can throw and send the transport down its fail path.
        pending.completeError(e);
        return _unsupported(e);
      } on Object catch (e, st) {
        final malformed = e is CodexProtocolException
            ? e
            : CodexProtocolException('invalid result: $e');
        pending.completeError(malformed, st);
        _fail(malformed);
      }
    }
    return takeBuffered?.call();
  }

  void deny(Object id, int code, String message) => _deny(id, code, message);
  void _deny(Object id, int code, String message) {
    replyError(id, code, message).catchError((Object error) {
      if (!_closed) _fail(error);
    });
  }

  Object? _unsupported(CodexOptionalUnsupported e) => onUnsupported?.call(
    clampJsonString(e.feature, 128),
    clampJsonString(e.reason, 4096),
  );
  Future<Object?> _optional(Future<Object?> value) async {
    try {
      return await _untilClosed(value);
    } on CodexOptionalUnsupported catch (e) {
      return _unsupported(e);
    }
  }

  Future<void> _consume(Object value) async {
    _consuming = true;
    for (final pending in _pending.values) {
      if (pending.pauseForOutput) pending.pause();
    }
    try {
      await _untilClosed(
        Future<void>.sync(() => consumeNotification?.call(value)),
      );
    } finally {
      _consuming = false;
      if (!_closed) {
        for (final pending in _pending.values) {
          pending.resume();
        }
      }
    }
  }

  Future<T?> _untilClosed<T>(Future<T?> action) {
    if (_closed) {
      action.ignore();
      return Future.value();
    }
    final result = Completer<T?>();
    void interrupt() {
      if (!result.isCompleted) result.complete();
    }

    _interrupts.add(interrupt);
    action.then<void>(
      (v) {
        _interrupts.remove(interrupt);
        if (!result.isCompleted) result.complete(v);
      },
      onError: (Object e, StackTrace st) {
        _interrupts.remove(interrupt);
        if (!result.isCompleted) result.completeError(e, st);
      },
    );
    return result.future;
  }

  void _fail(Object e) {
    if (_closed) return;
    _failure = e;
    unawaited(close());
    onFailure?.call(e);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _reader.close();
    _writer.close();
    for (final interrupt in _interrupts.toList()) {
      interrupt();
    }
    _interrupts.clear();
    for (final pending in _pending.values) {
      pending.completeError(_closedError());
    }
    _pending.clear();
    _done.complete();
  }
}

class _Pending<T> {
  _Pending(
    this.decode,
    this._remaining,
    this.expired, {
    this.pauseForOutput = true,
  });
  final bool pauseForOutput;
  final T Function(Object? result) decode;
  final void Function() expired;
  final result = Completer<T>();
  final _active = Stopwatch();
  Duration _remaining;
  Timer? _timer;
  void complete(Object? value) => result.complete(decode(value));
  void completeError(Object e, [StackTrace? st]) {
    pause();
    if (!result.isCompleted) result.completeError(e, st);
  }

  void pause() {
    if (!_active.isRunning) return;
    _active.stop();
    _remaining -= _active.elapsed;
    _timer?.cancel();
    _timer = null;
  }

  void resume() {
    if (_active.isRunning || result.isCompleted) return;
    _active
      ..reset()
      ..start();
    _timer = Timer(
      _remaining > Duration.zero ? _remaining : Duration.zero,
      expired,
    );
  }
}
