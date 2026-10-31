import 'dart:async';
import 'dart:convert';

import 'package:desktop/src/folder_picker.dart';
import 'package:desktop/src/terminal/terminal_controller.dart';
import 'package:desktop/src/workbench_controller.dart';
import 'package:desktop/src/workbench_page.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:host_protocol/host_protocol.dart';

import 'fake_host.dart';
import 'fake_terminal_surface.dart';

// --- layout fixtures (format 2) -----------------------------------------------

const Set<String> terminalCapabilities = {
  Capability.workbench,
  Capability.terminal,
};

PaneNode paneOf(
  String id, {
  String kind = 'note',
  String? ws,
  String? item,
  Map<String, Object?> state = const {},
}) => PaneNode(id: id, kind: kind, workspace: ws, item: item, state: state);

PaneNode restoredTerminal(
  String id, {
  String? ws,
  String profileId = 'builtin:pwsh',
  String profileName = 'pwsh',
}) => paneOf(
  id,
  kind: 'terminal',
  ws: ws,
  item: 'item-$id',
  state: {'profileId': profileId, 'profileName': profileName},
);

PaneNode overviewOf(String id, String ws) =>
    paneOf(id, kind: workspaceOverviewKind, ws: ws, item: ws);

SplitNode splitOf(
  String id,
  LayoutNode a,
  LayoutNode b, {
  SplitDirection direction = SplitDirection.horizontal,
  double ratio = 0.5,
}) =>
    SplitNode(id: id, direction: direction, ratio: ratio, first: a, second: b);

LayoutTabNode tabOf(String id, LayoutNode root, {String? focused}) =>
    LayoutTabNode(
      id: id,
      root: root,
      focusedPane: focused ?? root.panes.first.id,
    );

LayoutDocument docOf(
  List<LayoutTabNode> tabs, {
  String? active,
  String? selected,
  bool collapsed = false,
  List<String> recent = const [],
}) => LayoutDocument(
  tabs: tabs,
  activeTab: tabs.isEmpty ? null : (active ?? tabs.first.id),
  recent: recent,
  sidebarCollapsed: collapsed,
  selectedWorkspace: selected,
);

Json jsonOf(LayoutDocument d) =>
    jsonDecode(jsonEncode(layoutToJson(d))) as Json;

// --- widget test plumbing -------------------------------------------------------

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

class NoPicker implements FolderPicker {
  @override
  Future<String?> pickFolder() async => null;
}

class FakePicker implements FolderPicker {
  String? next;
  int calls = 0;

  @override
  Future<String?> pickFolder() async {
    calls++;
    return next;
  }
}

Finder key(String k) => find.byKey(Key(k));

Finder inside(String k, Finder f) => find.descendant(of: key(k), matching: f);

/// Lets queued microtasks and short timers run.
Future<void> flush(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

/// The workbench over a scripted host and fake surfaces.
class Rig {
  Rig(this.controller, this.link, this.surfaces);

  final WorkbenchController controller;
  final FakeHostLink link;
  final FakeSurfaces surfaces;

  LayoutDocument get layout => controller.layout!;

  List<PaneNode> get terminalPanes => [
    for (final p in layout.panes)
      if (p.kind == terminalKind) p,
  ];

  TerminalLink? linkOf(String paneId) => controller.terminals.linkOf(paneId);
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

/// Pumps the workbench page over [link] with fake surfaces; ids are
/// `prefix` + a counter, so a test can predict them.
Future<Rig> pumpRig(
  WidgetTester tester,
  FakeHostLink link, {
  FolderPicker? picker,
  Size size = const Size(1400, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final surfaces = FakeSurfaces();
  var n = 0;
  final controller = track(
    WorkbenchController(
      picker: picker ?? NoPicker(),
      newId: (prefix) => '$prefix${++n}',
      surfaceFactory: surfaces.call,
    ),
  );
  await tester.pumpWidget(
    MaterialApp(home: WorkbenchPage(controller: controller)),
  );
  unawaited(controller.attach(link));
  await flush(tester);
  return Rig(controller, link, surfaces);
}

/// A terminal-capable host holding [layout].
Future<Rig> pumpTerminals(
  WidgetTester tester, {
  LayoutDocument? layout,
  List<WorkspaceRecord> records = const [],
  Set<String> capabilities = terminalCapabilities,
  Size size = const Size(1400, 900),
}) => pumpRig(
  tester,
  linkWith(
    layout,
    records: records,
    hello: helloResult(capabilities: capabilities),
  ),
  size: size,
);

/// A workbench with no tabs.
Future<Rig> pumpEmpty(WidgetTester tester) => pumpTerminals(tester);

/// Chooses [entry] of the + launcher.
Future<void> launch(
  WidgetTester tester, {
  String entry = 'launch-terminal',
}) async {
  await tester.tap(key('add-tab'));
  await tester.pumpAndSettle();
  await tester.tap(key(entry));
  await flush(tester);
  await tester.pumpAndSettle();
}
