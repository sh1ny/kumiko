import 'dart:async';

import 'package:desktop/src/cleanup_list_view.dart';
import 'package:desktop/src/host_controller.dart';
import 'package:desktop/src/host_status_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:host_protocol/host_protocol.dart';

import 'support/fake_host.dart';

Future<HostController> pumpConnected(
  WidgetTester tester,
  FakeHostLink link,
) async {
  tester.view.physicalSize = const Size(900, 40000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = HostController(connector: () async => link, onExit: () {});
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: HostStatusPage(
        controller: controller,
        hostPath: '/app/host/bin/kumiko_host',
      ),
    ),
  );
  unawaited(controller.start());
  await tester.pumpAndSettle();
  link.emitState();
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets('list pages and shows counts', (tester) async {
    final link = FakeHostLink(
      workspaces: [for (var i = 0; i < 30; i++) workspace(i, unitCount: 3)],
    );
    await pumpConnected(tester, link);

    expect(find.text('30 workspaces, 90 units need cleanup'), findsOneWidget);
    expect(find.byType(WorkspaceTile), findsNWidgets(25));
    expect(find.text('/work/project-0'), findsOneWidget);
    expect(find.text('/work/project-29'), findsNothing);
    expect(find.text('3 units'), findsWidgets);

    await tester.tap(find.text('Show more workspaces'));
    await tester.pumpAndSettle();

    expect(find.byType(WorkspaceTile), findsNWidgets(30));
    expect(find.text('/work/project-29'), findsOneWidget);
    expect(find.text('Show more workspaces'), findsNothing);
    expect(link.calls.where((c) => c.startsWith('list')).length, 2);
  });

  testWidgets('states what cleaned means and shows each reason', (
    tester,
  ) async {
    final link = FakeHostLink(
      workspaces: [
        workspace(
          1,
          unitCount: 1,
          units: [unit(1, reason: 'marked process 4242 survived kill')],
        ),
      ],
    );
    await pumpConnected(tester, link);

    expect(
      find.textContaining('no recorded or marked process remains'),
      findsOneWidget,
    );
    expect(
      find.textContaining('marked process 4242 survived kill'),
      findsOneWidget,
    );
    expect(find.text('Retry cleanup'), findsOneWidget);
    expect(find.text('Confirm processes are gone'), findsOneWidget);
  });

  testWidgets('a workspace with more units than listed says so', (
    tester,
  ) async {
    final link = FakeHostLink(workspaces: [workspace(1, unitCount: 120)]);
    await pumpConnected(tester, link);

    expect(find.text('120 units'), findsOneWidget);
    expect(find.text('Show more units'), findsOneWidget);
  });

  testWidgets('retry cleanup acts on the workspace and removes it', (
    tester,
  ) async {
    final link = FakeHostLink(workspaces: [workspace(1), workspace(2)]);
    await pumpConnected(tester, link);

    await tester.tap(find.text('Retry cleanup').first);
    await tester.pumpAndSettle();

    expect(link.calls, contains('retry ws-1'));
    expect(find.byType(WorkspaceTile), findsOneWidget);
    expect(find.text('/work/project-1'), findsNothing);
    expect(find.text('1 workspace, 2 units need cleanup'), findsOneWidget);
  });

  testWidgets('retry that still fails keeps the workspace', (tester) async {
    final link = FakeHostLink(workspaces: [workspace(1)])
      ..retryResolves = false;
    await pumpConnected(tester, link);

    await tester.tap(find.text('Retry cleanup'));
    await tester.pumpAndSettle();

    expect(find.text('/work/project-1'), findsOneWidget);
    expect(find.textContaining('still unresolved'), findsOneWidget);
  });

  testWidgets('confirm processes are gone clears the workspace', (
    tester,
  ) async {
    final link = FakeHostLink(workspaces: [workspace(1)]);
    await pumpConnected(tester, link);

    await tester.tap(find.text('Confirm processes are gone'));
    await tester.pumpAndSettle();

    expect(link.calls, contains('confirm ws-1'));
    expect(find.byType(WorkspaceTile), findsNothing);
    expect(find.text('No unresolved cleanup'), findsOneWidget);
  });

  testWidgets('confirm refused during retry shows the reason and keeps it', (
    tester,
  ) async {
    final link = FakeHostLink(workspaces: [workspace(1)])
      ..confirmError = RpcException(
        ErrorCode.retryInProgress,
        'a retry is running',
      );
    await pumpConnected(tester, link);

    await tester.tap(find.text('Confirm processes are gone'));
    await tester.pumpAndSettle();

    expect(find.textContaining('retry is still running'), findsOneWidget);
    expect(find.text('/work/project-1'), findsOneWidget);
  });

  testWidgets('a revision change reloads the list from the first page', (
    tester,
  ) async {
    final link = FakeHostLink(
      workspaces: [for (var i = 0; i < 30; i++) workspace(i)],
    );
    await pumpConnected(tester, link);
    await tester.tap(find.text('Show more workspaces'));
    await tester.pumpAndSettle();
    expect(find.byType(WorkspaceTile), findsNWidgets(30));

    link.workspaces.removeRange(0, 10);
    link.revision++;
    link.emitState();
    await tester.pumpAndSettle();

    expect(find.byType(WorkspaceTile), findsNWidgets(20));
    expect(find.text('/work/project-0'), findsNothing);
    expect(find.text('20 workspaces, 40 units need cleanup'), findsOneWidget);
  });

  testWidgets('pages through every unit of a workspace', (tester) async {
    final link = FakeHostLink(workspaces: [workspace(1, unitCount: 25)])
      ..unitsPageSize = 15;
    await pumpConnected(tester, link);

    expect(find.textContaining('scan-unreadable'), findsNWidgets(10));
    expect(find.text('25 units'), findsOneWidget);

    await tester.tap(find.text('Show more units'));
    await tester.pumpAndSettle();
    expect(find.textContaining('scan-unreadable'), findsNWidgets(15));
    expect(find.text('Show more units'), findsOneWidget);

    await tester.tap(find.text('Show more units'));
    await tester.pumpAndSettle();
    expect(find.textContaining('scan-unreadable'), findsNWidgets(25));
    expect(find.textContaining('(pid 1024)'), findsOneWidget);
    expect(find.text('Show more units'), findsNothing);
    expect(link.calls.where((c) => c.startsWith('units ws-1')).length, 2);

    await tester.tap(find.text('Retry cleanup'));
    await tester.pumpAndSettle();
    expect(link.calls, contains('retry ws-1'));
    expect(find.byType(WorkspaceTile), findsNothing);
  });

  testWidgets('the first unit page is checked against the loaded revision', (
    tester,
  ) async {
    final link = FakeHostLink(workspaces: [workspace(1, unitCount: 25)]);
    await pumpConnected(tester, link);
    expect(link.calls.where((c) => c == 'list -'), hasLength(1));

    // The list changes before its cleanup/state notification arrives.
    link.revision++;
    await tester.tap(find.text('Show more units'));
    await tester.pumpAndSettle();

    expect(
      link.calls.where((c) => c == 'list -'),
      hasLength(2),
      reason: 'a stale first unit page reloads the list',
    );
  });

  testWidgets('a unit page answered after a reload is dropped', (tester) async {
    final link = FakeHostLink(workspaces: [workspace(1, unitCount: 25)])
      ..unitsPageSize = 15;
    await pumpConnected(tester, link);
    final gate = link.unitsGate = Completer();
    await tester.tap(find.text('Show more units'));
    await tester.pump();

    // While that page is outstanding, the workspace shrinks and the list
    // reloads.
    link.workspaces[0] = workspace(1, unitCount: 12);
    link.revision++;
    link.emitState();
    await tester.pumpAndSettle();
    expect(find.text('12 units'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();

    expect(
      find.textContaining('scan-unreadable'),
      findsNWidgets(10),
      reason: 'the units of the reloaded list, not the old page',
    );
    expect(find.text('Show more units'), findsOneWidget);
  });
}
