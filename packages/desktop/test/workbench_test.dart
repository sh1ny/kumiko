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
import 'support/fake_terminal_surface.dart';
import 'support/workbench_support.dart';

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
  Size size = const Size(1400, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = WorkbenchController(
    picker: picker ?? FakePicker(),
    surfaceFactory: FakeSurfaces().call,
  );
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

const ms500 = Duration(milliseconds: 500);

/// A tab holding [count] panes in a balanced tree of alternating splits, so
/// every pane keeps a usable size.
LayoutTabNode gridTab(String id, int count) {
  var n = 0;
  LayoutNode build(int panes, SplitDirection direction) {
    if (panes == 1) return paneOf('$id-p${++n}');
    final firstCount = panes ~/ 2;
    final other = direction == SplitDirection.horizontal
        ? SplitDirection.vertical
        : SplitDirection.horizontal;
    final first = build(firstCount, other);
    final second = build(panes - firstCount, other);
    return splitOf(
      '$id-s${n}x${first.id}',
      first,
      second,
      direction: direction,
    );
  }

  return tabOf(id, build(count, SplitDirection.horizontal));
}

// --- the saver (D6), without a widget ---------------------------------------

class SaveProbe {
  final calls =
      <({Json layout, int revision, Completer<WorkbenchSaveResult> done})>[];

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
          saved.any((s) => s.n >= entry.key && s.at <= entry.value + 2000),
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

  group('tabs and panes', () {
    uiTest('a one-pane tab gives its view the whole central area and the '
        'sidebar stays beside it', (tester) async {
      final link = linkWith(
        docOf([tabOf('t1', overviewOf('p1', 'A'))], selected: 'A'),
        records: [workspaceRecord('A')],
      );
      await pumpWorkbench(tester, link);

      final central = tester.getRect(key('central-area'));
      final pane = tester.getRect(key('pane-p1'));
      final strip = tester.getRect(key('tab-strip'));
      final sidebar = tester.getRect(key('sidebar'));
      expect(pane.left, central.left);
      expect(pane.right, central.right);
      expect(pane.bottom, central.bottom);
      expect(pane.top, strip.bottom);
      expect(sidebar.right, central.left, reason: 'beside, unchanged');
      expect(find.byKey(const Key('pane-p1')), findsOneWidget);
    });

    uiTest('the tab renders a terminal and an overview side by side', (
      tester,
    ) async {
      final link = linkWith(
        docOf([
          tabOf(
            't1',
            splitOf(
              's1',
              restoredTerminal('p1', ws: 'A'),
              overviewOf('p2', 'A'),
            ),
          ),
        ], selected: 'A'),
        records: [workspaceRecord('A')],
        hello: helloResult(capabilities: terminalCapabilities),
      );
      final c = await pumpWorkbench(tester, link);

      expect(
        inside('pane-p1', find.textContaining('Ended, not restored')),
        findsOneWidget,
      );
      expect(inside('pane-p2', key('overview-A')), findsOneWidget);
      final left = tester.getRect(key('pane-p1'));
      final right = tester.getRect(key('pane-p2'));
      expect(left.right, lessThanOrEqualTo(right.left));
      expect(left.top, right.top);
      expect(left.height, right.height);
      expect(find.byKey(const Key('tab-t1')), findsOneWidget);
      expect(find.byType(Draggable<String>), findsNothing);
      expect(c.layout!.tabs, hasLength(1));
    });

    uiTest('dragging a divider sets the ratio, also over several updates per '
        'frame', (tester) async {
      final link = linkWith(
        docOf([tabOf('t1', splitOf('s1', paneOf('p1'), paneOf('p2')))]),
      );
      final c = await pumpWorkbench(tester, link);
      double ratio() => c.layout!.splitNode('s1')!.ratio;
      final available = tester.getSize(key('split-view-s1')).width - 6;

      final drag = await tester.startGesture(
        tester.getCenter(key('split-handle-s1')),
      );
      await drag.moveBy(const Offset(40, 0));
      await tester.pump();
      final before = ratio();
      await drag.moveBy(const Offset(10, 0));
      await drag.moveBy(const Offset(10, 0));
      await drag.moveBy(const Offset(10, 0));
      await tester.pump();
      await drag.up();
      await tester.pump();

      expect(ratio(), closeTo(before + 30 / available, 1e-9));
      expect(c.layout!.focusedPane, 'p1', reason: 'a drag is not a focus');
    });

    uiTest('tapping a pane focuses it and marks it', (tester) async {
      final link = linkWith(
        docOf([tabOf('t1', splitOf('s1', paneOf('p1'), paneOf('p2')))]),
      );
      final c = await pumpWorkbench(tester, link);
      expect(c.layout!.focusedPane, 'p1');

      await tester.tapAt(tester.getCenter(key('pane-p2')));
      await tester.pump();

      expect(c.layout!.focusedPane, 'p2');
      expect(c.layout!.tab('t1')!.focusedPane, 'p2');
      expect(key('focused-pane-p2'), findsOneWidget);
      expect(key('focused-pane-p1'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    });

    uiTest('a tab is titled by its focused pane, with the pane count above '
        'one', (tester) async {
      final link = linkWith(
        docOf([
          tabOf(
            't1',
            splitOf('s1', overviewOf('p1', 'A'), paneOf('p2')),
            focused: 'p1',
          ),
          tabOf('t2', overviewOf('p3', 'B')),
        ]),
        records: [workspaceRecord('A'), workspaceRecord('B')],
      );
      await pumpWorkbench(tester, link);

      expect(
        inside('tab-t1', find.textContaining('Workspace overview · A')),
        findsOneWidget,
      );
      expect(inside('tab-t1', find.text('2')), findsOneWidget);
      expect(
        inside('tab-t2', find.textContaining('Workspace overview · B')),
        findsOneWidget,
      );
      expect(inside('tab-t2', find.text('1')), findsNothing);
    });
  });

  group('empty state', () {
    uiTest('closing the last tab shows the empty-state message and New '
        'terminal with its shortcut; + stays, sidebar and selection are '
        'unchanged', (tester) async {
      final link = linkWith(
        docOf([tabOf('t1', overviewOf('p1', 'A'))], selected: 'A'),
        records: [workspaceRecord('A')],
        hello: helloResult(capabilities: terminalCapabilities),
      );
      final c = await pumpWorkbench(tester, link);
      expect(key('empty-state'), findsNothing);

      await tester.tap(key('close-t1'));
      await tester.pumpAndSettle();

      expect(c.layout!.activeTab, isNull);
      expect(c.layout!.tabs, isEmpty);
      expect(key('empty-state'), findsOneWidget);
      expect(find.text('No tab is open.'), findsOneWidget);
      expect(inside('new-terminal', find.text('New terminal')), findsOneWidget);
      expect(inside('new-terminal', find.text('Ctrl+Shift+T')), findsOneWidget);
      expect(
        tester.widget<FilledButton>(key('new-terminal')).onPressed,
        isNotNull,
      );
      expect(key('add-tab'), findsOneWidget);
      expect(key('tab-strip'), findsOneWidget);
      expect(key('sidebar'), findsOneWidget);
      expect(c.layout!.selectedWorkspace, 'A');
      await tester.pump(const Duration(seconds: 3));
    });

    uiTest('first launch shows Personal with no tabs, the empty state and no '
        'prompt', (tester) async {
      final c = await pumpWorkbench(tester, linkWith(null));
      expect(c.layout!.tabs, isEmpty);
      expect(c.layout!.activeTab, isNull);
      expect(c.layout!.selectedWorkspace, isNull);
      expect(find.text('Personal'), findsOneWidget);
      expect(find.text('Open folder'), findsOneWidget);
      expect(key('empty-state'), findsOneWidget);
      expect(find.byTooltip('New tab'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
    });

    uiTest('an invalid stored layout shows no tabs, the empty state and the '
        'restore notice', (tester) async {
      final link = linkWith(null, records: [workspaceRecord('A')]);
      link.restoreError = 'activeTab "t9" is not a tab';
      final c = await pumpWorkbench(tester, link);

      expect(c.layout!.tabs, isEmpty);
      expect(key('empty-state'), findsOneWidget);
      expect(
        find.textContaining('saved layout could not be restored'),
        findsOneWidget,
      );
      expect(
        find.textContaining('activeTab "t9" is not a tab'),
        findsOneWidget,
      );
      expect(key('ws-A'), findsOneWidget);
    });

    uiTest('a stored format 2 layout that fails validation on the desktop '
        'is reported the same way', (tester) async {
      final link = linkWith(null);
      link.storedLayout = {'format': 2, 'tabs': <Object?>[], 'activeTab': 't1'};
      final c = await pumpWorkbench(tester, link);
      expect(c.layout!.tabs, isEmpty);
      expect(
        find.textContaining('saved layout could not be restored'),
        findsOneWidget,
      );
    });

    uiTest('New terminal is disabled with the reason when the host has no '
        'terminal capability, and the + menu works', (tester) async {
      await pumpWorkbench(tester, linkWith(null));

      final button = tester.widget<FilledButton>(key('new-terminal'));
      expect(button.onPressed, isNull);
      expect(find.textContaining('does not support terminals'), findsOneWidget);
      await tester.tap(key('add-tab'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<PopupMenuItem<String>>(key('launch-terminal')).enabled,
        isFalse,
      );
      expect(key('open-folder'), findsOneWidget);
    });
  });

  group('close', () {
    uiTest('pane close removes the pane and its sibling fills the space', (
      tester,
    ) async {
      final link = linkWith(
        docOf([
          tabOf('t1', splitOf('s1', paneOf('p1'), paneOf('p2')), focused: 'p2'),
        ]),
      );
      final c = await pumpWorkbench(tester, link);

      await tester.tap(key('close-pane-p2'));
      await tester.pumpAndSettle();

      final tab = c.layout!.tab('t1')!;
      expect(tab.root, isA<PaneNode>());
      expect(tab.root.id, 'p1');
      expect(tab.focusedPane, 'p1');
      expect(key('pane-p2'), findsNothing);
      expect(
        tester.getRect(key('pane-p1')).right,
        tester.getRect(key('central-area')).right,
      );
      await tester.pump(const Duration(seconds: 3));
    });

    uiTest('closing an inactive tab leaves the active tab and its focused '
        'pane', (tester) async {
      final link = linkWith(
        docOf([
          tabOf('t1', splitOf('s1', paneOf('p1'), paneOf('p2')), focused: 'p2'),
          tabOf('t2', paneOf('p3')),
        ]),
      );
      final c = await pumpWorkbench(tester, link);

      await tester.tap(key('close-t2'));
      await tester.pumpAndSettle();

      expect(c.layout!.tabs.map((t) => t.id), ['t1']);
      expect(c.layout!.activeTab, 't1');
      expect(c.layout!.focusedPane, 'p2');
      await tester.pump(const Duration(seconds: 3));
    });

    uiTest('closing the active middle tab activates the one on its right '
        'with its own focused pane', (tester) async {
      final link = linkWith(
        docOf([
          tabOf('t1', paneOf('p1')),
          tabOf('t2', paneOf('p2')),
          tabOf('t3', splitOf('s3', paneOf('p3'), paneOf('p4')), focused: 'p4'),
        ], active: 't2'),
      );
      final c = await pumpWorkbench(tester, link);

      await tester.tap(key('close-t2'));
      await tester.pumpAndSettle();

      expect(c.layout!.activeTab, 't3');
      expect(c.layout!.focusedPane, 'p4');
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('moves', () {
    uiTest('Move to new tab and Move into split are disabled when there is '
        'nothing to move', (tester) async {
      final link = linkWith(
        docOf([
          tabOf('t1', paneOf('p1')),
          tabOf('t2', splitOf('s2', paneOf('p2'), paneOf('p3'))),
        ]),
      );
      await pumpWorkbench(tester, link);

      expect(tester.widget<IconButton>(key('move-p1')).onPressed, isNull);

      await tester.tap(key('tab-menu-t1'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PopupMenuItem<String>>(key('move-split-right-t1'))
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<PopupMenuItem<String>>(key('move-split-below-t1'))
            .enabled,
        isFalse,
      );
      expect(
        tester.widget<PopupMenuItem<String>>(key('close-tab-t1')).enabled,
        isTrue,
      );
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      await tester.tap(key('tab-menu-t2'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PopupMenuItem<String>>(key('move-split-right-t2'))
            .enabled,
        isTrue,
      );
    });

    uiTest("the moved tab renders below the active tab's panes", (
      tester,
    ) async {
      final link = linkWith(
        docOf([
          tabOf('t1', splitOf('s1', paneOf('p1'), paneOf('p2'))),
          tabOf('t2', overviewOf('p3', 'B')),
        ]),
        records: [workspaceRecord('B')],
      );
      final c = await pumpWorkbench(tester, link);

      await tester.tap(key('tab-menu-t2'));
      await tester.pumpAndSettle();
      await tester.tap(key('move-split-below-t2'));
      await tester.pumpAndSettle();

      expect(c.layout!.tabs.map((t) => t.id), ['t1']);
      final root = c.layout!.tab('t1')!.root as SplitNode;
      expect(root.direction, SplitDirection.vertical);
      expect(root.second.id, 'p3');
      expect(c.layout!.focusedPane, 'p3');
      expect(c.layout!.pane('p3')!.workspace, 'B');
      expect(
        tester.getRect(key('pane-p3')).top,
        greaterThanOrEqualTo(tester.getRect(key('pane-p1')).bottom),
      );
      expect(key('overview-B'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    uiTest('Move to new tab puts the pane in a new active tab after its '
        'source and keeps its binding', (tester) async {
      final link = linkWith(
        docOf([
          tabOf(
            't1',
            splitOf('s1', overviewOf('p1', 'A'), paneOf('p2', ws: 'B')),
          ),
          tabOf('t9', paneOf('p9')),
        ]),
        records: [workspaceRecord('A'), workspaceRecord('B')],
      );
      final c = await pumpWorkbench(tester, link);

      await tester.tap(key('move-p2'));
      await tester.pumpAndSettle();

      final ids = c.layout!.tabs.map((t) => t.id).toList();
      expect(ids, hasLength(3));
      expect(ids.first, 't1');
      expect(ids.last, 't9');
      final moved = c.layout!.tabs[1];
      expect(moved.root.id, 'p2');
      expect(c.layout!.activeTab, moved.id);
      expect(c.layout!.pane('p2')!.workspace, 'B');
      expect(c.layout!.tab('t1')!.root.id, 'p1');
      await tester.pump(const Duration(seconds: 3));
    });

    uiTest('a refused move reports the limit and changes nothing', (
      tester,
    ) async {
      final link = linkWith(docOf([gridTab('t1', 9), gridTab('t2', 8)]));
      final c = await pumpWorkbench(tester, link);
      final before = jsonOf(c.layout!);

      await tester.tap(key('tab-menu-t2'));
      await tester.pumpAndSettle();
      await tester.tap(key('move-split-right-t2'));
      await tester.pumpAndSettle();

      expect(jsonOf(c.layout!), before);
      expect(find.textContaining('16 panes'), findsOneWidget);
    });
  });

  group('launcher', () {
    uiTest('+ opens Workspace overview in a new active tab bound to the '
        'sidebar selection, other views unchanged', (tester) async {
      final link = linkWith(
        docOf([tabOf('t1', overviewOf('p1', 'A'))], selected: 'B'),
        records: [workspaceRecord('A'), workspaceRecord('B')],
      );
      final c = await pumpWorkbench(tester, link);

      await tester.tap(key('add-tab'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Workspace overview'));
      await tester.pumpAndSettle();

      final d = c.layout!;
      expect(d.tabs, hasLength(2));
      expect(d.tabs.first.id, 't1');
      expect((d.tabs.first.root as PaneNode).workspace, 'A');
      final fresh = d.tabs.last.root as PaneNode;
      expect(fresh.kind, workspaceOverviewKind);
      expect(fresh.workspace, 'B');
      expect(d.activeTab, d.tabs.last.id);
      expect(d.focusedPane, fresh.id);
      await tester.pump(const Duration(seconds: 3));
    });

    uiTest('+ with Personal selected marks workspace-needing kinds, offers '
        'Open folder and creates no tab', (tester) async {
      final c = await pumpWorkbench(tester, linkWith(null));

      await tester.tap(find.byTooltip('New tab'));
      await tester.pumpAndSettle();

      expect(find.textContaining('needs a workspace'), findsOneWidget);
      expect(find.text('Open folder...'), findsOneWidget);
      await tester.tap(find.textContaining('needs a workspace'));
      await tester.pumpAndSettle();
      expect(c.layout!.tabs, isEmpty, reason: 'no tab until a workspace');
    });

    uiTest('opening an open item focuses its pane in another tab', (
      tester,
    ) async {
      final link = linkWith(
        docOf(
          [tabOf('t1', overviewOf('p1', 'A')), tabOf('t2', paneOf('p2'))],
          active: 't2',
          selected: 'A',
        ),
        records: [workspaceRecord('A')],
      );
      final c = await pumpWorkbench(tester, link);

      await tester.tap(key('add-tab'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Workspace overview'));
      await tester.pumpAndSettle();

      expect(c.layout!.tabs, hasLength(2));
      expect(c.layout!.activeTab, 't1');
      expect(c.layout!.focusedPane, 'p1');
      await tester.pump(const Duration(seconds: 3));
    });

    uiTest('the launcher reports the limit', (tester) async {
      final tabs = [for (var i = 1; i <= 8; i++) gridTab('t$i', 16)];
      final link = linkWith(
        docOf(tabs, selected: 'A'),
        records: [workspaceRecord('A')],
      );
      final c = await pumpWorkbench(tester, link);
      expect(c.layout!.paneCount, maxPanes);

      await tester.tap(key('add-tab'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Workspace overview'));
      await tester.pumpAndSettle();

      expect(c.layout!.tabs, hasLength(8));
      expect(c.layout!.paneCount, maxPanes);
      expect(find.textContaining('128 panes'), findsOneWidget);
    });
  });

  group('split', () {
    Future<WorkbenchController> pumpSplittable(
      WidgetTester tester,
      LayoutDocument layout,
    ) => pumpWorkbench(
      tester,
      linkWith(
        layout,
        records: [workspaceRecord('A')],
        hello: helloResult(capabilities: terminalCapabilities),
      ),
    );

    uiTest('the split action reports the limit', (tester) async {
      // A tab at 16 panes.
      final c = await pumpSplittable(tester, docOf([gridTab('t1', 16)]));
      await tester.tap(key('split-right-t1-p16'));
      await tester.pumpAndSettle();
      expect(c.layout!.paneCount, 16);
      expect(find.textContaining('16 panes'), findsOneWidget);
      expect(c.terminals.linkOf('t1-p16'), isNull);
    });

    uiTest('the split action reports the limit of the document', (
      tester,
    ) async {
      // 15 tabs of 8 panes = 120, and one of 8: 128 in all.
      final tabs = [for (var i = 1; i <= 16; i++) gridTab('t$i', 8)];
      final c = await pumpSplittable(tester, docOf(tabs, active: 't1'));
      expect(c.layout!.paneCount, maxPanes);

      await tester.tap(key('split-down-t1-p8'));
      await tester.pumpAndSettle();

      expect(c.layout!.paneCount, maxPanes);
      expect(find.textContaining('128 panes'), findsOneWidget);
    });
  });

  group('workspace binding', () {
    uiTest('a pane bound to an unavailable workspace keeps its binding and '
        'shows unavailable', (tester) async {
      final link = linkWith(
        docOf([tabOf('t1', overviewOf('p1', 'A'))], selected: 'A'),
        records: [
          workspaceRecord(
            'A',
            availability: Availability.unavailable,
            reason: 'folder missing',
          ),
        ],
      );
      final c = await pumpWorkbench(tester, link);

      expect(
        inside('pane-header-p1', find.text('unavailable')),
        findsOneWidget,
      );
      expect(find.textContaining('folder missing'), findsWidgets);
      expect(c.layout!.pane('p1')!.workspace, 'A');
      expect(key('check-A'), findsOneWidget);
    });
  });

  group('sidebar', () {
    uiTest('collapsing and expanding the sidebar keeps tabs, panes, splits, '
        'active tab and focused pane', (tester) async {
      final link = linkWith(
        docOf(
          [
            tabOf('t1', splitOf('s1', paneOf('p1', ws: 'A'), paneOf('p2'))),
            tabOf('t2', paneOf('p3')),
          ],
          active: 't1',
          selected: 'A',
        ),
        records: [workspaceRecord('A')],
      );
      final c = await pumpWorkbench(tester, link);
      await tester.tapAt(tester.getCenter(key('pane-p2')));
      await tester.pump();
      final before = jsonEncode(layoutToJson(c.layout!)['tabs']);
      expect(c.layout!.focusedPane, 'p2');

      await tester.tap(find.byTooltip('Collapse sidebar'));
      await tester.pump();
      expect(key('sidebar'), findsNothing);
      expect(find.byTooltip('Expand sidebar'), findsOneWidget);
      expect(c.layout!.sidebarCollapsed, isTrue);
      expect(c.layout!.activeTab, 't1');
      expect(c.layout!.focusedPane, 'p2');
      expect(key('pane-p1'), findsOneWidget);
      expect(key('pane-p2'), findsOneWidget);
      expect(key('tab-t2'), findsOneWidget);

      await tester.tap(find.byTooltip('Expand sidebar'));
      await tester.pump();
      expect(key('sidebar'), findsOneWidget);
      expect(jsonEncode(layoutToJson(c.layout!)['tabs']), before);
      expect(c.layout!.activeTab, 't1');
      expect(c.layout!.focusedPane, 'p2');
      await tester.pump(const Duration(seconds: 3));
    });

    uiTest('the collapsed sidebar is restored from load', (tester) async {
      await pumpWorkbench(tester, linkWith(docOf(const [], collapsed: true)));

      expect(key('sidebar'), findsNothing);
      expect(find.byTooltip('Expand sidebar'), findsOneWidget);
    });

    uiTest('Personal returns the selection to no workspace without moving '
        'any binding', (tester) async {
      final link = linkWith(
        docOf([tabOf('t1', overviewOf('p1', 'A'))], selected: 'A'),
        records: [workspaceRecord('A')],
      );
      final c = await pumpWorkbench(tester, link);

      await tester.tap(key('personal'));
      await tester.pump();

      expect(c.layout!.selectedWorkspace, isNull);
      expect(c.layout!.pane('p1')!.workspace, 'A');
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('unsupported view', () {
    uiTest('the unsupported view pane names the kind and can be split, moved '
        'and closed', (tester) async {
      final sketch = paneOf(
        'p1',
        kind: 'sketch',
        item: 'x',
        state: {
          'a': 1,
          'b': [2],
        },
      );
      final link = linkWith(
        docOf([tabOf('t1', sketch)]),
        hello: helloResult(capabilities: terminalCapabilities),
      );
      final c = await pumpWorkbench(tester, link);

      expect(
        inside('pane-p1', find.textContaining('Unsupported view')),
        findsWidgets,
      );
      expect(inside('pane-p1', find.textContaining('sketch')), findsWidgets);

      // Split: a terminal opens beside it.
      await tester.tap(key('split-right-p1'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(c.layout!.tabs.single.paneCount, 2);

      // Move it to a new tab.
      await tester.tap(key('move-p1'));
      await tester.pumpAndSettle();
      expect(c.layout!.tabs, hasLength(2));
      expect(c.layout!.tabOf('p1')!.paneCount, 1);

      // Its JSON is the same in the save.
      await tester.pump(ms500);
      await tester.pump();
      final saved = link.saves.last.layout;
      final panes = <Json>[];
      void walk(Object? n) {
        if (n is Map && n['type'] == 'pane') {
          panes.add(n.cast<String, Object?>());
        }
        if (n is Map && n['type'] == 'split') {
          walk(n['first']);
          walk(n['second']);
        }
      }

      for (final t in saved['tabs']! as List) {
        walk((t as Map)['root']);
      }
      final stored = panes.singleWhere((p) => p['id'] == 'p1');
      expect(stored, {
        'type': 'pane',
        'id': 'p1',
        'kind': 'sketch',
        'workspace': null,
        'item': 'x',
        'state': {
          'a': 1,
          'b': [2],
        },
      });

      // Close it.
      await tester.tap(key('close-pane-p1'));
      await tester.pumpAndSettle();
      expect(c.layout!.pane('p1'), isNull);
    });
  });

  group('narrow widths', () {
    uiTest('the strip, headers, empty state and every kind lay out without '
        'overflow at 143 px', (tester) async {
      final link = linkWith(
        docOf(
          [
            tabOf(
              't1',
              splitOf(
                's1',
                splitOf(
                  's2',
                  overviewOf('p1', 'A'),
                  restoredTerminal('p2', ws: 'A'),
                  direction: SplitDirection.vertical,
                ),
                paneOf('p3', kind: 'sketch', item: 'x'),
              ),
            ),
            tabOf('t2', paneOf('p4')),
          ],
          selected: 'A',
          collapsed: true,
        ),
        records: [workspaceRecord('A', label: 'a-rather-long-workspace-label')],
        hello: helloResult(capabilities: terminalCapabilities),
      );
      final c = await pumpWorkbench(tester, link, size: const Size(183, 600));
      expect(tester.takeException(), isNull);
      expect(tester.getSize(key('central-area')).width, 143);

      // The same with the empty state.
      await c.requestClose(['p1', 'p2', 'p3', 'p4'], (_) async => true);
      await tester.pumpAndSettle();
      expect(c.layout!.tabs, isEmpty);
      expect(key('empty-state'), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.physicalSize = const Size(100, 300);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('workbench', () {
    uiTest('workbench and layout show while the host reconciles', (
      tester,
    ) async {
      final layout = docOf([
        tabOf('t1', splitOf('s1', overviewOf('p1', 'A'), paneOf('p2'))),
      ], selected: 'A');
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

    uiTest('a change survives killing the desktop after the save period', (
      tester,
    ) async {
      final layout = docOf(const []);
      final link = linkWith(layout);
      final c = await pumpWorkbench(tester, link);

      await tester.tap(find.byTooltip('Collapse sidebar'));
      await tester.pump(ms500);
      await tester.pump();

      // Killed: no flush, no quit, nothing more runs in this desktop.
      final sent = jsonOf(c.layout!);
      await tester.pumpWidget(const SizedBox());
      expect(
        link.calls.where((x) => x.startsWith('workbench/save')),
        hasLength(1),
      );
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

    uiTest('the picked folder appears and becomes the sidebar selection', (
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
      expect(c.layout!.selectedWorkspace, id);
      await tester.pump(const Duration(seconds: 3));
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
      expect(c.layout!.selectedWorkspace, 'A');
      await tester.pump(const Duration(seconds: 3));
    });

    uiTest('no new binding to a workspace while its remove is out', (
      tester,
    ) async {
      final layout = docOf([tabOf('t1', paneOf('p1'))]);
      final link = linkWith(layout, records: [workspaceRecord('C')]);
      link.removeGate = Completer<void>();
      final c = await pumpWorkbench(tester, link);

      await tester.tap(key('remove-C'));
      await tester.pump();
      expect(link.calls.last, 'workspace/remove C');

      c.openView(workspaceOverviewKind);
      c.selectWorkspace('C');
      await tester.pump();
      expect(c.layout!.tabs, hasLength(1));
      expect(c.layout!.selectedWorkspace, isNull);
      expect(find.textContaining('being removed'), findsOneWidget);

      link.removeGate!.complete();
      await tester.pump();
      await tester.pump();
      expect(c.workspace('C'), isNull);
      expect(c.layout!.boundWorkspaces, isEmpty);
      await tester.pump(const Duration(seconds: 3));
    });

    uiTest('removing the selected workspace returns the in-memory selection '
        'to Personal', (tester) async {
      final layout = docOf([tabOf('t1', paneOf('p1'))], selected: 'C');
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

      expect(c.layout!.selectedWorkspace, isNull);
      expect(c.workspace('C'), isNull);
      expect(c.saver.counter, greaterThanOrEqualTo(9));
      await tester.pump(ms500);
      await tester.pump();
      expect(link.saves.last.revision, greaterThan(9));
      final saved = layoutFromJson(link.saves.last.layout);
      expect(saved.selectedWorkspace, isNull);
      expect(saved.sidebarCollapsed, isTrue);

      await tester.tap(find.byTooltip('New tab'));
      await tester.pumpAndSettle();
      expect(find.text('Open folder...'), findsOneWidget);
      expect(find.textContaining('needs a workspace'), findsOneWidget);
    });

    uiTest('Remove is disabled while panes are bound', (tester) async {
      final layout = docOf([tabOf('t1', paneOf('p1', ws: 'A'))]);
      final link = linkWith(
        layout,
        records: [workspaceRecord('A'), workspaceRecord('B')],
      );
      await pumpWorkbench(tester, link);

      expect(tester.widget<IconButton>(key('remove-A')).onPressed, isNull);
      expect(
        find.textContaining("A's panes must be closed first"),
        findsOneWidget,
      );
      expect(tester.widget<IconButton>(key('remove-B')).onPressed, isNotNull);
    });

    uiTest('sidebar selection focuses the most recent bound pane and never '
        'rebinds', (tester) async {
      final layout = docOf(
        [
          tabOf('t1', paneOf('p1', ws: 'A')),
          tabOf('t2', paneOf('p2', ws: 'B')),
        ],
        active: 't2',
        selected: 'B',
        recent: const ['p2', 'p1'],
      );
      final c = await pumpWorkbench(
        tester,
        linkWith(layout, records: [workspaceRecord('A'), workspaceRecord('B')]),
      );

      await tester.tap(key('ws-A'));
      await tester.pump();
      expect(c.layout!.activeTab, 't1');
      expect(c.layout!.focusedPane, 'p1');
      expect(c.layout!.selectedWorkspace, 'A');
      expect(c.layout!.pane('p2')!.workspace, 'B', reason: 'never rebinds');
      await tester.pump(const Duration(seconds: 3));
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
      final layout = docOf([tabOf('t1', overviewOf('p1', 'A'))], selected: 'A');
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
      expect(second.saves.last.layout['sidebar'], {
        'collapsed': false,
        'selected': null,
      });
      expect(second.saves.last.revision, greaterThan(1));
    });
  });
}
