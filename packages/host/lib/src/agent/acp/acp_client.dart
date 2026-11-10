import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';

import '../native_io.dart';
import '../runtime_transport.dart';
export '../native_io.dart' show LargeLinePermit;

const acpLineLimit = nativeLineLimit;
const acpLargeLineThreshold = nativeLargeLineThreshold;
// Retained native request IDs must fit every response, including cancellation.
// This counts JSON string contents (escaping included), without truncating IDs.
const _maxRequestIdBytes = 4096;
const _maxAdapterIdentityBytes = 4096;
const _maxSessionIdBytes = 4096;

class AcpProtocolException implements Exception {
  AcpProtocolException(this.message);
  final String message;
  @override
  String toString() => 'adapter-protocol: $message';
}

class AcpClosedException implements Exception {
  const AcpClosedException();
  @override
  String toString() => 'ACP transport closed';
}

class AcpRemoteException implements Exception {
  // Every native request error crosses an asynchronous consumer boundary.
  // Classify the original signature and discard arbitrary data before
  // completing its Future, while dispatch still owns the large-line permit.
  factory AcpRemoteException(int code, String message) {
    final bounded = clampUtf8(message, 4096);
    return AcpRemoteException._bounded(
      code,
      bounded,
      code == -32000 && message == 'Authentication required',
      bounded != message,
    );
  }

  AcpRemoteException._bounded(
    this.code,
    this.message,
    this.isAuthenticationRequired,
    this.messageTruncated,
  ) : data = null;

  final int code;
  final String message;
  final Object? data;
  final bool messageTruncated;

  /// Exact native signature observed with claude-agent-acp 0.99.1, classified
  /// before any native diagnostic truncation.
  final bool isAuthenticationRequired;

  @override
  String toString() => 'ACP error $code: $message';
}

/// Successful prompt display data only. Native results are reduced during
/// dispatch, before their Future or a credit-blocked turn can retain them.
class AcpPromptResult {
  AcpPromptResult._(Json result)
    : stopReason = result['stopReason']! as String,
      isCancelled = result['isCancelled']! as bool,
      truncated = result['truncated']! as bool;

  final String stopReason;
  final bool isCancelled;
  final bool truncated;
}

class AcpInitialization {
  AcpInitialization.fromJson(Json json)
    : protocolVersion = json['protocolVersion'] as int,
      adapterName =
          (json['agentInfo'] as Json?)?['name'] as String? ?? 'unknown',
      adapterVersion = (json['agentInfo'] as Json?)?['version'] as String?,
      agentCapabilities = json['agentCapabilities'] as Json? ?? const {} {
    _checkIdentity(adapterName);
    _checkIdentity(adapterVersion);
  }

  static void _checkIdentity(String? value) {
    if (value != null &&
        (value.length > _maxAdapterIdentityBytes ||
            clampJsonString(value, _maxAdapterIdentityBytes) != value)) {
      throw AcpProtocolException(
        'adapter identity exceeds $_maxAdapterIdentityBytes encoded bytes',
      );
    }
  }

  final int protocolVersion;
  final String adapterName;
  final String? adapterVersion;
  final Json agentCapabilities;
  Json get agentInfo => {
    'name': adapterName,
    if (adapterVersion != null) 'version': adapterVersion,
  };
}

