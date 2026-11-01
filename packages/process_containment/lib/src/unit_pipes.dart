import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'windows_pipe_io.dart';

/// Maximum native read/write chunk, and maximum queued caller input.
const unitPipeChunkSize = 64 * 1024;
const unitPipeQueueLimit = 1024 * 1024;

/// Caller-owned standard I/O of a unit launched with `pipes: true`.
///
/// stdout and stderr are independent, single-subscription byte streams.
/// Pausing either stream stops that pipe's reader; Windows permits only one
/// 64 KiB native read in flight. Stdin writes are ordered, acknowledged only
/// after the OS accepts them, and bounded to one native chunk plus 1 MiB of
/// queued input. No bytes are logged or discarded by the unit manager.
///
/// Keep this endpoint even after the unit leaves the manager's live map.
/// Process exit does NOT close the output streams: consume them through EOF
/// to receive trailing bytes. Pending stdin writes fail at process exit even
/// if the native flush never completes. Close stdin to send EOF without
/// killing the child. After terminating the containment, call [close] to
/// abandon any unread output and release all remaining pipe resources.
/// Closing a unit's job/process handles alone does not take ownership of
/// these streams.
class UnitPipes {
  UnitPipes._(this.stdin, this.stdout, this.stderr, this._dispose);

  /// Wraps the existing POSIX Process pipes; never reads the shim's stdout
  /// as an exec-status channel. Intended for the spawn implementation.
  factory UnitPipes.process(Process process) {
    final writer = _ProcessPipeWriter(process.stdin);
    final input = UnitPipeSink._(
      writer.write,
      writer.close,
      abort: writer.close,
    );
    unawaited(
      process.exitCode
          .then((_) {
            writer.processExited();
            return input.close();
          })
          .then<void>((_) {}, onError: (Object _) {}),
    );
    final output = _ProcessOutput(process.stdout);
    final errors = _ProcessOutput(process.stderr);
    return UnitPipes._(input, output.stream, errors.stream, () async {
      await Future.wait([output.close(), errors.close(), input._abortInput()]);
    });
  }

  /// Takes ownership of three non-inheritable Windows parent pipe ends.
  /// Every blocking read/write runs on a dedicated isolate, which closes its
  /// handle after its final native call. Intended for the spawn implementation.
  factory UnitPipes.windows(
    int input,
    int output,
    int errors,
    Future<int> exit,
  ) {
    final writer = WindowsPipeWriter(input);
    final sink = UnitPipeSink._(
      writer.write,
      writer.close,
      abort: writer.abort,
    );
    final stdout = WindowsPipeReader(output);
    final stderr = WindowsPipeReader(errors);
    unawaited(
      exit
          .then((_) {
            writer.processExited();
            return sink.close();
          })
          .then<void>((_) {}, onError: (Object _) {}),
    );
    return UnitPipes._(sink, stdout.stream, stderr.stream, () async {
      await Future.wait([stdout.close(), stderr.close(), sink._abortInput()]);
    });
  }

  final UnitPipeSink stdin;
  final Stream<Uint8List> stdout;
  final Stream<Uint8List> stderr;
  final Future<void> Function() _dispose;
  Future<void>? _closed;

  /// Releases this endpoint once, without waiting for paused listeners.
  /// Terminate the containment first if a native read or write may be blocked.
  /// Workers close their handles only after the current native call returns.
  Future<void> close() => _closed ??= _dispose();
}

/// Ordered, bounded byte sink. [write] snapshots the bytes before returning;
/// callers may reuse their buffer immediately. Await the returned future for
/// backpressure. Queue overflow fails that write with [StateError], before
/// any of its bytes are accepted; the caller can map it to its `busy` error.
class UnitPipeSink {
  UnitPipeSink._(this._write, this._close, {Future<void> Function()? abort})
    : _abort = abort ?? _close;

  final Future<void> Function(Uint8List) _write;
  final Future<void> Function() _close;
  final Future<void> Function() _abort;
  final Queue<_Input> _queue = Queue<_Input>();
  int _queuedBytes = 0;
  bool _accepting = true;
  bool _aborted = false;
  Object? _error;
  Future<void>? _running;
  Future<void>? _closed;

  /// Writes at most [unitPipeQueueLimit] bytes, split into native chunks.
  Future<void> write(List<int> bytes) {
    if (!_accepting || _error != null) {
      return Future.error(_error ?? StateError('pipe stdin is closed'));
    }
    if (bytes.length > unitPipeQueueLimit - _queuedBytes) {
      return Future.error(StateError('pipe stdin queue exceeds 1 MiB'));
    }
    if (bytes.isEmpty) return Future.value();
    final input = _Input(Uint8List.fromList(bytes));
    _queue.add(input);
    _queuedBytes += bytes.length;
    _running ??= _pump();
    return input.done.future;
  }

