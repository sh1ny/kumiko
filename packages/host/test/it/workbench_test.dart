import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:domain/domain.dart';
import 'package:host/src/profile_lock.dart';
import 'package:host/src/store/store.dart';
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

  LayoutDocument ok(LayoutResult r) => r.document!;

  PaneNode pane(
    String id, {
    String kind = 'terminal',
    String? workspace,
    String? item,
    Map<String, Object?> state = const {},
  }) => PaneNode(
    id: id,
    kind: kind,
    workspace: workspace,
    item: item,
    state: state,
  );

  /// One one-pane tab per entry of [bindings] (tab `t<i>`, pane `p<i>`).
  LayoutDocument layout({List<String?> bindings = const [], String? selected}) {
    var d = const LayoutDocument.initial();
    for (var i = 0; i < bindings.length; i++) {
      d = ok(d.openTab(pane('p$i', workspace: bindings[i]), tabId: 't$i'));
    }
    return d.copyWith(selectedWorkspace: selected);
  }

  /// Writes a layout straight into the stopped host's store.
  Future<void> storeLayout(String layout, int format, int revision) =>
      withStore(profile, (store) {
        store.execute(
          'UPDATE working_set SET layout = ?, layout_format = ?, '
          "revision = ? WHERE id = 'personal'",
          [layout, format, revision],
        );
      });

  Json json(LayoutDocument d) => layoutToJson(d);

  Future<RpcException> failure(Future<Object?> call) async {
    try {
      await call;
    } on RpcException catch (e) {
      return e;
    }
    fail('expected an RpcException');
  }

  test('binding and selection survive save, host restart and load', () async {
    final desktop = await start();
    final id = await open(desktop, 'one');

    final saved = await desktop.saveWorkbench(
      json(layout(bindings: [id], selected: id)),
      1,
    );
    await restart(desktop);
    final load = await desktop.loadWorkbench();

    expect(saved.revision, 1);
    expect(load.revision, 1);
    expect(load.restoreError, isNull);
    final back = layoutFromJson(load.layout);
    expect(back.panes.single.workspace, id);
    expect(back.selectedWorkspace, id);
    expect(load.workspaces.map((w) => w.id), [id]);
  });

  test('a one-pane terminal tab keeps its profile across restart', () async {
    final desktop = await start();
    const state = {'profileId': 'builtin:bash', 'profileName': 'bash'};
    final doc = ok(
      const LayoutDocument.initial().openTab(
        pane('p0', item: '0b6b7d8e-2f5a-4c1e-9d3a-6f1b2c3d4e5f', state: state),
        tabId: 't0',
      ),
    );

    await desktop.saveWorkbench(json(doc), 1);
    await restart(desktop);
    final load = await desktop.loadWorkbench();

    expect(load.restoreError, isNull);
    final p = layoutFromJson(load.layout).panes.single;
    expect(p.kind, 'terminal');
    expect(p.item, '0b6b7d8e-2f5a-4c1e-9d3a-6f1b2c3d4e5f');
    expect(p.state, state);
    expect(LedgerView(profile).units(), isEmpty, reason: 'no unit started');
  });

  test(
    'a terminal beside an overview and an unknown kind survive restart',
    () async {
      final desktop = await start();
      final id = await open(desktop, 'one');
      var d = ok(
        const LayoutDocument.initial().openTab(
          pane(
            'term',
            workspace: id,
            item: 'uuid-1',
            state: {'profileId': 'builtin:bash', 'profileName': 'bash'},
          ),
          tabId: 't0',
        ),
      );
      d = ok(
        d.splitPane(
          'term',
          SplitDirection.horizontal,
          pane('ov', kind: 'workspace-overview', workspace: id, item: id),
          splitId: 's0',
        ),
      );
      d = ok(
        d.splitPane(
          'ov',
          SplitDirection.vertical,
          pane(
            'odd',
            kind: 'chat-over-acp',
            state: {
              'n': [1, 2],
            },
          ),
          splitId: 's1',
        ),
      );
      d = ok(d.setRatio('s0', 0.3));

      await desktop.saveWorkbench(json(d), 1);
      await restart(desktop);
      final load = await desktop.loadWorkbench();

      expect(load.restoreError, isNull);
      expect(load.layout, json(d));
      expect(LedgerView(profile).units(), isEmpty);
    },
  );

  test('a closed tab is absent after save, host restart and load', () async {
    final desktop = await start();
    final id = await open(desktop, 'one');
    final two = layout(bindings: [id, id]);
    await desktop.saveWorkbench(json(two), 1);

    await desktop.saveWorkbench(json(ok(two.closeTab('t1'))), 2);
    await restart(desktop);
    final load = await desktop.loadWorkbench();

    expect(load.revision, 2);
    final back = layoutFromJson(load.layout);
    expect(back.tabs.map((t) => t.id), ['t0']);
    expect(back.panes.map((p) => p.id), ['p0']);
  });

  test('a closed pane is absent and its sibling holds its place', () async {
    final desktop = await start();
    var d = ok(const LayoutDocument.initial().openTab(pane('a'), tabId: 't0'));
    d = ok(
      d.splitPane('a', SplitDirection.horizontal, pane('b'), splitId: 's0'),
    );
    await desktop.saveWorkbench(json(d), 1);

    await desktop.saveWorkbench(json(ok(d.closePane('b'))), 2);
    await restart(desktop);
    final load = await desktop.loadWorkbench();

    final back = layoutFromJson(load.layout);
    expect(back.tabs.single.root, isA<PaneNode>());
    expect(back.panes.map((p) => p.id), ['a']);
    expect(back.tabs.single.focusedPane, 'a');
  });

  // Kills the host after a save: the stored layout is durable. Desktop loss
  // itself is covered by lifecycle_test ("killed desktop stand-in leaves no
  // host or marked process"), and the desktop sending its debounced save by
  // the desktop test "a change survives killing the desktop after the save
  // period".
  test('saved layout survives killing the host', () async {
    final desktop = await start();
    final id = await open(desktop, 'one');
    await desktop.saveWorkbench(json(layout(bindings: [id])), 1);

    Process.killPid(desktop.session.pid, ProcessSignal.sigkill);
    await desktop.session.lost.timeout(hostLossBound * 3);
    await desktop.restart();
    await desktop.waitState();
    final load = await desktop.loadWorkbench();

    expect(load.revision, 1);
    expect(layoutFromJson(load.layout).panes.single.workspace, id);
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
    await storeLayout('{"format":2,"tabs":42}', 2, 4);
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

  test(
    'a stored layout whose activeTab names no tab is a restoreError',
    () async {
      final desktop = await start();
      await desktop.session.quit();
      final bad = layoutToJson(layout(bindings: [null]))
        ..['activeTab'] = 'gone';
      await storeLayout(jsonEncode(bad), 2, 3);
      await desktop.restart();
      await desktop.waitState();

      final load = await desktop.loadWorkbench();

      expect(load.layout, isNull);
      expect(load.restoreError, contains('activeTab'));
      expect(load.revision, 3);
    },
  );

  test('a store upgraded from v3 with a format 1 layout loads no layout and '
      'no restoreError', () async {
    final lock = (await ProfileLock.tryAcquire(profile))!;
    Store.open(profile, lock, migrations: schemaMigrations.take(3).toList())
      ..execute(
        'UPDATE working_set SET layout = \'{"format":1,"root":{}}\', '
        'layout_format = 1, revision = 6',
      )
      ..close();
    await lock.release();

    final desktop = await start();
    final load = await desktop.loadWorkbench();

    expect(load.layout, isNull);
    expect(load.restoreError, isNull);
    expect(load.revision, 6);
    // The kept revision still guards saves.
    final e = await failure(desktop.saveWorkbench(json(layout()), 6));
    expect(e.reason, ErrorCode.staleRevision);
    expect((await desktop.saveWorkbench(json(layout()), 7)).revision, 7);
  });

  test('a format 1 save is refused layout-invalid', () async {
    final desktop = await start();
    final old = {
      'format': 1,
      'root': {
        'type': 'group',
        'id': 'g1',
        'context': null,
        'tabs': <Object?>[],
        'active': null,
      },
      'focusedGroup': 'g1',
      'recent': <Object?>[],
      'sidebar': {'collapsed': false},
    };

    final e = await failure(desktop.saveWorkbench(old, 1));

    expect(e.reason, ErrorCode.layoutInvalid);
    expect(e.message, contains('unsupported layout format 1'));
    expect((await desktop.loadWorkbench()).revision, 0);
  });

  test(
    'a missing selected workspace is repaired at load without an error',
    () async {
      final desktop = await start();
      final id = await open(desktop, 'one');
      await desktop.session.quit();
      await storeLayout(encodeLayout(layout(selected: 'gone-workspace')), 2, 2);
      await desktop.restart();
      await desktop.waitState();

      final load = await desktop.loadWorkbench();

      expect(load.restoreError, isNull);
      expect(layoutFromJson(load.layout).selectedWorkspace, isNull);
      expect(load.workspaces.map((w) => w.id), [id]);
    },
  );

  test(
    'a pane bound to an unknown workspace is refused layout-invalid',
    () async {
      final desktop = await start();

      final e = await failure(
        desktop.saveWorkbench(json(layout(bindings: ['nope'])), 1),
      );

      expect(e.reason, ErrorCode.layoutInvalid);
      expect(e.message, contains(ErrorCode.unknownWorkspace));
      expect((await desktop.loadWorkbench()).revision, 0);
    },
  );

  test('an oversized document is refused layout-invalid', () async {
    final desktop = await start();
    // Within every field bound, over the document bound: one big unknown key
    // is dropped by the decoder but counts toward the received size.
    final big = json(layout())..['padding'] = 'x' * (300 * 1024);
    expect(utf8.encode(jsonEncode(big)).length, greaterThan(maxDocumentBytes));

    final e = await failure(desktop.saveWorkbench(big, 1));

    expect(e.reason, ErrorCode.layoutInvalid);
    expect((await desktop.loadWorkbench()).revision, 0);
  });
}
