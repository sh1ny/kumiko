@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/fixture_harness.dart';
import 'support/pty_session.dart';

/// Unit process listing at the real containment boundary (change
/// `app-exit-and-reopen` design D2, ADR 0014 decisions 4-7): the processes a
/// terminal unit holds besides its shell, their image names, and whether the
/// leader still runs the shell's image.
void main() {
  String? shim;
  late Directory tmp;

  setUpAll(() async {
    String exe;
    (tmp, exe) = await compileFixtureHost();
    shim = exe; // pc_main runs the --unit-exec shim on POSIX
  });

  tearDownAll(() => deleteTempDir(tmp));

  /// Polls [read] until [done] holds for its result, or 15 s pass.
  Future<UnitProcesses> settle(
    UnitProbe probe,
    bool Function(UnitProcesses r) done, {
    String? what,
  }) async {
    final until = DateTime.now().add(const Duration(seconds: 15));
    var r = readUnitProcesses(probe);
    while (!done(r) && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      r = readUnitProcesses(probe);
    }
    if (!done(r)) {
      fail(
        'timed out waiting for ${what ?? 'state'}: leader ${r.leader} '
        '${r.leaderName}, others ${r.others.map(_named).toList()}',
      );
    }
    return r;
  }

  group('Windows', () {
    test('an idle PowerShell unit lists only its shell; the console host is '
        'not in the unit job', () async {
      final unit = spawnWindowsUnit(
        executable: _powershell(),
        args: ['-NoLogo', '-NoProfile', '-NoExit'],
        containmentId: 'up-idle-pwsh',
        pty: const PtyOptions(size: PtySize(100, 30)),
      );
      final session = PtySession(unit, unit.pty!);
      addTearDown(session.dispose);
      session.write('echo READY\r');
      await session.reader.waitForText('READY');

      final probe = UnitProbe(leaderPid: unit.pid, job: unit.jobHandle);
      final r = readUnitProcesses(probe);
      // ADR 0014 records this measurement (OpenConsole membership).
      // ignore: avoid_print
      print(
        'measured: idle PowerShell unit job pids '
        '${[unit.pid, ...r.others].map(_named).toList()}',
      );
      final consoles = await _consoleHostChildren();
      // ignore: avoid_print
      print(
        'measured: console hosts started by this process '
        '${consoles.map(_named).toList()}, in the unit job: '
        '${consoles.where((c) => isPidInJob(c, unit.jobHandle)).toList()}',
      );
      expect(consoles, isNotEmpty, reason: 'the console host runs');
      for (final c in consoles) {
        expect(isPidInJob(c, unit.jobHandle), isFalse, reason: _named(c));
      }
      expect(r.leader, LeaderState.shell);
      expect(
        r.others,
        isEmpty,
        reason: 'others: ${r.others.map(_named).toList()}',
      );
      expect(processImageName(unit.pid), 'powershell.exe');
    });

    test('a program the shell runs is listed with its image name', () async {
      final unit = spawnWindowsUnit(
        executable: _cmd(),
        args: ['/d', '/k'],
        containmentId: 'up-child-cmd',
        pty: const PtyOptions(size: PtySize(100, 30)),
      );
      final session = PtySession(unit, unit.pty!);
      addTearDown(session.dispose);
      session.write('ping -n 60 127.0.0.1\r');
      final probe = UnitProbe(leaderPid: unit.pid, job: unit.jobHandle);
      final r = await settle(
        probe,
        (r) => r.others.any((pid) => processImageName(pid) == 'PING.EXE'),
        what: 'PING.EXE in the unit',
      );
      expect(r.leader, LeaderState.shell);
      expect(r.others, orderedEquals([...r.others]..sort()));
      expect(r.others, isNot(contains(unit.pid)));
    });

    test('a unit whose processes all ended reads leader gone', () async {
      final unit = spawnWindowsUnit(
        executable: _cmd(),
        args: ['/d', '/c', 'exit 0'],
        containmentId: 'up-gone',
        pty: const PtyOptions(size: PtySize(80, 24)),
      );
      final session = PtySession(unit, unit.pty!);
      addTearDown(session.dispose);
      await unit.exitCode.timeout(const Duration(seconds: 10));
      final r = readUnitProcesses(
        UnitProbe(leaderPid: unit.pid, job: unit.jobHandle),
      );
      expect(r.leader, LeaderState.gone);
      expect(r.others, isEmpty);
    });
  }, testOn: 'windows');

  group('POSIX', () {
    Future<(PosixUnit, PtySession, UnitProbe)> startSh(
      String id, {
      List<String> args = const ['-i'],
      Map<String, String>? environment,
    }) async {
      // macOS's /bin/sh is a launcher that re-executes the real shell, so its
      // image would never match. bash is the image it starts as.
      final sh = _posixExecutable(Platform.isMacOS ? 'bash' : 'sh');
      final expected = executableIdentity(sh);
      expect(expected, isNotNull, reason: 'identity of $sh');
      final unit = await spawnPosixUnit(
        shimExecutable: shim!,
        containmentId: id,
        // No rc files on macOS: what a machine's profile starts is not this
        // test's subject, and the CI image's starts child shells.
        argv: [
          sh,
          if (Platform.isMacOS) ...const ['--norc', '--noprofile'],
          ...args,
        ],
        environment: {'PS1': r'$ ', ...?environment},
        pty: const PtyOptions(size: PtySize(100, 30)),
      );
      final session = PtySession(unit, unit.pty!);
      addTearDown(session.dispose);
      return (
        unit,
        session,
        UnitProbe(leaderPid: unit.pid, expectedLeader: expected),
      );
    }

    test('an idle shell lists only its leader, running the shell', () async {
      final (_, session, probe) = await startSh('up-idle-sh');
      session.write('echo READY\n');
      await session.reader.waitForText('READY');
      final r = readUnitProcesses(probe);
      expect(r.leader, LeaderState.shell);
      expect(
        r.others,
        isEmpty,
        reason: r.others.map(_named).toList().toString(),
      );
    });

    test('a foreground program and a background job are listed with their '
        'image names', () async {
      final (unit, session, probe) = await startSh('up-children');
      session.write('sleep 600 &\n');
      final r1 = await settle(
        probe,
        (r) => r.others.any((pid) => processImageName(pid) == 'sleep'),
        what: 'background sleep',
      );
      expect(r1.leader, LeaderState.shell);
      expect(r1.others, isNot(contains(unit.pid)));
    });

    test(
      'exec replaces the leader image and reads replaced with its name',
      () async {
        final (_, session, probe) = await startSh('up-exec');
        session.write('exec sleep 600\n');
        final r = await settle(
          probe,
          (r) => r.leader == LeaderState.replaced,
          what: 'leader replaced',
        );
        expect(r.leaderName, 'sleep');
        expect(r.others, isEmpty);
      },
    );

    test('an exec before the first read is still seen against the identity '
        'resolved before spawn', () async {
      final (_, _, probe) = await startSh(
        'up-startup-exec',
        args: ['-c', 'exec sleep 600'],
      );
      final r = await settle(
        probe,
        (r) => r.leader == LeaderState.replaced,
        what: 'leader replaced',
      );
      expect(r.leaderName, 'sleep');
    });

    test('a leader without an expected identity reads unreadable', () async {
      final (unit, session, _) = await startSh('up-no-identity');
      session.write('echo READY\n');
      await session.reader.waitForText('READY');
      final r = readUnitProcesses(UnitProbe(leaderPid: unit.pid));
      expect(r.leader, LeaderState.unreadable);
    });

    test('a zombie of the session is not listed', () async {
      // The child exits at once and the shell (exec'd sleep) never reaps it.
      final (_, _, probe) = await startSh(
        'up-zombie',
        args: ['-c', 'sh -c "exit 0" & exec sleep 600'],
      );
      final r = await settle(
        probe,
        (r) => r.leader == LeaderState.replaced,
        what: 'leader replaced',
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final again = readUnitProcesses(probe);
      expect(again.others, isEmpty, reason: 'zombies excluded');
      expect(r.leaderName, 'sleep');
    });
  }, testOn: 'linux || mac-os');
}

/// pids of the `conhost.exe` / `OpenConsole.exe` processes this process
/// started: the pseudo-console hosts.
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

String _named(int pid) => '$pid:${processImageName(pid)}';

String _powershell() {
  final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
  return p.join(
    root,
    'System32',
    'WindowsPowerShell',
    'v1.0',
    'powershell.exe',
  );
}

String _cmd() =>
    Platform.environment['ComSpec'] ?? r'C:\Windows\System32\cmd.exe';

String _posixExecutable(String name) {
  for (final dir in const ['/bin', '/usr/bin']) {
    final path = '$dir/$name';
    if (File(path).existsSync()) return path;
  }
  throw StateError('$name not found');
}
