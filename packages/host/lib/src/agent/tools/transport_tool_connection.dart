import 'dart:async';
import 'dart:io';

import 'tool_connection.dart';

/// Outbound bytes that may be pending before the connection stops reading
/// further requests (design: Resource Bounds, outbound queue).
const int maxPendingOutboundBytes = 1024 * 1024;

/// How long a final message gets to reach the peer before the transport is
/// torn down (flush, then the peer's EOF). Closing a Windows pipe discards
/// bytes the client has not read yet, so a refusal needs this to be seen.
const Duration finalMessageGrace = Duration(seconds: 1);

/// A writer for [sink] that runs each write (add, then flush) only after the
/// previous one settled. [IOSink] rejects `add` while a flush is pending, so
/// a burst of replies written directly would drop all but the first. Each
/// returned future settles with its own write, including its error.
Future<void> Function(List<int>) serializedSinkWriter(IOSink sink) {
  Future<void> tail = Future<void>.value();
  return (bytes) {
    final done = tail.then((_) {
      sink.add(bytes);
      return sink.flush();
    });
    tail = done.catchError((Object _) {});
    return done;
  };
}

/// Adapts a byte transport (unix `Socket`, Windows pipe connection) to
/// [ToolConnection] and adds the two behaviours both need:
///
/// - backpressure: while more than [maxPending] bytes are queued for the
///   peer, the source is paused, so no further requests are read;
/// - graceful close: when something was written, [close] first waits (bounded
///   by [grace] each) for the writes to flush and for the peer to close, then
///   tears the transport down. A connection that never received a message
///   closes at once.
class TransportToolConnection implements ToolConnection {
  TransportToolConnection({
    required Stream<List<int>> source,
    required this.write,
    required this.closeTransport,
    this.maxPending = maxPendingOutboundBytes,
    this.grace = finalMessageGrace,
  }) {
    _out = StreamController<List<int>>(
      onListen: () => _setConsumerPaused(false),
      onPause: () => _setConsumerPaused(true),
      onResume: () => _setConsumerPaused(false),
      onCancel: () {
        // The service stopped reading. Keep draining so the peer's EOF is
        // still noticed while a final message is being delivered.
        _detached = true;
        _setConsumerPaused(false);
      },
    );
    _src = source.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: false,
    );
    _src.pause(); // until the service listens
    _srcPaused = true;
  }

  final int maxPending;
  final Duration grace;
  final Future<void> Function(List<int>) write;
  final Future<void> Function() closeTransport;

  late final StreamController<List<int>> _out;
  late final StreamSubscription<List<int>> _src;
  final _peerDone = Completer<void>();
  final _outstanding = <Future<void>>{};
  bool _srcPaused = false;
  bool _consumerPaused = true;
  bool _detached = false;
  bool _peerEof = false;
  bool _wrote = false;
  int _pending = 0;
  Future<void>? _closing;

  @override
  Stream<List<int>> get input => _out.stream;

  /// Bytes queued for the peer and not yet accepted by the transport.
  int get pendingBytes => _pending;

  void _setConsumerPaused(bool paused) {
    _consumerPaused = paused;
    _syncPause();
  }

  void _syncPause() {
    final shouldPause =
        !_detached && (_consumerPaused || _pending > maxPending);
    if (shouldPause && !_srcPaused) {
      _src.pause();
      _srcPaused = true;
    } else if (!shouldPause && _srcPaused) {
      _src.resume();
      _srcPaused = false;
    }
  }

  void _onData(List<int> data) {
    if (_detached || _out.isClosed) return;
    _out.add(data);
  }

  void _onError(Object error, StackTrace stack) {
    _markPeerGone();
    if (!_detached && !_out.isClosed) _out.addError(error, stack);
  }

  void _onDone() {
    _markPeerGone();
    if (!_out.isClosed) unawaited(_out.close());
  }

  void _markPeerGone() {
    _peerEof = true;
    if (!_peerDone.isCompleted) _peerDone.complete();
  }

  @override
  void add(List<int> bytes) {
    if (_closing != null) throw StateError('connection is closing');
    _wrote = true;
    _pending += bytes.length;
    final length = bytes.length;
    late final Future<void> tracked;
    tracked = write(bytes).catchError((Object _) {}).whenComplete(() {
      _pending -= length;
      _outstanding.remove(tracked);
      _syncPause();
    });
    _outstanding.add(tracked);
    _syncPause();
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    if (_wrote) {
      // The service has stopped reading by now; make sure we still drain.
      _detached = true;
      _syncPause();
      if (_outstanding.isNotEmpty) {
        await Future.wait(_outstanding.toList())
            .timeout(grace, onTimeout: () => const <void>[]);
      }
      if (!_peerEof) {
        await _peerDone.future.timeout(grace, onTimeout: () {});
      }
    }
    try {
      await closeTransport();
    } on Object {
      // Already gone.
    }
    unawaited(_src.cancel().catchError((Object _) {}));
    if (!_out.isClosed) unawaited(_out.close());
  }
}