/// ACP v1 NDJSON transport. Does not own containment or stderr. [close] never
/// waits for native I/O; its owner must settle the unit then close UnitPipes.
///
/// Notification normalization is awaited while holding a large-line permit.
/// The normalized value is then consumed after releasing it. The consumer
/// MUST finish when events are enqueued, not delivered, and may gate the next
/// line on its bounded queue. No broadcast stream or asynchronous listen
/// callback sits between this loop and the source's pause propagation.
class AcpClient implements RuntimeTransport {
  AcpClient({
    required Stream<List<int>> input,
    required this._write,
    LargeLinePermit? largeLinePermit,
  }) {
    _writer = NativeWriteAdmission(
      _write,
      _fail,
      () => failure ?? const AcpClosedException(),
    );
    _reader = NativeLineReader(
      input: input,
      permit: largeLinePermit ?? LargeLinePermit.shared,
      normalize: _decodeAndDispatch,
      consume: _consumeNative,
      protocolError: AcpProtocolException.new,
      onEof: () => _fail(const AcpClosedException()),
      onError: (error) => _fail(
        error is AcpProtocolException ? error : AcpProtocolException('$error'),
      ),
    )..start();
  }
  factory AcpClient.pipes(
    UnitPipes pipes, {
    LargeLinePermit? largeLinePermit,
  }) => AcpClient(
    input: pipes.stdout,
    write: pipes.stdin.write,
    largeLinePermit: largeLinePermit,
  );
  final Future<void> Function(List<int>) _write;
  late final NativeLineReader _reader;
  late final NativeWriteAdmission _writer;
  final _pending = <Object, _Pending>{};
  final _done = Completer<void>();
  final _onClose = <void Function()>{};
  int _nextId = 1;
  bool _closed = false;
  bool _consuming = false;
  @override
  Object? failure;
  @override
  Future<void> get done => _done.future;
  @override
  bool get isClosed => _closed;
  bool get largeLineOwned => _reader.largeLineOwned;
  bool get largeLineWaiting => _reader.largeLineWaiting;
  FutureOr<Object?> Function(String method, Json params)? normalizeNotification;
  FutureOr<void> Function(Object normalized)? consumeNotification;
  Object? Function(Object id, Json params)? onPermissionRequest;
  void Function(Object error)? onFailure;

  Future<Json> request(
    String method,
    Json params, {
    Duration? timeout,
    void Function(Json result)? onResult,
  }) {
    try {
      return _request(method, params, timeout: timeout, onResult: onResult);
    } on Object catch (error, stack) {
      return Future.error(error, stack);
    }
  }

