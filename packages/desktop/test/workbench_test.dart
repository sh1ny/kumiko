import 'dart:async';
import 'dart:convert';

import 'package:desktop/src/cleanup_controller.dart';
import 'package:desktop/src/folder_picker.dart';
import 'package:desktop/src/layout_saver.dart';
import 'package:desktop/src/workbench_controller.dart';
import 'package:desktop/src/workbench_page.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:host_protocol/host_protocol.dart';

import 'support/fake_host.dart';

// --- fixtures ---------------------------------------------------------------

LayoutTab tabOf(
  String id, {
  String kind = 'note',
  String? ws,
  String? item,
  Map<String, Object?> state = const {},
}) => LayoutTab(id: id, kind: kind, workspace: ws, item: item, state: state);

TabGroup groupOf(
  String id, {
  String? ctx,
  List<LayoutTab> tabs = const [],
  String? active,
}) => TabGroup(
  id: id,
  context: ctx,
  tabs: tabs,
  active: active ?? (tabs.isEmpty ? null : tabs.first.id),
);

LayoutDocument docOf(
  LayoutNode root, {
  required String focused,
  bool collapsed = false,
  List<String> recent = const [],
}) => LayoutDocument(
  root: root,
  focusedGroup: focused,
  recent: recent,
  sidebarCollapsed: collapsed,
);

/// Two groups side by side.
LayoutDocument twoGroups(
  TabGroup a,
  TabGroup b, {
  String? focused,
  bool collapsed = false,
  List<String> recent = const [],
}) => docOf(
  SplitNode(
    id: 's1',
    direction: SplitDirection.horizontal,
    ratio: 0.5,
    first: a,
    second: b,
  ),
  focused: focused ?? a.id,
  collapsed: collapsed,
  recent: recent,
);

final _tracked = <ChangeNotifier>[];

T track<T extends ChangeNotifier>(T notifier) {
  _tracked.add(notifier);
  return notifier;
}

/// A widget test that disposes what it tracked inside the test, before the
/// framework checks for pending timers.
void uiTest(String name, Future<void> Function(WidgetTester tester) body) {
  testWidgets(name, (tester) async {
    try {
      await body(tester);
      await tester.pumpWidget(const SizedBox());
    } finally {
      for (final n in _tracked) {
        n.dispose();
      }
      _tracked.clear();
    }
  });
}

Json jsonOf(LayoutDocument d) =>
    jsonDecode(jsonEncode(layoutToJson(d))) as Json;

class FakePicker implements FolderPicker {
  String? next;
  int calls = 0;

  @override
  Future<String?> pickFolder() async {
    calls++;
    return next;
  }
}

/// A picker whose plugin call fails.
class _ThrowingPicker implements FolderPicker {
  @override
  Future<String?> pickFolder() async =>
      throw PlatformException(code: 'error', message: 'no portal');
}

Future<WorkbenchController> pumpWorkbench(
  WidgetTester tester,
  FakeHostLink link, {
  FolderPicker? picker,
  CleanupController? cleanup,
}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = WorkbenchController(picker: picker ?? FakePicker());
  track(controller);
  await tester.pumpWidget(
    MaterialApp(
      home: WorkbenchPage(controller: controller, cleanup: cleanup),
    ),
  );
  unawaited(controller.attach(link));
  await tester.pump();
  return controller;
}

FakeHostLink linkWith(
  LayoutDocument? layout, {
  List<WorkspaceRecord> records = const [],
  HelloResult? hello,
}) {
  final link = FakeHostLink(hello: hello);
  if (layout != null) link.storedLayout = jsonOf(layout);
  link.records.addAll(records);
  return link;
}

const ms500 = Duration(milliseconds: 500);

Finder key(String k) => find.byKey(Key(k));

Finder inside(String k, Finder f) => find.descendant(of: key(k), matching: f);

// --- the saver (D6), without a widget ---------------------------------------

class SaveProbe {
  final calls = <({Json layout, int revision, Completer<WorkbenchSaveResult> done})>[];

  Future<WorkbenchSaveResult> call(Json layout, int revision) {
    final done = Completer<WorkbenchSaveResult>();
    calls.add((layout: layout, revision: revision, done: done));
    return done.future;
  }

  void ok(int index) =>
      calls[index].done.complete(WorkbenchSaveResult(calls[index].revision));
  void fail(int index, Object error) => calls[index].done.completeError(error);
}

Json snap(int n) => {'n': n};

