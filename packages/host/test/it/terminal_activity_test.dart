import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/harness.dart';
import 'support/terminal_support.dart';

/// `terminal/activity` (change `app-exit-and-reopen` design D2, ADR 0014
/// decisions 4-7): whether each terminal holds a process besides its shell,
/// read on demand under a 1 s deadline with one read in flight per host.
void main() {
  setUpAll(buildTestHost);

  late Directory profile;
  late Directory work;
  late Directory home;
  setUp(() {
    profile = tempDir('activity_profile_');
    work = tempDir('activity_work_');
    home = tempDir('activity_home_');
  });
  tearDown(() async {
    killReported(work);
    await deleteTree(work);
    await deleteTree(home);
    await deleteTree(profile);
  });

  Future<Desktop> start() async {
    final desktop = await Desktop.start(
      profile,
      environment: {
        'USERPROFILE': home.path,
        'HOME': home.path,
        'TERM_FIXTURE_HOST': testHostExecutable(),
      },
    );
    addTearDown(desktop.dispose);
    await desktop.waitState();
    await desktop.saveFixtureProfile(cwd: work.path);
    return desktop;
  }

  /// A terminal running the OS's own shell: `cmd.exe` on Windows, `/bin/bash` on macOS, `/bin/sh`
  /// interactive elsewhere, with [env] in its environment.
  Future<OpenTerminal> realShell(
    Desktop desktop, {
    Map<String, String> env = const {},
  }) async {
    await desktop.saveProfile(
      ShellProfile(
        id: 'real',
        name: 'Real shell',
        executable: Platform.isWindows
            ? (Platform.environment['ComSpec'] ??
                  r'C:\Windows\System32\cmd.exe')
            // macOS's /bin/sh re-executes the real shell, which reads as replaced.
            : (Platform.isMacOS ? '/bin/bash' : '/bin/sh'),
        args: Platform.isWindows
            ? const ['/d', '/q', '/k']
            : Platform.isMacOS
            ? const ['--norc', '--noprofile', '-i']
            : const ['-i'],
        cwd: work.path,
        env: {if (!Platform.isWindows) 'PS1': r'$ ', ...env},
      ),
    );
    final t = await desktop.openTerminal('real');
    await t.send(_marker('READY', 'SHELL'));
    await t.waitForText('READYSHELL');
    return t;
  }

  Future<List<TerminalActivity>> activity(
    Desktop desktop,
    List<String> ids,
  ) async => TerminalActivityResult.fromJson(
    (await desktop.connection.request(
          Method.terminalActivity,
          TerminalActivityParams(ids).toJson(),
        ))!
        as Json,
  ).terminals;

  Future<TerminalActivity> one(Desktop desktop, String id) async =>
      (await activity(desktop, [id])).single;

  /// Polls until [id] reads [state], and returns that read.
  Future<TerminalActivity> until(
    Desktop desktop,
    String id,
    bool Function(TerminalActivity a) done,
  ) async {
    late TerminalActivity last;
    await eventually(() async {
      try {
        last = await one(desktop, id);
      } on RpcException catch (e) {
        if (e.reason == ErrorCode.busy) return false; // a read still runs
        rethrow;
      }
      return done(last);
    }, reason: 'activity of $id never matched');
    return last;
  }

  Future<int> activityReads(Desktop desktop) async =>
      ((await desktop.connection.request('test/terminal.stats'))!
              as Json)['activityReads']!
          as int;

  test('idle shell reads idle', () async {
    final desktop = await start();
    final t = await desktop.openTerminal('fixture');
    await t.waitForText('READY;');

    final a = await one(desktop, t.id);
    expect(a.terminalId, t.id);
    expect(a.state, TerminalActivityState.idle);
    expect(a.programs, isEmpty);
  });

  test('child program reads busy with its name', () async {
    final desktop = await start();
    final t = await realShell(desktop);
    await t.send(Platform.isWindows ? 'ping -n 600 127.0.0.1' : 'sleep 600');
    final expected = Platform.isWindows ? 'PING.EXE' : 'sleep';
    final a = await until(
      desktop,
      t.id,
      (a) => a.state == TerminalActivityState.busy,
    );
    expect(a.programs, contains(expected));
    expect(a.programs.length, lessThanOrEqualTo(3));
    expect(a.processCount, greaterThanOrEqualTo(1));
    for (final name in a.programs) {
      expect(name, isNot(contains(' ')), reason: 'no arguments: $name');
    }
  });

  test('background sleep reads busy', () async {
    final desktop = await start();
    final t = await realShell(desktop);
    await t.send(
      Platform.isWindows
          ? 'start /b ping -n 600 127.0.0.1 >nul'
          : 'sleep 600 &',
    );
    await t.send(_marker('BACK', 'PROMPT'));
    await t.waitForText('BACKPROMPT');
    final a = await until(
      desktop,
      t.id,
      (a) => a.state == TerminalActivityState.busy,
    );
    expect(a.programs, contains(Platform.isWindows ? 'PING.EXE' : 'sleep'));
  });

  test('exec replaces leader image and reads busy (POSIX)', () async {
    final desktop = await start();
    final t = await realShell(desktop);
    expect((await one(desktop, t.id)).state, TerminalActivityState.idle);
    await t.send('exec sleep 600');
    final a = await until(
      desktop,
      t.id,
      (a) => a.state == TerminalActivityState.busy,
    );
    expect(a.programs, ['sleep']);
  }, testOn: 'linux || mac-os');

  test(
    'startup-file exec reads busy against resolved executable (POSIX)',
    () async {
      final desktop = await start();
      final rc = File('${work.path}/startup.sh')
        ..writeAsStringSync('exec sleep 600\n');
      await desktop.saveProfile(
        ShellProfile(
          id: 'startup-exec',
          name: 'Startup exec',
          executable: 'sh', // resolved through PATH before the spawn
          args: const ['-i'],
          cwd: work.path,
          env: {'ENV': rc.path},
        ),
      );
      final t = await desktop.openTerminal('startup-exec');
      // On macOS sh hands off to bash first, which also reads busy, so wait for
      // the program the startup file execs.
      final a = await until(
        desktop,
        t.id,
        (a) =>
            a.state == TerminalActivityState.busy &&
            a.programs.contains('sleep'),
      );
      expect(a.programs, ['sleep']);
    },
    testOn: 'linux || mac-os',
  );

  test('injected unreadable leader image reads unknown', () async {
    final desktop = await start();
    final t = await desktop.openTerminal('fixture');
    await t.waitForText('READY;');
    await desktop.setFault(TestFault.activityImageUnreadable);

    final a = await one(desktop, t.id);
    expect(a.state, TerminalActivityState.unknown);
    expect(a.programs, isEmpty);
  });

  test('injected slow table read reads unknown at the deadline', () async {
    final desktop = await start();
    final t = await desktop.openTerminal('fixture');
    await t.waitForText('READY;');
    await desktop.setFault(TestFault.activityReadSlow);

    final clock = Stopwatch()..start();
    final answer = await activity(desktop, [t.id, 'term-missing']);
    final took = clock.elapsed;
    expect(answer.map((a) => a.terminalId), [t.id, 'term-missing']);
    expect(answer.first.state, TerminalActivityState.unknown);
    expect(answer.last.state, TerminalActivityState.ended);
    expect(took, greaterThanOrEqualTo(const Duration(milliseconds: 900)));
    expect(took, lessThan(const Duration(milliseconds: 1500)));

    // The timed-out read keeps the host's one slot until it returns.
    final second = await rpcFailure(
      desktop.connection.request(
        Method.terminalActivity,
        TerminalActivityParams([t.id]).toJson(),
      ),
    );
    expect(second.reason, ErrorCode.busy);

    await desktop.setFault(TestFault.activityReadSlow, enabled: false);
    final again = await until(
      desktop,
      t.id,
      (a) => a.state != TerminalActivityState.unknown,
    );
    expect(again.state, TerminalActivityState.idle);
  });

  test('unknown id reads ended', () async {
    final desktop = await start();
    final t = await desktop.openTerminal('fixture');
    await t.waitForText('READY;');

    final answer = await activity(desktop, ['term-nope', t.id]);
    expect(answer.first.terminalId, 'term-nope');
    expect(answer.first.state, TerminalActivityState.ended);
    expect(answer.last.state, TerminalActivityState.idle);
  });

  test('65 ids refused invalid-params without a table read', () async {
    final desktop = await start();
    final before = await activityReads(desktop);
    final refused = await rpcFailure(
      desktop.connection.request(Method.terminalActivity, {
        'terminalIds': [for (var i = 0; i < 65; i++) 'term-$i'],
      }),
    );
    expect(refused.reason, ErrorCode.invalidParams);
    expect(await activityReads(desktop), before);
  });
}

/// An `echo` whose output, `<a><b>`, differs from the echoed command line,
/// so seeing it means the shell ran the command.
String _marker(String a, String b) =>
    Platform.isWindows ? 'echo $a^$b' : 'echo $a""$b';
