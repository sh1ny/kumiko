import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:domain/domain.dart';
import 'package:host/src/host_options.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

/// A resolution timeout short enough to wait for, long enough that a normal
/// resolution never hits it.
const Map<String, String> shortTimeout = {
  'KUMIKO_TEST_RESOLVE_TIMEOUT_MS': '600',
};

/// Generous, for tests that delay a resolution without timing it out.
const Map<String, String> longTimeout = {
  'KUMIKO_TEST_RESOLVE_TIMEOUT_MS': '8000',
};

void main() {
  setUpAll(buildTestHost);

  late Directory profile;
  late Directory root;
  setUp(() {
    profile = tempDir('ws_profile_');
    root = tempDir('ws_root_');
  });
  tearDown(() async {
    await deleteTree(root);
    await deleteTree(profile);
  });

  Directory folder(String name) =>
      Directory(joinPath(root.path, name))..createSync();

  /// The canonical path and identity the host should report for [dir].
  ResolvedDirectory resolved(Directory dir) =>
      directoryIdentity(dir.path) as ResolvedDirectory;

  Future<Desktop> start({Map<String, String>? environment}) async {
    final desktop = await Desktop.start(profile, environment: environment);
    addTearDown(desktop.dispose);
    await desktop.waitState();
    return desktop;
  }

  /// Ends the host so the test can change the store, then starts another.
  Future<void> stopHost(Desktop desktop) => desktop.session.quit();

  Future<void> restart(Desktop desktop) async {
    await desktop.restart();
    await desktop.waitState();
  }

  /// Moves [dir] aside and creates an empty directory at its path, which
  /// has another identity (the old one is still in use, so it is not reused).
  Directory replace(Directory dir) {
    dir.renameSync('${dir.path}_old');
    return Directory(dir.path)..createSync();
  }

  Future<String?> refusal(Future<Object?> call) => call.then(
    (_) => null,
    onError: (Object e) => e is RpcException ? e.reason : '$e',
  );

  test('open returns canonical path and identity', () async {
    final checkout = folder('checkout')..createSync();
    Directory(joinPath(checkout.path, '.git')).createSync();
    final desktop = await start();

    final result = await desktop.openWorkspace(checkout.path);

    final expected = resolved(checkout);
    expect(result.existing, isFalse);
    expect(result.workspace.path, expected.realPath);
    expect(result.workspace.identity, expected.id);
    expect(result.workspace.label, 'checkout');
    expect(result.workspace.availability, Availability.available);
    expect(result.workspace.cleanup.groups, 0);
    expect(result.cleanupRevision, greaterThan(0));
    final rows = LedgerView(profile).workspaces();
    expect(rows, hasLength(1));
    expect(rows.single['id'], result.workspace.id);
    expect(rows.single['path'], expected.realPath);
    expect(rows.single['identity'], expected.id);
    expect(rows.single['label'], 'checkout');
  });

  test('plain directory opens as a workspace', () async {
    final plain = folder('plain');
    final desktop = await start();

    final result = await desktop.openWorkspace(plain.path);

    expect(result.existing, isFalse);
    expect(result.workspace.label, 'plain');
    expect(result.workspace.availability, Availability.available);
    expect(LedgerView(profile).workspaces(), hasLength(1));
  });

  test(
    'link or junction to an open directory returns it as existing',
    () async {
      final real = folder('real');
      final link = Link(joinPath(root.path, 'link'))
        ..createSync(real.path); // a junction on Windows
      final desktop = await start();
      final first = await desktop.openWorkspace(real.path);

      final again = await desktop.openWorkspace(link.path);

      expect(again.existing, isTrue);
      expect(again.workspace.id, first.workspace.id);
      expect(again.workspace.path, first.workspace.path);
      expect(LedgerView(profile).workspaces(), hasLength(1));
    },
  );

  test('opening a renamed directory moves its workspace to the new path', () async {
    final dir = folder('before');
    final desktop = await start();
    final first = (await desktop.openWorkspace(dir.path)).workspace;
    final moved = Directory(joinPath(root.path, 'after'));
    dir.renameSync(moved.path);

    final again = await desktop.openWorkspace(moved.path);

    final expected = resolved(moved);
    expect(expected.id, first.identity, reason: 'a rename keeps identity');
    expect(again.existing, isTrue);
    expect(again.workspace.id, first.id);
    expect(again.workspace.path, expected.realPath);
    expect(again.workspace.label, 'after');
    expect(again.workspace.availability, Availability.available);
    final rows = LedgerView(profile).workspaces();
    expect(rows, hasLength(1));
    expect(rows.single['path'], expected.realPath);
    expect(rows.single['label'], 'after');

    // Still available on the next check, at the new path.
    final checked = await desktop.checkWorkspace(first.id);
    expect(checked.workspace.availability, Availability.available);
    expect(checked.workspace.path, expected.realPath);
  });

  test('a workspace removed while its old path is checked is opened '
      'as a new one', () async {
    final dir = folder('before');
    final desktop = await start(environment: longTimeout);
    final first = (await desktop.openWorkspace(dir.path)).workspace;
    final moved = Directory(joinPath(root.path, 'after'));
    dir.renameSync(moved.path);
    // The open checks the stored (canonical) old path to see whether the
    // directory moved; temp paths are not canonical on every runner.
    final old = first.path;
    await desktop.resolveFault(old, hang: true);

    final open = desktop.openWorkspace(moved.path);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await desktop.removeWorkspace(first.id);
    await desktop.releaseResolve(old);
    final again = await open;

    expect(again.existing, isFalse);
    expect(again.workspace.id, isNot(first.id));
    expect(again.workspace.path, resolved(moved).realPath);
    final listed = (await desktop.listWorkspaces()).workspaces;
    expect(listed.map((w) => w.id), [again.workspace.id]);
    final rows = LedgerView(profile).workspaces();
    expect(rows, hasLength(1));
    expect(rows.single['id'], again.workspace.id);
  });

  test('replaced directory at the same path keeps the id and updates '
      'identity', () async {
    final dir = folder('project');
    final desktop = await start();
    final first = await desktop.openWorkspace(dir.path);

    final fresh = replace(dir);
    final again = await desktop.openWorkspace(fresh.path);

    expect(again.existing, isTrue);
    expect(again.workspace.id, first.workspace.id);
    expect(again.workspace.identity, resolved(fresh).id);
    expect(again.workspace.identity, isNot(first.workspace.identity));
    final rows = LedgerView(profile).workspaces();
    expect(rows, hasLength(1));
    expect(rows.single['identity'], resolved(fresh).id);
  });

  test('missing path is refused target-unavailable and adds no row', () async {
    final desktop = await start();

    expect(
      await refusal(desktop.openWorkspace(joinPath(root.path, 'nowhere'))),
      ErrorCode.targetUnavailable,
    );

    expect(LedgerView(profile).workspaces(), isEmpty);
    expect((await desktop.listWorkspaces()).workspaces, isEmpty);
  });

  test('hung resolution is refused resolve-timeout while control keeps '
      'answering', () async {
    final dir = folder('hung');
    final desktop = await start(environment: shortTimeout);
    await desktop.resolveFault(dir.path, hang: true);

    final open = refusal(desktop.openWorkspace(dir.path));
    // Control keeps answering while the resolution hangs.
    final clock = Stopwatch()..start();
    final list = await desktop.listWorkspaces();
    final cleanup = await desktop.list();
    expect(clock.elapsed, lessThan(const Duration(milliseconds: 400)));
    expect(list.workspaces, isEmpty);
    expect(cleanup.workspaces, isEmpty);

    expect(await open, ErrorCode.resolveTimeout);
    expect(LedgerView(profile).workspaces(), isEmpty);
    await desktop.releaseResolve(dir.path);
  });

  test('a fifth resolution is refused busy while four hang', () async {
    final dirs = [for (var i = 0; i < 5; i++) folder('d$i')];
    final desktop = await start(environment: shortTimeout);
    for (final d in dirs.take(4)) {
      await desktop.resolveFault(d.path, hang: true);
    }
    final hung = [
      for (final d in dirs.take(4)) refusal(desktop.openWorkspace(d.path)),
    ];

    expect(await refusal(desktop.openWorkspace(dirs[4].path)), ErrorCode.busy);
    expect(await Future.wait(hung), everyElement(ErrorCode.resolveTimeout));
    // Timed out but not returned: the slots stay held.
    expect(await refusal(desktop.openWorkspace(dirs[4].path)), ErrorCode.busy);

    for (final d in dirs.take(4)) {
      await desktop.releaseResolve(d.path);
    }
    await eventually(
      () async =>
          await refusal(desktop.openWorkspace(dirs[4].path)) != ErrorCode.busy,
      reason: 'slots were not released',
    );
    expect((await desktop.listWorkspaces()).workspaces, hasLength(1));
  });

  test('65th open is refused workspace-cap', () async {
    expect(HostOptions.defaultWorkspaceCap, 64);
    final desktop = await start();
    for (var i = 0; i < 64; i++) {
      await desktop.openWorkspace(folder('w$i').path);
    }
    expect(LedgerView(profile).workspaces(), hasLength(64));

    expect(
      await refusal(desktop.openWorkspace(folder('w64').path)),
      ErrorCode.workspaceCap,
    );
    expect(LedgerView(profile).workspaces(), hasLength(64));

    // A known directory is still returned: it adds no row.
    final known = await desktop.openWorkspace(joinPath(root.path, 'w3'));
    expect(known.existing, isTrue);
  });

  test('load returns checking then workspace/changed unavailable for a '
      'missing directory', () async {
    final a = folder('a');
    final b = folder('b');
    final desktop = await start();
    final recordA = (await desktop.openWorkspace(a.path)).workspace;
    final recordB = (await desktop.openWorkspace(b.path)).workspace;
    await stopHost(desktop);
    b.renameSync('${b.path}_moved');

    await restart(desktop);
    final load = await desktop.loadWorkbench();

    expect(load.layout, isNull);
    expect(load.revision, 0);
    expect(load.workspaces.map((w) => w.id), [recordA.id, recordB.id]);
    expect(
      load.workspaces.map((w) => w.availability),
      everyElement(Availability.checking),
    );
    final gone = await desktop.waitChange(
      recordB.id,
      where: (w) => w.availability != Availability.checking,
    );
    expect(gone.workspace.availability, Availability.unavailable);
    expect(gone.workspace.reason, isNotEmpty);
    final here = await desktop.waitChange(
      recordA.id,
      where: (w) => w.availability != Availability.checking,
    );
    expect(here.workspace.availability, Availability.available);
    expect(here.workspace.seq, greaterThan(load.workspaces.first.seq));
  });

  test('queued load checks finish unavailable when every slot hangs', () async {
    final dirs = [for (var i = 0; i < 5; i++) folder('q$i')];
    final desktop = await start(environment: shortTimeout);
    final records = [
      for (final d in dirs) (await desktop.openWorkspace(d.path)).workspace,
    ];
    await stopHost(desktop);
    await restart(desktop);
    for (final r in records.take(4)) {
      await desktop.resolveFault(r.path, hang: true);
    }

    await desktop.loadWorkbench();

    final queued = await desktop.waitChange(
      records[4].id,
      where: (w) => w.availability != Availability.checking,
    );
    expect(queued.workspace.availability, Availability.unavailable);
    expect(queued.workspace.reason, 'host busy resolving folders');
    final stuck = await desktop.waitChange(
      records[0].id,
      where: (w) => w.availability != Availability.checking,
    );
    expect(stuck.workspace.reason, 'not answering');
    for (final r in records.take(4)) {
      await desktop.releaseResolve(r.path);
    }
  });

  test('older resolution finishing last is not applied', () async {
    final dir = folder('slow');
    final desktop = await start(environment: longTimeout);
    final opened = (await desktop.openWorkspace(dir.path)).workspace;
    await stopHost(desktop);
    await restart(desktop);

    // The startup check sees the directory as it is now, and reports late.
    await desktop.resolveFault(opened.path, delayMs: 1500);
    await desktop.loadWorkbench();
    final fresh = replace(dir);
    final checked = await desktop.checkWorkspace(opened.id);

    final newIdentity = resolved(fresh).id;
    expect(checked.workspace.availability, Availability.available);
    expect(checked.workspace.identity, newIdentity);
    // Give the older resolution time to finish, then look again.
    await Future<void>.delayed(const Duration(milliseconds: 2000));
    final shown = (await desktop.listWorkspaces()).workspaces.single;
    expect(shown.identity, newIdentity);
    expect(shown.seq, checked.workspace.seq);
    expect(
      desktop.changesOf(opened.id).map((c) => c.workspace.identity),
      everyElement(newIdentity),
    );
    expect(LedgerView(profile).workspaces().single['identity'], newIdentity);
  });

  test('late completion after timeout changes nothing', () async {
    final dir = folder('late');
    final desktop = await start(environment: shortTimeout);
    final opened = (await desktop.openWorkspace(dir.path)).workspace;
    final fresh = replace(dir);
    await desktop.resolveFault(opened.path, hang: true);

    final checked = await desktop.checkWorkspace(opened.id);

    expect(checked.workspace.availability, Availability.unavailable);
    expect(checked.workspace.reason, 'not answering');
    final published = desktop.changesOf(opened.id).length;

    await desktop.releaseResolve(opened.path);
    // The released call returns the new directory, which must not show.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final shown = (await desktop.listWorkspaces()).workspaces.single;
    expect(shown.availability, Availability.unavailable);
    expect(shown.identity, opened.identity);
    expect(shown.seq, checked.workspace.seq);
    expect(desktop.changesOf(opened.id), hasLength(published));
    expect(
      LedgerView(profile).workspaces().single['identity'],
      opened.identity,
      reason: 'stored identity is unchanged (new one is ${resolved(fresh).id})',
    );
  });

  test('Check again after restore reports available', () async {
    final dir = folder('restore');
    final desktop = await start();
    final opened = (await desktop.openWorkspace(dir.path)).workspace;
    dir.renameSync('${dir.path}_away');

    final gone = await desktop.checkWorkspace(opened.id);
    expect(gone.workspace.availability, Availability.unavailable);
    expect(gone.workspace.reason, isNotEmpty);

    Directory('${dir.path}_away').renameSync(dir.path);
    final back = await desktop.checkWorkspace(opened.id);
    expect(back.workspace.availability, Availability.available);
    expect(back.workspace.reason, isNull);
    expect(back.workspace.seq, greaterThan(gone.workspace.seq));
  });

  test('workspace record counts unresolved groups', () async {
    final dir = folder('counted');
    final desktop = await start();
    final opened = (await desktop.openWorkspace(dir.path)).workspace;
    await stopHost(desktop);
    await withStore(profile, (store) {
      seedInstance(
        store,
        desktopPid: pid,
        desktopStartedAt: processStartTime(pid),
      );
      for (var i = 0; i < 2; i++) {
        seedUnit(
          store,
          id: 'u$i',
          state: 'unresolved',
          path: opened.path,
          identity: opened.identity,
        );
      }
      seedUnit(
        store,
        id: 'other',
        state: 'unresolved',
        path: '/elsewhere',
        identity: 'other:1',
      );
    });

    await restart(desktop);
    final listed = (await desktop.listWorkspaces()).workspaces.single;

    expect(listed.cleanup.groups, 1);
    final load = await desktop.loadWorkbench();
    expect(load.workspaces.single.cleanup.groups, 1);
    expect(
      load.cleanupRevision,
      (await desktop.listWorkspaces()).cleanupRevision,
    );
  });

  test('cleanup/list workspace filter pages old identities at the same '
      'path', () async {
    final dir = folder('replaced');
    final desktop = await start();
    final opened = (await desktop.openWorkspace(dir.path)).workspace;
    await stopHost(desktop);
    final fresh = replace(dir);
    const old = 21;
    await withStore(profile, (store) {
      seedInstance(
        store,
        desktopPid: pid,
        desktopStartedAt: processStartTime(pid),
      );
      // Units of the directory this path used to be, under many identities.
      for (var i = 0; i < old; i++) {
        seedUnit(
          store,
          id: 'old-$i',
          state: 'unresolved',
          path: opened.path,
          identity: 'old:${i.toString().padLeft(3, '0')}',
        );
      }
      // Units of the directory now there, and of an unrelated one.
      seedUnit(
        store,
        id: 'now',
        state: 'unresolved',
        path: opened.path,
        identity: resolved(fresh).id,
      );
      seedUnit(
        store,
        id: 'noise',
        state: 'unresolved',
        path: '/elsewhere',
        identity: 'noise:1',
      );
    });

    await restart(desktop);
    await desktop.openWorkspace(fresh.path); // identity is now the new one
    final record = (await desktop.listWorkspaces()).workspaces.single;
    expect(record.id, opened.id);
    expect(record.cleanup.groups, old + 1);

    final identities = <String>[];
    var pages = 0;
    String? cursor;
    do {
      final page = await desktop.list(
        workspace: opened.id,
        limit: 10,
        cursor: cursor,
      );
      identities.addAll(page.workspaces.map((w) => w.targetIdentity));
      cursor = page.nextCursor;
      pages++;
    } while (cursor != null);

    expect(pages, 3);
    expect(identities, hasLength(old + 1));
    expect(identities.toSet(), hasLength(old + 1));
    expect(identities, isNot(contains('noise:1')));
    expect(identities, contains(resolved(fresh).id));
    expect(identities, contains('old:000'));
    expect(
      await refusal(desktop.list(workspace: 'no-such-workspace')),
      ErrorCode.unknownWorkspace,
    );
  });

  test('remove deletes the row only and the directory is untouched', () async {
    final dir = folder('removed');
    File(joinPath(dir.path, 'keep.txt')).writeAsStringSync('mine');
    final desktop = await start();
    final opened = (await desktop.openWorkspace(dir.path)).workspace;

    final removed = await desktop.removeWorkspace(opened.id);

    expect(removed.revision, 0);
    expect((await desktop.listWorkspaces()).workspaces, isEmpty);
    expect(LedgerView(profile).workspaces(), isEmpty);
    expect(File(joinPath(dir.path, 'keep.txt')).readAsStringSync(), 'mine');
    expect(
      await refusal(desktop.removeWorkspace(opened.id)),
      ErrorCode.unknownWorkspace,
    );

    await stopHost(desktop);
    await restart(desktop);
    expect((await desktop.listWorkspaces()).workspaces, isEmpty);
    expect((await desktop.loadWorkbench()).workspaces, isEmpty);
  });

  test('remove clears stored contexts at the next revision', () async {
    final desktop = await start();
    final opened = (await desktop.openWorkspace(folder('ctx').path)).workspace;
    LayoutDocument withContext() => LayoutDocument(
      root: TabGroup(
        id: 'g1',
        context: opened.id,
        tabs: const [],
        active: null,
      ),
      focusedGroup: 'g1',
      recent: const [],
      sidebarCollapsed: false,
    );
    await desktop.saveWorkbench(layoutToJson(withContext()), 3);

    final removed = await desktop.removeWorkspace(opened.id);

    expect(removed.revision, 4);
    expect(LedgerView(profile).workspaces(), isEmpty);
    await stopHost(desktop);
    await withStore(profile, (store) {
      final row = store
          .select(
            "SELECT layout, revision FROM working_set WHERE id = 'personal'",
          )
          .single;
      expect(row['revision'], 4);
      final stored = decodeLayout(row['layout'] as String);
      expect(stored.groups.single.context, isNull);
    });
    await restart(desktop);
    final load = await desktop.loadWorkbench();
    expect(load.revision, 4);
    expect(jsonEncode(load.layout), isNot(contains(opened.id)));
  });

  test('check in flight at removal publishes nothing', () async {
    final dir = folder('inflight');
    final desktop = await start(environment: longTimeout);
    final opened = (await desktop.openWorkspace(dir.path)).workspace;
    await desktop.resolveFault(opened.path, delayMs: 1000);
    final before = desktop.changesOf(opened.id).length;

    final check = refusal(desktop.checkWorkspace(opened.id));
    await desktop.removeWorkspace(opened.id);
    await check; // the check ends; its answer is not the point
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect((await desktop.listWorkspaces()).workspaces, isEmpty);
    expect(LedgerView(profile).workspaces(), isEmpty);
    expect(desktop.changesOf(opened.id), hasLength(before));
  });

  test('remove refused workspace-in-use', () async {
    final dir = folder('bound');
    final desktop = await start();
    final opened = (await desktop.openWorkspace(dir.path)).workspace;
    await stopHost(desktop);
    final layout = LayoutDocument(
      root: TabGroup(
        id: 'g1',
        context: opened.id,
        tabs: [
          LayoutTab(
            id: 't1',
            kind: 'terminal',
            workspace: opened.id,
            item: null,
          ),
        ],
        active: 't1',
      ),
      focusedGroup: 'g1',
      recent: const ['t1'],
      sidebarCollapsed: false,
    );
    await withStore(profile, (store) {
      store.execute(
        "UPDATE working_set SET layout = ?, layout_format = 1, revision = 3 "
        "WHERE id = 'personal'",
        [encodeLayout(layout)],
      );
    });
    await restart(desktop);

    final load = await desktop.loadWorkbench();
    expect(load.revision, 3);
    expect(load.layout, isNotNull);
    expect(
      await refusal(desktop.removeWorkspace(opened.id)),
      ErrorCode.workspaceInUse,
    );
    expect(LedgerView(profile).workspaces(), hasLength(1));
    expect((await desktop.listWorkspaces()).workspaces, hasLength(1));
  });
}
