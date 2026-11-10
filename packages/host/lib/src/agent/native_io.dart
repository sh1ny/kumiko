import 'dart:async';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';

const nativeLineLimit = 16 * 1024 * 1024;
const nativeLargeLineThreshold = 1024 * 1024;

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

/// Concrete shared NDJSON framing only. The client owns envelope validation,
/// normalization and failure semantics; the session still owns lifecycle.
/// Normalize before releasing the host-wide permit, then await bounded
/// consumption outside it. No broadcast stream or extra input queue.
class NativeLineReader {
  NativeLineReader({
    required Stream<List<int>> input,
    required this.permit,
    required this.normalize,
    required this.consume,
    required this.protocolError,
    required this.onEof,
    required this.onError,
  }) : _iterator = StreamIterator(input);
  final LargeLinePermit permit;
  final StreamIterator<List<int>> _iterator;
  final FutureOr<Object?> Function(Uint8List bytes) normalize;
  final Future<void> Function(Object value) consume;
  final Object Function(String message) protocolError;
  final void Function() onEof;
  final void Function(Object error) onError;
  bool _closed = false;
  bool get largeLineOwned => permit.owns(this);
  bool get largeLineWaiting => permit.isWaiting(this);
  void start() => unawaited(_read());
  void close() {
    _closed = true;
    permit.release(this);
    _iterator.cancel().ignore();
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
            if (length == nativeLargeLineThreshold) {
              if (!await permit.acquire(this) || _closed) return;
            }
            final capacity = length < nativeLargeLineThreshold
                ? nativeLargeLineThreshold
                : nativeLineLimit;
            final take = remaining < capacity - length
                ? remaining
                : capacity - length;
            if (take == 0) {
              throw protocolError('message too large (16 MiB limit)');
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
              final dispatched = normalize(
                Uint8List.sublistView(buffer, 0, length),
              );
              normalized = dispatched is Future<Object?>
                  ? await dispatched
                  : dispatched;
            } finally {
              permit.release(this);
            }
            length = 0;
            if (buffer.length > nativeLargeLineThreshold) {
              buffer = Uint8List(65536);
            }
            if (normalized != null && !_closed) {
              await consume(normalized);
            }
            start = end + 1;
          }
        }
      }
      if (!_closed) {
        if (length != 0) throw protocolError('output ended mid-line');
        onEof();
      }
    } on Object catch (error) {
      if (!_closed) {
        onError(error);
      }
    } finally {
      permit.release(this);
    }
  }
}

/// Byte admission shared by both native clients. No chained write Future or
/// hidden queue: the real bounded sink is invoked synchronously in call order.
/// [beforeWrite] installs correlation only after admission, before observable I/O.
class NativeWriteAdmission {
  NativeWriteAdmission(this._write, this.onFailure, this.closedError);
  final Future<void> Function(List<int>) _write;
  final void Function(Object error) onFailure;
  final Object Function() closedError;
  final _pending = <Completer<void>>{};
  int _bytes = 0;
  bool _closed = false;
  Future<void> admit(List<int> bytes, {void Function()? beforeWrite}) {
    if (_closed) throw closedError();
    if (bytes.length > unitPipeQueueLimit - _bytes) {
      throw RpcException('busy', 'adapter stdin queue exceeds 1 MiB');
    }
    beforeWrite?.call();
    _bytes += bytes.length;
    final result = Completer<void>();
    _pending.add(result);
    Future<void> write;
    try {
      write = _write(bytes);
    } on Object catch (error, stack) {
      write = Future.error(error, stack);
    }
    write.then<void>(
      (_) {
        _bytes -= bytes.length;
        _pending.remove(result);
        if (!result.isCompleted) result.complete();
      },
      onError: (Object error, StackTrace stack) {
        _bytes -= bytes.length;
        _pending.remove(result);
        if (!_closed) onFailure(error);
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    return result.future;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final pending in _pending) {
      if (!pending.isCompleted) pending.completeError(closedError());
    }
    _pending.clear();
  }
}