  Future<void> _pump() async {
    try {
      while (_queue.isNotEmpty && !_aborted) {
        final input = _queue.first;
        while (input.offset < input.bytes.length && !_aborted) {
          final end = input.bytes.length - input.offset > unitPipeChunkSize
              ? input.offset + unitPipeChunkSize
              : input.bytes.length;
          final chunk = Uint8List.sublistView(input.bytes, input.offset, end);
          input.offset = end;
          await _write(chunk);
        }
        if (_aborted) break;
        _queue.removeFirst();
        // Charge the entire retained snapshot until it is released, rather
        // than allowing already-written prefixes to hide retained memory.
        _queuedBytes -= input.bytes.length;
        input.done.complete();
      }
    } on Object catch (error, stack) {
      _error = error;
      _failQueue(error, stack);
    } finally {
      _running = null;
    }
  }

  void _failQueue(Object error, [StackTrace? stack]) {
    while (_queue.isNotEmpty) {
      _queue.removeFirst().done.completeError(error, stack);
    }
    _queuedBytes = 0;
  }

  /// Sends EOF after every accepted write completes. Idempotent.
  Future<void> close() {
    _accepting = false;
    return _closed ??= (() async {
      await _running;
      await _close();
    })();
  }

  /// Abandons queued input. Terminate the containment first if a write is
  /// blocked; its closed read ends release the native writer on either OS.
  Future<void> _abortInput() async {
    if (!_aborted) {
      _accepting = false;
      _aborted = true;
      _error ??= StateError('pipe stdin was closed');
      // Join the native writer before releasing its handle. Killing the
      // containment, not closing a live native handle, unblocks its write.
      try {
        await Future.wait([_abort(), ?_running]);
      } finally {
        _failQueue(_error!);
      }
    } else {
      await _running;
    }
  }
}

/// The SDK destroys a process's stdin socket at exit. If that cancels a
/// blocked socket consumer before EPIPE arrives, its flush/close future may
/// never settle. Keep one outstanding acknowledgement, completed by either
/// the native operation or process exit, without adding an exit listener for
/// every write. The SDK has already released the native socket at exit.
class _ProcessPipeWriter {
  _ProcessPipeWriter(this._input) {
    // Native errors are forwarded to the operation's original caller below.
    _input.done.ignore();
  }

  final IOSink _input;
  Completer<void>? _pending;
  bool _exited = false;
  bool _closing = false;

  void processExited() {
    _exited = true;
    final pending = _pending;
    if (pending == null || pending.isCompleted) return;
    if (_closing) {
      pending.complete();
    } else {
      pending.completeError(StateError('pipe stdin closed on process exit'));
    }
  }

  Future<void> write(Uint8List bytes) {
    if (_exited) {
      return Future.error(StateError('pipe stdin closed on process exit'));
    }
    _input.add(bytes);
    return _wait(_input.flush());
  }

  Future<void> close() {
    _closing = true;
    if (_exited) return Future.value();
    return _wait(_input.close());
  }

  Future<void> _wait(Future<dynamic> native) async {
    final pending = _pending = Completer<void>();
    unawaited(
      native.then<void>(
        (_) {
          if (!pending.isCompleted) pending.complete();
        },
        onError: (Object error, StackTrace stack) {
          if (!pending.isCompleted) pending.completeError(error, stack);
        },
      ),
    );
    try {
      await pending.future;
    } finally {
      _pending = null;
    }
  }
}

class _Input {
  _Input(this.bytes);
  final Uint8List bytes;
  final Completer<void> done = Completer<void>();
  int offset = 0;
}

/// A forwarding subscription lets disposal also release never-listened pipes,
/// without attempting a second listen on streams already consumed by callers.
class _ProcessOutput {
  _ProcessOutput(Stream<List<int>> source) {
    _controller = StreamController<Uint8List>(
      sync: true,
      onListen: () {
        _subscription = source.listen(
          (bytes) {
            _controller.add(
              bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
            );
          },
          onError: _controller.addError,
          onDone: () {
            _ended = true;
            unawaited(_controller.close());
          },
        );
      },
      onPause: () => _subscription?.pause(),
      onResume: () => _subscription?.resume(),
      onCancel: () => _subscription?.cancel(),
    );
    _source = source;
  }
  late final Stream<List<int>> _source;
  late final StreamController<Uint8List> _controller;
  StreamSubscription<List<int>>? _subscription;
  bool _ended = false;
  Stream<Uint8List> get stream => _controller.stream;

  Future<void> close() async {
    if (_ended) return;
    _ended = true;
    await (_subscription ??= _source.listen((_) {})).cancel();
    unawaited(_controller.close());
  }
}
