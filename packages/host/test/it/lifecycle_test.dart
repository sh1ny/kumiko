import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:host/src/host_options.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/agent_support.dart';
import 'support/harness.dart';
import 'support/terminal_support.dart';

void main() {
  setUpAll(buildTestHost);

  late Directory profile;
  late Directory target;
  setUp(() {
    profile = tempDir('life_');
    target = tempDir('life_target_');
  });
  tearDown(() async {
    killReported(target);
    await deleteTree(target);
    await deleteTree(profile);
  });

  test('stdin close ends units, cleans ledger, exits', () async {
    final desktop = await Desktop.start(profile);
    await desktop.waitState();
    final hostPid = desktop.session.pid;
    final hostStart = processStartTime(hostPid)!;
    final a = await desktop.launch(target, TestFixture.tree);
    final b = await desktop.launch(target, TestFixture.escaper);
    final reports = await waitReports(target, 5);
    expect(reports.every((p) => p.alive), isTrue);
    expect(
      LedgerView(profile).units().map((u) => u['containment_id']),
      unorderedEquals([a, b]),
    );

    final watch = Stopwatch()..start();
    final quit = await desktop.session.quit();
    print(
      'measured: shutdown on quit with 2 units '
      '${watch.elapsedMilliseconds} ms on ${Platform.operatingSystem}',
    );

    expect(quit.timedOut, isFalse);
    expect(quit.exitCode, 0);
    await expectAllGone(reports);
    expect(isProcessAlive(hostPid, hostStart), isFalse);
    final view = LedgerView(profile);
    expect(view.units(), isEmpty, reason: 'every unit was cleaned');
    expect(view.instances().single['closed_cleanly'], 1);
  });

  test('killed desktop stand-in leaves no host or marked process', () async {
    final standin = await Process.start(desktopStandinExecutable(), [
      testHostExecutable(),
      profile.path,
      target.path,
    ]);
    addTearDown(() => standin.kill());
    final lines = standin.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    final errors = StringBuffer();
    standin.stderr.transform(utf8.decoder).listen(errors.write);
    final ready = await lines
        .firstWhere(
          (l) => l.startsWith('READY '),
          orElse: () => throw StateError('stand-in failed: $errors'),
        )
        .timeout(const Duration(seconds: 90));
    final hostPid = int.parse(ready.split(' ')[1]);
    final hostStart = processStartTime(hostPid)!;
    final reports = await waitReports(target, 5);
    expect(reports.every((p) => p.alive), isTrue);

    standin.kill(ProcessSignal.sigkill);
    await standin.exitCode;
    final watch = Stopwatch()..start();

    await eventually(
      () => !isProcessAlive(hostPid, hostStart),
      within: const Duration(seconds: 40),
      reason: 'host still running',
    );
    print(
      'measured: shutdown on desktop loss '
      '${watch.elapsedMilliseconds} ms on ${Platform.operatingSystem}',
    );
    await expectAllGone(reports);
  });

  test('killed stand-in desktop leaves no host, shell, child or adapter '
      'process', () async {
    final home = tempDir('life_home_');
    addTearDown(() => deleteTree(home));
    final script = File(joinPath(target.path, 'standin-script.json'))
      ..writeAsStringSync(
        jsonEncode({
          'prompt': [
            {'spawnTree': true},
          ],
          'holdPrompt': true,
        }),
      );
    final standin = await Process.start(
      desktopStandinExecutable(),
      [
        testHostExecutable(),
        profile.path,
        target.path,
        '--terminal-and-agent',
        terminalFixtureExecutable(),
        script.path,
      ],
      environment: {
        'USERPROFILE': home.path,
        'HOME': home.path,
        'KUMIKO_TEST_RUNTIME_PATH': '',
        'KUMIKO_TEST_SHELL_PATH': '',
      },
    );
    final standinStart = processStartTime(standin.pid)!;
    addTearDown(() async {
      standin.kill(ProcessSignal.sigkill);
      await standin.exitCode;
    });
    final lines = standin.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    final errors = StringBuffer();
    standin.stderr.transform(utf8.decoder).listen(errors.write);
    final ready = await lines
        .firstWhere(
          (l) => l.startsWith('READY '),
          orElse: () => throw StateError('stand-in failed: $errors'),
        )
        .timeout(const Duration(seconds: 90));
    final hostPid = int.parse(ready.split(' ')[1]);
    final hostStart = processStartTime(hostPid)!;

    // The terminal reports its shell and a child; the agent session reports
    // its adapter and a three-process tree. Each is known by pid and start
    // time, so a reused pid can neither pass nor fail the test.
    final reports = await waitReports(target, 6);
    expect(
      reports.map((p) => p.role),
      containsAll(['shell', 'sleeper']),
      reason: 'the terminal runs a shell and a child',
    );
    expect(reports.every((p) => p.alive), isTrue, reason: '$errors');
    expect(isProcessAlive(hostPid, hostStart), isTrue);

    standin.kill(ProcessSignal.sigkill);
    await standin.exitCode;
    expect(isProcessAlive(standin.pid, standinStart), isFalse);

    await eventually(
      () => !isProcessAlive(hostPid, hostStart),
      within: const Duration(seconds: 40),
      reason: 'host still running',
    );
    await expectAllGone(reports);
    expect(
      LedgerView(profile).instances().single['exit_kind'],
      isNull,
      reason: 'a kill is not a quit',
    );
  });

  test('desktop closing input without app/quit ends every unit, no dialog '
      'path', () async {
    final home = tempDir('life_home_');
    addTearDown(() => deleteTree(home));
    final desktop = await Desktop.start(
      profile,
      capabilities: {...testCapabilities, Capability.agent},
      environment: {
        'USERPROFILE': home.path,
        'HOME': home.path,
        'KUMIKO_TEST_RUNTIME_PATH': '',
        'KUMIKO_TEST_SHELL_PATH': '',
      },
    );
    addTearDown(desktop.dispose);
    await desktop.waitState();
    final hostPid = desktop.session.pid;
    final hostStart = processStartTime(hostPid)!;
    final instance = int.parse(desktop.session.hello.instanceId);

    // A session running a turn with tools, a terminal with a child, a unit.
    final workspace = (await desktop.openWorkspace(target.path)).workspace;
    await saveAgentFixture(
      desktop,
      target,
      script: {
        'prompt': [
          {'spawnTree': true},
        ],
        'holdPrompt': true,
      },
    );
    final agent = AgentPeer(desktop);
    await agent.start(workspace.id, runtime: 'acp');
    await agent.attach();
    await agent.prompt();
    await desktop.saveFixtureProfile(cwd: target.path);
    final terminal = await desktop.openTerminal('fixture');
    await terminal.waitForText('READY;');
    await terminal.send('child');
    await terminal.waitForText('CHILD:');
    await desktop.launch(target, TestFixture.tree);
    final reports = await waitReports(target, 9);
    expect(reports.every((p) => p.alive), isTrue);

    // The desktop closes its input; it never sent app/quit and is never
    // asked anything.
    final clock = Stopwatch()..start();
    final quit = await desktop.session.quit();
    final took = clock.elapsed;

    expect(quit.timedOut, isFalse);
    expect(quit.exitCode, 0);
    expect(took, lessThan(HostOptions.defaultShutdownDeadline));
    expect(isProcessAlive(hostPid, hostStart), isFalse);
    await expectAllGone(reports);
    final view = LedgerView(profile);
    expect(view.units(), isEmpty, reason: 'every unit was cleaned');
    final row = view.instances().firstWhere((r) => r['id'] == instance);
    expect(row['exit_kind'], isNull, reason: 'no quit was announced');
    expect(row['closed_cleanly'], 1);
    expect(
      agentRows(profile).single['id'],
      agent.id,
      reason: "the session's record remains",
    );
  });

  test('unendable unit at quit is cleanup unresolved at next launch', () async {
    // The kill fault is the host's; the unit's processes are real.
    final first = await Desktop.start(profile);
    await first.waitState();
    final id = await first.launch(target, TestFixture.sleeper);
    final reports = await waitReports(target, 1);
    await first.setFault(TestFault.killFails);
    await first.announceQuit();

    final quit = await first.session.quit();

    expect(quit.timedOut, isFalse, reason: 'quit still ends at the deadline');
    expect(quit.exitCode, 0);
    final kept = LedgerView(profile).unit(id);
    expect(kept, isNotNull, reason: 'the unit stays in the ledger');
    expect(kept!['state'], isNot('pending'));

    // The next launch, with kills still failing, cannot confirm the unit
    // ended: reconciliation is held so the fault is set before it begins.
    // (A new desktop carries no attestation of the earlier host's job, which
    // is what leaves a Windows unit unconfirmed.)
    final second = await Desktop.start(
      profile,
      environment: {'KUMIKO_TEST_RECONCILE_DELAY_MS': '2000'},
    );
    addTearDown(second.dispose);
    await second.setFault(TestFault.killFails);
    final state = await second.waitState(where: (s) => !s.reconciling);

    expect(state.unresolvedWorkspaces, 1);
    expect(state.unresolvedUnits, 1);
    final workspaces = await second.allWorkspaces();
    expect(workspaces.single.unitCount, 1);
    final row = LedgerView(profile).unit(id)!;
    expect(row['state'], 'unresolved');
    expect(row['unresolved_reason'], isNotNull);
    expect(
      await second.launchRefusal(target, TestFixture.sleeper),
      ErrorCode.cleanupUnresolved,
      reason: 'the workspace is gated until cleanup is resolved',
    );
    // Cleaned up by the tearDown; the reports show the process was real.
    expect(reports, isNotEmpty);
  });

  test('shutdown waits for an end already in progress', () async {
    final desktop = await Desktop.start(profile);
    addTearDown(desktop.dispose);
    await desktop.waitState();
    final id = await desktop.launch(target, TestFixture.stubborn);
    final reports = await waitReports(target, 1);

    // On POSIX the unit ignores SIGTERM, so this end is still in its grace
    // period when the desktop quits.
    final ending = desktop.end(id).then<void>((_) {}, onError: (Object _) {});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final quit = await desktop.session.quit();

    expect(quit.timedOut, isFalse);
    expect(quit.exitCode, 0);
    expect(reports.single.alive, isFalse, reason: 'ended before host exit');
    expect(LedgerView(profile).unit(id), isNull);
    await ending;
  });

  test(
    'kill failure past deadline keeps row; next host reconciles conditionally',
    () async {
      final desktop = await Desktop.start(profile);
      addTearDown(desktop.dispose);
      await desktop.waitState();
      await desktop.setFault(TestFault.killFails);
      final id = await desktop.launch(target, TestFixture.sleeper);
      final reports = await waitReports(target, 1);

      final quit = await desktop.session.quit();

      expect(quit.timedOut, isFalse);
      expect(quit.exitCode, 0, reason: 'the host exits with a kill failure');
      final row = LedgerView(profile).unit(id);
      expect(row, isNotNull, reason: 'the row stays for the next host');
      expect(row!['state'], isNot('pending'));

      // The next host reconciles it. Nothing keeps the process from being
      // terminated now, so the unit is cleaned and the workspace is free.
      await desktop.restart();
      await desktop.waitState();
      await expectAllGone(reports);
      expect(LedgerView(profile).unit(id), isNull);
      expect(await desktop.allWorkspaces(), isEmpty);
      expect(await desktop.launchRefusal(target, TestFixture.sleeper), isNull);
    },
  );

  test(
    'the next host reconciles units an earlier host left unresolved',
    () async {
      final desktop = await Desktop.start(profile);
      addTearDown(desktop.dispose);
      await desktop.waitState();
      await desktop.setFault(TestFault.killFails);
      final id = await desktop.launch(target, TestFixture.sleeper);
      final reports = await waitReports(target, 1);
      expect((await desktop.end(id)).cleaned, isFalse);
      expect(LedgerView(profile).unit(id)!['state'], 'unresolved');
      await desktop.session.quit();

      // Nothing keeps the next host from ending the unit now.
      await desktop.restart();
      await desktop.waitState(where: (s) => !s.reconciling);
      await expectAllGone(reports);
      expect(LedgerView(profile).unit(id), isNull);
      expect(await desktop.allWorkspaces(), isEmpty);
    },
  );

  test(
    'termination past the deadline keeps the row; the host exits on time',
    () async {
      const deadline = Duration(milliseconds: 1500);
      final desktop = await Desktop.start(
        profile,
        environment: {
          'KUMIKO_TEST_SHUTDOWN_DEADLINE_MS': '${deadline.inMilliseconds}',
        },
      );
      addTearDown(desktop.dispose);
      await desktop.waitState();
      final id = await desktop.launch(target, TestFixture.sleeper);
      await waitReports(target, 1);
      await desktop.setFault(TestFault.terminateHangs);

      final clock = Stopwatch()..start();
      final quit = await desktop.session.quit();
      final took = clock.elapsed;

      expect(quit.timedOut, isFalse, reason: 'the host stops at its deadline');
      expect(quit.exitCode, 0);
      expect(took, greaterThanOrEqualTo(deadline), reason: 'it waited');
      expect(took, lessThan(deadline + const Duration(seconds: 3)));
      final row = LedgerView(profile).unit(id);
      expect(row, isNotNull, reason: 'an unconfirmed unit keeps its row');
      expect(row!['state'], 'running');
    },
  );

  test('pending control over 4 MiB ends units and exits host', () async {
    // Large cleanup pages for the host to answer.
    await seedUnresolved(
      profile,
      workspaces: 30,
      unitsEach: 10,
      pathBytes: 4000,
    );
    final host = await RawHost.start(profile);
    addTearDown(host.dispose);
    final hello = await host.hello();
    expect(hello.capabilities, testCapabilities);
    await host.reconciled;
    await host.connection.request(
      Method.testUnitLaunch,
      TestUnitLaunchParams(
        target: target.path,
        fixture: TestFixture.tree,
      ).toJson(),
    );
    final reports = await waitReports(target, 3);

    // The desktop stops reading the pipe, then asks for more than the host
    // may queue.
    host.stopReading();
    final list = const CleanupListParams().toJson();
    for (var i = 0; i < 120; i++) {
      unawaited(
        host.connection
            .request(Method.cleanupList, list)
            .then<void>((_) {}, onError: (Object _) {}),
      );
    }

    final code = await host.exitCode.timeout(const Duration(seconds: 60));
    expect(code, isNot(0));
    expect(host.stderrText.toString(), contains('control-overflow'));
    await expectAllGone(reports);
    expect(
      LedgerView(profile).units().where((u) => u['state'] != 'unresolved'),
      isEmpty,
      reason: 'the unit was ended and cleaned',
    );
  });

  test(
    'windows launches are refused unless the desktop holds the outer job',
    () async {
      final host = await RawHost.start(profile, holdInJob: false);
      addTearDown(host.dispose);
      await host.hello();

      final reason = await failureReason(
        () => host.connection.request(
          Method.testUnitLaunch,
          TestUnitLaunchParams(
            target: target.path,
            fixture: TestFixture.sleeper,
          ).toJson(),
        ),
      );

      expect(reason, ErrorCode.outerJobMissing);
      expect(readReports(target), isEmpty);
      expect(LedgerView(profile).units(), isEmpty);
    },
    skip: Platform.isWindows ? false : 'the outer job is a Windows concept',
  );
}
