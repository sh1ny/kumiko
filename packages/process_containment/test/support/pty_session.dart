import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:process_containment/process_containment.dart';

/// Reads one PTY output handle on its own isolate (the shape of the host's
/// reader isolate, design D3) and accumulates what arrives.
class PtyReader {
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

  /// Completes with the text once [test] holds for it.
  Future<String> waitFor(
    bool Function(String text) test, {
    Duration timeout = const Duration(seconds: 20),
    String? what,
  }) {
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
    return completer.future
        .timeout(
          timeout,
          onTimeout: () => throw StateError(
            'timed out waiting for ${what ?? 'match'}: ${_show()}',
          ),
        )
        .whenComplete(() => _waiters.remove(check));
  }

  Future<String> waitForText(String needle, {Duration? timeout}) => waitFor(
    (t) => t.contains(needle),
    what: needle,
    timeout: timeout ?? const Duration(seconds: 20),
  );

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
  PtySession(this.unit, this.pty) : reader = PtyReader(pty.readHandle);

  final ContainedUnit unit;
  final PtyHandles pty;
  final PtyReader reader;
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
    await _closer!.done.timeout(const Duration(seconds: 15));
  }

  /// Ends the unit, drains the reader and releases the handles.
  Future<void> dispose() async {
    await unit.terminate();
    await closeConsole();
    await reader.done.timeout(const Duration(seconds: 15), onTimeout: () {});
    if (reader.atEof) {
      closePtyHandle(pty.readHandle);
    }
    closePtyHandle(pty.writeHandle);
    final u = unit;
    if (u is WindowsUnit) u.close();
  }
}

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