  /// Synchronous stdin admission precedes pending-request ownership.
  Future<Json> _request(
    String method,
    Json params, {
    Duration? timeout,
    void Function(Json result)? onResult,
  }) {
    if (_closed) throw failure ?? const AcpClosedException();
    final id = _nextId++;
    final write = _admit({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    final pending = _Pending(
      timeout,
      () {
        final expired = _pending.remove(id);
        expired?.completeError(
          TimeoutException('ACP $method timed out', timeout),
        );
      },
      prompt: method == 'session/prompt',
      newSession: method == 'session/new',
      onResult: onResult,
    );
    _pending[id] = pending;
    if (!_consuming) pending.resume();
    // Admitted I/O failure closes ACP even if its response already arrived.
    write.ignore();
    return pending.completer.future;
  }

  Future<void> notify(String method, Json params) =>
      _send({'jsonrpc': '2.0', 'method': method, 'params': params});

  /// Returns native write completion after synchronous queue admission.
  /// A closed transport or full queue throws before accepting the reply.
  Future<void> reply(Object id, Json result) =>
      _admit({'jsonrpc': '2.0', 'id': id, 'result': result});
  Future<void> replyError(Object id, int code, String message) => _send({
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  });
  Future<AcpInitialization> initialize({
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final result = await request('initialize', {
      'protocolVersion': 1,
      'clientCapabilities': {
        'fs': {'readTextFile': false, 'writeTextFile': false},
        'terminal': false,
      },
      'clientInfo': {'name': 'kumiko'},
    }, timeout: timeout);
    try {
      return AcpInitialization.fromJson(result);
    } on Object catch (error) {
      _fail(AcpProtocolException('invalid initialize result: $error'));
      throw failure!;
    }
  }

  /// [onCreated] binds the new session synchronously during response dispatch,
  /// before any following ACP line can consume its initial updates.
  Future<String> newSession(
    String cwd, {
    List<Json> mcpServers = const [],
    Duration timeout = const Duration(seconds: 60),
    void Function(String nativeSessionId)? onCreated,
  }) async {
    final result = await request(
      'session/new',
      {'cwd': cwd, 'mcpServers': mcpServers},
      timeout: timeout,
      onResult: onCreated == null
          ? null
          : (result) {
              onCreated(result['sessionId']! as String);
            },
    );
    return result['sessionId']! as String;
  }

  // Replay can block on the bounded event consumer. Count active time only,
  // never desktop credit starvation, against the same 60-second bound.
  Future<Json> loadSession(
    String id,
    String cwd, {
    List<Json> mcpServers = const [],
  }) => request('session/load', {
    'sessionId': id,
    'cwd': cwd,
    'mcpServers': mcpServers,
  }, timeout: const Duration(seconds: 60));
  Future<Json> resumeSession(
    String id,
    String cwd, {
    List<Json> mcpServers = const [],
  }) => request('session/resume', {
    'sessionId': id,
    'cwd': cwd,
    'mcpServers': mcpServers,
  }, timeout: const Duration(seconds: 60));

  /// Throws local queue-admission refusals before accepting the prompt.
  Future<AcpPromptResult> prompt(String id, String text) =>
      _request('session/prompt', {
        'sessionId': id,
        'prompt': [
          {'type': 'text', 'text': text},
        ],
      }).then(AcpPromptResult._);

  Future<void> cancel(String id) => notify('session/cancel', {'sessionId': id});

  /// Atomically admits pending permission cancellations before session/cancel.
  /// A local refusal throws before any message is accepted; the returned Future
  /// observes native I/O only, so callers can commit their Stop state afterward.
  Future<void> cancelWithPermissions(
    String id,
    Iterable<Object> permissionIds,
  ) {
    if (_closed) throw failure ?? const AcpClosedException();
    final cancel = {
      'jsonrpc': '2.0',
      'method': 'session/cancel',
      'params': {'sessionId': id},
    };
    final ids = permissionIds.iterator;
    if (!ids.moveNext()) return _admit(cancel);
    final lines = StringBuffer();
    do {
      lines.writeln(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': ids.current,
          'result': {
            'outcome': {'outcome': 'cancelled'},
          },
        }),
      );
    } while (ids.moveNext());
    lines.writeln(jsonEncode(cancel));
    return _admitBytes(utf8.encode(lines.toString()));
  }

  Future<void> _send(Json message) {
    try {
      return _admit(message);
    } on Object catch (error, stack) {
      return Future.error(error, stack);
    }
  }

  Future<void> _admit(Json message) {
    if (_closed) throw failure ?? const AcpClosedException();
    return _admitBytes(utf8.encode('${jsonEncode(message)}\n'));
  }

  Future<void> _admitBytes(List<int> bytes) {
    if (_closed) throw failure ?? const AcpClosedException();
    return _writer.admit(bytes);
  }

  Future<void> _consumeNative(Object normalized) async {
    _consuming = true;
    for (final pending in _pending.values) {
      pending.pause();
    }
    try {
      await _untilClosed<void>(
        Future<void>.sync(() => consumeNotification?.call(normalized)),
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

  FutureOr<Object?> _decodeAndDispatch(Uint8List bytes) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Json) {
      throw AcpProtocolException('envelope must be an object');
    }
    return _dispatch(decoded);
  }

  FutureOr<Object?> _dispatch(Json message) {
    if (message['jsonrpc'] != '2.0') {
      throw AcpProtocolException('invalid JSON-RPC version');
    }
    final method = message['method'];
    final id = message['id'];
    if (message.containsKey('method') && method is! String) {
      throw AcpProtocolException('invalid method envelope');
    }
    if (method != null) {
      if (method is! String || (id != null && id is! String && id is! int)) {
        throw AcpProtocolException('invalid request envelope');
      }
      if (id is String &&
          (id.length > _maxRequestIdBytes ||
              clampJsonString(id, _maxRequestIdBytes) != id)) {
        throw AcpProtocolException(
          'native request id exceeds $_maxRequestIdBytes encoded bytes',
        );
      }
      final params = message['params'];
      if (params != null && params is! Json) {
        throw AcpProtocolException('invalid request params');
      }
      if (message.containsKey('result') || message.containsKey('error')) {
        throw AcpProtocolException('invalid request envelope');
      }
      if (id != null) {
        if (method == 'session/request_permission' &&
            onPermissionRequest != null) {
          return onPermissionRequest!(id, params as Json? ?? {});
        } else {
          replyError(id, -32601, 'method not found').catchError((Object error) {
            if (!_closed) _fail(error);
          });
        }
        return null;
      }
      if (method != 'session/update' || normalizeNotification == null) {
        return null;
      }
      final normalized = normalizeNotification!(method, params as Json? ?? {});
      return normalized is Future<Object?>
          ? _untilClosed<Object?>(normalized)
          : normalized;
    }
    if ((id is! String && id is! int) ||
        message.containsKey('result') == message.containsKey('error')) {
      throw AcpProtocolException('invalid response envelope');
    }
    final error = message['error'];
    final result = message['result'];
    if (message.containsKey('error') &&
        (error is! Json ||
            error['code'] is! int ||
            error['message'] is! String)) {
      throw AcpProtocolException('invalid error response');
    }
    if (!message.containsKey('error') && result is! Json) {
      throw AcpProtocolException('invalid result response');
    }
    final pending = _pending[id];
    if (pending == null) {
      return null; // Unknown/late response cannot finish a turn twice.
    }
    Json? promptResult;
    Json? creationResult;
    if (!message.containsKey('error') && pending.prompt) {
      final reason = (result as Json)['stopReason'];
      if (reason is! String) {
        throw AcpProtocolException('invalid prompt stopReason');
      }
      final bounded = clampJsonString(reason, 4096);
      // Drop every other native result field and classify the original reason
      // while dispatch still owns the large-line permit. Only this small map
      // may cross the Future boundary, including for generic prompt requests.
      promptResult = {
        'stopReason': bounded,
        'isCancelled': reason == 'cancelled',
        'truncated': bounded != reason,
      };
    }
    if (!message.containsKey('error') && pending.newSession) {
      final native = (result as Json)['sessionId'];
      if (native is! String) {
        throw AcpProtocolException('invalid session/new session id');
      }
      if (native.length > _maxSessionIdBytes ||
          clampJsonString(native, _maxSessionIdBytes) != native) {
        throw AcpProtocolException(
          'native session id exceeds $_maxSessionIdBytes encoded bytes',
        );
      }
      // No arbitrary native result metadata crosses the binding/Future seam.
      creationResult = {'sessionId': native};
    }
    _pending.remove(id);
    pending.pause();
    if (message.containsKey('error')) {
      if (error is! Json) throw AcpProtocolException('invalid error response');
      pending.completeError(
        AcpRemoteException(error['code']! as int, error['message']! as String),
      );
    } else {
      final response = promptResult ?? creationResult ?? result as Json;
      try {
        pending.onResult?.call(response);
      } on Object catch (error, stack) {
        // A local binding/storage refusal is not a native protocol failure.
        pending.completeError(error, stack);
        return null;
      }
      pending.completer.complete(response);
    }
    return null;
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

    _onClose.add(interrupt);
    action.then<void>(
      (value) {
        _onClose.remove(interrupt);
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        _onClose.remove(interrupt);
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    return result.future;
  }

  void _fail(Object error) {
    if (_closed) return;
    failure = error;
    unawaited(close());
    onFailure?.call(error);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _reader.close();
    _writer.close();
    final interrupts = _onClose.toList();
    _onClose.clear();
    for (final interrupt in interrupts) {
      interrupt();
    }
    for (final pending in _pending.values) {
      pending.completeError(failure ?? const AcpClosedException());
    }
    _pending.clear();
    // Stream cancellation/native settlement belongs to separate lifetimes.
    // Observe cancellation errors but do not wait for a blocked native read.

    _done.complete();
  }
}

class _Pending {
  _Pending(
    Duration? timeout,
    this._expired, {
    required this.prompt,
    required this.newSession,
    this.onResult,
  }) : _remaining = timeout,
       _active = timeout == null ? null : Stopwatch();
  final bool prompt;
  final bool newSession;
  final void Function(Json result)? onResult;
  final completer = Completer<Json>();
  Duration? _remaining;
  final void Function() _expired;
  final Stopwatch? _active;
  Timer? _timer;

  void pause() {
    final active = _active;
    if (active == null || !active.isRunning) return;
    active.stop();
    _remaining = _remaining! - active.elapsed;
    _timer?.cancel();
    _timer = null;
  }

  void resume() {
    final remaining = _remaining;
    final active = _active;
    if (remaining == null ||
        active == null ||
        active.isRunning ||
        completer.isCompleted) {
      return;
    }
    active
      ..reset()
      ..start();
    _timer = Timer(
      remaining > Duration.zero ? remaining : Duration.zero,
      _expired,
    );
  }

  void completeError(Object error, [StackTrace? stack]) {
    pause();
    if (!completer.isCompleted) completer.completeError(error, stack);
  }
}
