@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/fixture_harness.dart';
import 'support/pty_session.dart';

const _posixOnly = 'POSIX only';

/// PTY spawn on both OSes (design D2, D3, Risks): the child sees a terminal on
/// 0/1/2, argv arrives unchanged, the size is applied and follows resizes, the
/// output ends when the child exits, and on POSIX the shim reports setup and
/// exec failures instead of an exit status that looks like a result.
void main() {
  late Directory tmp;
  late String exe;
  late File out;
  var counter = 0;
  final sessions = <PtySession>[];
  final units = <PosixUnit>[];

  setUpAll(() async {
    (tmp, exe) = await compileFixtureHost();
  });

  tearDownAll(() => deleteTempDir(tmp));

  setUp(() {
    out = File(p.join(tmp.path, 'out${counter++}.txt'));
  });

  tearDown(() async {
    for (final s in sessions) {
      await s.dispose();
    }
    sessions.clear();
    for (final u in units) {
      await u.terminate();
      final pty = u.pty;
      if (pty != null) {
        closePtyHandle(pty.readHandle);
        closePtyHandle(pty.writeHandle);
      }
    }
    units.clear();
  });

  Future<PtySession> start(
    List<String> fixtureArgs, {
    PtySize size = const PtySize(100, 30),
  }) async {
    final s = await startPtyFixture(
      exe,
      fixtureArgs,
      id: 'pty-$counter',
      out: out,
      size: size,
    );
    sessions.add(s);
    return s;
  }

  Future<PosixUnit> startPosix(List<String> argv, {PtyOptions? options}) async {
    final unit = await spawnPosixUnit(
      shimExecutable: exe,
      containmentId: 'pty-posix-$counter',
      argv: argv,
      pty: options ?? const PtyOptions(size: PtySize(80, 24)),
    );
    units.add(unit);
    return unit;
  }

  test('the child sees a terminal on stdin, stdout and stderr', () async {
    final s = await start(['tty']);
    await s.reader.waitForText('TTY:1:1:1;');
  });

  test('arguments with spaces and quotes arrive unchanged', () async {
    final argv = ['a b', 'say "hi"', r'back\slash\', '', "it's", 'tab\there'];
    final s = await start(['tty', ...argv]);
    final marker = RegExp(r'ARGS:([A-Za-z0-9+/=\s]+);');
    final text = await s.reader.waitFor(
      (t) => marker.hasMatch(t),
      what: 'ARGS marker',
    );
    final b64 = marker
        .firstMatch(text)!
        .group(1)!
        .replaceAll(RegExp(r'\s'), '');
    final received = (jsonDecode(utf8.decode(base64.decode(b64))) as List)
        .cast<String>();
    expect(received, argv);
  });

  test('the initial size is applied', () async {
    final s = await start(['tty'], size: const PtySize(100, 30));
    await s.reader.waitForText('SIZE:100x30;');
  });

  test('a resize is seen by the child', () async {
    final s = await start(['tty']);
    await s.reader.waitForText('SIZE:100x30;');
    ptyResize(s.pty, const PtySize(120, 40));
    await s.reader.waitForText('SIZE:120x40;');
  });

  test('output ends after the child exits', () async {
    final s = await start(['exit', '3']);
    expect(await s.unit.exitCode, 3);
    // ConPTY keeps its output pipe open until the console is closed.
    await s.closeConsole();
    await s.reader.done.timeout(const Duration(seconds: 15));
    expect(s.reader.error, isNull);
  });

  test('bash job control: Ctrl+Z stops a job and fg resumes it', () async {
    final unit = await startPosix(['/bin/bash', '--norc', '--noprofile', '-i']);
    final reader = PtyReader(unit.pty!.readHandle);
    void send(String s) =>
        ptyWrite(unit.pty!.writeHandle, Uint8List.fromList(utf8.encode(s)));

    send('echo ready-\$((20+1))\n');
    await reader.waitForText('ready-21');
    // The quotes keep the typed (echoed) command line from matching the
    // marker, so `started` proves the job is in the foreground group before
    // Ctrl+Z, which bash itself would ignore.
    send('sh -c \'echo star""ted; exec sleep 30\'\n');
    await reader.waitForText('started');
    send('\x1a'); // Ctrl+Z
    await reader.waitForText('Stopped');
    send('fg\n');
    await reader.waitFor(
      // typed line, the Stopped listing, and fg printing the job again
      (t) => t.split('exec sleep 30').length > 3,
      what: 'fg echoing the job',
    );
    send('\x03'); // Ctrl+C ends the resumed sleep
    send('echo after-\$((40+2))\n');
    await reader.waitForText('after-42');
    send('exit\n');
    expect(await unit.exitCode, 0);
    await reader.done.timeout(const Duration(seconds: 15));
  }, skip: Platform.isWindows ? _posixOnly : null);

  group('POSIX shim status pipe', () {
    test('a non-executable file raises SpawnFailed at exec', () async {
      final file = File(p.join(tmp.path, 'not-executable'))
        ..writeAsStringSync('#!/bin/sh\nexit 0\n');
      await Process.run('chmod', ['644', file.path]);
      await expectLater(
        startPosix([file.path]),
        throwsA(
          isA<SpawnFailed>()
              .having((e) => e.stage, 'stage', 'exec')
              .having((e) => e.errno, 'errno', 13),
        ),
      );
    });

    test('a missing program raises SpawnFailed at exec', () async {
      await expectLater(
        startPosix([p.join(tmp.path, 'does-not-exist')]),
        throwsA(
          isA<SpawnFailed>()
              .having((e) => e.stage, 'stage', 'exec')
              .having((e) => e.errno, 'errno', 2),
        ),
      );
    });

    test('an injected slave-open failure raises SpawnFailed', () async {
      await expectLater(
        startPosix(
          ['/bin/sh', '-c', 'exit 0'],
          options: PtyOptions(
            size: const PtySize(80, 24),
            slavePathForTesting: p.join(tmp.path, 'no-such-slave'),
          ),
        ),
        throwsA(
          isA<SpawnFailed>()
              .having((e) => e.stage, 'stage', 'open-slave')
              .having((e) => e.errno, 'errno', 2),
        ),
      );
    });

    for (final status in [126, 127]) {
      test('a program that exits $status spawns and reports $status', () async {
        final unit = await startPosix(['/bin/sh', '-c', 'exit $status']);
        expect(await unit.exitCode, status);
      });
    }
  }, skip: Platform.isWindows ? _posixOnly : null);
}
