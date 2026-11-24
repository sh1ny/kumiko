@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart' show chmodPath;
import 'package:test/test.dart';

import 'support/harness.dart';
import 'support/terminal_support.dart';

/// Issue #18 at host level: what a launch records and settles when the
/// unit's start time could not be read. Each outcome is forced through the
/// test build's `KUMIKO_TEST_SPAWN_IDENTITY` option, so no test depends on
/// winning or losing the race with the unit's exit (design D4, D5).
void main() {
  setUpAll(buildTestHost);

  final skipOnWindows = Platform.isWindows ? 'POSIX spawn identity only' : null;
  final unconfirmedReason = RegExp(r'^spawn-identity-unconfirmed:\d+$');

  late Directory profile;
  late Directory root;
  setUp(() {
    profile = tempDir('identity_');
    root = tempDir('identity_root_');
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

  Future<Desktop> start(Map<String, String> environment) async {
    final desktop = await Desktop.start(
      profile,
      environment: {
        'HOME': root.path,
        'TERM_FIXTURE_HOST': testHostExecutable(),
        ...environment,
      },
    );
    addTearDown(desktop.dispose);
    await desktop.waitState();
    return desktop;
  }

  Map<String, Object?> onlyRow() => LedgerView(profile).units().single;

  /// The workspace identity the cleanup API names [target] by.
  Future<String> identityOf(Desktop desktop) async =>
      (await desktop.allWorkspaces()).single.targetIdentity;

  /// Starts a launch that settles only once a held fault is released, and
  /// keeps its error for later. [HeldLaunch.settled] turns true when its
  /// answer arrives. Answers come in order on the one connection, so a
  /// launch still unsettled when a later call's answer arrives was still
  /// held when the host answered that call.
  HeldLaunch heldLaunch(Desktop desktop, Directory target) {
    final held = HeldLaunch();
    held.result = desktop
        .launch(target, TestFixture.sleeper)
        .then<Object?>((_) => null, onError: (Object e) => e)
        .whenComplete(() => held.settled = true);
    return held;
  }

  test(
    'fast-exit unit is durably recorded with its pid and start time -1 before '
    'the launch is reported',
    () async {
      final ws = workspace('fast');
      final desktop = await start({'KUMIKO_TEST_SPAWN_IDENTITY': 'reaped'});
      // Holds the settlement the unit's own exit starts, so the row written
      // by the launch can be read before anything deletes it.
      await desktop.setFault(TestFault.terminateHangs);

      final id = await desktop.launch(ws, TestFixture.reportedExit);
      final report = (await waitReports(ws, 1)).single;
      final row = LedgerView(profile).unit(id)!;

      expect(row['state'], 'running');
      expect(row['pid'], report.pid);
      expect(row['process_started_at'], '-1');

      await desktop.setFault(TestFault.terminateHangs, enabled: false);
      await eventually(
        () => LedgerView(profile).unit(id) == null,
        within: const Duration(minutes: 2),
        reason: 'the exited unit was not cleaned',
      );
    },
    skip: skipOnWindows,
  );

  test('ending a forced-gone unit whose exit is not observed leaves it '
      'unresolved and the scan ends it', () async {
    final ws = workspace('forced');
    final desktop = await start({
      'KUMIKO_TEST_SPAWN_IDENTITY': 'forced-gone',
      'KUMIKO_TEST_KILL_WAIT_MS': '0',
    });

    final id = await desktop.launch(ws, TestFixture.sleeper);
    final sleeper = (await waitReports(ws, 1)).single;
    expect(LedgerView(profile).unit(id)!['process_started_at'], '-1');

    final outcome = await desktop.end(id);

    expect(outcome.cleaned, isFalse);
    expect(outcome.reason, 'termination-timeout');
    expect(LedgerView(profile).unit(id)!['state'], 'unresolved');
    await expectAllGone([sleeper]);
  }, skip: skipOnWindows);

  test(
    'unconfirmed PTY spawn reports the exec stage, leaves its row unresolved '
    'and refuses the workspace',
    () async {
      final ws = workspace('pty');
      final desktop = await start({
        'KUMIKO_TEST_SPAWN_IDENTITY': 'unconfirmed',
      });
      final file = File(joinPath(ws.path, 'plain.txt'))
        ..writeAsStringSync('not a program');
      await desktop.saveFixtureProfile(
        id: 'plain',
        executable: file.path,
        cwd: ws.path,
      );

      final e = await rpcFailure(desktop.openTerminalRaw('plain'));

      expect(e.reason, ErrorCode.spawnFailed);
      expect(e.data['stage'], 'exec');
      final row = onlyRow();
      expect(row['state'], 'unresolved');
      expect(row['unresolved_reason'], matches(unconfirmedReason));
      expect(row['pid'], isNull, reason: 'the pid is diagnostic only');
      // A terminal opened without a workspace is attributed to HOME.
      expect(
        await desktop.launchRefusal(root, TestFixture.sleeper),
        ErrorCode.cleanupUnresolved,
      );
    },
    skip: skipOnWindows,
  );

  test('unconfirmed PTY spawn that fails exec with ENOENT, under a throwing '
      'scan, reports executable-not-found and refuses the workspace', () async {
    final ws = workspace('enoent');
    final desktop = await start({'KUMIKO_TEST_SPAWN_IDENTITY': 'unconfirmed'});
    // An executable script whose interpreter does not exist: the file
    // resolves, and only its execve fails, with ENOENT.
    final file = File(joinPath(ws.path, 'orphan.sh'))
      ..writeAsStringSync('#!/nonexistent/kumiko-interpreter\n');
    chmodPath(file.path, 0x1c0);
    await desktop.saveFixtureProfile(
      id: 'orphan',
      executable: file.path,
      cwd: ws.path,
    );
    await desktop.setFault(TestFault.scanThrows);

    final e = await rpcFailure(desktop.openTerminalRaw('orphan'));

    expect(e.reason, ErrorCode.executableNotFound);
    final row = onlyRow();
    expect(row['state'], 'unresolved');
    expect(row['unresolved_reason'], matches(unconfirmedReason));
    // The scan ran and threw, and its error was logged, not reported.
    await eventually(
      () => readHostLog(profile).any(
        (event) =>
            event['op'] == 'failed-spawn-scan-error' &&
            event['unit'] == row['containment_id'],
      ),
      within: const Duration(minutes: 2),
      reason: 'no failed-spawn-scan-error event for the unit',
    );
    expect(
      await desktop.launchRefusal(root, TestFixture.sleeper),
      ErrorCode.cleanupUnresolved,
    );
  }, skip: skipOnWindows);

  test('the workspace is gated while the failed-spawn scan is held, and a '
      'confirm made then is not undone by the scan', () async {
    final ws = workspace('held');
    final desktop = await start({'KUMIKO_TEST_SPAWN_IDENTITY': 'unconfirmed'});
    await desktop.setFault(TestFault.spawnScanHangs);

    final launching = heldLaunch(desktop, ws);
    final sleeper = (await waitReports(ws, 1)).single;
    await eventually(
      () => LedgerView(profile).units().any((u) => u['state'] == 'unresolved'),
      reason: 'the row was not marked unresolved before the scan',
    );

    expect(
      await desktop.launchRefusal(ws, TestFixture.sleeper),
      ErrorCode.cleanupUnresolved,
    );
    final confirmed = await desktop.confirm(await identityOf(desktop));
    expect(confirmed.resolvedUnits, 1);
    expect(LedgerView(profile).units(), isEmpty);
    final revision = (await desktop.list()).revision;
    expect(launching.settled, isFalse, reason: 'the scan is still held');

    await desktop.setFault(TestFault.spawnScanHangs, enabled: false);
    expect(await launching.result, isA<RpcException>());
    expect(LedgerView(profile).units(), isEmpty, reason: 'stays confirmed');
    expect(
      (await desktop.list()).revision,
      revision,
      reason: 'the released scan wrote nothing, not even to a deleted row',
    );
    await expectAllGone([sleeper]);
  }, skip: skipOnWindows);

  test(
    'a retry while the failed-spawn scan is held keeps the reason',
    () async {
      final ws = workspace('held-retry');
      final desktop = await start({
        'KUMIKO_TEST_SPAWN_IDENTITY': 'unconfirmed',
      });
      await desktop.setFault(TestFault.spawnScanHangs);

      final launching = heldLaunch(desktop, ws);
      await waitReports(ws, 1);
      await eventually(
        () =>
            LedgerView(profile).units().any((u) => u['state'] == 'unresolved'),
        reason: 'the row was not marked unresolved before the scan',
      );
      final reason = onlyRow()['unresolved_reason'];
      expect(reason, matches(unconfirmedReason));

      final retried = await desktop.retry(await identityOf(desktop));

      expect(retried.unresolvedUnits, 1);
      expect(onlyRow()['unresolved_reason'], reason);
      final revision = (await desktop.list()).revision;
      expect(launching.settled, isFalse, reason: 'the scan is still held');

      await desktop.setFault(TestFault.spawnScanHangs, enabled: false);
      expect(await launching.result, isA<RpcException>());
      expect(onlyRow()['state'], 'unresolved');
      expect(onlyRow()['unresolved_reason'], reason, reason: 'no late write');
      expect(
        (await desktop.list()).revision,
        revision,
        reason: 'the released scan wrote nothing',
      );
    },
    skip: skipOnWindows,
  );

  test("a scan that throws leaves the row unresolved and the launch fails with "
      "the spawn's own error", () async {
    final ws = workspace('throws');
    final desktop = await start({'KUMIKO_TEST_SPAWN_IDENTITY': 'unconfirmed'});
    await desktop.setFault(TestFault.scanThrows);

    final e = await rpcFailure(desktop.launch(ws, TestFixture.sleeper));

    expect(e.message, contains('not confirmed gone'));
    expect(e.message, isNot(contains('injected scan')));
    final row = onlyRow();
    expect(row['state'], 'unresolved');
    expect(row['unresolved_reason'], matches(unconfirmedReason));
  }, skip: skipOnWindows);

  test('unconfirmed row keeps its reason through retry and a failed restart; '
      'confirm clears it', () async {
    const reason = 'spawn-identity-unconfirmed:4242';
    await withStore(profile, (store) {
      seedInstance(store);
      seedUnit(
        store,
        id: 'unconfirmed',
        state: 'unresolved',
        identity: 'seed:unconfirmed',
        reason: reason,
      );
      seedUnit(store, id: 'other', state: 'pending', identity: 'seed:other');
    });

    // The fault is on before reconcile starts, so its settle throws.
    final desktop = await start({'KUMIKO_TEST_FAULTS': 'scanThrows'});

    final view = LedgerView(profile);
    expect(view.unit('unconfirmed')!['unresolved_reason'], reason);
    expect(
      view.unit('other')!['unresolved_reason'],
      startsWith('reconcile-failed'),
    );

    final retried = await desktop.retry('seed:unconfirmed');
    expect(retried.unresolvedUnits, 1);
    expect(view.unit('unconfirmed')!['unresolved_reason'], reason);

    await desktop.confirm('seed:unconfirmed');
    expect(view.unit('unconfirmed'), isNull);
  }, skip: skipOnWindows);

  test('retry of an unconfirmed row keeps it unresolved and still scans its '
      'marker', () async {
    const reason = 'spawn-identity-unconfirmed:4242';
    await withStore(profile, (store) {
      seedInstance(store);
      seedUnit(
        store,
        id: 'unconfirmed',
        state: 'unresolved',
        identity: 'seed:unconfirmed',
        reason: reason,
      );
    });
    final desktop = await start(const {});
    expect(
      LedgerView(profile).unit('unconfirmed')!['unresolved_reason'],
      reason,
    );

    // Started after reconcile, so only the retry's scan can end it.
    final marked = workspace('marked');
    final process = await Process.start(
      testHostExecutable(),
      ['--test-fixture', 'sleeper'],
      workingDirectory: marked.path,
      environment: {'KUMIKO_UNIT': 'unconfirmed'},
    );
    addTearDown(() => process.kill(ProcessSignal.sigkill));
    final sleeper = (await waitReports(marked, 1)).single;

    final retried = await desktop.retry('seed:unconfirmed');

    expect(retried.unresolvedUnits, 1);
    expect(
      LedgerView(profile).unit('unconfirmed')!['unresolved_reason'],
      reason,
    );
    await expectAllGone([sleeper]);

    await desktop.confirm('seed:unconfirmed');
    expect(LedgerView(profile).unit('unconfirmed'), isNull);
    expect(await desktop.allWorkspaces(), isEmpty);
  }, skip: skipOnWindows);

  test('retry of an unconfirmed row whose marked process survives keeps '
      'its pid-bearing reason', () async {
    const reason = 'spawn-identity-unconfirmed:4242';
    await withStore(profile, (store) {
      seedInstance(store);
      seedUnit(
        store,
        id: 'unconfirmed',
        state: 'unresolved',
        identity: 'seed:unconfirmed',
        reason: reason,
      );
    });
    final desktop = await start(const {});

    final marked = workspace('survivor');
    final process = await Process.start(
      testHostExecutable(),
      ['--test-fixture', 'sleeper'],
      workingDirectory: marked.path,
      environment: {'KUMIKO_UNIT': 'unconfirmed'},
    );
    addTearDown(() => process.kill(ProcessSignal.sigkill));
    await waitReports(marked, 1);
    // The scan finds the marked process but cannot end it.
    await desktop.setFault(TestFault.killFails);

    final retried = await desktop.retry('seed:unconfirmed');

    expect(retried.unresolvedUnits, 1);
    expect(
      LedgerView(profile).unit('unconfirmed')!['unresolved_reason'],
      reason,
      reason: 'not replaced by marked-survivor',
    );
  }, skip: skipOnWindows);

  test('retry of a row without a pid that is not an unconfirmed spawn takes '
      'the ordinary pending-without-pid reason', () async {
    await withStore(profile, (store) {
      seedInstance(store);
      seedUnit(
        store,
        id: 'pidless',
        state: 'unresolved',
        identity: 'seed:pidless',
        reason: 'seeded',
      );
    });
    // Reconcile's settle throws once, so the row starts with a reason
    // that only the retry can replace.
    final desktop = await start({'KUMIKO_TEST_FAULTS': 'scanThrows'});
    expect(
      LedgerView(profile).unit('pidless')!['unresolved_reason'],
      startsWith('reconcile-failed'),
    );

    final retried = await desktop.retry('seed:pidless');

    expect(retried.unresolvedUnits, 1);
    expect(
      LedgerView(profile).unit('pidless')!['unresolved_reason'],
      'pending-without-pid',
    );
  }, skip: skipOnWindows);
}

/// A launch held by a test fault; see `heldLaunch`.
class HeldLaunch {
  late final Future<Object?> result;
  bool settled = false;
}
