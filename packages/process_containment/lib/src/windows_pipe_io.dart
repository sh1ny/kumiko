import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'unit_pipes.dart' show unitPipeChunkSize;
import 'windows_api.dart' as w;

const _next = 1;
const _stop = 2;
const _ready = 3;
const _chunk = 4;
const _written = 5;
const _error = 6;
const _eof = 7;

/// Internal Windows reader: one request permits exactly one native read.
class WindowsPipeReader {
  WindowsPipeReader(int handle) {
    _controller = StreamController<Uint8List>(
      sync: true,
      onListen: () {
        _listening = true;
        _nextChunk();
      },
      onPause: () => _paused = true,
      onResume: () {
        _paused = false;
        _nextChunk();
      },
      onCancel: close,
    );
    _worker = _Worker(handle, true, _message);
    unawaited(
      _worker.ready.then(
        (_) => _nextChunk(),
        onError: (Object error, StackTrace stack) {
          if (!_closed) _controller.addError(error, stack);
          _finish();
        },
      ),
    );
  }

  late final StreamController<Uint8List> _controller;
  late final _Worker _worker;
  bool _listening = false;
  bool _paused = false;
  bool _pending = false;
  bool _closed = false;
  Stream<Uint8List> get stream => _controller.stream;

  void _nextChunk() {
    if (!_closed &&
        _listening &&
        !_paused &&
        !_pending &&
        _worker.commands != null) {
      _pending = true;
      _worker.commands!.send(_next);
    }
  }

  void _message(int tag, Object? value) {
    if (_closed) return;
    if (tag == _chunk) {
      _pending = false;
      _controller.add(
        (value as TransferableTypedData).materialize().asUint8List(),
      );
      _nextChunk();
    } else if (tag == _error) {
      _controller.addError(StateError('pipe read failed: $value'));
    } else if (tag == _eof) {
      _finish();
    }
  }

  void _finish() {
    if (_closed) return;
    _closed = true;
    unawaited(_controller.close());
  }

  Future<void> close() async {
    _finish();
    await _worker.stop();
  }
}

/// Internal Windows writer: a write is acknowledged only after WriteFile
/// accepts the entire chunk. It never accepts a second outstanding chunk.
class WindowsPipeWriter {
  WindowsPipeWriter(int handle) {
    _worker = _Worker(handle, false, (tag, value) {
      final pending = _pending;
      if (tag == _written || tag == _error) {
        _pending = null;
        if (tag == _written) {
          pending?.complete();
        } else {
          pending?.completeError(StateError('pipe write failed: $value'));
        }
      }
    });
    _worker.ready.ignore();
    unawaited(
      _worker.done.then((_) {
        _pending?.completeError(StateError('pipe writer ended'));
        _pending = null;
      }),
    );
  }
  late final _Worker _worker;
  Completer<void>? _pending;
  bool _closed = false;

  Future<void> write(Uint8List bytes) async {
    await _worker.ready;
    if (_closed || _worker.ended) throw StateError('pipe writer is closed');
    if (_pending != null) {
      throw StateError('only one pipe chunk may be in flight');
    }
    if (bytes.length > unitPipeChunkSize) {
      throw ArgumentError('pipe chunk exceeds 64 KiB');
    }
    final pending = _pending = Completer<void>();
    _worker.commands!.send(TransferableTypedData.fromList([bytes]));
    await pending.future;
  }

  Future<void> close() async {
    _closed = true;
    await _worker.stop();
  }

  Future<void> abort() => close();
}

/// The worker exclusively owns the pipe handle after Isolate.spawn succeeds.
/// Stop ends a parked worker immediately, or after its current native call
/// returns. Terminate the containment before abandoning blocked I/O: killing
/// its processes closes their ends and releases ReadFile/WriteFile. Never
/// close a handle underneath a native call, or cancel a Dart isolate's OS
/// thread (the VM may move an isolate between threads across awaits).
class _Worker {
  _Worker(int handle, bool reader, this._onMessage) {
    _port.listen(_message);
    unawaited(_start(handle, reader));
  }
  final void Function(int, Object?) _onMessage;
  final ReceivePort _port = ReceivePort();
  final Completer<void> _readyCompleter = Completer<void>();
  final Completer<void> _done = Completer<void>();
  SendPort? commands;
  bool ended = false;
  bool _stopping = false;
  Future<void> get ready => _readyCompleter.future;
  Future<void> get done => _done.future;

