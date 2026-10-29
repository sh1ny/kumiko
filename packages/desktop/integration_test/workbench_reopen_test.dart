import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:desktop/main.dart';
import 'package:desktop/src/folder_picker.dart';
import 'package:desktop/src/host_link.dart';
import 'package:desktop/src/host_location.dart';
import 'package:desktop/src/launcher_link.dart';
import 'package:desktop/src/workbench_controller.dart';
import 'package:desktop/src/workbench_page.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:integration_test/integration_test.dart';

/// Answers each Open folder with the next prepared path: no native dialog.
class _QueuePicker implements FolderPicker {
  _QueuePicker(this.paths);

  final List<String> paths;

  @override
  Future<String?> pickFolder() async =>
      paths.isEmpty ? null : paths.removeAt(0);
}

/// Pumps (letting real IO run) until [done] holds.
Future<void> _pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  expect(done(), isTrue, reason: 'timed out waiting for the UI');
}

WorkbenchController _controller(WidgetTester tester) =>
    tester.widget<WorkbenchPage>(find.byType(WorkbenchPage)).controller;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('workbench reopen', () {
    late Directory profile;
    late Directory folders;
    HostLink? link;

    setUp(() {
      profile = Directory.systemTemp.createTempSync('kumiko_it_profile_');
      folders = Directory.systemTemp.createTempSync('kumiko_it_folders_');
    });

    tearDown(() async {
      await link?.quit();
      link = null;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      for (final d in [profile, folders]) {
        try {
          d.deleteSync(recursive: true);
        } on FileSystemException {
          // Best effort: the host may still be releasing its log file.
        }
      }
    });

    /// One app launch on [profile]; the workbench is loaded when this returns.
    Future<void> launch(
      WidgetTester tester, [
      List<String> picks = const [],
    ]) async {
      final os = HostOs.current;
      final hostPath = resolveHostExecutable(
        override: const String.fromEnvironment('KUMIKO_HOST'),
        appExecutable: Platform.resolvedExecutable,
        os: os,
      );
      final connect = launcherConnector(
        HostLauncher(
          executable: hostPath,
          profileDir: profile.path,
          capabilities: const {Capability.workbench},
        ),
      );
      await tester.pumpWidget(
        KumikoApp(
          connector: () async => link = await connect(),
          hostPath: hostPath,
          onExit: () {},
          folderPicker: _QueuePicker([...picks]),
        ),
      );
      await _pumpUntil(
        tester,
        () =>
            find.byType(WorkbenchPage).evaluate().isNotEmpty &&
            _controller(tester).layout != null,
      );
    }

    /// The app's exit path: the lifecycle listener's flush-then-shutdown, then
    /// the app is removed and the host is gone.
    Future<void> quit(WidgetTester tester) async {
      final response = await tester.runAsync(
        tester.binding.handleRequestAppExit,
      );
      expect(response, AppExitResponse.exit);
      await tester.pumpWidget(const SizedBox());
      link = null;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1000)),
      );
    }

    testWidgets(
      'fresh profile opens Personal with one empty group and no prompt',
      (tester) async {
        await launch(tester);

        final layout = _controller(tester).layout!;
        expect(layout.root, isA<TabGroup>());
        expect(layout.groupCount, 1);
        expect(layout.tabCount, 0);
        expect(layout.group(layout.focusedGroup)!.context, isNull);

        expect(find.text('Personal'), findsOneWidget);
        expect(find.text('No tabs. Use + to open a view.'), findsOneWidget);
        expect(find.byIcon(Icons.add), findsOneWidget);
        expect(find.text('Open folder'), findsOneWidget);
        // No prompt: no dialog and no notice.
        expect(find.byType(Dialog), findsNothing);
        expect(find.byType(AlertDialog), findsNothing);
        expect(_controller(tester).restoreNotice, isNull);
        expect(_controller(tester).message, isNull);
      },
    );

    testWidgets(
      'quit and reopen restores groups, split, ratio, tabs and focus',
      (tester) async {
        final names = ['alpha', 'bravo', 'charlie'];
        for (final n in names) {
          Directory('${folders.path}/$n').createSync();
        }
        final real = [for (final n in names) '${folders.path}/$n'];

        await launch(tester, real);
        final c = _controller(tester);

        Future<void> openFolder() async {
          final before = c.workspaces.length;
          await tester.tap(find.text('Open folder'));
          await _pumpUntil(tester, () => c.workspaces.length == before + 1);
        }

        Future<void> openOverview(String groupId, String label) async {
          await tester.tap(find.byKey(Key('add-$groupId')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Workspace overview').last);
          await tester.pumpAndSettle();
          expect(find.text('Workspace overview · $label'), findsOneWidget);
        }

        // alpha in the first group, then split right; bravo and charlie in the
        // new group.
        final g1 = c.layout!.focusedGroup;
        await openFolder();
        await openOverview(g1, 'alpha');
        await tester.tap(find.byKey(Key('split-h-$g1')));
        await tester.pumpAndSettle();
        final g2 = c.layout!.focusedGroup;
        expect(g2, isNot(g1));

        await openFolder();
        await openOverview(g2, 'bravo');
        await openFolder();
        await openOverview(g2, 'charlie');

        // A non-default ratio, by dragging the handle.
        final split = c.layout!.root as SplitNode;
        await tester.drag(
          find.byKey(Key('split-handle-${split.id}')),
          const Offset(120, 0),
        );
        await tester.pumpAndSettle();

        // Active tabs and focus: g2 shows bravo (not its last tab); g1 is
        // focused last.
        // A tab strip scrolls when its group is narrow (macOS opens a smaller
        // window), so bring each tab into view before tapping it.
        for (final label in ['bravo', 'alpha']) {
          final tab = find.text('Workspace overview · $label');
          await tester.ensureVisible(tab);
          await tester.pumpAndSettle();
          await tester.tap(tab);
          await tester.pumpAndSettle();
        }

        final before = c.layout!;
        final beforeSplit = before.root as SplitNode;
        expect(beforeSplit.direction, SplitDirection.horizontal);
        expect(beforeSplit.ratio, isNot(0.5));
        expect(before.focusedGroup, g1);
        expect(before.group(g1)!.tabs.length, 1);
        expect(before.group(g2)!.tabs.length, 2);
        expect(
          before.tab(before.group(g2)!.active!)!.item,
          before.group(g2)!.tabs.first.item,
        );

        await quit(tester);

        await launch(tester);
        await _pumpUntil(
          tester,
          () => _controller(tester).workspaces.length == 3,
        );
        final after = _controller(tester).layout!;
        expect(_controller(tester).restoreNotice, isNull);

        expect(layoutToJson(after), layoutToJson(before));
        final afterSplit = after.root as SplitNode;
        expect(afterSplit.id, beforeSplit.id);
        expect(afterSplit.direction, SplitDirection.horizontal);
        expect(afterSplit.ratio, beforeSplit.ratio);
        expect(after.focusedGroup, g1);
        expect(after.group(g2)!.active, before.group(g2)!.active);
        expect(
          [for (final t in after.tabs) t.id],
          [for (final t in before.tabs) t.id],
        );

        // And the UI shows them.
        expect(find.byKey(Key('group-$g1')), findsOneWidget);
        expect(find.byKey(Key('group-$g2')), findsOneWidget);
        for (final n in names) {
          expect(find.text('Workspace overview · $n'), findsOneWidget);
        }
        expect(find.byKey(Key('split-handle-${split.id}')), findsOneWidget);
      },
    );
  });
}
