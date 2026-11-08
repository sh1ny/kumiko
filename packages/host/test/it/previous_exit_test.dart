import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

/// What the host records about how the desktop ended, and what it reports of
/// the previous instance at the next launch (change `app-exit-and-reopen`
/// design D5, specs `execution-host` and `desktop-host-protocol`).
void main() {
  setUpAll(buildTestHost);

  late Directory profile;
  late Directory target;
  setUp(() {
    profile = tempDir('prevexit_');
    target = tempDir('prevexit_target_');
  });
  tearDown(() async {
    killReported(target);
    await deleteTree(target);
    await deleteTree(profile);
  });

  Future<Desktop> start({Map<String, String>? environment}) async {
    final d = await Desktop.start(profile, environment: environment);
    await d.waitState();
    return d;
  }

  Object? exitKindOf(int instance) =>
      LedgerView(profile)
          .instances()
          .firstWhere((r) => r['id'] == instance)['exit_kind'];

  test('app/quit then input close writes exit_kind quit', () async {
    final desktop = await start();
    await desktop.launch(target, TestFixture.tree);
    final reports = await waitReports(target, 3);
    final instance = int.parse(desktop.session.hello.instanceId);
    expect(exitKindOf(instance), isNull, reason: 'nothing recorded while up');

    await desktop.announceQuit();
    expect(exitKindOf(instance), isNull, reason: 'recorded at exit, not now');
    final quit = await desktop.session.quit();

    expect(quit.timedOut, isFalse);
    expect(quit.exitCode, 0);
    await expectAllGone(reports);
    final row = LedgerView(profile).instances().single;
    expect(row['exit_kind'], 'quit');
    expect(row['closed_cleanly'], 1);
  });

  test('input close without app/quit records no quit', () async {
    final desktop = await start();
    final instance = int.parse(desktop.session.hello.instanceId);

    final quit = await desktop.session.quit();

    expect(quit.exitCode, 0);
    expect(exitKindOf(instance), isNull);
    expect(LedgerView(profile).instances().single['closed_cleanly'], 1);
  });

  test('app/quit followed by a protocol violation records no quit', () async {
    final host = await RawHost.start(profile);
    addTearDown(host.dispose);
    final hello = await host.hello();
    expect(hello.capabilities, contains(Capability.lifecycle));
    await host.reconciled;
    await host.connection.request(Method.appQuit, {});

    host.writeRaw(oversizeHeader());

    expect(await host.exitCode.timeout(const Duration(seconds: 30)), 65);
    final row = LedgerView(profile).instances().single;
    expect(row['exit_kind'], isNull);
  });

  test('killed stand-in desktop leaves exit_kind null', () async {
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

    standin.kill(ProcessSignal.sigkill);
    await standin.exitCode;
    await eventually(
      () => !isProcessAlive(hostPid, hostStart),
      within: const Duration(seconds: 40),
      reason: 'host still running',
    );

    await expectAllGone(reports);
    final row = LedgerView(profile).instances().single;
    expect(row['exit_kind'], isNull);
  });

  test('killed host leaves exit_kind null', () async {
    final desktop = await start();
    final instance = int.parse(desktop.session.hello.instanceId);
    final hostPid = desktop.session.pid;
    final hostStart = processStartTime(hostPid)!;
    await desktop.announceQuit();

    Process.killPid(hostPid, ProcessSignal.sigkill);
    await eventually(
      () => !isProcessAlive(hostPid, hostStart),
      reason: 'host still running',
    );

    expect(exitKindOf(instance), isNull);
    expect(LedgerView(profile).instances().single['closed_cleanly'], 0);
    await desktop.session.quit();
  });

  test('previousExit after quit reports quit; no notice', () async {
    var desktop = await start();
    await desktop.announceQuit();
    await desktop.session.quit();
    final opened =
        LedgerView(profile).instances().single['opened_at']! as String;

    desktop = await Desktop.start(profile);
    addTearDown(desktop.dispose);
    await desktop.waitState();

    final previous = await desktop.previousExit();
    expect(previous.kind, PreviousExitKind.quit);
    expect(previous.openedAt, DateTime.parse(opened));
  });

  test('new profile reports no previous instance', () async {
    final desktop = await start();
    addTearDown(desktop.dispose);

    final previous = await desktop.previousExit();

    expect(previous.kind, PreviousExitKind.none);
    expect(previous.openedAt, isNull);
  });

  test('previousExit after an unexpected end reports unexpected', () async {
    final first = await start();
    final opened =
        LedgerView(profile).instances().single['opened_at']! as String;
    await first.session.quit();

    final desktop = await Desktop.start(profile);
    addTearDown(desktop.dispose);
    await desktop.waitState();

    final previous = await desktop.previousExit();
    expect(previous.kind, PreviousExitKind.unexpected);
    expect(previous.openedAt, DateTime.parse(opened));
  });

  test('after a host loss, previousExit reports the lost instance as one stable snapshot', () async {
    final desktop = await start();
    addTearDown(desktop.dispose);
    final lost = int.parse(desktop.session.hello.instanceId);
    final lostOpened =
        LedgerView(profile).instances().single['opened_at']! as String;
    final hostPid = desktop.session.pid;
    final hostStart = processStartTime(hostPid)!;
    Process.killPid(hostPid, ProcessSignal.sigkill);
    await eventually(
      () => !isProcessAlive(hostPid, hostStart),
      reason: 'host still running',
    );
    await desktop.session.quit();

    await desktop.restart();
    await desktop.waitState();

    // The host reports the lost instance as one snapshot, however often it is
    // asked; it is the desktop that asks only for its first host.
    final first = await desktop.previousExit();
    final second = await desktop.previousExit();
    expect(first.kind, PreviousExitKind.unexpected);
    expect(first.openedAt, DateTime.parse(lostOpened));
    expect(second.kind, first.kind);
    expect(second.openedAt, first.openedAt);
    expect(
      int.parse(desktop.session.hello.instanceId),
      greaterThan(lost),
      reason: 'a new instance, not the lost one',
    );
  });

  test('snapshot taken before reconciliation deletes the row', () async {
    // An older instance keeps an unresolved unit, so reconciliation cannot
    // remove it; the instance before the next host owns none and is removed.
    await withStore(profile, (store) {
      seedInstance(
        store,
        desktopPid: pid,
        desktopStartedAt: processStartTime(pid),
      );
      seedUnit(store, id: 'older', state: 'unresolved');
      store.execute(
        "UPDATE host_instance SET exit_kind = 'quit' WHERE id = 900",
      );
    });
    final first = await start();
    final middle = int.parse(first.session.hello.instanceId);
    final middleOpened =
        LedgerView(profile)
                .instances()
                .firstWhere((r) => r['id'] == middle)['opened_at']!
            as String;
    await first.session.quit();

    final desktop = await Desktop.start(profile);
    addTearDown(desktop.dispose);
    await desktop.waitState();

    final ids = [for (final r in LedgerView(profile).instances()) r['id']];
    expect(ids, isNot(contains(middle)), reason: 'reconciliation removed it');
    expect(ids, contains(900), reason: 'its unresolved unit keeps the older');
    final previous = await desktop.previousExit();
    expect(previous.kind, PreviousExitKind.unexpected);
    expect(previous.openedAt, DateTime.parse(middleOpened));
  });

  test('unreadable snapshot logs only and shows no notice', () async {
    await withStore(profile, (store) {
      seedInstance(store);
      store.execute("UPDATE host_instance SET opened_at = 'not a time'");
    });

    final desktop = await start();
    addTearDown(desktop.dispose);

    final previous = await desktop.previousExit();
    expect(previous.kind, PreviousExitKind.none);
    expect(previous.openedAt, isNull);
    expect(
      readHostLog(profile).where((e) => e['op'] == 'previous-exit-unreadable'),
      hasLength(1),
    );
    expect(desktop.states.any((s) => !s.reconciling), isTrue);
  });

  test('host without lifecycle refuses method-not-available; quit still ends units', () async {
    final desktop = await start(environment: {'KUMIKO_TEST_NO_LIFECYCLE': '1'});
    expect(desktop.session.hello.capabilities, isNot(contains('lifecycle')));
    final instance = int.parse(desktop.session.hello.instanceId);

    expect(
      await failureReason(desktop.previousExit),
      ErrorCode.methodNotAvailable,
    );
    expect(
      await failureReason(desktop.announceQuit),
      ErrorCode.methodNotAvailable,
    );
    await desktop.launch(target, TestFixture.tree);
    final reports = await waitReports(target, 3);

    final quit = await desktop.session.quit();

    expect(quit.timedOut, isFalse);
    expect(quit.exitCode, 0);
    await expectAllGone(reports);
    expect(LedgerView(profile).units(), isEmpty);
    expect(exitKindOf(instance), isNull);
  });
}
