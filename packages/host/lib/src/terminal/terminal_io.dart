import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:process_containment/process_containment.dart';

/// Blocking PTY I/O for one terminal, on isolates of their own (design D3).
/// Each isolate owns the native handle it uses; the main isolate never
/// blocks on a PTY.

const int _next = 1;
const int _discard = 2;
const int _stop = 3;
const int _eof = 0;
const int _written = 1;

class _ReaderInit {
  _ReaderInit(this.out, this.handle, this.suppressEof, this.scripted);
  final SendPort out;
  final int handle;
  final bool suppressEof;
  final List<Uint8List> scripted;
}

/// The reader isolate of one terminal (design D3).
///
/// It starts parked: it reads nothing until [next]. Every [next] lets it read
/// one chunk (at most 64 KiB) and send it, then it parks again, so at most one
/// chunk is ever in flight and a host that grants no `next` stops reading the
/// PTY. After [discard] it reads and drops bytes until the end of output
/// without waiting for tokens.
class PtyReaderIsolate {
  PtyReaderIsolate._(this._commands, this.exited);

  final SendPort _commands;

  /// Completes when the isolate ended: end of output was reported, the read
  /// failed, or it was told to stop. The read handle may be closed after.
  final Future<void> exited;

  /// Starts the reader of [handle]. [onChunk], [onEof] (end of output; never
  /// called with [suppressEof], which models a PTY that never ends) and
  /// [onError] (the read failed; the end of output follows) run on the
  /// calling isolate. [scripted] chunks are yielded, one per [next], before
  /// the first read of [handle] (a test fault).
  static Future<PtyReaderIsolate> start(
    int handle, {
    required void Function(Uint8List chunk) onChunk,
    required void Function() onEof,
    required void Function(String error) onError,
    bool suppressEof = false,
    List<Uint8List> scripted = const [],
  }) async {
    final port = ReceivePort();
    final exit = ReceivePort();
    final exited = exit.first.then<void>((_) => exit.close());
    final ready = Completer<SendPort>();
    port.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
      } else if (message is TransferableTypedData) {
        onChunk(message.materialize().asUint8List());
      } else if (message is String) {
        onError(message);
      } else {
        onEof();
      }
    });
    unawaited(exited.then((_) => port.close()));
    await Isolate.spawn(
      _readerMain,
      _ReaderInit(port.sendPort, handle, suppressEof, scripted),
      onExit: exit.sendPort,
    );
    return PtyReaderIsolate._(await ready.future, exited);
  }

  /// Lets the reader read one more chunk.
  void next() => _commands.send(_next);

  /// Reads and drops until the end of output; never waits for [next].
  void discard() => _commands.send(_discard);
}

Future<void> _readerMain(_ReaderInit init) async {
  final commands = ReceivePort();
  init.out.send(commands.sendPort);
  var tokens = 0;
  var discarding = false;
  var scripted = 0;
  Completer<void>? wake;
  commands.listen((message) {
    if (message == _next) {
      tokens++;
    } else if (message == _discard) {
      discarding = true;
    }
    wake?.complete();
    wake = null;
  });
  try {
    while (true) {
      while (tokens == 0 && !discarding) {
        await (wake = Completer<void>()).future;
      }
      if (tokens > 0) tokens--;
      final chunk = scripted < init.scripted.length
          ? init.scripted[scripted++]
          : ptyReadChunk(init.handle);
      if (chunk == null) {
        if (init.suppressEof) {
          // A PTY that never reaches the end of its output: keep "reading"
          // until told to stop.
          while (!discarding) {
            await (wake = Completer<void>()).future;
          }
          return;
        }
        init.out.send(_eof);
        return;
      }
      if (!discarding) {
        init.out.send(TransferableTypedData.fromList([chunk]));
      }
      // Let a command that arrived during the blocking read be seen.
      await Future<void>.delayed(Duration.zero);
    }
  } on PtyIoException catch (e) {
    init.out.send('$e');
    init.out.send(_eof);
  } finally {
    commands.close();
  }
}

class _WriterInit {
  _WriterInit(this.out, this.handle);
  final SendPort out;
  final int handle;
}

/// A PTY write failed or the writer died.
class PtyWriteFailed implements Exception {
  PtyWriteFailed(this.detail);
  final String detail;

  @override
  String toString() => 'PTY write failed: $detail';
}

/// The writer isolate of one terminal: it takes one chunk at a time and
/// answers when the native write returned (design D3). A shell that does not
/// read its input keeps the chunk, and so the caller waiting for the answer.
class PtyWriterIsolate {
  PtyWriterIsolate._(this._commands, this.exited);

  final SendPort _commands;

  /// Completes when the isolate ended. The write handle may be closed after.
  final Future<void> exited;
  Completer<void>? _pending;

  static Future<PtyWriterIsolate> start(int handle) async {
    final port = ReceivePort();
    final exit = ReceivePort();
    final exited = exit.first.then<void>((_) => exit.close());
    final ready = Completer<SendPort>();
    PtyWriterIsolate? writer;
    port.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
      } else {
        writer?._onReply(message);
      }
    });
    unawaited(
      exited.then((_) {
        port.close();
        writer?._onDone();
      }),
    );
    await Isolate.spawn(
      _writerMain,
      _WriterInit(port.sendPort, handle),
      onExit: exit.sendPort,
    );
    return writer = PtyWriterIsolate._(await ready.future, exited);
  }

  void _onReply(Object? message) {
    final pending = _pending;
    _pending = null;
    if (pending == null) return;
    if (message == _written) {
      pending.complete();
    } else {
      pending.completeError(PtyWriteFailed('$message'));
    }
  }

  void _onDone() {
    final pending = _pending;
    _pending = null;
    pending?.completeError(PtyWriteFailed('the writer ended'));
  }

  /// Writes [chunk] (at most 64 KiB) and completes when it is written. Only
  /// one write may be outstanding.
  Future<void> write(Uint8List chunk) {
    assert(_pending == null, 'one chunk at a time');
    final pending = _pending = Completer<void>();
    _commands.send(TransferableTypedData.fromList([chunk]));
    return pending.future;
  }

  /// Ends the isolate once its current write returned.
  void stop() => _commands.send(_stop);
}

void _writerMain(_WriterInit init) {
  final commands = ReceivePort();
  init.out.send(commands.sendPort);
  commands.listen((message) {
    if (message is TransferableTypedData) {
      try {
        ptyWrite(init.handle, message.materialize().asUint8List());
        init.out.send(_written);
      } on PtyIoException catch (e) {
        init.out.send('$e');
      }
    } else if (message == _stop) {
      commands.close();
    }
  });
}
