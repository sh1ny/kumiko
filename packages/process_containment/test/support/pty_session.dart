import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:process_containment/process_containment.dart';

import 'hang_guard.dart';

/// Reads one PTY output handle on its own isolate (the shape of the host's
/// reader isolate, design D3) and accumulates what arrives.
class PtyReader {
  /// A reader with no handle behind it, for testing [PtySession] itself: its
  /// output has already ended when [ended] is true, and never ends otherwise.
  PtyReader.detached({bool ended = false}) {
    if (ended) _done.complete();
  }

  /// With [keep] false the bytes are dropped instead of accumulated, for a
  /// drain that may see a lot of output.
  PtyReader(int handle, {bool keep = true}) {
    final port = ReceivePort();
    port.listen((message) {
      if (message is TransferableTypedData) {
        final data = message.materialize().asUint8List();
        if (keep) _bytes.add(data);
        for (final w in List.of(_waiters)) {
          w();
        }
      } else if (message is String) {
        error = message;
      } else {
        // null: end of output.
        port.close();
        _done.complete();
        for (final w in List.of(_waiters)) {
          w();
        }
      }
    });
    Isolate.spawn(_readLoop, (port.sendPort, handle)).then(
      (_) {},
      onError: (Object e) {
        error = '$e';
        _done.complete();
      },
    );
  }

  final _bytes = BytesBuilder();
  final _done = Completer<void>();
  final _waiters = <void Function()>[];

  /// Set when the read failed for a reason other than end of output.
  String? error;

  /// Completes at end of output (EOF, `EIO` or a broken pipe).
  Future<void> get done => _done.future;

  bool get atEof => _done.isCompleted;

  /// Everything read so far, with terminal escape sequences removed.
  String get text =>
      stripEscapes(utf8.decode(_bytes.toBytes(), allowMalformed: true));

  /// Completes with the text once [test] holds for it. Fails at once if
  /// output ends first, and under [hangGuard] if neither happens.
  Future<String> waitFor(bool Function(String text) test, {String? what}) {
    final completer = Completer<String>();
    void check() {
      if (completer.isCompleted) return;
      if (test(text)) {
        completer.complete(text);
      } else if (atEof) {
        completer.completeError(
          StateError('output ended without ${what ?? 'match'}: ${_show()}'),
        );
      }
    }

    _waiters.add(check);
    check();
    return guarded(
      completer.future,
      what ?? 'match',
      state: _show,
    ).whenComplete(() => _waiters.remove(check));
  }

  Future<String> waitForText(String needle) =>
      waitFor((t) => t.contains(needle), what: needle);

  String _show() =>
      jsonEncode(text.length > 600 ? text.substring(text.length - 600) : text);
}

void _readLoop((SendPort, int) args) {
  final (port, handle) = args;
  try {
    while (true) {
      final chunk = ptyReadChunk(handle);
      if (chunk == null) {
        port.send(null);
        return;
      }
      port.send(TransferableTypedData.fromList([chunk]));
    }
  } on PtyIoException catch (e) {
    port.send('$e');
    port.send(null);
  }
}

final _escapes = RegExp(
  r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)|\x1B\[[0-?]*[ -/]*[@-~]|'
  r'\x1B[()][A-Za-z0-9]|\x1B[=>78MNOPXZc]',
);

/// Removes CSI, OSC and charset escape sequences, so assertions see the text a
/// child printed even when ConPTY interleaves cursor movement.
String stripEscapes(String s) => s.replaceAll(_escapes, '');

/// A fixture unit attached to a PTY with a reader running.
class PtySession {
  /// [reader], [drain] and [closeHandle] replace the real reader, the
  /// end-of-output wait under [hangGuard] and [closePtyHandle]; only this
  /// file's own tests pass them.
  PtySession(
    this.unit,
    this.pty, {
    PtyReader? reader,
    Drain? drain,
    void Function(int handle)? closeHandle,
  }) : reader = reader ?? PtyReader(pty.readHandle),
       _drain = drain ?? guarded,
       _closeHandle = closeHandle ?? closePtyHandle;

  final ContainedUnit unit;
  final PtyHandles pty;
  final PtyReader reader;
  final Drain _drain;
  final void Function(int handle) _closeHandle;
  ConsoleCloser? _closer;

  void write(String text) {
    ptyWrite(pty.writeHandle, Uint8List.fromList(utf8.encode(text)));
  }

  /// Closes the pseudo-console (Windows) so its output pipe ends. Needed for
  /// EOF after the child exited: ConPTY keeps the pipe open until then.
  Future<void> closeConsole() async {
    final hpcon = pty.console;
    if (hpcon == null || _closer != null) return;
    _closer = await ConsoleCloser.start(hpcon);
    await guarded(
      _closer!.done,
      'console close (ClosePseudoConsole)',
      state: reader._show,
    );
  }

  /// Ends the unit, drains the reader and releases the handles.
  ///
  /// If a step fails (output does not end under [hangGuard], the console does
  /// not close, the unit does not terminate), it still closes the write handle
  /// and the Windows unit, leaves the read handle open unless output ended
  /// (the reader isolate may be blocked reading it), and then fails naming
  /// the unit and the step's error.
  Future<void> dispose() async {
    Object? failure;
    try {
      await unit.terminate();
      await closeConsole();
      await _drain(
        reader.done,
        'end of output after dispose',
        state: reader._show,
      );
    } on Object catch (e) {
      failure = e;
    }
    if (reader.atEof) {
      _closeHandle(pty.readHandle);
    }
    _closeHandle(pty.writeHandle);
    final u = unit;
    if (u is WindowsUnit) u.close();
    if (failure != null) {
      throw StateError(
        'PTY session of unit pid ${unit.pid} was not disposed cleanly: '
        '$failure',
      );
    }
  }
}

/// The end-of-output wait of [PtySession.dispose]: [guarded] unless a test
/// replaces it.
typedef Drain = Future<void> Function(
  Future<void> done,
  String what, {
  String Function()? state,
});

/// Starts the fixture host [exe] with `--fixture <fixtureArgs>` as a PTY unit
/// on the current OS.
Future<PtySession> startPtyFixture(
  String exe,
  List<String> fixtureArgs, {
  required String id,
  required File out,
  PtySize size = const PtySize(100, 30),
}) async {
  final environment = {'PC_FIXTURE_OUT': out.path};
  if (Platform.isWindows) {
    final unit = spawnWindowsUnit(
      executable: exe,
      args: ['--fixture', ...fixtureArgs],
      containmentId: id,
      environment: environment,
      pty: PtyOptions(size: size),
    );
    return PtySession(unit, unit.pty!);
  }
  final unit = await spawnPosixUnit(
    shimExecutable: exe,
    containmentId: id,
    argv: [exe, '--fixture', ...fixtureArgs],
    environment: environment,
    pty: PtyOptions(size: size),
  );
  return PtySession(unit, unit.pty!);
}
