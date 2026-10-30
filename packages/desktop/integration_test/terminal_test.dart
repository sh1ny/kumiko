import 'dart:convert';
import 'dart:io';

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

/// The visible text of each grid row, trailing blanks trimmed.
List<String> _rows(AlacrittySurface surface) {
  final grid = surface.engine.grid;
  return [
    for (var y = 0; y < grid.rows; y++)
      String.fromCharCodes([
        for (var x = 0; x < grid.columns; x++)
          grid.codepointAt(y, x) == 0 ? 0x20 : grid.codepointAt(y, x),
      ]).trimRight(),
  ];
}

/// The real app and the bundled host: a terminal runs a real shell (design
/// D7, D8).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(AlacrittySurface.init);

  group('terminal', () {
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

    testWidgets(
      'first launch shows the empty state; New terminal opens a terminal in '
      'Personal and Split right a second shell',
      (tester) async {
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
          what: 'the workbench and the shell profiles',
        );
        final c = _controller(tester);
        expect(c.layout!.tabs, isEmpty, reason: 'a fresh profile has no tab');
        expect(c.layout!.selectedWorkspace, isNull, reason: 'Personal');
        expect(find.byKey(const Key('empty-state')), findsOneWidget);
        expect(find.text('New terminal'), findsOneWidget);

        await tester.tap(find.byKey(const Key('new-terminal')));
        await _pumpUntil(
          tester,
          () => c.layout!.tabs.length == 1,
          what: 'the tab to open',
        );

        // The default profile opens at once: no dialog, no picker.
        final pane = c.layout!.tabs.single.root as PaneNode;
        expect(pane.kind, terminalKind);
        expect(pane.workspace, isNull);
        await _pumpUntil(
          tester,
          () => c.terminals.statusOf(pane.id) == TerminalStatus.live,
          what: 'the shell to start',
        );
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(Dialog), findsNothing);
        expect(c.message, isNull);
        expect(find.byKey(const Key('empty-state')), findsNothing);

        // The shell answers what is typed into the view.
        final surface =
            c.terminals.linkOf(pane.id)!.surface as AlacrittySurface;
        surface.engine.write(utf8.encode('echo kumiko-terminal-ok\r'));
        await _pumpUntil(
          tester,
          () => _rows(surface).contains('kumiko-terminal-ok'),
          what: 'the shell to print its answer',
        );
        expect(c.terminals.statusOf(pane.id), TerminalStatus.live);

        // Split right: a second shell beside the first.
        await tester.tap(find.byKey(Key('split-right-${pane.id}')));
        await _pumpUntil(
          tester,
          () => c.layout!.panes.length == 2,
          what: 'the split pane to open',
        );
        final second = c.layout!.focusedPane!;
        expect(second, isNot(pane.id));
        await _pumpUntil(
          tester,
          () => c.terminals.statusOf(second) == TerminalStatus.live,
          what: 'the second shell to start',
        );
        final other = c.terminals.linkOf(second)!.surface as AlacrittySurface;
        other.engine.write(utf8.encode('echo kumiko-second-ok\r'));
        await _pumpUntil(
          tester,
          () => _rows(other).contains('kumiko-second-ok'),
          what: 'the second shell to print its answer',
        );
        expect(c.terminals.statusOf(pane.id), TerminalStatus.live);
        expect(_rows(surface).contains('kumiko-second-ok'), isFalse);

        // The views go away with the app; the host ends the shells.
        await tester.pumpWidget(const SizedBox());
      },
    );
  });
}
