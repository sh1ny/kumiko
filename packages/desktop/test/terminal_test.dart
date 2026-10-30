import 'dart:async';
import 'dart:convert';

import 'package:desktop/src/terminal/terminal_controller.dart';
import 'package:desktop/src/workbench_controller.dart';
import 'package:domain/domain.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:host_protocol/host_protocol.dart';

import 'support/fake_host.dart';
import 'support/fake_terminal_surface.dart';
import 'support/workbench_support.dart';

Uint8List bytesOf(String text) => Uint8List.fromList(utf8.encode(text));

/// A tab of four live terminal panes: [first] with three splits made through
/// the pane headers. Returns the pane ids in tree order.
Future<List<String>> fourPaneTab(WidgetTester tester, Rig rig) async {
  await launch(tester);
  final first = rig.terminalPanes.single.id;
  await tester.tap(key('split-right-$first'));
  await flush(tester);
  await tester.pumpAndSettle();
  final second = rig.layout.focusedPane!;
  await tester.tap(key('split-down-$second'));
  await flush(tester);
  await tester.pumpAndSettle();
  final third = rig.layout.focusedPane!;
  await tester.tap(key('split-down-$third'));
  await flush(tester);
  await tester.pumpAndSettle();
  final panes = [for (final p in rig.layout.tabs.single.panes) p.id];
  expect(panes, hasLength(4));
  return panes;
}

Future<void> sendShortcut(WidgetTester tester) async {
  final mac = defaultTargetPlatform == TargetPlatform.macOS;
  if (mac) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  } else {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.sendKeyDownEvent(LogicalKeyboardKey.keyT);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.keyT);
  if (mac) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  } else {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }
  await flush(tester);
  await tester.pumpAndSettle();
}

/// Calls to the host other than layout saves, which follow every change.
int hostCalls(Rig rig) =>
    rig.link.calls.where((c) => !c.startsWith('workbench/save')).length;

Future<void> tapCloseTab(WidgetTester tester, String tabId) async {
  await tester.tap(key('close-$tabId'));
  await tester.pumpAndSettle();
}

Future<void> tapClosePane(WidgetTester tester, String paneId) async {
  await tester.tap(key('close-pane-$paneId'));
  await tester.pumpAndSettle();
}

Future<void> confirm(WidgetTester tester) async {
  await tester.tap(key('close-warning-confirm'));
  await flush(tester);
  await tester.pumpAndSettle();
}

/// Types [key] and returns what each host terminal has received.
Future<Map<String, List<String>>> typed(
  WidgetTester tester,
  Rig rig,
  LogicalKeyboardKey key,
) async {
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  await flush(tester);
  return {
    for (final e in rig.link.terminals.entries)
      e.key: [for (final w in e.value.written) utf8.decode(w)],
  };
}