void main() {
  group('layout saver', () {
    uiTest('continuous changes are saved at least every 2 s (fake clock)', (
      tester,
    ) async {
      var now = 0;
      final saved = <({int at, int n})>[];
      final saver = LayoutSaver(
        save: (layout, revision) async {
          saved.add((at: now, n: layout['n']! as int));
          return WorkbenchSaveResult(revision);
        },
      );
      track(saver);
      final changedAt = <int, int>{};
      var n = 0;
      // A change every 400 ms for 10 s: the 500 ms quiet period never ends.
      for (var step = 0; step < 100; step++) {
        final t = step * 100;
        if (t > 0 && t % 400 == 0) {
          n++;
          changedAt[n] = t;
          saver.change(snap(n));
        }
        now = t + 100; // an upper bound on when a timer in this step fires
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(saved.length, greaterThanOrEqualTo(4));
      for (final entry in changedAt.entries) {
        if (entry.value > 7900) continue; // saved after the loop ends
        expect(
          saved.any(
            (s) => s.n >= entry.key && s.at <= entry.value + 2000,
          ),
          isTrue,
          reason: 'change ${entry.key} at ${entry.value} ms saved within 2 s',
        );
      }
    });

    uiTest('a change is sent after 500 ms of quiet, once', (tester) async {
      final probe = SaveProbe();
      final saver = LayoutSaver(save: probe.call, revision: 3);
      track(saver);
      saver.change(snap(1));
      await tester.pump(const Duration(milliseconds: 499));
      expect(probe.calls, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(probe.calls, hasLength(1));
      expect(probe.calls.single.revision, 4);
      expect(saver.state, SaveState.inFlight);
      probe.ok(0);
      await tester.pump();
      expect(saver.state, SaveState.clean);
      expect(saver.acknowledged, 4);
    });

    uiTest('answered saves release their bookkeeping', (tester) async {
      final probe = SaveProbe();
      final saver = LayoutSaver(save: probe.call);
      track(saver);
      for (var i = 0; i < 5; i++) {
        saver.change(snap(i));
        await tester.pump(ms500);
        probe.ok(i);
        await tester.pump();
      }
      expect(saver.state, SaveState.clean);
      expect(saver.unansweredSaves, 0);

      // A save that timed out keeps its entry until its late answer.
      saver.change(snap(9));
      await tester.pump(ms500);
      await tester.pump(const Duration(seconds: 10));
      expect(saver.state, SaveState.failed);
      expect(saver.unansweredSaves, 1);
      probe.ok(5);
      await tester.pump();
      expect(saver.state, SaveState.clean, reason: 'the late ok still counts');
      expect(saver.unansweredSaves, 0);
    });

    uiTest('a host that never answers holds at most 2 saves', (tester) async {
      final probe = SaveProbe();
      final saver = LayoutSaver(save: probe.call);
      track(saver);

      // Every save times out; changes and Retry keep coming.
      for (var i = 0; i < 6; i++) {
        saver.change(snap(i));
        await tester.pump(ms500);
        await tester.pump(const Duration(seconds: 10));
        saver.retry();
        await tester.pump();
      }
      expect(probe.calls, hasLength(2), reason: 'two unanswered at most');
      expect(saver.unansweredSaves, 2);
      expect(saver.notice, contains('Layout not saved'));

      // An answer frees a place: the newest snapshot is sent at once.
      probe.fail(
        0,
        ConnectionClosedException(const CloseReason(CloseReason.inputClosed)),
      );
      await tester.pump();
      expect(probe.calls, hasLength(3));
      expect(probe.calls[2].layout, snap(5));
      probe.ok(2);
      await tester.pump();
      expect(saver.state, SaveState.clean);
      expect(saver.notice, isNull);
    });

    uiTest('changes during a save send only the newest after it returns', (
      tester,
    ) async {
      final probe = SaveProbe();
      final saver = LayoutSaver(save: probe.call);
      track(saver);
      saver.change(snap(1));
      await tester.pump(ms500);
      saver.change(snap(2));
      saver.change(snap(3));
      await tester.pump(const Duration(seconds: 5));
      expect(probe.calls, hasLength(1), reason: 'one save in flight at most');
      probe.ok(0);
      await tester.pump();
      expect(probe.calls, hasLength(2));
      expect(probe.calls[1].layout, snap(3));
      expect(probe.calls[1].revision, 2);
      probe.ok(1);
      await tester.pump();
      expect(saver.state, SaveState.clean);
    });

    uiTest('the revision counter starts at the loaded one, never lowers', (
      tester,
    ) async {
      final probe = SaveProbe();
      final saver = LayoutSaver(save: probe.call, revision: 4);
      track(saver);
      saver.raiseCounter(2);
      saver.change(snap(1));
      await tester.pump(ms500);
      expect(probe.calls.single.revision, 5);
      probe.ok(0);
      await tester.pump();
      saver.raiseCounter(9);
      saver.change(snap(2));
      await tester.pump(ms500);
      expect(probe.calls[1].revision, 10);
    });

    uiTest('a save without an answer fails after 10 s; a change sends anew', (
      tester,
    ) async {
      final probe = SaveProbe();
      final saver = LayoutSaver(save: probe.call);
      track(saver);
      saver.change(snap(1));
      await tester.pump(ms500);
      await tester.pump(const Duration(seconds: 9));
      expect(saver.state, SaveState.inFlight);
      await tester.pump(const Duration(seconds: 1));
      expect(saver.state, SaveState.failed);
      expect(saver.notice, contains('the host did not answer'));
      saver.change(snap(2));
      expect(saver.state, SaveState.pending);
      await tester.pump(ms500);
      expect(probe.calls, hasLength(2), reason: 'the slot was freed');
      expect(probe.calls[1].layout, snap(2));
      expect(probe.calls[1].revision, 2);
    });

    uiTest('a late ok clears Failed when nothing changed after it', (
      tester,
    ) async {
      final probe = SaveProbe();
      final saver = LayoutSaver(save: probe.call);
      track(saver);
      saver.change(snap(1));
      await tester.pump(ms500);
      await tester.pump(const Duration(seconds: 10));
      expect(saver.state, SaveState.failed);
      probe.ok(0);
      await tester.pump();
      expect(saver.state, SaveState.clean);
      expect(saver.notice, isNull);
    });

    uiTest('a late ok keeps Failed when a change was made after it', (
      tester,
    ) async {
      final probe = SaveProbe();
      final saver = LayoutSaver(save: probe.call);
      track(saver);
      saver.change(snap(1));
      await tester.pump(ms500);
      saver.change(snap(2)); // made after snapshot 1 was taken
      await tester.pump(const Duration(seconds: 10));
      expect(saver.state, SaveState.failed);
      probe.ok(0);
      await tester.pump();
      expect(saver.state, SaveState.failed);
      expect(saver.notice, isNotNull);
      expect(saver.acknowledged, 1);
    });

    uiTest('a late error is ignored once a higher revision is acknowledged', (
      tester,
    ) async {
      final probe = SaveProbe();
      final saver = LayoutSaver(save: probe.call);
      track(saver);
      saver.change(snap(1));
      await tester.pump(ms500);
      await tester.pump(const Duration(seconds: 10));
      saver.retry();
      expect(probe.calls, hasLength(2));
      probe.ok(1);
      await tester.pump();
      expect(saver.state, SaveState.clean);
      probe.fail(0, RpcException(ErrorCode.storeError, 'late'));
      await tester.pump();
      expect(saver.state, SaveState.clean);
      expect(saver.notice, isNull);
    });

    uiTest('stale-revision resends above the counter and the stored one', (
      tester,
    ) async {
      final probe = SaveProbe();
      final saver = LayoutSaver(save: probe.call, revision: 5);
      track(saver);
      saver.change(snap(1));
      await tester.pump(ms500);
      expect(probe.calls.single.revision, 6);
      probe.fail(0, staleRevision(9));
      await tester.pump();
      expect(probe.calls, hasLength(2));
      expect(probe.calls[1].revision, 10);
      expect(probe.calls[1].layout, snap(1));
      probe.ok(1);
      await tester.pump();
      expect(saver.state, SaveState.clean);
    });

    uiTest('stale-revision is success when the snapshot was stored later', (
      tester,
    ) async {
      final probe = SaveProbe();
      final saver = LayoutSaver(save: probe.call);
      track(saver);
      saver.change(snap(1));
      await tester.pump(ms500);
      await tester.pump(const Duration(seconds: 10)); // call 0 timed out
      saver.retry(); // call 1: the same snapshot
      probe.ok(0); // the late one commits after all
      await tester.pump();
      probe.fail(1, staleRevision(1));
      await tester.pump();
      expect(probe.calls, hasLength(2), reason: 'no resend');
      expect(saver.state, SaveState.clean);
      expect(saver.notice, isNull);
    });

    uiTest('flush sends a pending change at once and waits for the ok', (
      tester,
    ) async {
      final probe = SaveProbe();
      final saver = LayoutSaver(save: probe.call);
      track(saver);
      saver.change(snap(1));
      var done = false;
      unawaited(saver.flush().then((_) => done = true));
      await tester.pump();
      expect(probe.calls, hasLength(1), reason: 'no debounce wait');
      expect(done, isFalse);
      probe.ok(0);
      await tester.pump();
      expect(done, isTrue);
    });

    uiTest('flush gives up after 2 s and sets the notice', (tester) async {
      final probe = SaveProbe();
      final saver = LayoutSaver(save: probe.call);
      track(saver);
      saver.change(snap(1));
      var done = false;
      unawaited(saver.flush().then((_) => done = true));
      await tester.pump(const Duration(seconds: 1));
      expect(done, isFalse);
      await tester.pump(const Duration(seconds: 1));
      expect(done, isTrue);
      expect(saver.notice, contains('Layout not saved'));
    });
  });

  group('workbench', () {
    uiTest('workbench and layout show while the host reconciles', (
      tester,
    ) async {
      final layout = twoGroups(
        groupOf('g1', ctx: 'A', tabs: [tabOf('t1', ws: 'A')]),
        groupOf('g2'),
      );
      final link = linkWith(
        layout,
        records: [workspaceRecord('A')],
        hello: helloResult(state: HostState.reconciling),
      );
      await pumpWorkbench(tester, link);

      expect(find.text('Personal'), findsOneWidget);
      expect(key('tab-t1'), findsOneWidget);
      expect(key('ws-A'), findsOneWidget);
      expect(find.textContaining('Cleaning up'), findsOneWidget);
    });

    uiTest('first launch shows Personal with one empty group', (
      tester,
    ) async {
      final c = await pumpWorkbench(tester, linkWith(null));
      expect(c.layout!.groupCount, 1);
      expect(c.layout!.tabCount, 0);
      expect(find.text('Personal'), findsOneWidget);
      expect(find.text('Open folder'), findsOneWidget);
      expect(find.byTooltip('New tab'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
    });

    uiTest('dragging a tab to another group keeps its binding', (
      tester,
    ) async {
      final layout = twoGroups(
        groupOf('g1', ctx: 'A', tabs: [
          tabOf('t0'),
          tabOf('t1', kind: workspaceOverviewKind, ws: 'A', item: 'A'),
        ]),
        groupOf('g2', ctx: 'B'),
      );
      final link = linkWith(
        layout,
        records: [workspaceRecord('A'), workspaceRecord('B')],
      );
      final c = await pumpWorkbench(tester, link);

      // The visible start of the tab (its center can lie behind the + button).
      final from = tester.getTopLeft(key('tab-t1')) + const Offset(20, 18);
      final to = tester.getCenter(key('group-g2'));
      final drag = await tester.startGesture(from);
      await drag.moveBy(const Offset(24, 0));
      await tester.pump();
      await drag.moveTo(to);
      await tester.pump();
      await drag.up();
      await tester.pump();

      final moved = c.layout!;
      expect(moved.groupOf('t1')!.id, 'g2');
      expect(moved.group('g2')!.active, 't1');
      expect(moved.tab('t1')!.workspace, 'A');
      expect(inside('group-g2', key('tab-t1')), findsOneWidget);
      expect(inside('group-g1', key('tab-t1')), findsNothing);
      expect(inside('group-g1', key('tab-t0')), findsOneWidget);
    });

    uiTest('split action reports the group limit', (tester) async {
      var d = LayoutDocument.initial('g1');
      var n = 1;
      var dir = SplitDirection.horizontal;
      // Balanced: every round splits every group once.
      while (d.groupCount < maxTabGroups) {
        for (final g in d.groups.toList()) {
          n++;
          d = d.split(g.id, dir, 'g$n', 's$n').document!;
          d = d.focusGroup('g1').document!;
        }
        dir = dir == SplitDirection.horizontal
            ? SplitDirection.vertical
            : SplitDirection.horizontal;
      }
      expect(d.groupCount, maxTabGroups);
      final c = await pumpWorkbench(tester, linkWith(d));
      expect(c.layout!.groupCount, maxTabGroups);

      await tester.tap(key('split-h-g1'));
      await tester.pump();

      expect(c.layout!.groupCount, maxTabGroups);
      expect(find.textContaining('16 tab groups'), findsOneWidget);
    });

    uiTest(
      '+ in an unfocused group opens the view there bound to that group\'s context',
      (tester) async {
        final layout = twoGroups(
          groupOf('g1', ctx: 'A', tabs: [tabOf('t0', ws: 'A')]),
          groupOf('g2', ctx: 'B'),
          focused: 'g1',
        );
        final link = linkWith(
          layout,
          records: [workspaceRecord('A'), workspaceRecord('B')],
        );
        final c = await pumpWorkbench(tester, link);

        await tester.tap(key('add-g2'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Workspace overview'));
        await tester.pumpAndSettle();

        final d = c.layout!;
        final g2 = d.group('g2')!;
        expect(g2.tabs, hasLength(1));
        expect(g2.tabs.single.kind, workspaceOverviewKind);
        expect(g2.tabs.single.workspace, 'B');
        expect(g2.active, g2.tabs.single.id);
        expect(d.focusedGroup, 'g2');
        expect(d.group('g1')!.tabs, hasLength(1));
      },
    );

    uiTest(
      'launcher without context marks workspace-needing kinds and offers Open folder',
      (tester) async {
        final c = await pumpWorkbench(tester, linkWith(null));

        await tester.tap(find.byTooltip('New tab'));
        await tester.pumpAndSettle();

        expect(find.textContaining('needs a workspace'), findsOneWidget);
        expect(find.text('Open folder...'), findsOneWidget);
        await tester.tap(find.textContaining('needs a workspace'));
        await tester.pumpAndSettle();
        expect(c.layout!.tabCount, 0, reason: 'no tab until a workspace');
      },
    );

    uiTest('launcher reports the tab limit', (tester) async {
      final tabs = [for (var i = 0; i < maxTabs; i++) tabOf('t$i', ws: 'A')];
      final layout = docOf(groupOf('g1', ctx: 'A', tabs: tabs), focused: 'g1');
      final c = await pumpWorkbench(
        tester,
        linkWith(layout, records: [workspaceRecord('A')]),
      );

      await tester.tap(key('add-g1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Workspace overview'));
      await tester.pumpAndSettle();

      expect(c.layout!.tabCount, maxTabs);
      expect(find.textContaining('128 tabs'), findsOneWidget);
    });

    uiTest(
      'tab bound to an unavailable workspace keeps its binding and shows unavailable',
      (tester) async {
        final layout = docOf(
          groupOf('g1', ctx: 'A', tabs: [
            tabOf('t1', kind: workspaceOverviewKind, ws: 'A', item: 'A'),
          ]),
          focused: 'g1',
        );
        final link = linkWith(
          layout,
          records: [
            workspaceRecord(
              'A',
              availability: Availability.unavailable,
              reason: 'folder missing',
            ),
          ],
        );
        final c = await pumpWorkbench(tester, link);

        expect(inside('tab-t1', find.text('unavailable')), findsOneWidget);
        expect(find.textContaining('folder missing'), findsWidgets);
        expect(c.layout!.tab('t1')!.workspace, 'A');
        expect(key('check-A'), findsOneWidget);
      },
    );

    uiTest('collapsing and expanding the sidebar keeps groups, tabs and focus', (
      tester,
    ) async {
      final layout = twoGroups(
        groupOf('g1', ctx: 'A', tabs: [tabOf('t1', ws: 'A')]),
        groupOf('g2', tabs: [tabOf('t2')]),
        focused: 'g2',
      );
      final c = await pumpWorkbench(
        tester,
        linkWith(layout, records: [workspaceRecord('A')]),
      );
      final before = jsonEncode(layoutToJson(c.layout!)['root']);

      await tester.tap(find.byTooltip('Collapse sidebar'));
      await tester.pump();
      expect(key('sidebar'), findsNothing);
      expect(find.byTooltip('Expand sidebar'), findsOneWidget);
      expect(c.layout!.sidebarCollapsed, isTrue);
      expect(c.layout!.focusedGroup, 'g2');
      expect(key('tab-t1'), findsOneWidget);
      expect(key('tab-t2'), findsOneWidget);

      await tester.tap(find.byTooltip('Expand sidebar'));
      await tester.pump();
      expect(key('sidebar'), findsOneWidget);
      expect(jsonEncode(layoutToJson(c.layout!)['root']), before);
      expect(c.layout!.focusedGroup, 'g2');
      await tester.pump(const Duration(seconds: 3)); // let the saves go
    });

    uiTest('a change survives killing the desktop after the save period', (
      tester,
    ) async {
      final layout = docOf(groupOf('g1'), focused: 'g1');
      final link = linkWith(layout);
      final c = await pumpWorkbench(tester, link);

      await tester.tap(find.byTooltip('Collapse sidebar'));
      await tester.pump(ms500);
      await tester.pump();

      // Killed: no flush, no quit, nothing more runs in this desktop.
      final sent = jsonOf(c.layout!);
      await tester.pumpWidget(const SizedBox());
      expect(link.calls.where((x) => x.startsWith('workbench/save')), hasLength(1));
      expect(link.quitCalled, isFalse);

      // The next launch: a new desktop and host on the same profile.
      final next = linkWith(null)
        ..storedLayout = link.storedLayout
        ..layoutRevision = link.layoutRevision;
      final reopened = await pumpWorkbench(tester, next);
      await tester.pump();

      expect(jsonOf(reopened.layout!), sent);
      expect(reopened.layout!.sidebarCollapsed, isTrue);
      expect(find.byTooltip('Expand sidebar'), findsOneWidget);
    });

    uiTest('collapsed sidebar is restored from load', (tester) async {
      final layout = docOf(groupOf('g1'), focused: 'g1', collapsed: true);
      await pumpWorkbench(tester, linkWith(layout));

      expect(key('sidebar'), findsNothing);
      expect(find.byTooltip('Expand sidebar'), findsOneWidget);
    });

    uiTest('Layout not saved notice with reason', (tester) async {
      final link = linkWith(null);
      link.saveAnswers.add(RpcException(ErrorCode.storeError, 'disk full'));
      final c = await pumpWorkbench(tester, link);

      await tester.tap(find.byTooltip('Collapse sidebar'));
      await tester.pump(ms500);
      await tester.pump();

      expect(find.textContaining('Layout not saved'), findsOneWidget);
      expect(find.textContaining('disk full'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(c.layout!.sidebarCollapsed, isTrue, reason: 'arrangement kept');
    });

    uiTest('save without answer fails after 10 s and frees the slot', (
      tester,
    ) async {
      final link = linkWith(null);
      link.saveGate = Completer<void>();
      await pumpWorkbench(tester, link);

      await tester.tap(find.byTooltip('Collapse sidebar'));
      await tester.pump(ms500);
      expect(link.saves, hasLength(1));
      await tester.pump(const Duration(seconds: 10));

      expect(find.textContaining('the host did not answer'), findsOneWidget);
      link.saveGate = null;
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(link.saves, hasLength(2), reason: 'Retry sends a new save');
      expect(find.textContaining('Layout not saved'), findsNothing);
    });

    uiTest('Retry stores the layout and clears the notice', (tester) async {
      final link = linkWith(null);
      link.saveAnswers.add(RpcException(ErrorCode.storeError, 'disk full'));
      final c = await pumpWorkbench(tester, link);
      await tester.tap(find.byTooltip('Collapse sidebar'));
      await tester.pump(ms500);
      await tester.pump();
      expect(find.textContaining('Layout not saved'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pump();

      expect(find.textContaining('Layout not saved'), findsNothing);
      expect(link.storedLayout, jsonOf(c.layout!));
    });

    uiTest('the save notice stays until a save succeeds', (tester) async {
      final link = linkWith(null);
      link.saveAnswers.add(RpcException(ErrorCode.storeError, 'disk full'));
      final c = await pumpWorkbench(tester, link);
      await tester.tap(find.byTooltip('Collapse sidebar'));
      await tester.pump(ms500);
      await tester.pump();
      expect(find.textContaining('Layout not saved'), findsOneWidget);

      // A later change: pending, not stored yet.
      await tester.tap(find.byTooltip('Expand sidebar'));
      await tester.pump();
      expect(c.saver.state, SaveState.pending);
      expect(find.textContaining('Layout not saved'), findsOneWidget);

      // Retry: in flight, not stored yet.
      link.saveGate = Completer<void>();
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(c.saver.state, SaveState.inFlight);
      expect(find.textContaining('Layout not saved'), findsOneWidget);

      link.saveGate!.complete();
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Layout not saved'), findsNothing);
      expect(link.storedLayout, jsonOf(c.layout!));
    });

    uiTest('empty layout with restore notice', (tester) async {
      final link = linkWith(null, records: [workspaceRecord('A')]);
      link.restoreError = 'unsupported layout format 9';
      final c = await pumpWorkbench(tester, link);

      expect(c.layout!.groupCount, 1);
      expect(c.layout!.tabCount, 0);
      expect(
        find.textContaining('saved layout could not be restored'),
        findsOneWidget,
      );
      expect(find.textContaining('unsupported layout format 9'), findsOneWidget);
      expect(key('ws-A'), findsOneWidget);
    });

    uiTest('unsupported view tab names the kind', (tester) async {
      final layout = docOf(
        groupOf('g1', tabs: [
          tabOf('t1', kind: 'sketch', item: 'x', state: {'a': 1, 'b': [2]}),
        ]),
        focused: 'g1',
      );
      final link = linkWith(layout);
      await pumpWorkbench(tester, link);

      expect(find.textContaining('Unsupported view'), findsWidgets);
      expect(find.textContaining('sketch'), findsWidgets);

      await tester.tap(find.byTooltip('Collapse sidebar'));
      await tester.pump(ms500);
      await tester.pump();
      expect(link.saves, hasLength(1));
      expect(
        jsonEncode(link.saves.single.layout['root']),
        jsonEncode(jsonOf(layout)['root']),
      );
    });

    uiTest('picked folder appears and becomes group context', (
      tester,
    ) async {
      final picker = FakePicker()..next = '/work/new-project';
      final link = linkWith(null);
      final c = await pumpWorkbench(tester, link, picker: picker);

      await tester.tap(find.text('Open folder'));
      await tester.pump();
      await tester.pump();

      expect(link.calls, contains('workspace/open /work/new-project'));
      expect(find.text('new-project'), findsOneWidget);
      expect(find.text('/work/new-project'), findsOneWidget);
      final id = c.workspaces.single.id;
      expect(c.layout!.group(c.layout!.focusedGroup)!.context, id);
    });

    uiTest('an already known folder is selected as in the sidebar', (
      tester,
    ) async {
      final picker = FakePicker()..next = '/work/A';
      final link = linkWith(
        null,
        records: [workspaceRecord('A', path: '/work/A')],
      );
      final c = await pumpWorkbench(tester, link, picker: picker);

      await tester.tap(find.text('Open folder'));
      await tester.pump();
      await tester.pump();

      expect(c.workspaces, hasLength(1));
      expect(c.layout!.group(c.layout!.focusedGroup)!.context, 'A');
    });

    uiTest('a failed open shows path and reason and adds nothing', (
      tester,
    ) async {
      final picker = FakePicker()..next = '/work/gone';
      final link = linkWith(null);
      link.openAnswers.add(
        RpcException(ErrorCode.targetUnavailable, 'not a folder'),
      );
      final c = await pumpWorkbench(tester, link, picker: picker);

      await tester.tap(find.text('Open folder'));
      await tester.pump();
      await tester.pump();

      expect(c.workspaces, isEmpty);
      expect(find.textContaining('/work/gone'), findsOneWidget);
      expect(find.textContaining('not a folder'), findsOneWidget);
    });

    uiTest('cancelled picker adds nothing', (tester) async {
      final picker = FakePicker();
      final link = linkWith(null);
      final c = await pumpWorkbench(tester, link, picker: picker);
      final before = jsonOf(c.layout!);

      await tester.tap(find.text('Open folder'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));

      expect(picker.calls, 1);
      expect(link.calls.where((x) => x.startsWith('workspace/open')), isEmpty);
      expect(c.workspaces, isEmpty);
      expect(link.saves, isEmpty);
      expect(jsonOf(c.layout!), before);
    });

    uiTest('a failing picker reports why and adds nothing', (tester) async {
      final link = linkWith(null);
      final c = await pumpWorkbench(tester, link, picker: _ThrowingPicker());

      await tester.tap(find.text('Open folder'));
      await tester.pump();
      await tester.pump();

      expect(c.workspaces, isEmpty);
      expect(link.calls.where((x) => x.startsWith('workspace/open')), isEmpty);
      expect(find.textContaining('no portal'), findsOneWidget);
    });

    uiTest('a list answer held across a remove does not restore it', (
      tester,
    ) async {
      final link = linkWith(
        null,
        records: [workspaceRecord('A'), workspaceRecord('C')],
      );
      final c = await pumpWorkbench(tester, link);

      // A cleanup-triggered list taken while C still exists, held.
      link.listAnswers.add(
        WorkspaceListResult(
          workspaces: [workspaceRecord('A'), workspaceRecord('C')],
          cleanupRevision: 2,
        ),
      );
      link.listGate = Completer<void>();
      link.cleanupRevision = 2;
      link.revision = 2;
      link.emitState();
      await tester.pump();
      expect(link.calls.last, 'workspace/list');

      await tester.tap(key('remove-C'));
      await tester.pump();
      await tester.pump();
      expect(c.workspace('C'), isNull);

      link.listGate!.complete();
      await tester.pump();
      await tester.pump();

      expect(c.workspace('C'), isNull);
      expect(key('ws-C'), findsNothing);
      expect(c.workspace('A'), isNotNull);
    });

    uiTest('one workspace notification does not reject a list for others', (
      tester,
    ) async {
      final link = linkWith(
        null,
        records: [
          workspaceRecord('A', cleanupGroups: 2),
          workspaceRecord('B', cleanupGroups: 2),
        ],
      );
      final c = await pumpWorkbench(tester, link);

      // A list taken at cleanup revision 2, held.
      link.listAnswers.add(
        WorkspaceListResult(
          workspaces: [workspaceRecord('A'), workspaceRecord('B')],
          cleanupRevision: 2,
        ),
      );
      link.listGate = Completer<void>();
      link.revision = 2;
      link.emitState();
      await tester.pump();
      expect(link.calls.last, 'workspace/list');

      // A's own record at revision 3 arrives first.
      link.emitWorkspaceChanged(workspaceRecord('A'), cleanupRevision: 3);
      await tester.pump();
      link.listGate!.complete();
      await tester.pump();
      await tester.pump();

      expect(c.workspace('A')!.cleanup.groups, 0);
      expect(c.workspace('B')!.cleanup.groups, 0, reason: 'B is not stale');
      expect(key('badge-B'), findsNothing);
    });

    uiTest('no new binding to a workspace while its remove is out', (
      tester,
    ) async {
      final layout = twoGroups(
        groupOf('g1', ctx: 'C'),
        groupOf('g2'),
      );
      final link = linkWith(layout, records: [workspaceRecord('C')]);
      link.removeGate = Completer<void>();
      final c = await pumpWorkbench(tester, link);

      await tester.tap(key('remove-C'));
      await tester.pump();
      expect(link.calls.last, 'workspace/remove C');

      c.openView('g1', workspaceOverviewKind);
      c.focusGroup('g2');
      c.selectWorkspace('C');
      await tester.pump();
      expect(c.layout!.tabCount, 0);
      expect(c.layout!.group('g2')!.context, isNull);
      expect(find.textContaining('being removed'), findsOneWidget);

      link.removeGate!.complete();
      await tester.pump();
      await tester.pump();
      expect(c.workspace('C'), isNull);
      expect(c.layout!.boundWorkspaces, isEmpty);
      await tester.pump(const Duration(seconds: 3));
    });

    uiTest('a workspace record received during the load is applied after it', (
      tester,
    ) async {
      final link = linkWith(null);
      // The load snapshot still has A checking, then is held.
      link.loadAnswers.add(
        WorkbenchLoadResult(
          layout: null,
          restoreError: null,
          revision: 0,
          workspaces: [
            workspaceRecord('A', availability: Availability.checking),
            workspaceRecord('B', availability: Availability.checking, seq: 3),
          ],
          cleanupRevision: 1,
        ),
      );
      link.loadGate = Completer<void>();
      final c = await pumpWorkbench(tester, link);

      // A's resolution is published before the load answer is processed;
      // B's arrives with an older seq than the snapshot's.
      link.emitWorkspaceChanged(workspaceRecord('A', seq: 2));
      link.emitWorkspaceChanged(workspaceRecord('B', seq: 2));
      await tester.pump();

      link.loadGate!.complete();
      await tester.pump();
      await tester.pump();

      expect(c.workspace('A')!.availability, Availability.available);
      expect(c.workspace('B')!.availability, Availability.checking);
      expect(find.text('Checking...'), findsOneWidget);
    });

    uiTest('a cleanup revision received during the load is kept', (
      tester,
    ) async {
      final link = linkWith(
        null,
        records: [workspaceRecord('A', cleanupGroups: 2, seq: 4)],
      );
      // The load snapshot is taken at cleanup revision 1, then held.
      link.loadAnswers.add(
        WorkbenchLoadResult(
          layout: null,
          restoreError: null,
          revision: 0,
          workspaces: [workspaceRecord('A', cleanupGroups: 2, seq: 4)],
          cleanupRevision: 1,
        ),
      );
      link.loadGate = Completer<void>();
      final c = await pumpWorkbench(tester, link);

      // Reconciliation advances before the load answers.
      link.records[0] = workspaceRecord('A', cleanupGroups: 0, seq: 4);
      link.cleanupRevision = 2;
      link.revision = 2;
      link.emitState();
      await tester.pump();

      link.loadGate!.complete();
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(link.calls, contains('workspace/list'));
      expect(c.workspace('A')!.cleanup.groups, 0);
      expect(key('badge-A'), findsNothing);
    });

    uiTest('sidebar badge opens filtered cleanup list', (tester) async {
      final layout = docOf(
        groupOf('g1', ctx: 'A', tabs: [
          tabOf('t1', kind: workspaceOverviewKind, ws: 'A', item: 'A'),
        ]),
        focused: 'g1',
      );
      final link = linkWith(
        layout,
        records: [workspaceRecord('A', cleanupGroups: 2)],
      );
      link.workspaces.add(workspace(1));
      await pumpWorkbench(tester, link);

      expect(inside('ws-A', find.text('Cleanup unresolved')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('overview-A')),
          matching: find.textContaining('Cleanup unresolved'),
        ),
        findsOneWidget,
        reason: 'also shown in the Workspace overview',
      );

      await tester.tap(key('badge-A'));
      await tester.pumpAndSettle();

      expect(link.calls, contains('list - ws=A'));
      expect(find.text('/work/project-1'), findsOneWidget);
    });

    uiTest('the whole cleanup list is reachable from the workbench', (
      tester,
    ) async {
      // Unresolved cleanup for a directory with no workspace row: no badge
      // can lead to it.
      final link = linkWith(null);
      link.workspaces.add(workspace(1));
      final cleanup = track(CleanupController(link));
      await pumpWorkbench(tester, link, cleanup: cleanup);
      await tester.pump();

      expect(key('cleanup-all'), findsOneWidget);
      expect(
        find.textContaining('Cleanup unresolved: 1 workspace, 2 units'),
        findsOneWidget,
      );

      // Still reachable with the sidebar collapsed.
      await tester.tap(find.byTooltip('Collapse sidebar'));
      await tester.pump();
      await tester.tap(key('cleanup-all'));
      await tester.pumpAndSettle();

      expect(link.calls, contains('list -'));
      expect(find.text('/work/project-1'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
    });

    uiTest('no cleanup action while nothing is unresolved', (tester) async {
      final link = linkWith(null);
      final cleanup = track(CleanupController(link));
      await pumpWorkbench(tester, link, cleanup: cleanup);
      await tester.pump();
      expect(key('cleanup-all'), findsNothing);
    });

    uiTest('cleanup-only list update clears the badge with an unchanged seq', (
      tester,
    ) async {
      final link = linkWith(
        null,
        records: [workspaceRecord('A', cleanupGroups: 2, seq: 4)],
      );
      final c = await pumpWorkbench(tester, link);
      expect(key('badge-A'), findsOneWidget);

      link.records[0] = workspaceRecord('A', cleanupGroups: 0, seq: 4);
      link.cleanupRevision = 2;
      link.revision = 2;
      link.emitState();
      await tester.pump();
      await tester.pump();

      expect(link.calls, contains('workspace/list'));
      expect(key('badge-A'), findsNothing);
      expect(c.workspace('A')!.cleanup.groups, 0);

      // An older answer (cleanupRevision 1 < applied 2) is ignored.
      link.listAnswers.add(
        WorkspaceListResult(
          workspaces: [workspaceRecord('A', cleanupGroups: 3, seq: 4)],
          cleanupRevision: 1,
        ),
      );
      link.revision = 3;
      link.cleanupRevision = 3;
      link.emitState();
      await tester.pump();
      await tester.pump();
      expect(key('badge-A'), findsNothing);
      expect(c.workspace('A')!.cleanup.groups, 0);
    });

    uiTest('in-memory context cleared', (tester) async {
      final layout = docOf(groupOf('g1', ctx: 'C'), focused: 'g1');
      final link = linkWith(layout, records: [workspaceRecord('C')]);
      link.removeAnswers.add(const WorkspaceRemoveResult(9));
      link.removeGate = Completer<void>();
      final c = await pumpWorkbench(tester, link);

      // Unsaved changes when Remove is chosen.
      await tester.tap(find.byTooltip('Collapse sidebar'));
      await tester.pump();
      await tester.tap(find.byTooltip('Expand sidebar'));
      await tester.pump();
      await tester.tap(key('remove-C'));
      await tester.pump();
      expect(link.calls.last, 'workspace/remove C');
      expect(
        link.calls[link.calls.length - 2],
        startsWith('workbench/save'),
        reason: 'the layout is flushed before the remove',
      );

      // A change made while the remove is out.
      c.setSidebarCollapsed(true);
      link.removeGate!.complete();
      await tester.pump();
      await tester.pump();

      expect(c.layout!.group('g1')!.context, isNull);
      expect(c.workspace('C'), isNull);
      expect(c.saver.counter, greaterThanOrEqualTo(9));
      await tester.pump(ms500);
      await tester.pump();
      expect(link.saves.last.revision, greaterThan(9));
      final saved = layoutFromJson(link.saves.last.layout);
      expect(saved.group('g1')!.context, isNull);
      expect(saved.sidebarCollapsed, isTrue);

      await tester.tap(find.byTooltip('New tab'));
      await tester.pumpAndSettle();
      expect(find.text('Open folder...'), findsOneWidget);
      expect(find.textContaining('needs a workspace'), findsOneWidget);
    });

    uiTest('Remove disabled while tabs are bound', (tester) async {
      final layout = docOf(
        groupOf('g1', ctx: 'A', tabs: [tabOf('t1', ws: 'A')]),
        focused: 'g1',
      );
      final link = linkWith(
        layout,
        records: [workspaceRecord('A'), workspaceRecord('B')],
      );
      await pumpWorkbench(tester, link);

      expect(tester.widget<IconButton>(key('remove-A')).onPressed, isNull);
      expect(find.textContaining("A's tabs must be closed first"), findsOneWidget);
      expect(tester.widget<IconButton>(key('remove-B')).onPressed, isNotNull);
    });

    uiTest('workspace-in-use on remove is reported', (tester) async {
      final link = linkWith(null, records: [workspaceRecord('A')]);
      link.removeAnswers.add(
        RpcException(ErrorCode.workspaceInUse, 'a tab is bound'),
      );
      final c = await pumpWorkbench(tester, link);

      await tester.tap(key('remove-A'));
      await tester.pump();
      await tester.pump();

      expect(c.workspace('A'), isNotNull);
      expect(find.textContaining('in use'), findsOneWidget);
    });

    uiTest('sidebar selection focuses the most recent bound tab', (
      tester,
    ) async {
      final layout = twoGroups(
        groupOf('g1', ctx: 'A', tabs: [tabOf('t1', ws: 'A')]),
        groupOf('g2', ctx: 'B'),
        focused: 'g2',
        recent: const ['t1'],
      );
      final c = await pumpWorkbench(
        tester,
        linkWith(layout, records: [workspaceRecord('A'), workspaceRecord('B')]),
      );

      await tester.tap(key('ws-A'));
      await tester.pump();
      expect(c.layout!.focusedGroup, 'g1');
      expect(c.layout!.tab('t1')!.workspace, 'A');
      expect(c.layout!.group('g2')!.context, 'B', reason: 'never rebinds');
      await tester.pump(const Duration(seconds: 3));
    });

    uiTest('records are applied only when seq is above the last applied', (
      tester,
    ) async {
      final link = linkWith(null, records: [workspaceRecord('A', seq: 3)]);
      final c = await pumpWorkbench(tester, link);

      link.emitWorkspaceChanged(
        workspaceRecord(
          'A',
          seq: 5,
          availability: Availability.unavailable,
          reason: 'gone',
        ),
      );
      await tester.pump();
      expect(c.workspace('A')!.availability, Availability.unavailable);

      link.emitWorkspaceChanged(workspaceRecord('A', seq: 4));
      await tester.pump();
      expect(c.workspace('A')!.availability, Availability.unavailable);
      expect(c.workspace('A')!.seq, 5);

      link.emitWorkspaceChanged(workspaceRecord('A', seq: 6));
      await tester.pump();
      expect(c.workspace('A')!.availability, Availability.available);

      link.emitWorkspaceChanged(workspaceRecord('Z', seq: 1));
      await tester.pump();
      expect(c.workspace('Z'), isNull, reason: 'not listed');
    });

    uiTest('Check again applies the checked record', (tester) async {
      final link = linkWith(
        null,
        records: [
          workspaceRecord(
            'A',
            availability: Availability.unavailable,
            reason: 'gone',
          ),
        ],
      );
      link.checkAnswers.add(
        WorkspaceCheckResult(
          workspace: workspaceRecord('A', seq: 2),
          cleanupRevision: 1,
        ),
      );
      final c = await pumpWorkbench(tester, link);

      await tester.tap(key('check-A'));
      await tester.pump();
      await tester.pump();

      expect(c.workspace('A')!.availability, Availability.available);
      expect(key('check-A'), findsNothing);
    });

    uiTest('after a host restart the in-memory layout is kept and saved', (
      tester,
    ) async {
      final first = linkWith(null);
      final c = await pumpWorkbench(tester, first);
      await tester.tap(find.byTooltip('Collapse sidebar'));
      await tester.pump(ms500);
      await tester.pump();
      c.detach();
      await tester.tap(find.byTooltip('Expand sidebar')); // unsaved change
      await tester.pump();

      final second = linkWith(null, records: [workspaceRecord('A')]);
      unawaited(c.attach(second));
      await tester.pump();
      await tester.pump(ms500);
      await tester.pump();

      expect(c.layout!.sidebarCollapsed, isFalse);
      expect(c.workspace('A'), isNotNull);
      expect(second.saves, isNotEmpty);
      expect(second.saves.last.layout['sidebar'], {'collapsed': false});
      expect(second.saves.last.revision, greaterThan(1));
    });
  });
}
