import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'libc.dart' as c;
import 'pty.dart';
import 'windows_api.dart' as w;

/// Blocks until output is available on [handle] (a [PtyHandles.readHandle])
/// and returns at most [ptyChunkSize] bytes. Returns null at the end of the
/// output: zero-byte read or `EIO` on POSIX (the slave side closed), a broken
/// pipe on Windows. Throws [PtyIoException] on any other failure.
///
/// The call blocks its isolate's thread; run it on a dedicated reader isolate
/// (design D3). Do not close [handle] while a read is blocked on it.
Uint8List? ptyReadChunk(int handle) {
  final buf = calloc<Uint8>(ptyChunkSize);
  try {
    if (Platform.isWindows) {
      final read = calloc<Uint32>();
      try {
        while (true) {
          final ok = w.readFileNative(handle, buf, ptyChunkSize, read, nullptr);
          if (ok == 0) {
            final err = w.getLastError();
            // GetLastError is unreliable after a call that blocked (the VM's
            // return-from-native transition may overwrite it), so an unknown
            // code (0) counts as the end of the output too.
            if (err == 0 ||
                err == w.errorBrokenPipe ||
                err == w.errorHandleEof ||
                err == w.errorNoData) {
              return null;
            }
            throw PtyIoException('ReadFile', err);
          }
          if (read.value > 0) {
            return Uint8List.fromList(buf.asTypedList(read.value));
          }
        }
      } finally {
        calloc.free(read);
      }
    }
    while (true) {
      final n = c.posixRead(handle, buf, ptyChunkSize);
      if (n > 0) return Uint8List.fromList(buf.asTypedList(n));
      if (n == 0) return null;
      final err = c.errno();
      if (err == c.eintr) continue;
      if (err == c.eio) return null;
      throw PtyIoException('read', err);
    }
  } finally {
    calloc.free(buf);
  }
}

/// Writes all of [data] to [handle] (a [PtyHandles.writeHandle]), blocking
/// while the child does not read its input. Throws [PtyIoException] when the
/// write fails (the other side is gone). Run it on a dedicated writer isolate
/// and pass one chunk of at most [ptyChunkSize] bytes at a time (design D3).
void ptyWrite(int handle, Uint8List data) {
  final buf = calloc<Uint8>(data.isEmpty ? 1 : data.length);
  try {
    buf.asTypedList(data.length).setAll(0, data);
    var offset = 0;
    if (Platform.isWindows) {
      final written = calloc<Uint32>();
      try {
        while (offset < data.length) {
          final ok = w.writeFileNative(
            handle,
            buf + offset,
            data.length - offset,
            written,
            nullptr,
          );
          if (ok == 0) throw PtyIoException('WriteFile', w.getLastError());
          offset += written.value;
        }
      } finally {
        calloc.free(written);
      }
      return;
    }
    while (offset < data.length) {
      final n = c.posixWrite(handle, buf + offset, data.length - offset);
      if (n < 0) {
        final err = c.errno();
        if (err == c.eintr) continue;
        throw PtyIoException('write', err);
      }
      offset += n;
    }
  } finally {
    calloc.free(buf);
  }
}

/// Sets the terminal to [size]: `TIOCSWINSZ` on the master (POSIX, the kernel
/// signals the foreground group with `SIGWINCH`) or `ResizePseudoConsole`
/// (Windows). Throws [PtyIoException] on failure.
void ptyResize(PtyHandles pty, PtySize size) {
  if (Platform.isWindows) {
    final hr = w.resizePseudoConsole(pty.console!, size.packedCoord);
    if (hr != 0) throw PtyIoException('ResizePseudoConsole', hr);
    return;
  }
  if (c.setWindowSize(pty.readHandle, size.cols, size.rows) != 0) {
    throw PtyIoException('ioctl(TIOCSWINSZ)', c.errno());
  }
}

/// Closes a pipe end or descriptor. Call it only once nothing is blocked on
/// the handle. Errors are ignored: nothing useful can be done about them.
void closePtyHandle(int handle) {
  if (Platform.isWindows) {
    w.closeHandleNative(handle);
  } else {
    c.posixClose(handle);
  }
}

/// `ClosePseudoConsole` running on its own short-lived isolate, which owns the
/// `HPCON` for the call (design D3). A close waits for its output to be
/// drained, so it must never run on the reader or main isolate; the reader
/// keeps draining while the closer waits. Windows only.
class ConsoleCloser {
  ConsoleCloser._(this.isolate, this.done);

  /// The closer isolate. While the native call is stuck it cannot be
  /// interrupted; the host keeps this object (and the handles) until [done].
  final Isolate isolate;

  /// Completes when `ClosePseudoConsole` returned (the isolate then exits).
  final Future<void> done;

  /// Starts closing [hpcon].
  static Future<ConsoleCloser> start(int hpcon) async {
    final exit = ReceivePort();
    final isolate = await Isolate.spawn(
      _closeEntry,
      hpcon,
      onExit: exit.sendPort,
    );
    final done = exit.first.then<void>((_) => exit.close());
    return ConsoleCloser._(isolate, done);
  }

  /// True if the close finished within [timeout] (design: 5 s); false leaves
  /// it running in the background.
  Future<bool> completesWithin(Duration timeout) =>
      done.then((_) => true).timeout(timeout, onTimeout: () => false);
}

void _closeEntry(int hpcon) {
  w.closePseudoConsole(hpcon);
}
