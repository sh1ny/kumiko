import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

void main() {
  setUpAll(buildTestHost);

  late Directory profile;
  late Directory target;
  setUp(() {
    profile = tempDir('ledger_');
    target = tempDir('ledger_target_');
  });
  tearDown(() async {
    killReported(target);
    await deleteTree(target);
    await deleteTree(profile);
  });

  test(
    'pending row committed before spawn, pid and start time after',
    () async {
      final desktop = await Desktop.start(profile);
      addTearDown(desktop.dispose);

      // The host dies right after the pending commit: the row exists and no
      // process does.
      await desktop.setFault(TestFault.crashAfterPendingWrite);
      await expectLater(
        desktop.launch(target, TestFixture.sleeper),
        throwsA(isA<ConnectionClosedException>()),
      );
      await desktop.session.lost.timeout(hostLossBound * 3);
      final pending = LedgerView(profile).units().single;
      expect(pending['state'], 'pending');
      expect(pending['pid'], isNull);
      expect(pending['target_identity'], isNotEmpty);
      expect(pending['kind'], 'test');
      expect(readReports(target), isEmpty, reason: 'nothing was spawned');

      // A normal launch: the row carries pid and start time once reported.
      await desktop.restart();
      await desktop.waitState();
      if (!Platform.isWindows) {
        // Only a Windows job can confirm a pending row (design D8); here it
        // stays unresolved until the user says the processes are gone.
        final workspace = (await desktop.allWorkspaces()).single;
        expect(
          workspace.units.single.reason,
          startsWith('pending-without-pid'),
        );
        expect(
          await desktop.launchRefusal(target, TestFixture.sleeper),
          ErrorCode.cleanupUnresolved,
        );
        await desktop.confirm(workspace.targetIdentity);
      }
      final id = await desktop.launch(target, TestFixture.sleeper);
      final reports = await waitReports(target, 1);
      final row = LedgerView(profile).unit(id)!;
      expect(row['state'], 'running');
      expect(row['pid'], reports.single.pid);
      expect(row['process_started_at'], reports.single.startTime.toString());
      expect(reports.single.marker, id);
    },
  );

  test('pending write fault refuses launch with store-error', () async {
    final desktop = await Desktop.start(profile);
    addTearDown(desktop.dispose);
    await desktop.waitState();
    await desktop.setFault(TestFault.pendingWriteFails);

    expect(
      await desktop.launchRefusal(target, TestFixture.sleeper),
      ErrorCode.storeError,
    );

    expect(LedgerView(profile).units(), isEmpty);
    expect(readReports(target), isEmpty);
    await desktop.setFault(TestFault.pendingWriteFails, enabled: false);
    await desktop.launch(target, TestFixture.sleeper); // the host recovered
  });

  test('running write fault ends the whole unit before its row goes', () async {
    final desktop = await Desktop.start(profile);
    addTearDown(desktop.dispose);
    await desktop.waitState();
    // The pid write fails after 1 s, once the tree has started its
    // descendants, including one outside the unit's POSIX session.
    await desktop.setFault(TestFault.runningWriteFails);

    expect(
      await desktop.launchRefusal(target, TestFixture.tree),
      ErrorCode.storeError,
    );

    final reports = await waitReports(target, 3);
    await expectAllGone(reports);
    expect(LedgerView(profile).units(), isEmpty);
    await desktop.setFault(TestFault.runningWriteFails, enabled: false);
    await desktop.launch(target, TestFixture.sleeper); // not gated
  });

  test('spawn failing after the leader started settles its marker', () async {
    final desktop = await Desktop.start(profile);
    addTearDown(desktop.dispose);
    await desktop.waitState();
    // As when the leader's start time cannot be read: the leader is killed
    // and the spawn fails, after the tree has started its descendants.
    await desktop.setFault(TestFault.identityReadFails);

    expect(
      await desktop.launchRefusal(target, TestFixture.tree),
      ErrorCode.internalError,
    );

    final reports = await waitReports(target, 3);
    await expectAllGone(reports);
    expect(LedgerView(profile).units(), isEmpty);
    await desktop.setFault(TestFault.identityReadFails, enabled: false);
    await desktop.launch(target, TestFixture.sleeper); // not gated
  });

  test(
    'crash between spawn and pid write leaves a pending row and a process',
    () async {
      final desktop = await Desktop.start(profile);
      addTearDown(desktop.dispose);
      await desktop.waitState();
      await desktop.setFault(TestFault.crashAfterSpawnBeforePid);

      await expectLater(
        desktop.launch(target, TestFixture.sleeper),
        throwsA(isA<ConnectionClosedException>()),
      );
      await desktop.session.lost.timeout(hostLossBound * 3);

      final row = LedgerView(profile).units().single;
      expect(row['state'], 'pending');
      expect(row['pid'], isNull);
    },
  );

  test('escaper descendant killed via marker scan, unit cleaned', () async {
    final desktop = await Desktop.start(profile);
    addTearDown(desktop.dispose);
    await desktop.waitState();

    final id = await desktop.launch(target, TestFixture.escaper);
    final reports = await waitReports(target, 2);
    expect(reports.map((r) => r.marker), everyElement(id));
    if (!Platform.isWindows) {
      final escapee = reports.firstWhere((r) => r.role != 'escaper');
      final leader = reports.firstWhere((r) => r.role == 'escaper');
      expect(escapee.sid, isNot(leader.sid), reason: 'left the unit session');
    }

    final result = await desktop.end(id);

    expect(result.cleaned, isTrue, reason: result.reason);
    await expectAllGone(reports);
    expect(LedgerView(profile).unit(id), isNull);
    expect(
      readHostLog(profile).where((l) => l['op'] == 'unit-cleaned'),
      isNotEmpty,
    );
  });

  test('kill failure marks unit and workspace unresolved', () async {
    final desktop = await Desktop.start(profile);
    addTearDown(desktop.dispose);
    await desktop.waitState();
    await desktop.setFault(TestFault.killFails);
    final id = await desktop.launch(target, TestFixture.sleeper);
    await waitReports(target, 1);

    final result = await desktop.end(id);

    expect(result.cleaned, isFalse);
    expect(result.reason, startsWith('kill-failed'));
    final row = LedgerView(profile).unit(id)!;
    expect(row['state'], 'unresolved');
    expect(row['unresolved_reason'], result.reason);
    expect(
      await desktop.launchRefusal(target, TestFixture.sleeper),
      ErrorCode.cleanupUnresolved,
    );
    final listed = await desktop.allWorkspaces();
    expect(listed.single.units.single.reason, result.reason);
  });

  test('launch beyond the unit cap is refused with unit-cap', () async {
    final desktop = await Desktop.start(
      profile,
      environment: {'KUMIKO_TEST_UNIT_CAP': '2'},
    );
    addTearDown(desktop.dispose);
    await desktop.waitState();
    final a = await desktop.launch(target, TestFixture.sleeper);
    await desktop.launch(target, TestFixture.sleeper);

    expect(
      await desktop.launchRefusal(target, TestFixture.sleeper),
      ErrorCode.unitCap,
    );
    expect(LedgerView(profile).units(), hasLength(2));

    final ended = await desktop.end(a);
    expect(ended.cleaned, isTrue, reason: ended.reason);
    await desktop.launch(target, TestFixture.sleeper); // room again
  });
}
