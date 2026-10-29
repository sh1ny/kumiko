import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:domain/domain.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

void main() {
  setUpAll(buildTestHost);

  late Directory profile;
  late Directory root;
  setUp(() {
    profile = tempDir('wb_profile_');
    root = tempDir('wb_root_');
  });
  tearDown(() async {
    await deleteTree(root);
    await deleteTree(profile);
  });

  Future<Desktop> start() async {
    final desktop = await Desktop.start(profile);
    addTearDown(desktop.dispose);
    await desktop.waitState();
    return desktop;
  }

  Future<void> restart(Desktop desktop) async {
    await desktop.session.quit();
    await desktop.restart();
    await desktop.waitState();
  }

  Future<String> open(Desktop desktop, String name) async {
    final dir = Directory(joinPath(root.path, name))..createSync();
    return (await desktop.openWorkspace(dir.path)).workspace.id;
  }

  /// One group with a tab per entry of [bindings] (tab id `t<i>`), the group
  /// context [context].
  LayoutDocument layout({List<String?> bindings = const [], String? context}) {
    final tabs = [
      for (var i = 0; i < bindings.length; i++)
        LayoutTab(
          id: 't$i',
          kind: 'terminal',
          workspace: bindings[i],
          item: null,
        ),
    ];
    return LayoutDocument(
      root: TabGroup(
        id: 'g1',
        context: context,
        tabs: tabs,
        active: tabs.isEmpty ? null : tabs.first.id,
      ),
      focusedGroup: 'g1',
      recent: [for (final t in tabs) t.id],
      sidebarCollapsed: false,
    );
  }

  Json json(LayoutDocument d) => layoutToJson(d);

  Future<RpcException> failure(Future<Object?> call) async {
    try {
      await call;
    } on RpcException catch (e) {
      return e;
    }
    fail('expected an RpcException');
  }

  test('binding survives save, host restart and load', () async {
    final desktop = await start();
    final id = await open(desktop, 'one');

    final saved = await desktop.saveWorkbench(
      json(layout(bindings: [id], context: id)),
      1,
    );
    await restart(desktop);
    final load = await desktop.loadWorkbench();

    expect(saved.revision, 1);
    expect(load.revision, 1);
    expect(load.restoreError, isNull);
    final back = layoutFromJson(load.layout);
    expect(back.tabs.single.workspace, id);
    expect(back.groups.single.context, id);
    expect(load.workspaces.map((w) => w.id), [id]);
  });

  test('a closed tab is absent after save, host restart and load', () async {
    final desktop = await start();
    final id = await open(desktop, 'one');
    await desktop.saveWorkbench(json(layout(bindings: [id, id])), 1);

    await desktop.saveWorkbench(json(layout(bindings: [id])), 2);
    await restart(desktop);
    final load = await desktop.loadWorkbench();

    expect(load.revision, 2);
    expect(layoutFromJson(load.layout).tabs.map((t) => t.id), ['t0']);
  });

  test('saved layout survives killing the desktop stand-in', () async {
    final desktop = await start();
    final id = await open(desktop, 'one');
    await desktop.saveWorkbench(json(layout(bindings: [id])), 1);

    Process.killPid(desktop.session.pid, ProcessSignal.sigkill);
    await desktop.session.lost.timeout(hostLossBound * 3);
    await desktop.restart();
    await desktop.waitState();
    final load = await desktop.loadWorkbench();

    expect(load.revision, 1);
    expect(layoutFromJson(load.layout).tabs.single.workspace, id);
  });

  test(
    'equal revision is refused stale-revision with the stored one',
    () async {
      final desktop = await start();
      await desktop.saveWorkbench(json(layout()), 5);

      final e = await failure(desktop.saveWorkbench(json(layout()), 5));

      expect(e.reason, ErrorCode.staleRevision);
      expect(storedRevisionOf(e), 5);
    },
  );

  test('lower revision is refused stale-revision and stores nothing', () async {
    final desktop = await start();
    final id = await open(desktop, 'one');
    await desktop.saveWorkbench(json(layout()), 5);

    final e = await failure(
      desktop.saveWorkbench(json(layout(bindings: [id])), 3),
    );

    expect(e.reason, ErrorCode.staleRevision);
    expect(storedRevisionOf(e), 5);
    final load = await desktop.loadWorkbench();
    expect(load.revision, 5);
    expect(layoutFromJson(load.layout).tabs, isEmpty);
  });

  test(
    'injected save failure returns store-error and keeps the stored revision',
    () async {
      final desktop = await start();
      final id = await open(desktop, 'one');
      await desktop.saveWorkbench(json(layout()), 1);
      await desktop.setFault(TestFault.layoutSaveFails);

      final e = await failure(
        desktop.saveWorkbench(json(layout(bindings: [id])), 2),
      );

      expect(e.reason, ErrorCode.storeError);
      await desktop.setFault(TestFault.layoutSaveFails, enabled: false);
      final load = await desktop.loadWorkbench();
      expect(load.revision, 1);
      expect(layoutFromJson(load.layout).tabs, isEmpty);
      // The same revision can be saved once the fault is gone.
      expect((await desktop.saveWorkbench(json(layout()), 2)).revision, 2);
    },
  );

  test('a hung save is unanswered until the fault is cleared', () async {
    final desktop = await start();
    await desktop.setFault(TestFault.layoutSaveHangs);
    var answered = false;
    final save = desktop.saveWorkbench(json(layout()), 1).whenComplete(() {
      answered = true;
    });

    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(answered, isFalse);

    await desktop.setFault(TestFault.layoutSaveHangs, enabled: false);
    expect((await save).revision, 1);
  });

  test('invalid stored layout loads as restoreError with workspaces', () async {
    final desktop = await start();
    final id = await open(desktop, 'one');
    await desktop.session.quit();
    await withStore(profile, (store) {
      store.execute(
        "UPDATE working_set SET layout = '{\"format\":1,\"root\":42}', "
        "layout_format = 1, revision = 4 WHERE id = 'personal'",
      );
    });
    await desktop.restart();
    await desktop.waitState();

    final load = await desktop.loadWorkbench();

    expect(load.layout, isNull);
    expect(load.restoreError, isNotEmpty);
    expect(load.revision, 4);
    expect(load.workspaces.map((w) => w.id), [id]);
    // The next save overwrites the row, above the stored revision.
    expect((await desktop.saveWorkbench(json(layout()), 5)).revision, 5);
    expect((await desktop.loadWorkbench()).restoreError, isNull);
  });

  test('a dangling context is repaired at load without an error', () async {
    final desktop = await start();
    final id = await open(desktop, 'one');
    await desktop.session.quit();
    await withStore(profile, (store) {
      store.execute(
        "UPDATE working_set SET layout = ?, layout_format = 1, revision = 2 "
        "WHERE id = 'personal'",
        [encodeLayout(layout(context: 'gone-workspace'))],
      );
    });
    await desktop.restart();
    await desktop.waitState();

    final load = await desktop.loadWorkbench();

    expect(load.restoreError, isNull);
    expect(layoutFromJson(load.layout).groups.single.context, isNull);
    expect(load.workspaces.map((w) => w.id), [id]);
  });

  test('a binding to an unknown workspace is refused layout-invalid', () async {
    final desktop = await start();

    final e = await failure(
      desktop.saveWorkbench(json(layout(bindings: ['nope'])), 1),
    );

    expect(e.reason, ErrorCode.layoutInvalid);
    expect(e.message, contains(ErrorCode.unknownWorkspace));
    expect((await desktop.loadWorkbench()).revision, 0);
  });

  test('an oversized document is refused layout-invalid', () async {
    final desktop = await start();
    // Within every field bound, over the document bound: many tabs with
    // large state would be refused by their own bounds, so a wide `recent`
    // is not an option either; one big unknown key is dropped by the decoder
    // but counts toward the received size.
    final big = json(layout())..['padding'] = 'x' * (300 * 1024);
    expect(utf8.encode(jsonEncode(big)).length, greaterThan(maxDocumentBytes));

    final e = await failure(desktop.saveWorkbench(big, 1));

    expect(e.reason, ErrorCode.layoutInvalid);
    expect((await desktop.loadWorkbench()).revision, 0);
  });
}
