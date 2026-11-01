import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:desktop/main.dart';
import 'package:desktop/src/agent/agent_controller.dart';
import 'package:desktop/src/folder_picker.dart';
import 'package:desktop/src/host_link.dart';
import 'package:desktop/src/launcher_link.dart';
import 'package:desktop/src/terminal/alacritty_surface.dart';
import 'package:desktop/src/workbench_controller.dart';
import 'package:desktop/src/workbench_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

class AgentHarness {
  AgentHarness(this.root);
  final Directory root;
  HostLink? link;
  Directory get profile => Directory('${root.path}/profile');
  Directory get workspace => Directory('${root.path}/workspace');
  String get host => const String.fromEnvironment('KUMIKO_HOST');
  WorkbenchController controller(WidgetTester tester) =>
      tester.widget<WorkbenchPage>(find.byType(WorkbenchPage)).controller;
  AgentController agents(WidgetTester tester) => controller(tester).agents;

  Future<void> until(WidgetTester tester, bool Function() condition, String what) async {
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (!condition() && DateTime.now().isBefore(deadline)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(condition(), isTrue, reason: 'Timed out: $what');
  }

  Future<void> launch(WidgetTester tester) async {
    expect(File(host).isAbsolute, isTrue, reason: 'KUMIKO_HOST must name the absolute bundled test host executable');
    profile.createSync(recursive: true);
    workspace.createSync(recursive: true);
    final connector = launcherConnector(HostLauncher(
      executable: host,
      profileDir: profile.absolute.path,
      capabilities: const {Capability.workbench, Capability.terminal, Capability.agent},
      environment: {
        'KUMIKO_TEST_QUALIFIED_ADAPTERS': jsonEncode([
          ['scripted-acp', 'test-only', ['load', 'resume']],
        ]),
      },
    ));
    await tester.pumpWidget(KumikoApp(
      key: UniqueKey(),
      connector: () async => link = await connector(),
      hostPath: host,
      onExit: () {},
      folderPicker: _Picker(workspace.path),
      surfaceFactory: AlacrittySurface.new,
    ));
    await until(tester, () => find.byType(WorkbenchPage).evaluate().isNotEmpty && controller(tester).layout != null, 'workbench loaded');
  }

  Future<void> configure(WidgetTester tester) async {
    final script = <String, Object?>{
      'agentCapabilities': {'loadSession': true, 'sessionCapabilities': {'resume': <String, Object?>{}}},
      'prompt': [
        {'update': {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': 'streamed fixture reply'}}},
        {'update': {'sessionUpdate': 'tool_call', 'toolCallId': 'tool-1', 'title': 'Edit fixture.txt', 'kind': 'edit', 'status': 'pending'}},
        {'permission': {'toolCall': {'toolCallId': 'tool-1', 'title': 'Edit fixture.txt'}, 'options': [
          {'optionId': 'allow-once', 'name': 'Allow', 'kind': 'allow_once'},
          {'optionId': 'reject', 'name': 'Reject', 'kind': 'reject_once'},
        ]}},
        {'update': {'sessionUpdate': 'tool_call_update', 'toolCallId': 'tool-1', 'status': 'completed', 'content': [
          {'type': 'diff', 'path': 'fixture.txt', 'oldText': 'old', 'newText': 'new'},
        ]}},
        {'waitCancel': true},
      ],
      'load': [
        {'update': {'sessionUpdate': 'user_message_chunk', 'content': {'type': 'text', 'text': 'saved question'}}},
        {'update': {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': 'loaded history'}}},
      ],
      'cancel': 'honour',
    };
    await tester.runAsync(() async {
      await controller(tester).saveRuntimeProfile(RuntimeProfile(
        id: 'fixture-profile', name: 'Scripted ACP', runtimeKind: 'claude-code',
        executable: host, args: const ['--test-fixture', 'acp-agent'],
        env: {'KUMIKO_TEST_ACP_SCRIPT': jsonEncode(script)},
      ));
      await controller(tester).setDefaultRuntimeProfile('fixture-profile');
      await controller(tester).openFolder();
    });
    await tester.pump();
  }

  Future<String> newChat(WidgetTester tester) async {
    final c = controller(tester);
    final before = c.layout!.panes.map((pane) => pane.id).toSet();
    await tester.tap(find.byKey(const Key('add-tab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('launch-agent-chat')));
    await until(tester, () => c.layout!.focusedPane != null &&
        !before.contains(c.layout!.focusedPane) &&
        agents(tester).linkOf(c.layout!.focusedPane!)?.statusLabel == 'Idle', 'new agent idle');
    return c.layout!.focusedPane!;
  }

  List<String> agentUnits() {
    final db = sql.sqlite3.open('${profile.path}/kumiko.db', mode: sql.OpenMode.readOnly);
    try {
      return [for (final row in db.select("SELECT containment_id FROM unit WHERE kind = 'agent'")) row['containment_id']! as String];
    } finally {
      db.close();
    }
  }

  Future<void> quit(WidgetTester tester) async {
    // Settle text-input focus teardown before Flutter snapshots lifecycle
    // observers for asynchronous exit dispatch.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(await tester.runAsync(tester.binding.handleRequestAppExit), AppExitResponse.exit);
    await tester.pumpWidget(const SizedBox());
    link = null;
  }

  Future<void> dispose() async {
    await link?.quit();
    root.deleteSync(recursive: true);
  }
}

class _Picker implements FolderPicker {
  const _Picker(this.path);
  final String path;
  @override
  Future<String?> pickFolder() async => path;
}
