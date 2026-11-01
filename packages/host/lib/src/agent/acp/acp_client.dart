import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';

const acpLineLimit = 16 * 1024 * 1024;
const acpLargeLineThreshold = 1024 * 1024;
// Retained native request IDs must fit every response, including cancellation.
// This counts JSON string contents (escaping included), without truncating IDs.
const _maxRequestIdBytes = 4096;
const _maxAdapterIdentityBytes = 4096;

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

/// One host-wide permit. A closed waiting client is removed, not granted a
/// permit later. Owners release after normalization, before event delivery.
class LargeLinePermit {
  static final shared = LargeLinePermit();
  Object? _owner;
  final _waiters = <Object, Completer<bool>>{};

  bool owns(Object owner) => _owner == owner;
  bool isWaiting(Object owner) => _waiters.containsKey(owner);

  Future<bool> acquire(Object owner) {
    if (_owner == owner) return Future.value(true);
    if (_owner == null) {
      _owner = owner;
      return Future.value(true);
    }
    return (_waiters[owner] ??= Completer<bool>()).future;
  }

  void release(Object owner) {
    final waiter = _waiters.remove(owner);
    if (waiter != null) waiter.complete(false);
    if (_owner != owner) return;
    _owner = null;
    if (_waiters.isNotEmpty) {
      final next = _waiters.entries.first;
      _waiters.remove(next.key);
      _owner = next.key;
      next.value.complete(true);
    }
  }
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
class AcpClient {
  AcpClient({
    required Stream<List<int>> input,
    required this._write,
    LargeLinePermit? largeLinePermit,
  }) : _permit = largeLinePermit ?? LargeLinePermit.shared {
    _iterator = StreamIterator(input);
    unawaited(_read());
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
  final LargeLinePermit _permit;
  late final StreamIterator<List<int>> _iterator;
  final _pending = <Object, _Pending>{};
  final _done = Completer<void>();
  final _onClose = <void Function()>{};
  int _nextId = 1;
  int _writingBytes = 0;
  bool _closed = false;
  bool _consuming = false;
  Object? failure;
  Future<void> get done => _done.future;
  bool get isClosed => _closed;
  bool get largeLineOwned => _permit.owns(this);
  bool get largeLineWaiting => _permit.isWaiting(this);
  FutureOr<Object?> Function(String method, Json params)? normalizeNotification;
  FutureOr<void> Function(Object normalized)? consumeNotification;
  Object? Function(Object id, Json params)? onPermissionRequest;
  void Function(Object error)? onFailure;

  Future<Json> request(String method, Json params, {
    Duration? timeout,
    void Function(Json result)? onResult,
  }) {
    if (_closed) return Future.error(failure ?? const AcpClosedException());
    final id = _nextId++;
    final pending = _Pending(timeout, () {
      final expired = _pending.remove(id);
      expired?.completeError(
        TimeoutException('ACP $method timed out', timeout),
      );
    }, prompt: method == 'session/prompt', onResult: onResult);
    _pending[id] = pending;
    if (!_consuming) pending.resume();
    _send({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    }).then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        if (_pending.remove(id) == pending) pending.completeError(error, stack);
      },
    );
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
    Duration timeout = const Duration(seconds: 60),
    void Function(String nativeSessionId)? onCreated,
  }) async {
    final result = await request('session/new', {
      'cwd': cwd,
      'mcpServers': <Object>[],
    }, timeout: timeout, onResult: onCreated == null ? null : (result) {
      final native = result['sessionId'];
      if (native is String) onCreated(native);
    });
    if (result['sessionId'] is! String) {
      _fail(AcpProtocolException('invalid session/new result'));
      throw failure!;
    }
    return result['sessionId']! as String;
  }

  // Replay can block on the bounded event consumer. Count active time only,
  // never desktop credit starvation, against the same 60-second bound.
  Future<Json> loadSession(String id, String cwd) => request('session/load', {
    'sessionId': id,
    'cwd': cwd,
    'mcpServers': <Object>[],
  }, timeout: const Duration(seconds: 60));
  Future<Json> resumeSession(String id, String cwd) => request(
    'session/resume',
    {'sessionId': id, 'cwd': cwd, 'mcpServers': <Object>[]},
    timeout: const Duration(seconds: 60),
  );
  Future<AcpPromptResult> prompt(String id, String text) async {
    final result = await request('session/prompt', {
      'sessionId': id,
      'prompt': [
        {'type': 'text', 'text': text},
      ],
    });
    return AcpPromptResult._(result);
  }

  Future<void> cancel(String id) => notify('session/cancel', {'sessionId': id});

  /// Atomically admits pending permission cancellations before session/cancel.
  /// A local refusal throws before any message is accepted; the returned Future
  /// observes native I/O only, so callers can commit their Stop state afterward.
  Future<void> cancelWithPermissions(String id, Iterable<Object> permissionIds) {
    if (_closed) throw failure ?? const AcpClosedException();
    final cancel = {'jsonrpc': '2.0', 'method': 'session/cancel', 'params': {'sessionId': id}};
    final ids = permissionIds.iterator;
    if (!ids.moveNext()) return _admit(cancel);
    final lines = StringBuffer();
    do {
      lines.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': ids.current,
        'result': {'outcome': {'outcome': 'cancelled'}},
      }));
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
    if (bytes.length > unitPipeQueueLimit - _writingBytes) {
      throw RpcException('busy', 'adapter stdin queue exceeds 1 MiB');
    }
    _writingBytes += bytes.length;
    // Invoke the real bounded sink now, in call order. Never retain an
    // unbounded Future chain of permission replies or outgoing requests.
    Future<void> write;
    try {
      write = _write(bytes);
    } on Object catch (error, stack) {
      write = Future.error(error, stack);
    }
    final result = Completer<void>();
    void interrupt() {
      if (!result.isCompleted) {
        result.completeError(failure ?? const AcpClosedException());
      }
    }

    if (_closed) {
      interrupt();
    } else {
      _onClose.add(interrupt);
    }
    write.then<void>(
      (_) {
        _writingBytes -= bytes.length;
        _onClose.remove(interrupt);
        if (!result.isCompleted) result.complete();
      },
      onError: (Object error, StackTrace stack) {
        _writingBytes -= bytes.length;
        _onClose.remove(interrupt);
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    return result.future;
  }

  Future<void> _read() async {
    // Grow only as necessary; a session blocked at the permit retains <=1 MiB
    // plus its one current UnitPipes chunk. Never allocate 16 MiB per session.
    var buffer = Uint8List(65536);
    var length = 0;
    try {
      while (!_closed && await _iterator.moveNext()) {
        final chunk = _iterator.current;
        var start = 0;
        while (start < chunk.length && !_closed) {
          var end = start;
          while (end < chunk.length && chunk[end] != 10) {
            end++;
          }
          var remaining = end - start;
          while (remaining > 0 && !_closed) {
            if (length == acpLargeLineThreshold) {
              if (!await _permit.acquire(this) || _closed) return;
            }
            final capacity = length < acpLargeLineThreshold
                ? acpLargeLineThreshold
                : acpLineLimit;
            final take = remaining < capacity - length
                ? remaining
                : capacity - length;
            if (take == 0) {
              throw AcpProtocolException('message too large (16 MiB limit)');
            }
            final needed = length + take;
            if (needed > buffer.length) {
              var size = buffer.length;
              while (size < needed) {
                size *= 2;
              }
              final grown = Uint8List(size);
              grown.setRange(0, length, buffer);
              buffer = grown;
            }
            buffer.setRange(length, needed, chunk, start);
            length = needed;
            start += take;
            remaining -= take;
          }
          if (_closed) return;
          if (end < chunk.length) {
            // The final parse can overlap close, so the close path also owns
            // release; release is idempotent for an owner and cancelled waiter.
            Object? normalized;
            try {
              // Decode and synchronous normalization live on a separate stack.
              // Do not retain the original decoded (up to 16 MiB) envelope in
              // this async reader frame while bounded consumption waits.
              final dispatched = _decodeAndDispatch(
                Uint8List.sublistView(buffer, 0, length),
              );
              normalized = dispatched is Future<Object?>
                  ? await dispatched
                  : dispatched;
            } finally {
              _permit.release(this);
            }
            length = 0;
            if (buffer.length > acpLargeLineThreshold) {
              buffer = Uint8List(65536);
            }
            if (normalized != null && !_closed) {
              _consuming = true;
              for (final pending in _pending.values) {
                pending.pause();
              }
              try {
                await _untilClosed<void>(
                  Future<void>.sync(
                    () => consumeNotification?.call(normalized!),
                  ),
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
            start = end + 1;
          }
        }
      }
      if (!_closed) {
        if (length != 0) throw AcpProtocolException('output ended mid-line');
        _fail(const AcpClosedException());
      }
    } on Object catch (error) {
      if (!_closed) {
        _fail(
          error is AcpProtocolException
              ? error
              : AcpProtocolException('$error'),
        );
      }
    } finally {
      _permit.release(this);
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
    _pending.remove(id);
    pending.pause();
    if (message.containsKey('error')) {
      if (error is! Json) throw AcpProtocolException('invalid error response');
      pending.completeError(
        AcpRemoteException(error['code']! as int, error['message']! as String),
      );
    } else {
      final response = promptResult ?? result as Json;
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

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _permit.release(this);
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
    _iterator.cancel().ignore();
    _done.complete();
  }
}

class _Pending {
  _Pending(Duration? timeout, this._expired, {required this.prompt, this.onResult})
    : _remaining = timeout,
      _active = timeout == null ? null : Stopwatch();
  final bool prompt;
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
