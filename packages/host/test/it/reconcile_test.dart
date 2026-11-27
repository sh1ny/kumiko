import 'dart:io';

import 'package:host/src/host_faults.dart';
import 'package:host/src/host_log.dart';
import 'package:host/src/ledger.dart';
import 'package:host/src/profile_lock.dart';
import 'package:host/src/settler.dart';
import 'package:host/src/store/store.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

const _hangGuard = Duration(minutes: 2);

Future<void> _releaseReconcile(Desktop desktop) async {
  await desktop.connection.request(
    'test/reconcile.release',
    const <String, Object?>{},
  );
}

Future<List<FixtureProcess>> _readyFixtures(Directory target, int count) async {
  await eventually(
    () => readReports(target).length >= count,
    within: _hangGuard,
    reason: 'fixtures did not report $count processes in ${target.path}',
  );
  return readReports(target);
}

Future<void> _expectFixturesGone(List<FixtureProcess> fixtures) => eventually(
  () => fixtures.every((fixture) => !fixture.alive),
  within: _hangGuard,
  reason: 'fixtures from $fixtures did not stop',
);

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

  Future<Desktop> startHeldHost() async {
    final desktop = await Desktop.start(
      profile,
      environment: {'KUMIKO_TEST_RECONCILE_HELD': '1'},
    );
    addTearDown(() async {
      try {
        if (!desktop.session.isLost) await _releaseReconcile(desktop);
      } finally {
        await desktop.dispose();
      }
    });
    await _releaseReconcile(desktop);
    await desktop.waitState(within: _hangGuard);
    return desktop;
  }

  /// Kills the host without any shutdown, as a crash would.
  Future<void> killHost(Desktop desktop) async {
    Process.killPid(desktop.session.pid, ProcessSignal.sigkill);
    await desktop.session.lost.timeout(_hangGuard);
  }

  test('restarted host refuses launches until reconciled', () async {
    final first = workspace('first');
    final desktop = await startHeldHost();
    await desktop.launch(first, TestFixture.sleeper);
    final running = await _readyFixtures(first, 1);
    await killHost(desktop);

    await desktop.restart();
    expect(desktop.session.hello.state, HostState.reconciling);

    final other = workspace('other');
    expect(
      await desktop.launchRefusal(other, TestFixture.sleeper),
      ErrorCode.reconciling,
    );
    expect(readReports(other), isEmpty);

    await _releaseReconcile(desktop);
    await desktop.waitState(within: _hangGuard);
    await _expectFixturesGone(running);
    await desktop.launch(other, TestFixture.sleeper);
    await _readyFixtures(other, 1);
  });

  // Run the unfiltered native scan once. The fixture exit checks do not prove
  // that the scan could account for every possible marked process.
  test(
    "killed host's units cleaned or unresolved; no launch before reconcile",
    () async {
      final one = workspace('one');
      final two = workspace('two');
      final desktop = await startHeldHost();
      final a = await desktop.launch(one, TestFixture.tree);
      final b = await desktop.launch(two, TestFixture.escaper);
      final running = [
        ...await _readyFixtures(one, 3),
        ...await _readyFixtures(two, 2),
      ];
      expect(running.every((p) => p.alive), isTrue);
      await killHost(desktop);

      await desktop.restart();
      expect(
        await desktop.launchRefusal(one, TestFixture.sleeper),
        ErrorCode.reconciling,
      );
      await _releaseReconcile(desktop);
      final state = await desktop.waitState(within: _hangGuard);

      await _expectFixturesGone(running);
      final rows = LedgerView(profile).units();
      expect(state.unresolvedUnits, rows.length);
      expect(state.unresolvedWorkspaces, rows.length);
      if (Platform.isWindows || rows.isEmpty) {
        expect(rows, isEmpty);
      } else {
        expect(
          rows.map((row) => row['containment_id']),
          unorderedEquals([a, b]),
        );
        expect(rows.map((row) => row['state']), everyElement('unresolved'));
        final reason = rows.first['unresolved_reason'];
        expect(reason, matches(RegExp(r'^scan-unreadable:[1-9][0-9]*$')));
        expect(rows.last['unresolved_reason'], reason);
        for (final target in [one, two]) {
          expect(
            await desktop.launchRefusal(target, TestFixture.sleeper),
            ErrorCode.cleanupUnresolved,
          );
        }
      }
      if (!Platform.isWindows) {
        final outcome = rows.isEmpty
            ? 'cleaned'
            : rows.first['unresolved_reason'];
        print('native crash reconciliation: $outcome');
      }
    },
  );

  for (final unreadable in [false, true]) {
    test(
      unreadable
          ? 'settlement with an unreadable scan keeps both rows unresolved'
          : 'settlement with a clean scan removes both rows',
      () async {
        const previousInstance = 900;
        final lock = (await ProfileLock.tryAcquire(profile))!;
        addTearDown(lock.release);
        final store = Store.open(profile, lock);
        addTearDown(store.close);
        seedInstance(store, id: previousInstance);
        for (final name in ['one', 'two']) {
          seedUnit(
            store,
            id: name,
            state: 'running',
            path: workspace(name).path,
            identity: 'seed:$name',
            pid: 2147483000,
            startedAt: -1,
            instance: previousInstance,
          );
        }
        final ledger = Ledger(store)
          ..openInstance(
            hostPid: pid,
            hostStartedAt: null,
            desktopPid: null,
            desktopStartedAt: null,
            os: Platform.operatingSystem,
          );
        final settler = Settler(
          ledger: ledger,
          log: HostLog.open(profile, version: 'test'),
          faults: HostFaults(),
          table: _SettlementTable(unreadable: unreadable),
        );
        final rows = ledger.earlierUnits();
        final outcomes = await settler.settle(
          rows,
          live: const {},
          evidence: const WindowsEvidence(attestedInstance: previousInstance),
        );
        settler.apply(rows, outcomes);

        final settled = ledger.earlierUnits();
        if (unreadable) {
          expect(settled.map((row) => row.containmentId), ['one', 'two']);
          expect(settled.map((row) => row.state), everyElement('unresolved'));
          expect(
            settled.map((row) => row.reason),
            everyElement('scan-unreadable:${_SettlementTable.unreadablePid}'),
          );
        } else {
          expect(settled, isEmpty);
        }
      },
    );
  }

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
      await desktop.session.lost.timeout(_hangGuard);
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

class _SettlementTable implements ProcessTable {
  const _SettlementTable({required this.unreadable});

  static const unreadablePid = 52;
  final bool unreadable;

  @override
  int get currentUid => 1;

  @override
  List<int> listPids() => unreadable ? const [unreadablePid] : const [];

  @override
  ProcessSnapshot? snapshot(int pid) => throw const ProcessReadDenied();

  @override
  List<String> environment(int pid) => throw StateError('unexpected env read');

  @override
  Set<int> confirmedExits(Map<int, int?> pids) => const {};

  @override
  Set<int> foreignPids(Set<int> pids) => const {};

  @override
  bool kill(int pid, int startTime) => throw StateError('unexpected kill');
}