  Future<void> _start(int handle, bool reader) async {
    try {
      await Isolate.spawn(
        _pipeMain,
        (_port.sendPort, handle, reader),
        onExit: _port.sendPort,
        onError: _port.sendPort,
      );
    } on Object catch (error, stack) {
      w.closeHandleNative(handle);
      _readyCompleter.completeError(error, stack);
      _finish();
    }
  }

  void _message(dynamic message) {
    if (message == null) {
      if (!_readyCompleter.isCompleted) {
        _readyCompleter.completeError(
          StateError('pipe worker exited before ready'),
        );
      }
      _onMessage(_eof, null);
      _finish();
      return;
    }
    if (message is List && message.length == 2 && message[0] is int) {
      final tag = message[0] as int;
      if (tag == _ready) {
        commands = message[1] as SendPort;
        _readyCompleter.complete();
        if (_stopping) _requestStop();
      } else {
        _onMessage(tag, message[1] as Object?);
      }
    } else {
      _onMessage(_error, '$message');
    }
  }

  void _requestStop() {
    commands?.send(_stop);
  }

  Future<void> stop() async {
    if (ended) return;
    if (!_stopping) {
      _stopping = true;
      _requestStop();
    }
    await done;
  }

  void _finish() {
    if (ended) return;
    ended = true;
    _port.close();
    _done.complete();
  }
}

Future<void> _pipeMain((SendPort, int, bool) init) async {
  final (out, handle, reader) = init;
  final commands = ReceivePort();
  final buffer = calloc<Uint8>(unitPipeChunkSize);
  final count = calloc<Uint32>();
  var stopping = false;
  var token = false;
  Uint8List? pending;
  Completer<void>? wake;
  // Resolve the error binding before a failing call, as elsewhere in the
  // package: binding it lazily can itself overwrite the thread's last error.
  w.getLastError();
  commands.listen((message) {
    if (message == _stop) {
      stopping = true;
    } else if (message == _next) {
      token = true;
    } else if (message is TransferableTypedData) {
      pending = message.materialize().asUint8List();
    }
    wake?.complete();
    wake = null;
  });
  out.send([_ready, commands.sendPort]);
  try {
    while (!stopping) {
      while (!stopping && (reader ? !token : pending == null)) {
        await (wake = Completer<void>()).future;
      }
      if (stopping) break;
      if (reader) {
        token = false;
        final ok = w.readFileNative(
          handle,
          buffer,
          unitPipeChunkSize,
          count,
          nullptr,
        );
        if (ok == 0) {
          final error = w.getLastError();
          if (error != 0 &&
              error != w.errorBrokenPipe &&
              error != w.errorHandleEof &&
              error != w.errorNoData) {
            out.send([_error, 'ReadFile: $error']);
          }
          break;
        }
        if (count.value == 0) break;
        out.send([
          _chunk,
          TransferableTypedData.fromList([buffer.asTypedList(count.value)]),
        ]);
      } else {
        final bytes = pending!;
        pending = null;
        buffer.asTypedList(bytes.length).setAll(0, bytes);
        var offset = 0;
        while (offset < bytes.length) {
          final ok = w.writeFileNative(
            handle,
            buffer + offset,
            bytes.length - offset,
            count,
            nullptr,
          );
          if (ok == 0 || count.value == 0) {
            out.send([_error, 'WriteFile: ${w.getLastError()}']);
            return;
          }
          offset += count.value;
        }
        out.send([_written, null]);
      }
      // Deliver stop before starting another native call. Terminating the
      // containment releases an already-blocked native read or write.
      await Future<void>.delayed(Duration.zero);
    }
  } finally {
    w.closeHandleNative(handle);
    calloc.free(buffer);
    calloc.free(count);
    commands.close();
    out.send([_eof, null]);
  }
}