void main() {
  group('launcher', () {
    uiTest('Terminal opens a new active tab holding a terminal pane with the '
        'default profile, bound to the sidebar selection', (tester) async {
      final rig = await pumpTerminals(
        tester,
        layout: docOf(const [], selected: 'ws-a'),
        records: [workspaceRecord('ws-a')],
      );
      await launch(tester);

      final pane = rig.terminalPanes.single;
      expect(pane.workspace, 'ws-a');
      expect(pane.state, {'profileId': 'builtin:pwsh', 'profileName': 'pwsh'});
      expect(rig.layout.tabs, hasLength(1));
      expect(rig.layout.tabs.single.root, same(rig.layout.pane(pane.id)));
      expect(rig.layout.activeTab, rig.layout.tabs.single.id);
      expect(rig.layout.focusedPane, pane.id);
      expect(rig.link.opened.single.profileId, 'builtin:pwsh');
      expect(rig.link.opened.single.workspaceId, 'ws-a');
      expect(rig.linkOf(pane.id)!.status, TerminalStatus.live);
    });

    uiTest('a second launch adds a new tab with a fresh UUID item and leaves '
        'the first unchanged', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final first = rig.terminalPanes.single;
      await launch(tester);

      expect(rig.terminalPanes, hasLength(2));
      expect(rig.layout.tabs, hasLength(2));
      final items = [for (final p in rig.terminalPanes) p.item];
      expect(items.toSet(), hasLength(2));
      final uuid = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      for (final item in items) {
        expect(item, matches(uuid));
      }
      expect(rig.terminalPanes.first.id, first.id);
      expect(rig.linkOf(first.id)!.status, TerminalStatus.live);
      expect(rig.link.opened, hasLength(2));
    });

    uiTest('profile picker opens the chosen profile', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester, entry: 'launch-terminal-profile');
      expect(key('profile-picker'), findsOneWidget);
      await tester.tap(key('pick-builtin:bash'));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(rig.link.opened.single.profileId, 'builtin:bash');
      expect(rig.terminalPanes.single.state['profileName'], 'bash');
    });

    uiTest('a host without the capability: the launcher entry is disabled '
        'with the reason, New terminal and the splits likewise, and the '
        'workbench works', (tester) async {
      final rig = await pumpTerminals(
        tester,
        layout: docOf(const [], selected: 'ws-a'),
        records: [workspaceRecord('ws-a')],
        capabilities: const {Capability.workbench},
      );
      expect(
        tester.widget<FilledButton>(key('new-terminal')).onPressed,
        isNull,
      );
      await tester.tap(key('add-tab'));
      await tester.pumpAndSettle();

      final terminal = tester.widget<PopupMenuItem<String>>(
        key('launch-terminal'),
      );
      expect(terminal.enabled, isFalse);
      expect(
        find.descendant(
          of: key('launch-terminal'),
          matching: find.textContaining('does not support terminals'),
        ),
        findsOneWidget,
      );
      final overview = tester.widget<PopupMenuItem<String>>(
        find.widgetWithText(PopupMenuItem<String>, 'Workspace overview'),
      );
      expect(overview.enabled, isTrue);
      await tester.tap(
        find.widgetWithText(PopupMenuItem<String>, 'Workspace overview'),
      );
      await tester.pumpAndSettle();

      // A pane of the new tab: its splits are disabled with the reason.
      final pane = rig.layout.tabs.single.root.id;
      for (final k in ['split-right-$pane', 'split-down-$pane']) {
        final button = tester.widget<IconButton>(key(k));
        expect(button.onPressed, isNull);
        expect(button.tooltip, contains('does not support terminals'));
      }
      expect(rig.link.calls, isNot(contains(startsWith('terminal/'))));
      await tester.pump(const Duration(seconds: 3));
    });

    uiTest('a removed default: the launcher and New terminal ask to choose, '
        'naming it, and open nothing', (tester) async {
      final rig = await pumpEmpty(tester);
      rig.link.profiles = const ProfileListResult(
        profiles: [
          ShellProfile(
            id: 'builtin:bash',
            name: 'bash',
            executable: '/bin/bash',
          ),
        ],
        defaultId: 'builtin:pwsh',
        defaultAvailable: false,
      );
      await launch(tester);

      expect(key('choose-profile-prompt'), findsOneWidget);
      expect(find.textContaining('pwsh'), findsWidgets);
      expect(find.textContaining('no longer available'), findsOneWidget);
      expect(rig.link.opened, isEmpty);
      expect(rig.layout.tabs, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await tester.tap(key('new-terminal'));
      await flush(tester);
      await tester.pumpAndSettle();
      expect(key('choose-profile-prompt'), findsOneWidget);
      expect(find.textContaining('pwsh'), findsWidgets);
      expect(rig.link.opened, isEmpty);
      expect(rig.layout.tabs, isEmpty);
    });

    uiTest('an empty profile list says so and offers Add profile', (
      tester,
    ) async {
      final rig = await pumpEmpty(tester);
      rig.link.profiles = const ProfileListResult(
        profiles: [],
        defaultAvailable: false,
      );
      await launch(tester);

      expect(
        find.textContaining('No shell profile is available'),
        findsOneWidget,
      );
      expect(key('add-profile'), findsOneWidget);
      expect(rig.link.opened, isEmpty);
      expect(rig.layout.tabs, isEmpty);
    });
  });

  group('empty state', () {
    uiTest('New terminal opens an active tab with one terminal pane bound to '
        'the sidebar selection', (tester) async {
      final rig = await pumpTerminals(
        tester,
        layout: docOf(const [], selected: 'ws-a'),
        records: [workspaceRecord('ws-a')],
      );
      expect(key('empty-state'), findsOneWidget);

      await tester.tap(key('new-terminal'));
      await flush(tester);
      await tester.pumpAndSettle();

      final pane = rig.terminalPanes.single;
      expect(pane.workspace, 'ws-a');
      expect(rig.layout.activeTab, rig.layout.tabs.single.id);
      expect(rig.layout.focusedPane, pane.id);
      expect(rig.link.opened.single.workspaceId, 'ws-a');
      expect(rig.link.opened.single.profileId, 'builtin:pwsh');
      expect(rig.linkOf(pane.id)!.status, TerminalStatus.live);
      expect(key('empty-state'), findsNothing);
    });
  });

  group('shortcut', () {
    for (final mac in [false, true]) {
      uiTest('${mac ? 'Cmd+T with the platform set to macOS' : 'Ctrl+Shift+T'} '
          'with no tabs opens an active terminal tab bound to the sidebar '
          'selection with the default profile', (tester) async {
        debugDefaultTargetPlatformOverride = mac ? TargetPlatform.macOS : null;
        try {
          final rig = await pumpTerminals(
            tester,
            layout: docOf(const [], selected: 'ws-a'),
            records: [workspaceRecord('ws-a')],
          );
          expect(
            inside('new-terminal', find.text(mac ? 'Cmd+T' : 'Ctrl+Shift+T')),
            findsOneWidget,
          );

          await sendShortcut(tester);

          final pane = rig.terminalPanes.single;
          expect(pane.workspace, 'ws-a');
          expect(rig.layout.activeTab, rig.layout.tabs.single.id);
          expect(rig.link.opened.single.profileId, 'builtin:pwsh');
          expect(rig.link.opened.single.workspaceId, 'ws-a');
          expect(rig.linkOf(pane.id)!.status, TerminalStatus.live);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    uiTest('with a live terminal pane focused, the shortcut opens a new '
        'terminal tab and the focused terminal\'s input channel receives no '
        'bytes', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final first = rig.terminalPanes.single;

      // The fake view takes the focus and types every key it receives.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyX);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyX);
      await flush(tester);
      final typed = rig.link.terminals['t1']!.written.length;
      expect(typed, greaterThan(0), reason: 'the view receives plain keys');

      await sendShortcut(tester);

      expect(rig.layout.tabs, hasLength(2));
      expect(rig.layout.activeTab, rig.layout.tabs.last.id);
      expect(rig.terminalPanes, hasLength(2));
      expect(rig.link.terminals['t1']!.written, hasLength(typed));
      expect(rig.linkOf(first.id)!.status, TerminalStatus.live);
    });

    uiTest('while the close warning is open the shortcut opens no terminal; '
        'after it closes the shortcut works again', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final first = rig.terminalPanes.single;
      await tester.tap(key('split-right-${first.id}'));
      await flush(tester);
      await tester.pumpAndSettle();
      await tapClosePane(tester, rig.layout.focusedPane!);
      expect(key('close-warning'), findsOneWidget);
      final panes = rig.terminalPanes.length;
      final calls = hostCalls(rig);

      await sendShortcut(tester);

      expect(rig.terminalPanes, hasLength(panes));
      expect(rig.link.opened, hasLength(2));
      expect(hostCalls(rig), calls);

      await tester.tap(key('close-warning-cancel'));
      await tester.pumpAndSettle();
      expect(key('close-warning'), findsNothing);
      await sendShortcut(tester);

      expect(rig.terminalPanes, hasLength(panes + 1));
      expect(rig.link.opened, hasLength(3));
    });

    uiTest('without the terminal capability the shortcut opens no tab and '
        'shows the reason', (tester) async {
      final rig = await pumpTerminals(
        tester,
        capabilities: const {Capability.workbench},
      );

      await sendShortcut(tester);

      expect(rig.layout.tabs, isEmpty);
      expect(rig.controller.message, contains('does not support terminals'));
      expect(find.textContaining('does not support terminals'), findsWidgets);
    });
  });

  group('keyboard focus', () {
    /// Types one key and returns the keys each host terminal has received.
    Future<Map<String, List<String>>> typeKey(
      WidgetTester tester,
      Rig rig,
      LogicalKeyboardKey key,
    ) async {
      await tester.sendKeyDownEvent(key);
      await tester.sendKeyUpEvent(key);
      await flush(tester);
      return {
        for (final e in rig.link.terminals.entries)
          e.key: [for (final w in e.value.written) utf8.decode(w)],
      };
    }

    uiTest('a terminal opened by the launcher takes the keys', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);

      final got = await typeKey(tester, rig, LogicalKeyboardKey.keyA);

      expect(got['t1'], ['key:A']);
    });

    uiTest('after Split right, typed keys reach the new terminal and '
        'not the old one', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final first = rig.terminalPanes.single;
      await tester.tap(key('split-right-${first.id}'));
      await flush(tester);
      await tester.pumpAndSettle();

      final got = await typeKey(tester, rig, LogicalKeyboardKey.keyB);

      expect(got['t2'], ['key:B']);
      expect(got['t1'], isEmpty);
    });

    uiTest('after closing the focused pane, keys reach the sibling', (
      tester,
    ) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final first = rig.terminalPanes.single;
      await tester.tap(key('split-right-${first.id}'));
      await flush(tester);
      await tester.pumpAndSettle();
      await tapClosePane(tester, rig.layout.focusedPane!);
      await confirm(tester);
      rig.link.emitExit('t2', status: null, reason: TerminalExitReason.closed);
      await flush(tester);
      await tester.pumpAndSettle();
      expect(rig.layout.focusedPane, first.id);

      final got = await typeKey(tester, rig, LogicalKeyboardKey.keyC);

      expect(got['t1'], ['key:C']);
    });

    uiTest('after switching to another tab, keys reach the focused '
        'pane', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final firstTab = rig.layout.tabs.single.id;
      await launch(tester);

      await tester.tap(key('tab-$firstTab'));
      await tester.pumpAndSettle();
      final got = await typeKey(tester, rig, LogicalKeyboardKey.keyD);

      expect(got['t1'], ['key:D']);
      expect(got['t2'], isEmpty);
    });

    uiTest('clicking a pane gives it the keys', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final first = rig.terminalPanes.single;
      await tester.tap(key('split-right-${first.id}'));
      await flush(tester);
      await tester.pumpAndSettle();

      await tester.tapAt(tester.getCenter(key('pane-${first.id}')));
      await tester.pump();
      final got = await typeKey(tester, rig, LogicalKeyboardKey.keyE);

      expect(got['t1'], ['key:E']);
      expect(got['t2'], isEmpty);
    });

    uiTest('focusing a non-terminal pane takes the keys from the terminal', (
      tester,
    ) async {
      final rig = await pumpTerminals(
        tester,
        layout: docOf([tabOf('t1', overviewOf('p1', 'A'))], selected: 'A'),
        records: [workspaceRecord('A')],
      );
      await tester.tap(key('split-down-p1'));
      await flush(tester);
      await tester.pumpAndSettle();
      var got = await typeKey(tester, rig, LogicalKeyboardKey.keyH);
      expect(got['t1'], ['key:H']);

      await tester.tapAt(tester.getCenter(key('pane-p1')));
      await tester.pump();
      expect(rig.layout.focusedPane, 'p1');
      got = await typeKey(tester, rig, LogicalKeyboardKey.keyI);

      expect(got['t1'], ['key:H'], reason: 'the overview is focused');
    });

    uiTest('after a move the moved pane keeps the keys, and the shortcut opens '
        'new tab takes them', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final first = rig.terminalPanes.single;
      await tester.tap(key('split-right-${first.id}'));
      await flush(tester);
      await tester.pumpAndSettle();
      await tester.tap(key('move-${rig.layout.focusedPane!}'));
      await tester.pumpAndSettle();

      var got = await typeKey(tester, rig, LogicalKeyboardKey.keyF);
      expect(got['t2'], ['key:F']);

      await sendShortcut(tester);
      got = await typeKey(tester, rig, LogicalKeyboardKey.keyG);
      expect(got['t3'], ['key:G']);
      expect(got['t2'], ['key:F']);
    });
  });

  group('inactive tabs', () {
    uiTest('a terminal in an inactive tab keeps receiving output; switching '
        'back shows the same surface and link and sends nothing to the host', (
      tester,
    ) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final tabA = rig.layout.tabs.single.id;
      final paneA = rig.terminalPanes.single.id;
      final linkA = rig.linkOf(paneA)!;
      final surfaceA = rig.surfaces.made.first;
      await launch(tester);
      expect(rig.layout.activeTab, isNot(tabA));
      final made = rig.surfaces.made.length;

      rig.link.terminals['t1']!.send(bytesOf('while away'));
      await flush(tester);
      expect(utf8.decode(surfaceA.fedAll), 'while away');
      final calls = hostCalls(rig);

      await tester.tap(key('tab-$tabA'));
      await tester.pumpAndSettle();

      expect(rig.linkOf(paneA), same(linkA));
      expect(linkA.surface, same(surfaceA));
      expect(rig.surfaces.made, hasLength(made));
      expect(surfaceA.disposed, isFalse);
      expect(find.byKey(const ValueKey('surface-1')), findsOneWidget);
      expect(utf8.decode(surfaceA.fedAll), 'while away');
      expect(hostCalls(rig), calls, reason: 'switching sends nothing');
      expect(rig.link.closed, isEmpty);
      expect(linkA.status, TerminalStatus.live);
    });

    uiTest('the view of an inactive tab stays mounted with its state', (
      tester,
    ) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final tabA = rig.layout.tabs.single.id;
      await launch(tester);

      expect(
        find.byKey(const ValueKey('surface-1'), skipOffstage: false),
        findsOneWidget,
        reason: 'not unmounted while its tab is inactive',
      );
      expect(find.byKey(const ValueKey('surface-1')), findsNothing);
      await tester.tap(key('tab-$tabA'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('surface-1')), findsOneWidget);
    });
  });

  group('shell profiles', () {
    Future<void> openProfiles(WidgetTester tester) async {
      await launch(tester, entry: 'shell-profiles');
      expect(key('profiles-dialog'), findsOneWidget);
    }

    uiTest('a built-in profile offers Copy as new profile, not Edit or '
        'Remove', (tester) async {
      final rig = await pumpEmpty(tester);
      await openProfiles(tester);

      expect(key('edit-builtin:bash'), findsNothing);
      expect(key('remove-builtin:bash'), findsNothing);
      await tester.tap(key('copy-builtin:bash'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(key('profile-executable')).controller!.text,
        '/bin/bash',
      );
      await tester.tap(key('profile-save'));
      await flush(tester);
      await tester.pumpAndSettle();

      final saved = rig.link.savedProfiles.single;
      expect(saved.isBuiltin, isFalse);
      expect(saved.executable, '/bin/bash');
    });

    uiTest('add a profile with arguments and an environment override', (
      tester,
    ) async {
      final rig = await pumpEmpty(tester);
      await openProfiles(tester);
      await tester.tap(key('add-profile'));
      await tester.pumpAndSettle();

      await tester.enterText(key('profile-name'), 'elvish');
      await tester.enterText(key('profile-executable'), r'C:\tools\elvish.exe');
      await tester.enterText(key('profile-args'), '--login\n--private');
      await tester.enterText(key('profile-env'), 'EDITOR=hx');
      await tester.tap(key('profile-save'));
      await flush(tester);
      await tester.pumpAndSettle();

      final saved = rig.link.savedProfiles.single;
      expect(saved.name, 'elvish');
      expect(saved.args, ['--login', '--private']);
      expect(saved.env, {'EDITOR': 'hx'});
      expect(saved.id, isNot(startsWith('builtin:')));
    });

    uiTest('a profile with an empty executable is refused with a message', (
      tester,
    ) async {
      final rig = await pumpEmpty(tester);
      await openProfiles(tester);
      await tester.tap(key('add-profile'));
      await tester.pumpAndSettle();
      await tester.enterText(key('profile-name'), 'nothing');
      await tester.tap(key('profile-save'));
      await tester.pumpAndSettle();

      expect(find.text('The executable is required.'), findsOneWidget);
      expect(rig.link.savedProfiles, isEmpty);
    });

    uiTest('remove a user profile and set the default', (tester) async {
      final rig = await pumpEmpty(tester);
      rig.link.profiles = const ProfileListResult(
        profiles: [
          ShellProfile(id: 'builtin:pwsh', name: 'pwsh', executable: '/p'),
          ShellProfile(id: 'user-1', name: 'mine', executable: '/m'),
        ],
        defaultId: 'builtin:pwsh',
        defaultAvailable: true,
      );
      await openProfiles(tester);

      await tester.tap(key('set-default-user-1'));
      await flush(tester);
      await tester.pumpAndSettle();
      expect(rig.link.defaultsSet, ['user-1']);

      await tester.tap(key('remove-user-1'));
      await flush(tester);
      await tester.pumpAndSettle();
      expect(rig.link.removedProfiles, ['user-1']);
    });
  });

  group('split', () {
    uiTest('Split right opens a default-profile terminal bound to the '
        "pane's workspace and leaves the first terminal unchanged", (
      tester,
    ) async {
      final rig = await pumpTerminals(
        tester,
        layout: docOf(const [], selected: 'ws-a'),
        records: [workspaceRecord('ws-a')],
      );
      await launch(tester);
      final first = rig.terminalPanes.single;
      rig.link.terminals['t1']!.send(bytesOf('first output'));
      await flush(tester);

      await tester.tap(key('split-right-${first.id}'));
      await flush(tester);
      await tester.pumpAndSettle();

      final tab = rig.layout.tabs.single;
      final root = tab.root as SplitNode;
      expect(root.direction, SplitDirection.horizontal);
      expect(root.ratio, 0.5);
      expect(root.first.id, first.id);
      final second = root.second as PaneNode;
      expect(second.kind, terminalKind);
      expect(second.workspace, 'ws-a');
      expect(tab.focusedPane, second.id);
      expect(rig.link.opened, hasLength(2));
      expect(rig.link.opened.last.profileId, 'builtin:pwsh');
      expect(rig.link.opened.last.workspaceId, 'ws-a');
      expect(rig.linkOf(second.id)!.status, TerminalStatus.live);
      expect(rig.linkOf(first.id)!.status, TerminalStatus.live);
      expect(utf8.decode(rig.surfaces.made.first.fedAll), 'first output');
      expect(rig.surfaces.made.first.disposed, isFalse);
      expect(rig.link.closed, isEmpty);
    });

    uiTest('Split down on an overview opens a terminal in its workspace '
        'below it', (tester) async {
      final rig = await pumpTerminals(
        tester,
        layout: docOf([tabOf('t1', overviewOf('p1', 'B'))], selected: 'A'),
        records: [workspaceRecord('A'), workspaceRecord('B')],
      );

      await tester.tap(key('split-down-p1'));
      await flush(tester);
      await tester.pumpAndSettle();

      final root = rig.layout.tab('t1')!.root as SplitNode;
      expect(root.direction, SplitDirection.vertical);
      expect(root.first.id, 'p1');
      final below = root.second as PaneNode;
      expect(below.kind, terminalKind);
      expect(
        below.workspace,
        'B',
        reason: "the split pane's, not the selection",
      );
      expect(rig.link.opened.single.workspaceId, 'B');
      expect(rig.layout.pane('p1')!.kind, workspaceOverviewKind);
      expect(rig.layout.pane('p1')!.workspace, 'B');
      expect(key('overview-B'), findsOneWidget);
      expect(
        tester.getRect(key('pane-${below.id}')).top,
        greaterThanOrEqualTo(tester.getRect(key('pane-p1')).bottom),
      );
    });

    uiTest('a split with an unavailable default creates no pane, leaves the '
        'layout unchanged and names the profile', (tester) async {
      final rig = await pumpTerminals(
        tester,
        layout: docOf([tabOf('t1', overviewOf('p1', 'A'))]),
        records: [workspaceRecord('A')],
      );
      rig.link.profiles = const ProfileListResult(
        profiles: [
          ShellProfile(
            id: 'builtin:bash',
            name: 'bash',
            executable: '/bin/bash',
          ),
        ],
        defaultId: 'builtin:pwsh',
        defaultAvailable: false,
      );
      final before = jsonOf(rig.layout);

      await tester.tap(key('split-down-p1'));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(key('choose-profile-prompt'), findsOneWidget);
      expect(
        find.textContaining('"pwsh" is no longer available'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(jsonOf(rig.layout), before);
      expect(rig.link.opened, isEmpty);
    });

    uiTest('a split whose terminal open is refused keeps the new pane '
        'focused beside the split pane with the reason and Start shell; the '
        'split pane is unchanged', (tester) async {
      final rig = await pumpTerminals(
        tester,
        layout: docOf([tabOf('t1', overviewOf('p1', 'A'))]),
        records: [workspaceRecord('A')],
      );
      rig.link.terminalOpenAnswers.add(
        RpcException(ErrorCode.unitCap, 'at most 64 units'),
      );

      await tester.tap(key('split-right-p1'));
      await flush(tester);
      await tester.pumpAndSettle();

      final root = rig.layout.tab('t1')!.root as SplitNode;
      final fresh = root.second as PaneNode;
      expect(root.first.id, 'p1');
      expect(rig.layout.tab('t1')!.focusedPane, fresh.id);
      expect(rig.linkOf(fresh.id)!.status, TerminalStatus.ended);
      expect(
        inside('pane-${fresh.id}', find.textContaining('unit-cap')),
        findsOneWidget,
      );
      expect(key('start-shell-${fresh.id}'), findsOneWidget);
      expect(rig.layout.pane('p1')!.kind, workspaceOverviewKind);
      expect(key('overview-A'), findsOneWidget);
    });
  });

  group('terminal link', () {
    uiTest('an open refused at the unit cap shows its reason in the pane', (
      tester,
    ) async {
      final rig = await pumpEmpty(tester);
      rig.link.terminalOpenAnswers.add(
        RpcException(ErrorCode.unitCap, 'at most 64 units'),
      );
      await launch(tester);

      final pane = rig.terminalPanes.single;
      expect(rig.linkOf(pane.id)!.status, TerminalStatus.ended);
      expect(
        inside('pane-${pane.id}', find.textContaining('unit-cap')),
        findsOneWidget,
      );
      expect(key('start-shell-${pane.id}'), findsOneWidget);
    });

    uiTest('exited status 0 closes the pane without a dialog, its sibling '
        'takes the space and focus, and no new open is sent', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final first = rig.terminalPanes.single;
      await tester.tap(key('split-right-${first.id}'));
      await flush(tester);
      await tester.pumpAndSettle();
      final second = rig.layout.focusedPane!;
      final calls = hostCalls(rig);

      rig.link.emitExit('t2', status: 0);
      await flush(tester);
      await tester.pumpAndSettle();

      expect(key('close-warning'), findsNothing);
      expect(rig.layout.panes.map((p) => p.id), [first.id]);
      expect(rig.layout.tabs.single.root.id, first.id, reason: 'no split left');
      expect(rig.layout.focusedPane, first.id);
      expect(rig.linkOf(second), isNull);
      expect(rig.link.opened, hasLength(2));
      expect(rig.link.closed, isEmpty, reason: 'nothing is live to close');
      expect(rig.link.released, ['t2']);
      expect(hostCalls(rig), calls + 1, reason: 'only the release');
      expect(
        tester.getRect(key('pane-${first.id}')).right,
        tester.getRect(key('central-area')).right,
      );
      // Focus went to the sibling: keys reach it.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyD);
      await flush(tester);
      expect(
        [for (final w in rig.link.terminals['t1']!.written) utf8.decode(w)],
        ['key:D'],
      );
    });

    uiTest('a clean exit in the only pane closes the tab, and the last tab '
        'shows the empty state', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      await launch(tester);
      expect(rig.layout.tabs, hasLength(2));

      rig.link.emitExit('t2');
      await flush(tester);
      await tester.pumpAndSettle();
      expect(rig.layout.tabs, hasLength(1));
      expect(rig.layout.activeTab, rig.layout.tabs.single.id);

      rig.link.emitExit('t1');
      await flush(tester);
      await tester.pumpAndSettle();
      expect(rig.layout.tabs, isEmpty);
      expect(rig.layout.activeTab, isNull);
      expect(key('empty-state'), findsOneWidget);
      expect(key('new-terminal'), findsOneWidget);
      expect(key('add-tab'), findsOneWidget);
      expect(rig.link.released, containsAll(['t1', 't2']));
    });

    uiTest('exit status 3 keeps the pane ended with the earlier output and '
        'Start shell; a started shell that exits 0 closes its pane', (
      tester,
    ) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final pane = rig.terminalPanes.single;
      final surface = rig.surfaces.last;
      rig.link.lastTerminal.send(bytesOf('before exit\r\n'));
      await flush(tester);

      rig.link.emitExit('t1', status: 3);
      await flush(tester);

      expect(rig.linkOf(pane.id)!.status, TerminalStatus.ended);
      expect(find.textContaining('exit status 3'), findsOneWidget);
      expect(key('start-shell-${pane.id}'), findsOneWidget);
      expect(utf8.decode(surface.fedAll), 'before exit\r\n');
      expect(rig.link.opened, hasLength(1));
      expect(rig.layout.panes, hasLength(1));

      await tester.tap(key('start-shell-${pane.id}'));
      await flush(tester);
      await tester.pumpAndSettle();
      expect(rig.linkOf(pane.id)!.status, TerminalStatus.live);
      expect(rig.link.opened, hasLength(2));

      rig.link.emitExit('t2', status: 0);
      await flush(tester);
      await tester.pumpAndSettle();
      expect(rig.layout.tabs, isEmpty);
    });

    uiTest('a clean exit while the close dialog is open removes the pane '
        'once, and confirming then sends no close', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final first = rig.terminalPanes.single;
      await tester.tap(key('split-right-${first.id}'));
      await flush(tester);
      await tester.pumpAndSettle();
      final second = rig.layout.focusedPane!;
      await tapClosePane(tester, second);
      expect(key('close-warning'), findsOneWidget);

      rig.link.emitExit('t2', status: 0);
      await flush(tester);
      await confirm(tester);

      expect(rig.layout.panes.map((p) => p.id), [first.id]);
      expect(rig.link.closed, isEmpty);
    });

    uiTest('a signal, an io-error and a closed exit with no status keep the '
        'pane; none closes it', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      await launch(tester);
      await launch(tester);

      rig.link.emitExit('t1', status: null);
      rig.link.emitExit('t2', status: null, reason: TerminalExitReason.ioError);
      rig.link.emitExit('t3', status: 137);
      await flush(tester);
      await tester.pumpAndSettle();

      expect(rig.layout.panes, hasLength(3));
      for (final p in rig.layout.panes) {
        expect(rig.linkOf(p.id)!.status, TerminalStatus.ended);
      }
    });

    uiTest('a clean exit in an unfocused pane of the active tab leaves the '
        'focus unchanged and only deletes the pane from recent', (
      tester,
    ) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final first = rig.terminalPanes.single;
      await tester.tap(key('split-right-${first.id}'));
      await flush(tester);
      await tester.pumpAndSettle();
      final second = rig.layout.focusedPane!;
      rig.controller.focusPane(first.id);
      await tester.pumpAndSettle();
      final recent = [
        for (final id in rig.layout.recent)
          if (id != second) id,
      ];
      final tab = rig.layout.activeTab;

      rig.link.emitExit('t2', status: 0);
      await flush(tester);
      await tester.pumpAndSettle();

      expect(rig.layout.pane(second), isNull);
      expect(rig.layout.activeTab, tab);
      expect(rig.layout.focusedPane, first.id);
      expect(rig.layout.recent, recent);
      final got = await typed(tester, rig, LogicalKeyboardKey.keyE);
      expect(got['t1'], ['key:E']);
    });

    uiTest('a clean exit in a pane of an inactive tab leaves the active tab '
        'and keyboard focus unchanged and only deletes the pane from recent; a '
        'clean exit in the only pane of an inactive tab closes that tab and '
        'does the same', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final first = rig.terminalPanes.single;
      await tester.tap(key('split-right-${first.id}'));
      await flush(tester);
      await tester.pumpAndSettle();
      final firstTab = rig.layout.tabs.single.id;
      await launch(tester); // t3, in a second tab that is active
      final active = rig.layout.activeTab;
      final focused = rig.layout.focusedPane;
      expect(active, isNot(firstTab));

      final before = rig.layout.recent;
      rig.link.emitExit('t1', status: 0); // one of two panes of firstTab
      await flush(tester);
      await tester.pumpAndSettle();
      expect(rig.layout.pane(first.id), isNull);
      expect(rig.layout.tabs, hasLength(2));
      expect(rig.layout.activeTab, active);
      expect(rig.layout.focusedPane, focused);
      expect(rig.layout.recent, [
        for (final id in before)
          if (id != first.id) id,
      ], reason: 'survivors keep their order; the removed id is deleted');
      final recent = rig.layout.recent;

      rig.link.emitExit('t2', status: 0); // now the only pane of firstTab
      await flush(tester);
      await tester.pumpAndSettle();
      expect(rig.layout.tabs.map((t) => t.id), [active]);
      expect(rig.layout.activeTab, active);
      expect(rig.layout.focusedPane, focused);
      expect(rig.layout.recent, [
        for (final id in recent)
          if (rig.layout.pane(id) != null) id,
      ]);
      final got = await typed(tester, rig, LogicalKeyboardKey.keyF);
      expect(got['t3'], ['key:F']);
      expect(got['t1'], isEmpty);
      expect(got['t2'], isEmpty);
    });

    uiTest('status 0 with outputComplete false keeps the pane ended with '
        'output may be incomplete and Start shell', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final pane = rig.terminalPanes.single;
      rig.link.lastTerminal.send(bytesOf('partial'));
      await flush(tester);

      rig.link.emitExit('t1', status: 0, outputComplete: false);
      await flush(tester);
      await tester.pumpAndSettle();

      expect(rig.layout.panes, hasLength(1));
      expect(rig.linkOf(pane.id)!.status, TerminalStatus.ended);
      expect(find.textContaining('output may be incomplete'), findsOneWidget);
      expect(key('start-shell-${pane.id}'), findsOneWidget);
      expect(utf8.decode(rig.surfaces.last.fedAll), 'partial');
    });

    uiTest('a clean exit closes the pane at once while the engine is '
        'stalled, drops the unconsumed output and releases the terminal', (
      tester,
    ) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final pane = rig.terminalPanes.single;
      rig.surfaces.last.stall();
      final big = Uint8List(1024 * 1024 + 4096);
      rig.link.lastTerminal
        ..send(big)
        ..send(big)
        ..send(bytesOf('last words\r\n'));
      await flush(tester);
      expect(rig.link.lastTerminal.queuedBytes, greaterThan(0));

      rig.link.emitExit('t1', status: 0);
      await flush(tester);
      await tester.pumpAndSettle();

      expect(rig.layout.pane(pane.id), isNull, reason: 'did not wait');
      expect(rig.linkOf(pane.id), isNull);
      expect(rig.link.released, ['t1']);
      expect(rig.link.closed, isEmpty);
      expect(rig.layout.tabs, isEmpty);
    });

    uiTest('the ended grid fills the pane height below the banner', (
      tester,
    ) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final pane = rig.terminalPanes.single;
      final live = tester.getSize(key('surface-box-1')).height;

      rig.link.emitExit('t1', status: 3);
      await flush(tester);
      await tester.pumpAndSettle();

      final box = tester.getRect(key('surface-box-1'));
      final body = tester.getRect(key('pane-${pane.id}'));
      final banner = tester.getRect(key('start-shell-${pane.id}'));
      expect(box.bottom, body.bottom, reason: 'no blank area below the grid');
      expect(box.top, greaterThanOrEqualTo(banner.bottom));
      expect(box.height, greaterThan(live / 2));
      expect(box.width, body.width);
    });

    uiTest('an externally killed shell reports its status and the ended view '
        'keeps the earlier output', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final surface = rig.surfaces.last;
      rig.link.lastTerminal.send(bytesOf('building...\r\n'));
      await flush(tester);

      rig.link.emitExit('t1', status: 137);
      await flush(tester);

      expect(find.textContaining('exit status 137'), findsOneWidget);
      expect(utf8.decode(surface.fedAll), 'building...\r\n');
      expect(surface.disposed, isFalse, reason: 'its output stays visible');
      expect(find.byKey(const ValueKey('surface-1')), findsOneWidget);
    });

    uiTest('the last line arrives before the ended state; outputComplete '
        'false says the output may be incomplete', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final pane = rig.terminalPanes.single;
      rig.surfaces.last.stall();
      // More than the bound, so the channel is paused with bytes left over.
      final big = Uint8List(1024 * 1024 + 4096);
      rig.link.lastTerminal
        ..send(big)
        ..send(big)
        ..send(bytesOf('error: last line\r\n'));
      await flush(tester);
      expect(rig.link.lastTerminal.queuedBytes, greaterThan(0));

      rig.link.emitExit('t1', status: 1, outputComplete: false);
      await flush(tester);
      expect(
        rig.linkOf(pane.id)!.status,
        TerminalStatus.live,
        reason: 'the engine has not taken the last bytes yet',
      );
      expect(rig.link.released, isEmpty);

      rig.surfaces.last.resume();
      await flush(tester);
      expect(rig.linkOf(pane.id)!.status, TerminalStatus.ended);
      expect(
        utf8.decode(rig.surfaces.last.fedAll.sublist(big.length * 2)),
        'error: last line\r\n',
      );
      expect(find.textContaining('output may be incomplete'), findsOneWidget);
      expect(rig.link.released, ['t1']);
    });

    uiTest('a new host drops every link: the panes show ended and an earlier '
        "host's open result is ignored", (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final first = rig.terminalPanes.single;
      rig.link.terminalOpenGate = Completer<void>();
      await launch(tester);
      final second = rig.terminalPanes.last;
      expect(rig.linkOf(second.id)!.status, TerminalStatus.starting);

      final next = FakeHostLink(
        hello: helloResult(capabilities: terminalCapabilities),
      )..storedLayout = jsonOf(rig.layout);
      unawaited(rig.controller.attach(next));
      await flush(tester);
      rig.link.terminalOpenGate!.complete();
      await flush(tester);

      expect(rig.linkOf(first.id)!.status, TerminalStatus.ended);
      expect(rig.linkOf(second.id)!.status, TerminalStatus.ended);
      expect(rig.link.closed, isEmpty, reason: 'that host is gone');
      expect(next.opened, isEmpty);
    });

    uiTest('saved terminal pane state holds profileId and profileName only', (
      tester,
    ) async {
      final rig = await pumpTerminals(
        tester,
        layout: docOf(const [], selected: 'ws-a'),
        records: [workspaceRecord('ws-a')],
      );
      await launch(tester);
      rig.link.lastTerminal.send(bytesOf('secret output'));
      await tester.pump(const Duration(seconds: 1));
      await flush(tester);

      final saved = rig.link.saves.last.layout;
      expect(jsonEncode(saved), isNot(contains('secret output')));
      final pane = layoutFromJson(saved).panes.single;
      expect(pane.kind, 'terminal');
      expect(pane.workspace, 'ws-a');
      expect(pane.state.keys.toSet(), {'profileId', 'profileName'});
    });
  });

  group('restored panes', () {
    uiTest('Start shell opens with the pane\'s profile and workspace and '
        'empty scrollback', (tester) async {
      final rig = await pumpTerminals(
        tester,
        layout: docOf([
          tabOf(
            't1',
            restoredTerminal(
              'p9',
              ws: 'ws-a',
              profileId: 'builtin:bash',
              profileName: 'bash',
            ),
          ),
        ]),
        records: [workspaceRecord('ws-a')],
      );
      expect(find.textContaining('Ended, not restored'), findsOneWidget);
      expect(find.textContaining('bash'), findsWidgets);
      expect(rig.link.opened, isEmpty, reason: 'reopen starts nothing');

      await tester.tap(key('start-shell-p9'));
      await flush(tester);
      expect(rig.link.opened.single.profileId, 'builtin:bash');
      expect(rig.link.opened.single.workspaceId, 'ws-a');
      expect(rig.surfaces.made, hasLength(1));
      expect(rig.surfaces.last.fed, isEmpty);

      rig.link.lastTerminal.send(bytesOf('old output'));
      rig.link.emitExit('t1', status: 1);
      await flush(tester);
      await tester.tap(key('start-shell-p9'));
      await flush(tester);
      expect(rig.surfaces.made, hasLength(2));
      expect(rig.surfaces.last.fed, isEmpty, reason: 'new, empty scrollback');
    });

    uiTest('a restored pane stays ended, not restored, and keeps Start shell '
        'while another pane exits cleanly', (tester) async {
      final rig = await pumpTerminals(
        tester,
        layout: docOf([
          tabOf(
            't1',
            restoredTerminal(
              'p9',
              ws: 'ws-a',
              profileId: 'builtin:bash',
              profileName: 'bash',
            ),
          ),
        ]),
        records: [workspaceRecord('ws-a')],
      );
      await launch(tester);
      expect(rig.layout.tabs, hasLength(2));

      rig.link.emitExit('t1', status: 0);
      await flush(tester);
      await tester.pumpAndSettle();

      expect(rig.layout.tabs, hasLength(1));
      expect(rig.layout.pane('p9'), isNotNull);
      await tester.tap(key('tab-t1'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Ended, not restored'), findsOneWidget);
      expect(key('start-shell-p9'), findsOneWidget);

      await tester.tap(key('start-shell-p9'));
      await flush(tester);
      expect(rig.linkOf('p9')!.status, TerminalStatus.live);
      rig.link.emitExit('t2', status: 0);
      await flush(tester);
      await tester.pumpAndSettle();
      expect(rig.layout.pane('p9'), isNull);
      expect(rig.layout.tabs, isEmpty);
    });

    uiTest('a missing profile is named and Start shell offers the default '
        'without opening', (tester) async {
      final rig = await pumpTerminals(
        tester,
        layout: docOf([
          tabOf(
            't1',
            restoredTerminal(
              'p9',
              profileId: 'user-gone',
              profileName: 'Old shell',
            ),
          ),
        ]),
      );
      expect(find.textContaining('Old shell'), findsWidgets);
      expect(find.textContaining('no longer exists'), findsOneWidget);
      expect(
        find.descendant(
          of: key('start-shell-p9'),
          matching: find.textContaining('pwsh'),
        ),
        findsOneWidget,
        reason: 'the button names the default',
      );
      expect(rig.link.opened, isEmpty);

      await tester.tap(key('start-shell-p9'));
      await flush(tester);
      expect(rig.link.opened.single.profileId, 'builtin:pwsh');
    });
  });

  group('close', () {
    uiTest('confirm sends close and removes the pane on exited{closed}, its '
        'sibling taking its space', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final first = rig.terminalPanes.single;
      await tester.tap(key('split-right-${first.id}'));
      await flush(tester);
      await tester.pumpAndSettle();
      final second = rig.layout.focusedPane!;

      await tapClosePane(tester, second);
      expect(key('close-warning'), findsOneWidget);
      expect(rig.link.closed, isEmpty, reason: 'nothing before confirm');
      await confirm(tester);

      expect(rig.link.closed, ['t2']);
      expect(rig.linkOf(second)!.status, TerminalStatus.closing);
      expect(find.text('Closing…'), findsOneWidget);
      expect(rig.layout.panes, hasLength(2));

      rig.link.emitExit('t2', status: null, reason: TerminalExitReason.closed);
      await flush(tester);
      await tester.pumpAndSettle();
      expect(rig.layout.panes.map((p) => p.id), [first.id]);
      expect(rig.layout.tabs.single.root.id, first.id, reason: 'no split left');
      expect(rig.layout.focusedPane, first.id);
      expect(rig.link.released, contains('t2'));
      expect(
        tester.getRect(key('pane-${first.id}')).right,
        tester.getRect(key('central-area')).right,
      );
    });

    uiTest("cancel keeps the pane, its place in the split, link and channels "
        'untouched', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final first = rig.terminalPanes.single;
      await tester.tap(key('split-right-${first.id}'));
      await flush(tester);
      await tester.pumpAndSettle();
      final before = jsonOf(rig.layout);

      await tapClosePane(tester, first.id);
      await tester.tap(key('close-warning-cancel'));
      await tester.pumpAndSettle();

      expect(jsonOf(rig.layout), before);
      expect(rig.linkOf(first.id)!.status, TerminalStatus.live);
      expect(rig.link.closed, isEmpty);
      expect(rig.link.terminals['t1']!.listening, isTrue);
      expect(rig.surfaces.made.first.disposed, isFalse);
    });

    uiTest('a clean exit during the dialog removes that pane at once; confirm '
        'closes only the other terminal', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final first = rig.terminalPanes.single;
      await tester.tap(key('split-right-${first.id}'));
      await flush(tester);
      await tester.pumpAndSettle();
      final second = rig.layout.focusedPane!;
      await tapCloseTab(tester, rig.layout.tabs.single.id);
      expect(key('close-warning'), findsOneWidget);

      rig.link.emitExit('t2', status: 0);
      await flush(tester);
      await tester.pumpAndSettle();
      expect(rig.layout.pane(second), isNull, reason: 'at once');
      expect(rig.link.closed, isEmpty);

      await confirm(tester);
      expect(rig.link.closed, ['t1'], reason: 'only the one still present');
      expect(rig.link.released, ['t2']);
      rig.link.emitExit('t1', status: null, reason: TerminalExitReason.closed);
      await flush(tester);
      await tester.pumpAndSettle();
      expect(rig.layout.tabs, isEmpty);
      expect(rig.link.released, unorderedEquals(['t1', 't2']));
    });

    uiTest('a clean exit during the dialog, then cancel, leaves the other '
        'terminal running', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final first = rig.terminalPanes.single;
      await tester.tap(key('split-right-${first.id}'));
      await flush(tester);
      await tester.pumpAndSettle();
      final second = rig.layout.focusedPane!;
      await tapClosePane(tester, first.id);

      rig.link.emitExit('t2', status: 0);
      await flush(tester);
      await tester.tap(key('close-warning-cancel'));
      await tester.pumpAndSettle();

      expect(rig.layout.pane(second), isNull);
      expect(rig.layout.pane(first.id), isNotNull);
      expect(rig.linkOf(first.id)!.status, TerminalStatus.live);
      expect(rig.link.closed, isEmpty);
      expect(rig.link.terminals['t1']!.listening, isTrue);
    });

    uiTest('a non-zero exit during the dialog keeps the pane ended, and '
        'confirm removes it without sending another close', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final first = rig.terminalPanes.single;
      await tester.tap(key('split-right-${first.id}'));
      await flush(tester);
      await tester.pumpAndSettle();
      final second = rig.layout.focusedPane!;
      await tapCloseTab(tester, rig.layout.tabs.single.id);

      rig.link.emitExit('t2', status: 1);
      await flush(tester);
      await tester.pumpAndSettle();
      expect(rig.linkOf(second)!.status, TerminalStatus.ended);
      expect(rig.layout.pane(second), isNotNull);

      await confirm(tester);
      expect(rig.link.closed, ['t1'], reason: 'no second close for t2');
      expect(rig.layout.pane(second), isNull);
      rig.link.emitExit('t1', status: null, reason: TerminalExitReason.closed);
      await flush(tester);
      await tester.pumpAndSettle();
      expect(rig.layout.tabs, isEmpty);
      expect(rig.link.released, unorderedEquals(['t1', 't2']));
    });

    uiTest('a mixed dialog: one of four exits cleanly, confirm closes the '
        'other three', (tester) async {
      final rig = await pumpEmpty(tester);
      await fourPaneTab(tester, rig);
      await tapCloseTab(tester, rig.layout.tabs.single.id);

      rig.link.emitExit('t4', status: 0);
      await flush(tester);
      await confirm(tester);

      expect(rig.link.closed, unorderedEquals(['t1', 't2', 't3']));
      expect(rig.layout.panes, hasLength(3), reason: 'closing, not removed');
    });

    uiTest('a mixed dialog: one of four exits cleanly, cancel keeps the '
        'other three running', (tester) async {
      final rig = await pumpEmpty(tester);
      await fourPaneTab(tester, rig);
      await tapCloseTab(tester, rig.layout.tabs.single.id);

      rig.link.emitExit('t4', status: 0);
      await flush(tester);
      await tester.tap(key('close-warning-cancel'));
      await tester.pumpAndSettle();

      expect(rig.link.closed, isEmpty);
      expect(rig.layout.panes, hasLength(3));
      for (final p in rig.layout.panes) {
        expect(rig.linkOf(p.id)!.status, TerminalStatus.live);
      }
    });

    uiTest('an ended terminal pane closes without a dialog', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final pane = rig.terminalPanes.single;
      rig.link.emitExit('t1', status: 1);
      await flush(tester);

      await tapClosePane(tester, pane.id);
      expect(key('close-warning'), findsNothing);
      expect(rig.layout.tabs, isEmpty);
      expect(rig.link.closed, isEmpty);
    });

    uiTest('pane close names the live terminal; confirm removes the pane and '
        'its sibling fills the space', (tester) async {
      final rig = await pumpTerminals(
        tester,
        layout: docOf([
          tabOf(
            't1',
            splitOf(
              's1',
              overviewOf('p1', 'A'),
              restoredTerminal('p2', ws: 'A'),
            ),
          ),
        ]),
        records: [workspaceRecord('A')],
      );
      await tester.tap(key('start-shell-p2'));
      await flush(tester);
      await tester.pumpAndSettle();

      await tapClosePane(tester, 'p2');
      expect(key('close-warning-item-p2'), findsOneWidget);
      await confirm(tester);
      rig.link.emitExit('t1', status: null, reason: TerminalExitReason.closed);
      await flush(tester);
      await tester.pumpAndSettle();

      expect(rig.layout.tab('t1')!.root.id, 'p1');
      expect(rig.layout.focusedPane, 'p1');
    });

    uiTest('tab close: one dialog names the three live terminals only; '
        'confirm closes all and the tab', (tester) async {
      final rig = await pumpEmpty(tester);
      final panes = await fourPaneTab(tester, rig);
      final tabId = rig.layout.tabs.single.id;
      rig.link.emitExit('t4', status: 1); // the fourth ended
      await flush(tester);

      await tapCloseTab(tester, tabId);

      expect(key('close-warning'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith(
                'close-warning-item-',
              ),
        ),
        findsNWidgets(3),
      );
      for (final id in panes.take(3)) {
        expect(key('close-warning-item-$id'), findsOneWidget);
      }
      expect(key('close-warning-item-${panes[3]}'), findsNothing);
      await confirm(tester);

      expect(rig.link.closed, unorderedEquals(['t1', 't2', 't3']));
      for (final id in ['t1', 't2', 't3']) {
        rig.link.emitExit(id, status: null, reason: TerminalExitReason.closed);
      }
      await flush(tester);
      expect(rig.layout.tabs, isEmpty);
      expect(rig.layout.activeTab, isNull);
    });

    uiTest('tab close shows one dialog naming both live terminals; confirm '
        'closes the tab', (tester) async {
      final rig = await pumpTerminals(
        tester,
        layout: docOf([
          tabOf(
            't1',
            splitOf(
              's1',
              overviewOf('p1', 'A'),
              splitOf(
                's2',
                restoredTerminal('p2', ws: 'A'),
                restoredTerminal('p3', ws: 'A'),
                direction: SplitDirection.vertical,
              ),
            ),
          ),
        ]),
        records: [workspaceRecord('A')],
      );
      await tester.tap(key('start-shell-p2'));
      await flush(tester);
      await tester.tap(key('start-shell-p3'));
      await flush(tester);
      await tester.pumpAndSettle();

      await tapCloseTab(tester, 't1');

      expect(key('close-warning'), findsOneWidget);
      expect(key('close-warning-item-p2'), findsOneWidget);
      expect(key('close-warning-item-p3'), findsOneWidget);
      expect(key('close-warning-item-p1'), findsNothing);
      await confirm(tester);
      expect(rig.link.closed, unorderedEquals(['t1', 't2']));
      for (final id in ['t1', 't2']) {
        rig.link.emitExit(id, status: null, reason: TerminalExitReason.closed);
      }
      await flush(tester);
      expect(rig.layout.tabs, isEmpty);
    });

    uiTest('cancel leaves the tab, its panes, tree and ratios unchanged', (
      tester,
    ) async {
      final rig = await pumpTerminals(
        tester,
        layout: docOf([
          tabOf(
            't1',
            splitOf(
              's1',
              overviewOf('p1', 'A'),
              restoredTerminal('p2', ws: 'A'),
              ratio: 0.3,
            ),
          ),
        ]),
        records: [workspaceRecord('A')],
      );
      await tester.tap(key('start-shell-p2'));
      await flush(tester);
      await tester.pumpAndSettle();
      final before = jsonOf(rig.layout);

      await tapCloseTab(tester, 't1');
      await tester.tap(key('close-warning-cancel'));
      await tester.pumpAndSettle();

      expect(jsonOf(rig.layout), before);
      expect(rig.link.closed, isEmpty);
      expect(rig.linkOf('p2')!.status, TerminalStatus.live);
    });

    uiTest('a tab of an overview and an ended terminal closes without a '
        'dialog', (tester) async {
      final rig = await pumpTerminals(
        tester,
        layout: docOf([
          tabOf(
            't1',
            splitOf(
              's1',
              overviewOf('p1', 'A'),
              restoredTerminal('p2', ws: 'A'),
            ),
          ),
        ]),
        records: [workspaceRecord('A')],
      );

      await tapCloseTab(tester, 't1');

      expect(key('close-warning'), findsNothing);
      expect(rig.layout.tabs, isEmpty);
      expect(rig.link.closed, isEmpty);
    });

    uiTest('tab close of an overview and two live terminals with one '
        'closeFailed: the overview and the other terminal are removed, the '
        'failed pane keeps its id and error and fills the tab, and the tab '
        'stays', (tester) async {
      final rig = await pumpTerminals(
        tester,
        layout: docOf([
          tabOf(
            't1',
            splitOf(
              's1',
              overviewOf('p1', 'A'),
              splitOf(
                's2',
                restoredTerminal('p2', ws: 'A'),
                restoredTerminal('p3', ws: 'A'),
                direction: SplitDirection.vertical,
              ),
            ),
          ),
        ]),
        records: [workspaceRecord('A')],
      );
      await tester.tap(key('start-shell-p2'));
      await flush(tester);
      await tester.tap(key('start-shell-p3'));
      await flush(tester);
      await tester.pumpAndSettle();

      await tapCloseTab(tester, 't1');
      await confirm(tester);
      expect(
        rig.layout.pane('p1'),
        isNull,
        reason: 'the overview goes at once',
      );

      rig.link.emitExit('t1', status: null, reason: TerminalExitReason.closed);
      rig.link.emitCloseFailed('t2', 'scan-unreadable');
      await flush(tester);
      await tester.pumpAndSettle();

      expect(rig.layout.tabs.map((t) => t.id), ['t1']);
      expect(rig.layout.panes.map((p) => p.id), ['p3']);
      expect(rig.layout.tab('t1')!.root.id, 'p3', reason: 'fills the tab');
      expect(rig.linkOf('p3')!.error, contains('scan-unreadable'));
      expect(
        inside('pane-p3', find.textContaining('scan-unreadable')),
        findsOneWidget,
      );
      expect(key('close-warning'), findsNothing);
    });

    uiTest('closeFailed on a single closed pane keeps it in place with the '
        'error and its split, sibling and ratio unchanged', (tester) async {
      final rig = await pumpTerminals(
        tester,
        layout: docOf([
          tabOf(
            't1',
            splitOf(
              's1',
              overviewOf('p1', 'A'),
              restoredTerminal('p2', ws: 'A'),
              ratio: 0.3,
            ),
          ),
        ]),
        records: [workspaceRecord('A')],
      );
      await tester.tap(key('start-shell-p2'));
      await flush(tester);
      await tester.pumpAndSettle();
      final before = jsonOf(rig.layout);

      await tapClosePane(tester, 'p2');
      await confirm(tester);
      rig.link.emitCloseFailed('t1', 'scan-unreadable');
      await flush(tester);
      await tester.pumpAndSettle();

      expect(jsonOf(rig.layout), before);
      expect(
        inside('pane-p2', find.textContaining('scan-unreadable')),
        findsOneWidget,
      );
      expect(rig.linkOf('p2')!.closeRequested, isFalse);
    });

    uiTest('a shell that exits while the dialog is open: confirm removes the '
        'pane without sending close', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final pane = rig.terminalPanes.single;

      await tapClosePane(tester, pane.id);
      rig.link.emitExit('t1', status: 0);
      await flush(tester);
      expect(key('close-warning'), findsOneWidget, reason: 'still open');
      await confirm(tester);

      expect(rig.layout.tabs, isEmpty);
      expect(rig.link.closed, isEmpty);
    });

    uiTest('a shell that exits before close is acknowledged: the pane is '
        'removed on exited{exited}', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final pane = rig.terminalPanes.single;
      rig.link.terminalCloseGate = Completer<void>();

      await tapClosePane(tester, pane.id);
      await confirm(tester);
      expect(rig.link.closed, ['t1']);
      expect(rig.linkOf(pane.id)!.closeRequested, isTrue);

      rig.link.emitExit('t1', status: 0, reason: TerminalExitReason.exited);
      await flush(tester);
      expect(rig.layout.tabs, isEmpty);

      // The late answer of the close changes nothing.
      rig.link.closeError = RpcException(ErrorCode.unknownTerminal);
      rig.link.terminalCloseGate!.complete();
      await flush(tester);
      expect(rig.layout.tabs, isEmpty);
      expect(rig.controller.message, isNull);
    });

    uiTest('unknown-terminal for a close with no exit received keeps the '
        'pane with the error (D9)', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final pane = rig.terminalPanes.single;
      rig.link.closeError = RpcException(ErrorCode.unknownTerminal);

      await tapClosePane(tester, pane.id);
      await confirm(tester);
      await flush(tester);
      expect(rig.terminalPanes, hasLength(1));
      expect(rig.linkOf(pane.id)!.closeRequested, isFalse);
      expect(rig.linkOf(pane.id)!.error, isNotNull);
    });

    uiTest('a close the program ignores shows Closing… then removal, or the '
        'error on closeFailed', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final pane = rig.terminalPanes.single;

      await tapClosePane(tester, pane.id);
      await confirm(tester);
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('Closing…'), findsOneWidget);
      expect(rig.terminalPanes, hasLength(1));

      rig.link.emitCloseFailed('t1', 'scan-unreadable');
      await flush(tester);
      expect(rig.terminalPanes, hasLength(1));
      expect(find.text('Closing…'), findsNothing);
      expect(find.textContaining('scan-unreadable'), findsOneWidget);
      expect(rig.linkOf(pane.id)!.closeRequested, isFalse);

      // The other outcome: a second terminal's close ends with the exit.
      await launch(tester);
      final second = rig.terminalPanes.last;
      await tapClosePane(tester, second.id);
      await confirm(tester);
      expect(find.text('Closing…'), findsOneWidget);
      rig.link.emitExit('t2', status: null, reason: TerminalExitReason.closed);
      await flush(tester);
      expect(rig.layout.pane(second.id), isNull);
    });

    uiTest('a late open result for a closed pane is closed, not attached', (
      tester,
    ) async {
      final rig = await pumpEmpty(tester);
      rig.link.terminalOpenGate = Completer<void>();
      await launch(tester);
      final pane = rig.terminalPanes.single;
      expect(rig.linkOf(pane.id)!.status, TerminalStatus.starting);

      await tapClosePane(tester, pane.id);
      expect(key('close-warning'), findsOneWidget, reason: 'starting warns');
      await confirm(tester);
      expect(rig.layout.tabs, isEmpty, reason: 'removed at once');
      expect(rig.link.closed, isEmpty);

      rig.link.terminalOpenGate!.complete();
      await flush(tester);
      expect(rig.link.closed, ['t1']);
      expect(rig.link.lastTerminal.listening, isFalse);
      expect(rig.surfaces.last.fed, isEmpty);
    });
  });

  group('move', () {
    uiTest('moving a live terminal pane to a new tab and then into a split '
        'shows no dialog, sends no host message, and keeps its terminal id, '
        'link and surface', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final first = rig.terminalPanes.single;
      await tester.tap(key('split-right-${first.id}'));
      await flush(tester);
      await tester.pumpAndSettle();
      final moved = rig.layout.focusedPane!;
      final movedLink = rig.linkOf(moved)!;
      final surface = movedLink.surface as FakeTerminalSurface;
      final terminalId = movedLink.terminalId;
      rig.link.terminals[terminalId]!.send(bytesOf('scrollback'));
      await flush(tester);
      final calls = hostCalls(rig);
      final made = rig.surfaces.made.length;

      await tester.tap(key('move-$moved'));
      await tester.pumpAndSettle();
      final newTab = rig.layout.activeTab!;
      expect(rig.layout.tabOf(moved)!.id, newTab);
      expect(rig.layout.tabOf(moved)!.paneCount, 1);

      // Back to the first tab, then the moved tab into its split.
      await tester.tap(key('tab-${rig.layout.tabs.first.id}'));
      await tester.pumpAndSettle();
      await tester.tap(key('tab-menu-$newTab'));
      await tester.pumpAndSettle();
      await tester.tap(key('move-split-right-$newTab'));
      await tester.pumpAndSettle();

      expect(rig.layout.tabs, hasLength(1));
      expect(rig.layout.tabOf(moved)!.paneCount, 2);
      expect(key('close-warning'), findsNothing);
      expect(hostCalls(rig), calls, reason: 'no host message');
      expect(rig.linkOf(moved), same(movedLink));
      expect(movedLink.surface, same(surface));
      expect(movedLink.terminalId, terminalId);
      expect(movedLink.status, TerminalStatus.live);
      expect(rig.surfaces.made, hasLength(made));
      expect(surface.disposed, isFalse);
      expect(utf8.decode(surface.fedAll), 'scrollback');
    });

    uiTest('a clean exit right after a move removes the pane by id with no '
        'duplicate close or release and no unrelated pane removed', (
      tester,
    ) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final first = rig.terminalPanes.single;
      await tester.tap(key('split-right-${first.id}'));
      await flush(tester);
      await tester.pumpAndSettle();
      final moved = rig.layout.focusedPane!;
      await tester.tap(key('move-$moved'));
      await tester.pumpAndSettle();
      expect(rig.layout.tabs, hasLength(2));

      rig.link.emitExit('t2', status: 0);
      await flush(tester);
      await tester.pumpAndSettle();

      expect(rig.layout.pane(moved), isNull);
      expect(rig.layout.pane(first.id), isNotNull);
      expect(rig.layout.tabs.map((t) => t.id), [
        rig.layout.tabOf(first.id)!.id,
      ]);
      expect(rig.linkOf(first.id)!.status, TerminalStatus.live);
      expect(rig.link.released, ['t2']);
      expect(rig.link.closed, isEmpty);
    });

    uiTest('a clean exit right before a move removes the pane by id with no '
        'duplicate close or release and no unrelated pane removed', (
      tester,
    ) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final first = rig.terminalPanes.single;
      await tester.tap(key('split-right-${first.id}'));
      await flush(tester);
      await tester.pumpAndSettle();
      final moved = rig.layout.focusedPane!;

      // The exit is delivered in the same turn as the tap on Move.
      rig.link.emitExit('t2', status: 0);
      await tester.tap(key('move-$moved'), warnIfMissed: false);
      await flush(tester);
      await tester.pumpAndSettle();

      expect(rig.layout.pane(moved), isNull);
      expect(rig.layout.pane(first.id), isNotNull);
      expect(rig.layout.tabs, hasLength(1));
      expect(rig.linkOf(first.id)!.status, TerminalStatus.live);
      expect(rig.link.released, ['t2']);
      expect(rig.link.closed, isEmpty);
    });

    uiTest('a pane moved while its open is pending attaches when the open '
        'result arrives; a pane moved after a confirmed close is removed on '
        'exited; neither move sends a host message', (tester) async {
      final rig = await pumpEmpty(tester);
      await launch(tester);
      final first = rig.terminalPanes.single;
      rig.link.terminalOpenGate = Completer<void>();
      await tester.tap(key('split-right-${first.id}'));
      await flush(tester);
      await tester.pumpAndSettle();
      final starting = rig.layout.focusedPane!;
      expect(rig.linkOf(starting)!.status, TerminalStatus.starting);
      final calls = hostCalls(rig);

      await tester.tap(key('move-$starting'));
      await tester.pumpAndSettle();
      expect(hostCalls(rig), calls, reason: 'a move sends nothing');
      rig.link.terminalOpenGate!.complete();
      await flush(tester);
      await tester.pumpAndSettle();
      expect(rig.linkOf(starting)!.status, TerminalStatus.live);
      expect(rig.link.terminals['t2']!.listening, isTrue, reason: 'attached');
      expect(rig.link.closed, isEmpty);

      // Confirmed close in progress, then move.
      await tester.tap(key('split-right-$starting'));
      await flush(tester);
      await tester.pumpAndSettle();
      final closing = rig.layout.focusedPane!;
      await tapClosePane(tester, closing);
      await confirm(tester);
      expect(rig.linkOf(closing)!.status, TerminalStatus.closing);
      final before = hostCalls(rig);

      await tester.tap(key('move-$closing'));
      await tester.pumpAndSettle();
      expect(hostCalls(rig), before, reason: 'a move sends nothing');
      rig.link.emitExit('t3', status: null, reason: TerminalExitReason.closed);
      await flush(tester);
      await tester.pumpAndSettle();

      expect(rig.layout.pane(closing), isNull);
      expect(rig.layout.pane(starting), isNotNull);
      expect(rig.layout.tabs.every((t) => t.paneCount >= 1), isTrue);
    });
  });

  group('controller', () {
    TerminalController newController(
      FakeSurfaces surfaces,
      FakeHostLink link, {
      void Function(String)? removePane,
    }) {
      final controller = TerminalController(
        surfaceFactory: surfaces.call,
        removePane: removePane ?? (_) {},
      )..attach(link);
      addTearDown(controller.dispose);
      return controller;
    }

    FakeHostLink newLink() =>
        FakeHostLink(hello: helloResult(capabilities: terminalCapabilities));

    test(
      'stalled engine consumption: channel reads and credit stop at 1 MiB '
      'pending plus one chunk; on resume every byte arrives in order',
      () async {
        final link = newLink();
        final surfaces = FakeSurfaces();
        final controller = newController(surfaces, link);
        await controller.start('pane', profileId: 'p', profileName: 'p');
        final surface = surfaces.last;
        final terminal = link.lastTerminal;
        expect(controller.statusOf('pane'), TerminalStatus.live);

        surface.stall();
        const chunkSize = 64 * 1024;
        final sent = <int>[];
        for (var i = 0; i < 40; i++) {
          final chunk = Uint8List.fromList([
            for (var j = 0; j < chunkSize; j++) (i * 7 + j) & 0xFF,
          ]);
          sent.addAll(chunk);
          terminal.send(chunk);
        }
        await pumpEventQueue();

        expect(terminal.paused, isTrue);
        expect(terminal.delivered, greaterThanOrEqualTo(1024 * 1024));
        expect(terminal.delivered, lessThanOrEqualTo(1024 * 1024 + chunkSize));
        expect(surface.pending.value, terminal.delivered);
        final stalledAt = terminal.delivered;
        await pumpEventQueue();
        expect(terminal.delivered, stalledAt, reason: 'no further credit');
        expect(terminal.queuedBytes, sent.length - stalledAt);

        surface.resume();
        await pumpEventQueue();
        expect(terminal.queuedBytes, 0);
        expect(surface.fedAll, orderedEquals(sent), reason: 'none dropped');
      },
    );

    test(
      'input beyond 1 MiB is refused with input paused until it drains',
      () async {
        final link = newLink();
        final surfaces = FakeSurfaces();
        final controller = newController(surfaces, link);
        await controller.start('pane', profileId: 'p', profileName: 'p');
        final surface = surfaces.last;
        final terminal = link.lastTerminal..writeGate = Completer<void>();
        final paneLink = controller.linkOf('pane')!;

        final paste = Uint8List(600 * 1024);
        surface.type(paste);
        await pumpEventQueue();
        expect(paneLink.inputPaused, isFalse);
        surface.type(paste);
        expect(paneLink.inputPaused, isTrue, reason: 'over the 1 MiB queue');

        terminal.writeGate!.complete();
        await pumpEventQueue();
        expect(
          terminal.written,
          hasLength(1),
          reason: 'the refused one is gone',
        );
        expect(paneLink.inputPaused, isFalse);

        surface.type(bytesOf('ls\r'));
        await pumpEventQueue();
        expect(terminal.written.last, bytesOf('ls\r'));
      },
    );

    test('input is written in order', () async {
      final link = newLink();
      final surfaces = FakeSurfaces();
      final controller = newController(surfaces, link);
      await controller.start('pane', profileId: 'p', profileName: 'p');
      for (final s in ['a', 'b', 'c']) {
        surfaces.last.type(bytesOf(s));
      }
      await pumpEventQueue();
      expect(
        [for (final w in link.lastTerminal.written) utf8.decode(w)],
        ['a', 'b', 'c'],
      );
      expect(controller.statusOf('pane'), TerminalStatus.live);
    });
  });

  testWidgets('100 resizes in 1 s are coalesced and the last size wins', (
    tester,
  ) async {
    final link = FakeHostLink(
      hello: helloResult(capabilities: terminalCapabilities),
    );
    final surfaces = FakeSurfaces();
    final controller = TerminalController(
      surfaceFactory: surfaces.call,
      removePane: (_) {},
    )..attach(link);
    addTearDown(controller.dispose);
    unawaited(controller.start('pane', profileId: 'p', profileName: 'p'));
    await tester.pump();
    await tester.pump();
    expect(controller.statusOf('pane'), TerminalStatus.live);
    expect(link.opened.single.cols, 100, reason: 'open carries the size');

    for (var i = 1; i <= 100; i++) {
      surfaces.last.emitSize(100 + i, 30);
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pump(const Duration(milliseconds: 200));

    expect(link.resizes.length, lessThanOrEqualTo(1000 ~/ 50 + 2));
    expect(link.resizes.length, greaterThan(1));
    expect((link.resizes.last.cols, link.resizes.last.rows), (200, 30));
    expect(link.resizes.every((r) => r.id == 't1'), isTrue);
  });
}
