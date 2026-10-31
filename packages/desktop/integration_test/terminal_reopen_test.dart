import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:desktop/main.dart';
import 'package:desktop/src/host_link.dart';
import 'package:desktop/src/host_location.dart';
import 'package:desktop/src/launcher_link.dart';
import 'package:desktop/src/terminal/alacritty_surface.dart';
import 'package:desktop/src/terminal/terminal_controller.dart';
import 'package:desktop/src/workbench_controller.dart';
import 'package:desktop/src/workbench_page.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

/// Pumps (letting real IO run) until [done] holds.
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  String what = 'the UI',
}) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  expect(done(), isTrue, reason: 'timed out waiting for $what');
}

WorkbenchController _controller(WidgetTester tester) =>
    tester.widget<WorkbenchPage>(find.byType(WorkbenchPage)).controller;

/// The ledger's terminal units, read from the host's store.
List<String> _terminalUnits(Directory profile) {
  final file = File('${profile.path}/kumiko.db');
  if (!file.existsSync()) return const [];
  final db = sql.sqlite3.open(file.path, mode: sql.OpenMode.readOnly);
  try {
    return [
      for (final r in db.select(
        "SELECT containment_id FROM unit WHERE kind = 'terminal'",
      ))
        r['containment_id']! as String,
    ];
  } finally {
    db.close();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(AlacrittySurface.init);

  group('terminal reopen', () {
    late Directory profile;
    HostLink? link;

    setUp(() => profile = Directory.systemTemp.createTempSync('kumiko_it_'));

    tearDown(() async {
      await link?.quit();
      link = null;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      try {
        profile.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort: the host may still be releasing its log file.
      }
    });

    /// One app launch on [profile]; the workbench is loaded when this returns.
    Future<void> launch(WidgetTester tester) async {
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
          capabilities: const {Capability.workbench, Capability.terminal},
        ),
      );
      await tester.pumpWidget(
        KumikoApp(
          connector: () async => link = await connect(),
          hostPath: hostPath,
          onExit: () {},
          surfaceFactory: AlacrittySurface.new,
        ),
      );
      await _pumpUntil(
        tester,
        () =>
            find.byType(WorkbenchPage).evaluate().isNotEmpty &&
            _controller(tester).layout != null &&
            _controller(tester).profiles != null,
        what: 'the workbench',
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
      'a tab of four terminal panes reopens with the same tree and ratios, '
      'each ended, not restored, and the host runs no terminal unit',
      (tester) async {
        await launch(tester);
        final c = _controller(tester);
        expect(c.layout!.tabs, isEmpty);

        await tester.tap(find.byKey(const Key('new-terminal')));
        await _pumpUntil(
          tester,
          () => c.layout!.paneCount == 1,
          what: 'the first terminal to open',
        );
        // Split right, then split down the new pane twice: a tree of three
        // splits over four panes.
        for (final direction in ['right', 'down', 'down']) {
          final focused = c.layout!.focusedPane!;
          final count = c.layout!.paneCount;
          await tester.tap(find.byKey(Key('split-$direction-$focused')));
          await _pumpUntil(
            tester,
            () => c.layout!.paneCount == count + 1,
            what: 'the split pane to open',
          );
        }
        final tab = c.layout!.tabs.single;
        final panes = [for (final p in tab.panes) p.id];
        expect(panes, hasLength(4));
        expect(tab.root, isA<SplitNode>());

        // A ratio that is not the default.
        final root = tab.root as SplitNode;
        final handle = find.byKey(Key('split-handle-${root.id}'));
        await tester.drag(handle, const Offset(-60, 0));
        await tester.pumpAndSettle();
        expect(c.layout!.splitNode(root.id)!.ratio, isNot(0.5));

        await _pumpUntil(
          tester,
          () => panes.every(
            (id) => c.terminals.statusOf(id) == TerminalStatus.live,
          ),
          what: 'four shells to start',
        );
        expect(_terminalUnits(profile), hasLength(4));
        final before = layoutToJson(c.layout!);

        await quit(tester);

        await launch(tester);
        final after = _controller(tester);
        expect(layoutToJson(after.layout!), before);
        expect(after.restoreNotice, isNull);

        // Every pane is in place and says so; nothing is running.
        expect(find.textContaining('Ended, not restored'), findsNWidgets(4));
        for (final id in panes) {
          expect(after.terminals.linkOf(id), isNull);
          expect(find.byKey(Key('start-shell-$id')), findsOneWidget);
        }
        expect(_terminalUnits(profile), isEmpty);
      },
    );
  });
}
