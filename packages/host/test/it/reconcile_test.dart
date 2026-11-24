import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

/// Holds reconciliation open long enough to observe the refusal.
const Map<String, String> slowReconcile = {
  'KUMIKO_TEST_RECONCILE_DELAY_MS': '1500',
};

void main() {
  setUpAll(buildTestHost);

  late Directory profile;
  late Directory root;
  setUp(() {
    profile = tempDir('reconcile_');
    root = tempDir('reconcile_root_');
  });
  tearDown(() async {
    for (final e in root.listSync(followLinks: false)) {
      if (e is Directory) killReported(e);
    }
    await deleteTree(root);
    await deleteTree(profile);
  });

  Directory workspace(String name) =>
      Directory(joinPath(root.path, name))..createSync();

  /// Kills the host without any shutdown, as a crash would.
  Future<void> killHost(Desktop desktop) async {
    Process.killPid(desktop.session.pid, ProcessSignal.sigkill);
    await desktop.session.lost.timeout(hostLossBound * 3);
  }

  test('restarted host refuses launches until reconciled', () async {
    final first = workspace('first');
    final desktop = await Desktop.start(profile, environment: slowReconcile);
    addTearDown(desktop.dispose);
    await desktop.waitState();
    await desktop.launch(first, TestFixture.sleeper);
    await waitReports(first, 1);
    await killHost(desktop);

    await desktop.restart();
    expect(desktop.session.hello.state, HostState.reconciling);

    final other = workspace('other');
    expect(
      await desktop.launchRefusal(other, TestFixture.sleeper),
      ErrorCode.reconciling,
    );
    expect(readReports(other), isEmpty);

    final done = await desktop.waitState();
    expect(done.unresolvedWorkspaces, 0);
    expect(await desktop.launchRefusal(other, TestFixture.sleeper), isNull);
    await waitReports(other, 1);
  });

  test(
    "killed host's units cleaned or unresolved; no launch before reconcile",
    () async {
      final one = workspace('one');
      final two = workspace('two');
      final desktop = await Desktop.start(profile, environment: slowReconcile);
      addTearDown(desktop.dispose);
      await desktop.waitState();
      final a = await desktop.launch(one, TestFixture.tree);
      final b = await desktop.launch(two, TestFixture.escaper);
      final running = [
        ...await waitReports(one, 3),
        ...await waitReports(two, 2),
      ];
      expect(running.every((p) => p.alive), isTrue);
      await killHost(desktop);

      await desktop.restart();
      expect(
        await desktop.launchRefusal(one, TestFixture.sleeper),
        ErrorCode.reconciling,
      );
      final state = await desktop.waitState();

      // Every process is gone, and every unit is cleaned or unresolved with a
      // reason. All of them can be terminated here, so all are cleaned.
      await expectAllGone(running);
      final rows = LedgerView(profile).units();
      for (final row in rows) {
        expect(row['state'], 'unresolved');
        expect(row['unresolved_reason'], isNotNull);
      }
      expect(state.unresolvedUnits, rows.length);
      expect(rows, isEmpty, reason: 'both units were confirmed cleaned');
      expect(LedgerView(profile).unit(a), isNull);
      expect(LedgerView(profile).unit(b), isNull);
    },
  );

  test('pid with different start time is never signalled', () async {
    // A live process that is not a unit, recorded under a pid that "was
    // reused": same pid, other start time.
    final bystander = tempDir('bystander_');
    addTearDown(() => deleteTree(bystander));
    final process = await Process.start(testHostExecutable(), [
      '--test-fixture',
      'sleeper',
    ], workingDirectory: bystander.path);
    addTearDown(() => process.kill());
    final started = (await waitReports(bystander, 1)).single;
    expect(started.alive, isTrue);
    await withStore(profile, (store) {
      seedInstance(store);
      seedUnit(
        store,
        id: 'reused-pid',
        state: 'running',
        path: bystander.path,
        identity: 'reused:1',
        pid: started.pid,
        startedAt: started.startTime + 12345,
      );
    });

    final desktop = await Desktop.start(profile);
    addTearDown(desktop.dispose);
    await desktop.waitState();

    expect(started.alive, isTrue, reason: 'never signalled');
    expect(
      LedgerView(profile).unit('reused-pid'),
      isNull,
      reason: 'not counted as the unit: cleaned',
    );
    expect(await desktop.allWorkspaces(), isEmpty);
  });

  // Issue #18: a row whose leader exited before its start time was read
  // carries -1, which matches no process (design D2).
  final skipOnWindows = Platform.isWindows ? 'POSIX start time -1 only' : null;

  test('start time -1 row with a live bystander pid is cleaned and the '
      'bystander never signalled', () async {
    final bystander = workspace('bystander');
    final process = await Process.start(testHostExecutable(), [
      '--test-fixture',
      'sleeper',
    ], workingDirectory: bystander.path);
    addTearDown(() => process.kill(ProcessSignal.sigkill));
    final started = (await waitReports(bystander, 1)).single;
    await withStore(profile, (store) {
      seedInstance(store);
      seedUnit(
        store,
        id: 'gone-leader',
        state: 'running',
        path: bystander.path,
        identity: 'gone:1',
        pid: started.pid,
        startedAt: -1,
      );
    });

    final desktop = await Desktop.start(profile);
    addTearDown(desktop.dispose);
    await desktop.waitState();

    expect(started.alive, isTrue, reason: 'never signalled');
    expect(LedgerView(profile).unit('gone-leader'), isNull);
  }, skip: skipOnWindows);

  for (final killFails in [false, true]) {
    test('start time -1 row: the marker scan ends its marked descendant'
        '${killFails ? ' (kills fail: unresolved)' : ''}', () async {
      // Seeded first: the scan reads processes started since the row.
      await withStore(profile, (store) {
        seedInstance(store);
        seedUnit(
          store,
          id: 'gone-leader',
          state: 'running',
          identity: 'gone:2',
          pid: 2147483000,
          startedAt: -1,
        );
      });
      final marked = workspace('marked');
      final process = await Process.start(
        testHostExecutable(),
        ['--test-fixture', 'sleeper'],
        workingDirectory: marked.path,
        environment: {'KUMIKO_UNIT': 'gone-leader'},
      );
      addTearDown(() => process.kill(ProcessSignal.sigkill));
      final sleeper = (await waitReports(marked, 1)).single;

      // With kills failing from the start, reconcile cannot end it.
      final desktop = await Desktop.start(
        profile,
        environment: {if (killFails) 'KUMIKO_TEST_FAULTS': 'killFails'},
      );
      addTearDown(desktop.dispose);
      await desktop.waitState();

      final row = LedgerView(profile).unit('gone-leader');
      if (killFails) {
        expect(sleeper.alive, isTrue);
        expect(row!['state'], 'unresolved');
        expect(row['unresolved_reason'], 'marked-survivor:${sleeper.pid}');
      } else {
        await expectAllGone([sleeper]);
        expect(row, isNull);
      }
    }, skip: skipOnWindows);
  }

  test('crash windows leave unresolved unless Windows job confirmed', () async {
    for (final fault in [
      TestFault.crashAfterPendingWrite,
      TestFault.crashAfterSpawnBeforePid,
    ]) {
      final dir = workspace(fault.name);
      final round = Directory(joinPath(profile.path, fault.name))..createSync();
      final desktop = await Desktop.start(round);
      await desktop.waitState();
      await desktop.setFault(fault);
      await expectLater(
        desktop.launch(dir, TestFixture.sleeper),
        throwsA(isA<ConnectionClosedException>()),
      );
      await desktop.session.lost.timeout(hostLossBound * 3);
      expect(
        LedgerView(round).units().where((u) => u['state'] == 'pending'),
        hasLength(1),
      );

      await desktop.restart();
      await desktop.waitState();

      // Whatever the crashed host spawned has ended by the scan (POSIX) or
      // the terminated job (Windows).
      await expectAllGone(readReports(dir));
      final listed = await desktop.allWorkspaces();
      final refusal = await desktop.launchRefusal(dir, TestFixture.sleeper);
      if (Platform.isWindows) {
        // The outer job was terminated and attested: the unit is cleaned.
        expect(listed, isEmpty, reason: fault.name);
        expect(refusal, isNull, reason: fault.name);
      } else {
        expect(refusal, ErrorCode.cleanupUnresolved, reason: fault.name);
        expect(listed.single.units.single.reason, isNotEmpty);
      }
      await desktop.dispose();
    }
  });
}
