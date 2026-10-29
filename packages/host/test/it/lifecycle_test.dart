import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

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
