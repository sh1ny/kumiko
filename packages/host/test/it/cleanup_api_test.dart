import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

void main() {
  setUpAll(buildTestHost);

  late Directory profile;
  late Directory target;
  setUp(() {
    profile = tempDir('cleanup_');
    target = tempDir('cleanup_target_');
  });
  tearDown(() async {
    killReported(target);
    await deleteTree(target);
    await deleteTree(profile);
  });

  /// A running host with one unit in [target] whose kill failed, so the
  /// workspace is cleanup unresolved. The kill fault is left on.
  Future<(Desktop, String, List<FixtureProcess>)> unresolved(
    FixtureProcessCount fixture, {
    Map<String, String>? environment,
  }) async {
    final desktop = await Desktop.start(profile, environment: environment);
    addTearDown(desktop.dispose);
    await desktop.waitState();
    await desktop.setFault(TestFault.killFails);
    final id = await desktop.launch(target, fixture.fixture);
    final reports = await waitReports(target, fixture.processes);
    final result = await desktop.end(id);
    expect(result.cleaned, isFalse);
    return (desktop, id, reports);
  }

  Future<String> onlyWorkspace(Desktop desktop) async =>
      (await desktop.allWorkspaces()).single.targetIdentity;

  test('pages over 1 MiB of unresolved results; actions cover all units', () async {
    await seedUnresolved(profile, workspaces: 40, unitsEach: 120);
    final desktop = await Desktop.start(profile);
    addTearDown(desktop.dispose);

    final state = await desktop.waitState();
    expect(state.unresolvedWorkspaces, 40);
    expect(state.unresolvedUnits, 4800);
    expect(
      jsonEncode(state.toJson()).length,
      lessThan(200),
      reason: 'the summary is constant size',
    );

    // The whole result is more than one control message holds, in pages.
    var total = 0;
    final workspaces = <CleanupWorkspace>[];
    String? cursor;
    var pages = 0;
    do {
      final page = await desktop.list(cursor: cursor, revision: state.revision);
      expect(page.stale, isFalse);
      expect(page.workspaces.length, lessThanOrEqualTo(maxListWorkspaces));
      final size = jsonEncode(page.toJson()).length;
      expect(size, lessThan(512 * 1024));
      total += size;
      for (final w in page.workspaces) {
        expect(w.units.length, lessThanOrEqualTo(maxUnitsPerWorkspaceInList));
        expect(w.unitCount, 120);
        expect(
          utf8.encode(w.targetPath).length,
          lessThanOrEqualTo(maxPathBytes),
        );
      }
      workspaces.addAll(page.workspaces);
      cursor = page.nextCursor;
      pages++;
    } while (cursor != null);
    expect(pages, 2);
    expect(workspaces, hasLength(40));
    expect(workspaces.map((w) => w.targetIdentity).toSet(), hasLength(40));

    // Every unit of every workspace, in pages of at most 100.
    final first = workspaces.first.targetIdentity;
    final ids = <String>[];
    for (final workspace in workspaces) {
      String? unitCursor;
      var unitPages = 0;
      do {
        final page = await desktop.units(
          workspace.targetIdentity,
          cursor: unitCursor,
        );
        expect(page.units.length, lessThanOrEqualTo(maxUnitsPage));
        for (final u in page.units) {
          expect(
            utf8.encode(u.reason!).length,
            lessThanOrEqualTo(maxReasonBytes),
          );
        }
        total += jsonEncode(page.toJson()).length;
        if (workspace.targetIdentity == first) {
          ids.addAll(page.units.map((u) => u.containmentId));
        }
        unitCursor = page.nextCursor;
        unitPages++;
      } while (unitCursor != null);
      expect(unitPages, 2);
    }
    expect(ids.toSet(), hasLength(120));
    expect(total, greaterThan(1024 * 1024), reason: 'more than one message');

    // Retry and confirm act on all units of the workspace, whatever was paged.
    final retried = await desktop.retry(first);
    expect(retried.resolvedUnits, 120);
    expect(retried.unresolvedUnits, 0);
    final second = workspaces[1].targetIdentity;
    final confirmed = await desktop.confirm(second);
    expect(confirmed.resolvedUnits, 120);
    expect(
      LedgerView(profile).units().where((u) => u['target_identity'] == second),
      isEmpty,
    );

    // A page read across the change is flagged stale.
    final stale = await desktop.list(revision: state.revision);
    expect(stale.stale, isTrue);
    expect(stale.revision, greaterThan(state.revision));
    expect(stale.workspaces, hasLength(25));
    final after = await desktop.waitState(
      where: (s) => s.unresolvedWorkspaces == 38,
    );
    expect(after.unresolvedUnits, 38 * 120);
    expect((await desktop.allWorkspaces()), hasLength(38));
  });

  test('retry after exit cleans and unblocks workspace', () async {
    final (desktop, _, reports) = await unresolved(FixtureProcessCount.sleeper);
    final ws = await onlyWorkspace(desktop);
    await desktop.setFault(TestFault.killFails, enabled: false);
    for (final p in reports) {
      Process.killPid(p.pid, ProcessSignal.sigkill);
    }
    await expectAllGone(reports);

    final result = await desktop.retry(ws);

    expect(result.resolvedUnits, 1);
    expect(result.unresolvedUnits, 0);
    expect(await desktop.allWorkspaces(), isEmpty);
    expect(LedgerView(profile).units(), isEmpty);
    final state = await desktop.waitState(where: (s) => s.unresolvedUnits == 0);
    expect(state.unresolvedWorkspaces, 0);
    expect(await desktop.launchRefusal(target, TestFixture.sleeper), isNull);
  });

  test('retry with survivor keeps workspace with updated reason', () async {
    final (desktop, id, reports) = await unresolved(
      FixtureProcessCount.escaper,
    );
    final ws = await onlyWorkspace(desktop);
    final first = LedgerView(profile).unit(id)!['unresolved_reason'];
    expect(first, startsWith('kill-failed'));
    // The unit's leader exits by itself; its escaped descendant stays, and
    // the kill still fails.
    final leader = reports.firstWhere((r) => r.role == 'escaper');
    Process.killPid(leader.pid, ProcessSignal.sigkill);
    await eventually(() => !leader.alive);

    final result = await desktop.retry(ws);

    expect(result.resolvedUnits, 0);
    expect(result.unresolvedUnits, 1);
    final listed = (await desktop.allWorkspaces()).single;
    expect(listed.targetIdentity, ws);
    final reason = listed.units.single.reason!;
    if (Platform.isWindows) {
      expect(reason, startsWith('kill-failed'));
    } else {
      expect(reason, startsWith('marked-survivor:'), reason: 'updated');
      expect(reason, isNot(first));
    }
    expect(
      await desktop.launchRefusal(target, TestFixture.sleeper),
      ErrorCode.cleanupUnresolved,
    );

    // With the fault gone the next retry ends the survivor.
    await desktop.setFault(TestFault.killFails, enabled: false);
    final again = await desktop.retry(ws);
    expect(again.resolvedUnits, 1);
    await expectAllGone(reports);
  });

  test('confirm deletes rows, logs unit ids, unblocks', () async {
    final (desktop, id, _) = await unresolved(FixtureProcessCount.sleeper);
    final ws = await onlyWorkspace(desktop);

    final result = await desktop.confirm(ws);

    expect(result.resolvedUnits, 1);
    expect(LedgerView(profile).units(), isEmpty);
    expect(await desktop.allWorkspaces(), isEmpty);
    final logged = readHostLog(profile)
        .where((l) => l['op'] == 'unit-confirmed-by-user');
    expect(logged.map((l) => l['unit']), [id]);
    await desktop.setFault(TestFault.killFails, enabled: false);
    expect(await desktop.launchRefusal(target, TestFixture.sleeper), isNull);
  });

  test('confirm during retry refused with retry-in-progress', () async {
    final (desktop, _, _) = await unresolved(
      FixtureProcessCount.sleeper,
      environment: {'KUMIKO_TEST_RETRY_DELAY_MS': '1500'},
    );
    final ws = await onlyWorkspace(desktop);

    final retry = desktop.retry(ws); // fails: the kill fault is still on
    expect(
      await failureReason(() => desktop.confirm(ws)),
      ErrorCode.retryInProgress,
    );
    expect(
      await failureReason(() => desktop.retry(ws)),
      ErrorCode.retryInProgress,
      reason: 'cleanup operations on a workspace are serialized',
    );
    expect(await desktop.allWorkspaces(), hasLength(1));

    final done = await retry;
    expect(done.resolvedUnits, 0);
    expect(await desktop.allWorkspaces(), hasLength(1));
    // Once the retry ended, the confirmation is accepted.
    expect((await desktop.confirm(ws)).resolvedUnits, 1);
  });
}

/// A fixture and how many processes it reports.
enum FixtureProcessCount {
  sleeper(TestFixture.sleeper, 1),
  escaper(TestFixture.escaper, 2);

  const FixtureProcessCount(this.fixture, this.processes);
  final TestFixture fixture;
  final int processes;
}
