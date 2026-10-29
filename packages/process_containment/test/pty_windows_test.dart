@TestOn('windows')
@Timeout(Duration(minutes: 5))
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/fixture_harness.dart';
import 'support/fixture_lines.dart';
import 'support/pty_session.dart';

final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
final int Function(
  int,
  Pointer<Void>,
  int,
  Pointer<Void>,
  Pointer<Uint32>,
  Pointer<Void>,
)
_peekNamedPipe = _kernel32
    .lookupFunction<
      Int32 Function(
        IntPtr,
        Pointer<Void>,
        Uint32,
        Pointer<Void>,
        Pointer<Uint32>,
        Pointer<Void>,
      ),
      int Function(
        int,
        Pointer<Void>,
        int,
        Pointer<Void>,
        Pointer<Uint32>,
        Pointer<Void>,
      )
    >('PeekNamedPipe');

/// Bytes waiting in [pipe], which nobody reads.
int _pendingBytes(int pipe) {
  final avail = calloc<Uint32>();
  try {
    _peekNamedPipe(pipe, nullptr, 0, nullptr, avail, nullptr);
    return avail.value;
  } finally {
    calloc.free(avail);
  }
}

/// pids of the `conhost.exe` / `OpenConsole.exe` processes this process
/// started (the pseudo-console hosts, design: Failure & Visibility).
Future<List<int>> _consoleHostChildren() async {
  final result = await Process.run('powershell', [
    '-NoProfile',
    '-Command',
    r'Get-CimInstance Win32_Process '
        '-Filter "ParentProcessId=$pid" | '
        r'Where-Object { $_.Name -in "conhost.exe","OpenConsole.exe" } | '
        r'ForEach-Object { $_.ProcessId }',
  ]);
  return (result.stdout as String)
      .split(RegExp(r'\s+'))
      .map(int.tryParse)
      .whereType<int>()
      .toList();
}

/// ConPTY close under saturated output (design D3, Risks): `ClosePseudoConsole`
/// waits for its output to drain, so it runs on a closer isolate while the
/// reader drains on another.
void main() {
  late Directory tmp;
  late String exe;

  setUpAll(() async {
    (tmp, exe) = await compileFixtureHost();
  });

  tearDownAll(() => deleteTempDir(tmp));

  test('closing a pseudo-console nobody reads completes once the reader '
      'drains, and no console host remains', () async {
    final out = File(p.join(tmp.path, 'flood.txt'));
    final unit = spawnWindowsUnit(
      executable: exe,
      args: ['--fixture', 'flood'],
      containmentId: 'pty-flood',
      environment: {'PC_FIXTURE_OUT': out.path},
      pty: const PtyOptions(size: PtySize(100, 30)),
    );
    final pty = unit.pty!;
    addTearDown(unit.close);
    await waitForLines(out, 1);

    // Nobody reads: the child fills the output pipe and blocks.
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (_pendingBytes(pty.readHandle) < 4000) {
      expect(DateTime.now().isBefore(deadline), isTrue, reason: 'pipe fills');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(
      await _consoleHostChildren(),
      isNotEmpty,
      reason: 'the pseudo-console has a host process',
    );

    expect((await unit.terminate()).terminated, isTrue);

    final closer = await ConsoleCloser.start(pty.console!);
    final reader = PtyReader(pty.readHandle, keep: false);
    expect(
      await closer.completesWithin(const Duration(seconds: 5)),
      isTrue,
      reason: 'ClosePseudoConsole returns while the reader drains',
    );
    await reader.done.timeout(const Duration(seconds: 15));
    expect(reader.error, isNull);
    closePtyHandle(pty.readHandle);
    closePtyHandle(pty.writeHandle);

    final until = DateTime.now().add(const Duration(seconds: 10));
    var left = await _consoleHostChildren();
    while (left.isNotEmpty && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      left = await _consoleHostChildren();
    }
    expect(left, isEmpty, reason: 'no conhost/OpenConsole child remains');
  });
}
