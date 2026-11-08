import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:desktop/src/agent/agent_controller.dart';
import 'package:desktop/src/exit_coordinator.dart';
import 'package:desktop/src/terminal/terminal_controller.dart';
import 'package:desktop/src/workbench_controller.dart';
import 'package:desktop/src/workbench_page.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:host_protocol/host_protocol.dart';

import 'support/fake_host.dart';
import 'support/fake_terminal_surface.dart';
import 'support/workbench_support.dart';

const _capabilities = {
  Capability.workbench,
  Capability.terminal,
  Capability.agent,
  Capability.lifecycle,
};

/// One exit request and the answer it got, once it has one.
class _Request {
  _Request(Future<AppExitResponse> answer) {
    unawaited(answer.then((r) => this.answer = r));
  }

  AppExitResponse? answer;
}

/// The workbench over a scripted host with an [ExitCoordinator] on top of it,
/// wired as `main.dart` wires them.
class _Env {
  _Env(this.rig, this.exit);

  final Rig rig;
  final ExitCoordinator exit;
  int shutdowns = 0;

  FakeHostLink get host => rig.link;
  WorkbenchController get controller => rig.controller;
  AgentController get agents => controller.agents;
  TerminalController get terminals => controller.terminals;
}

Future<_Env> _env(
  WidgetTester tester, {
  Set<String> capabilities = _capabilities,
}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final host = FakeHostLink(hello: helloResult(capabilities: capabilities));
  host.records.add(workspaceRecord('A'));
  host.storedLayout = jsonOf(docOf([], selected: 'A'));
  final surfaces = FakeSurfaces();
  var n = 0;
  final controller = track(
    WorkbenchController(
      picker: NoPicker(),
      newId: (prefix) => '$prefix${++n}',
      surfaceFactory: surfaces.call,
    ),
  );
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      home: WorkbenchPage(controller: controller),
    ),
  );
  unawaited(controller.attach(host));
  await flush(tester);
  late final _Env env;
  final exit = track(
    ExitCoordinator(
      workbench: controller,
      navigatorKey: navigator,
      quit: () async {
        env.shutdowns++;
        await host.quit();
      },
    ),
  );
  return env = _Env(Rig(controller, host, surfaces), exit);
}

/// Starts an agent in a new tab; it is idle and has a saved record.
Future<AgentLink> _agent(_Env env, WidgetTester tester) async {
  await env.controller.launchAgent();
  await flush(tester);
  final pane = env.rig.layout.panes.lastWhere((p) => p.kind == agentChatKind);
  return env.agents.linkOf(pane.id)!;
}

/// A turn begins in [link]'s session.
void _runTurn(_Env env, AgentLink link, [int seq = 5]) =>
    env.host.agentState(link.sessionId!, AgentState.running, seq);

/// A live terminal in a new tab; returns its pane id.
Future<String> _terminal(_Env env, WidgetTester tester) async {
  await env.controller.launchTerminal();
  await flush(tester);
  await tester.pumpAndSettle();
  final pane = env.rig.layout.panes.lastWhere((p) => p.kind == terminalKind);
  expect(env.terminals.statusOf(pane.id), TerminalStatus.live);
  return pane.id;
}

String _terminalIdOf(_Env env, String paneId) =>
    env.terminals.linkOf(paneId)!.terminalId!;

/// Asks to exit and lets the first round of work run.
Future<_Request> _quit(_Env env, WidgetTester tester) async {
  final request = _Request(env.exit.requestExit());
  await flush(tester);
  await tester.pump();
  return request;
}

Future<void> _wait(WidgetTester tester, int ms) async {
  await tester.pump(Duration(milliseconds: ms));
  await flush(tester);
}

Finder _dialog() => key('exit-dialog');
Finder _item(String paneId) => key('exit-item-$paneId');
Finder _stop(String paneId) => key('exit-stop-$paneId');

Future<void> _tap(WidgetTester tester, String k) async {
  await tester.tap(key(k));
  await flush(tester);
  await tester.pumpAndSettle();
}

void main() {
  group('app exit', () {
    uiTest(
      'quit with idle agent, idle terminal and stored draft exits without a '
      'dialog',
      (tester) async {
        final env = await _env(tester);
        final link = await _agent(env, tester);
        await _terminal(env, tester);
        link.prompt.text = 'half-written prompt';
        env.controller.setSidebarCollapsed(true);
        // Nothing has been sent yet: no quiet period has passed.
        expect(env.host.storedDrafts, isEmpty);

        final request = await _quit(env, tester);

        expect(request.answer, AppExitResponse.exit);
        expect(_dialog(), findsNothing);
        expect(find.byType(AlertDialog), findsNothing);
        expect(
          env.host.storedDrafts[link.sessionId]?.text,
          'half-written prompt',
        );
        expect(
          (env.host.saves.last.layout['sidebar']! as Map)['collapsed'],
          isTrue,
        );
        expect(env.host.quitAnnounced, isTrue);
        expect(env.host.quitCalled, isTrue);
        expect(env.shutdowns, 1);
        // The pending saves go out before the host is told it is a quit.
        final announce = env.host.calls.indexOf('app/quit');
        expect(
          env.host.calls.indexOf('agent/draftSave ${link.sessionId}'),
          lessThan(announce),
        );
        expect(
          env.host.calls.lastIndexWhere((c) => c.startsWith('workbench/save')),
          lessThan(announce),
        );
        // Nothing was ended by the desktop: the host ends the units.
        expect(env.host.closed, isEmpty);
        expect(env.host.agentCloses, isEmpty);
      },
    );

    uiTest('a host without the lifecycle capability quits without app/quit', (
      tester,
    ) async {
      final env = await _env(
        tester,
        capabilities: {Capability.workbench, Capability.terminal},
      );
      await _terminal(env, tester);

      final request = await _quit(env, tester);

      expect(request.answer, AppExitResponse.exit);
      expect(env.host.calls, isNot(contains('app/quit')));
      expect(env.host.quitAnnounced, isFalse);
      expect(env.shutdowns, 1);
    });

    uiTest('activity timeout lists the terminal as may be running programs', (
      tester,
    ) async {
      final env = await _env(tester);
      final pane = await _terminal(env, tester);
      env.host.activityGate = Completer<void>();

      final request = await _quit(env, tester);
      expect(_dialog(), findsNothing, reason: 'the query is still out');
      await _wait(tester, 4000);

      expect(request.answer, isNull);
      expect(_dialog(), findsOneWidget);
      expect(
        inside(
          'exit-item-$pane',
          find.textContaining('may be running programs'),
        ),
        findsOneWidget,
      );
      expect(env.host.closed, isEmpty);
      expect(env.shutdowns, 0);

      await _tap(tester, 'exit-cancel');
      expect(request.answer, AppExitResponse.cancel);
      env.host.activityGate!.complete();
      await flush(tester);
    });

    uiTest('dialog lists running agent and vim with per-item Stop, bulk and '
        'Cancel', (tester) async {
      final env = await _env(tester);
      final agent = await _agent(env, tester);
      final terminal = await _terminal(env, tester);
      _runTurn(env, agent);
      env.host.setBusy(_terminalIdOf(env, terminal), ['vim']);

      final request = await _quit(env, tester);

      expect(request.answer, isNull, reason: 'the window stays open');
      expect(_dialog(), findsOneWidget);
      expect(
        inside(
          'exit-item-${agent.paneId}',
          find.textContaining('running a turn'),
        ),
        findsOneWidget,
      );
      expect(
        inside('exit-item-$terminal', find.textContaining('vim')),
        findsOneWidget,
      );
      expect(_stop(agent.paneId), findsOneWidget);
      expect(_stop(terminal), findsOneWidget);
      expect(key('exit-stop-all'), findsOneWidget);
      expect(find.text('Stop processes and close'), findsOneWidget);
      expect(key('exit-cancel'), findsOneWidget);
      expect(env.shutdowns, 0);
      await _tap(tester, 'exit-cancel');
    });

    uiTest('item leaves the list when its work ends; last item quits', (
      tester,
    ) async {
      final env = await _env(tester);
      final agent = await _agent(env, tester);
      final terminal = await _terminal(env, tester);
      final id = _terminalIdOf(env, terminal);
      _runTurn(env, agent);
      env.host.setBusy(id);
      final request = await _quit(env, tester);
      expect(_item(agent.paneId), findsOneWidget);
      expect(_item(terminal), findsOneWidget);

      // The turn ends on its own.
      env.host.agentState(agent.sessionId!, AgentState.idle, 6);
      await flush(tester);
      await tester.pump();

      expect(_item(agent.paneId), findsNothing);
      expect(_item(terminal), findsOneWidget);
      expect(env.host.agentCloses, isEmpty);
      expect(env.host.agentStops, isEmpty);
      expect(request.answer, isNull);

      // The program ends: the next poll finds the terminal idle.
      env.host.activities.remove(id);
      await _wait(tester, 1100);
      await _wait(tester, 100);

      expect(request.answer, AppExitResponse.exit);
      expect(env.host.quitAnnounced, isTrue);
      expect(env.shutdowns, 1);
      expect(env.host.closed, isEmpty);
    });

    uiTest('final check keeps the dialog when a terminal became busy', (
      tester,
    ) async {
      final env = await _env(tester);
      final agent = await _agent(env, tester);
      final terminal = await _terminal(env, tester);
      _runTurn(env, agent);
      final request = await _quit(env, tester);
      expect(_item(terminal), findsNothing);

      // A background job starts; then the last listed item finishes before
      // the next poll sees the job.
      env.host.setBusy(_terminalIdOf(env, terminal), ['sleep']);
      env.host.agentState(agent.sessionId!, AgentState.idle, 6);
      await flush(tester);
      await tester.pump();

      expect(request.answer, isNull);
      expect(_item(terminal), findsOneWidget);
      expect(env.shutdowns, 0);
      await _tap(tester, 'exit-cancel');
    });

    uiTest('second quit request focuses the open dialog', (tester) async {
      final env = await _env(tester);
      final agent = await _agent(env, tester);
      final terminal = await _terminal(env, tester);
      _runTurn(env, agent);
      env.host.setBusy(_terminalIdOf(env, terminal));
      final first = await _quit(env, tester);
      expect(_dialog(), findsOneWidget);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      final second = await _quit(env, tester);

      expect(second.answer, AppExitResponse.cancel);
      expect(first.answer, isNull);
      expect(_dialog(), findsOneWidget, reason: 'no second dialog');
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(_item(agent.paneId), findsOneWidget);
      expect(_item(terminal), findsOneWidget);
      final focus = FocusManager.instance.primaryFocus;
      expect(focus, isNotNull);
      expect(
        focus!.context!.findAncestorWidgetOfExactType<AlertDialog>(),
        isNotNull,
        reason: 'the keyboard focus is inside the dialog',
      );
      await _tap(tester, 'exit-cancel');
      expect(first.answer, AppExitResponse.cancel);
    });

    uiTest('per-item Stop removes only that item; quits when list empties', (
      tester,
    ) async {
      final env = await _env(tester);
      final agent = await _agent(env, tester);
      final terminal = await _terminal(env, tester);
      final id = _terminalIdOf(env, terminal);
      final session = agent.sessionId!;
      _runTurn(env, agent);
      env.host.setBusy(id);
      final request = await _quit(env, tester);
      final layoutBefore = layoutToJson(env.rig.layout);

      await _tap(tester, 'exit-stop-${agent.paneId}');
      expect(env.host.agentCloses, [session]);
      expect(env.host.closed, isEmpty);
      expect(_stop(agent.paneId), findsNothing, reason: 'stopping');
      env.host.agentExit(session);
      await flush(tester);
      await tester.pump();

      expect(_item(agent.paneId), findsNothing);
      expect(_item(terminal), findsOneWidget);
      expect(request.answer, isNull);
      expect(env.rig.layout.pane(agent.paneId), isNotNull);

      await _tap(tester, 'exit-stop-$terminal');
      expect(env.host.closed, [id]);
      expect(request.answer, isNull, reason: 'the shell has not ended yet');
      env.host.emitExit(id, reason: TerminalExitReason.closed, status: null);
      await flush(tester);
      await tester.pump();
      await _wait(tester, 100);

      expect(request.answer, AppExitResponse.exit);
      expect(env.shutdowns, 1);
      // Stopping never removed a pane or changed the layout.
      expect(layoutToJson(env.rig.layout), layoutBefore);
      expect(env.rig.layout.pane(terminal), isNotNull);
    });

    uiTest('failed Stop keeps the item with error and cleanup unresolved; '
        'polls do not remove it', (tester) async {
      final env = await _env(tester);
      final agent = await _agent(env, tester);
      final terminal = await _terminal(env, tester);
      final id = _terminalIdOf(env, terminal);
      _runTurn(env, agent);
      env.host.setBusy(id);
      final request = await _quit(env, tester);

      await _tap(tester, 'exit-stop-$terminal');
      env.host.emitCloseFailed(id, 'scan-unreadable');
      await flush(tester);
      await tester.pump();

      expect(_item(terminal), findsOneWidget);
      expect(
        inside('exit-item-$terminal', find.textContaining('scan-unreadable')),
        findsOneWidget,
      );
      expect(
        inside(
          'exit-item-$terminal',
          find.textContaining('cleanup unresolved'),
        ),
        findsOneWidget,
      );
      expect(_stop(terminal), findsNothing);
      expect(_stop(agent.paneId), findsOneWidget, reason: 'others unchanged');
      expect(_dialog(), findsOneWidget);

      // Later polls report the terminal ended; the item stays.
      env.host.activities[id] = TerminalActivity(
        terminalId: id,
        state: TerminalActivityState.ended,
      );
      await _wait(tester, 3000);
      expect(_item(terminal), findsOneWidget);
      expect(_stop(terminal), findsNothing);
      expect(request.answer, isNull);

      await _tap(tester, 'exit-cancel');
      expect(request.answer, AppExitResponse.cancel);
    });

    uiTest('bulk action states consequences and ends all items', (
      tester,
    ) async {
      final env = await _env(tester);
      final agent = await _agent(env, tester);
      final first = await _terminal(env, tester);
      final second = await _terminal(env, tester);
      _runTurn(env, agent);
      env.host.setBusy(_terminalIdOf(env, first));
      env.host.setBusy(_terminalIdOf(env, second), ['node']);
      final request = await _quit(env, tester);

      final consequences = tester.widget<Text>(key('exit-consequences'));
      expect(
        consequences.data,
        contains('every listed process will be stopped'),
      );
      expect(consequences.data, isNot(contains('unsaved draft')));
      await _tap(tester, 'exit-stop-all');
      await _wait(tester, 100);

      expect(request.answer, AppExitResponse.exit);
      expect(env.host.quitAnnounced, isTrue);
      expect(env.host.quitCalled, isTrue);
      expect(env.shutdowns, 1);
      expect(env.host.calls.last, 'app/quit');
      // The host ends every unit; the desktop ends none one by one, deletes
      // no record and marks no pane closed.
      expect(env.host.closed, isEmpty);
      expect(env.host.agentCloses, isEmpty);
      expect(env.rig.layout.pane(agent.paneId), isNotNull);
      expect(env.rig.layout.pane(first), isNotNull);
      expect(env.rig.layout.pane(second), isNotNull);
      expect(env.host.agentRecordMap[agent.sessionId], isNotNull);
    });

    uiTest('draft-too-large composer listed as unsaved; bulk names its loss', (
      tester,
    ) async {
      final env = await _env(tester);
      final agent = await _agent(env, tester);
      env.host.draftSaveAnswers.add(
        RpcException(
          ErrorCode.draftTooLarge,
          'a draft is at most 262144 bytes',
        ),
      );
      agent.prompt.text = 'a very long draft';

      final request = await _quit(env, tester);

      expect(request.answer, isNull);
      expect(_dialog(), findsOneWidget);
      expect(
        inside(
          'exit-item-${agent.paneId}',
          find.textContaining('Draft not saved: too long'),
        ),
        findsOneWidget,
      );
      expect(_stop(agent.paneId), findsNothing);
      final consequences = tester.widget<Text>(key('exit-consequences'));
      expect(consequences.data, contains('unsaved draft'));
      expect(consequences.data, contains('will be lost'));

      await _tap(tester, 'exit-stop-all');
      await _wait(tester, 100);
      expect(request.answer, AppExitResponse.exit);
      // The composer keeps its text; nothing was deleted.
      expect(agent.prompt.text, 'a very long draft');
      expect(env.rig.layout.pane(agent.paneId), isNotNull);
    });

    uiTest('Cancel after one Stop keeps the rest running and the stop done', (
      tester,
    ) async {
      final env = await _env(tester);
      final agent = await _agent(env, tester);
      final terminal = await _terminal(env, tester);
      final id = _terminalIdOf(env, terminal);
      _runTurn(env, agent);
      env.host.setBusy(id, ['vim']);
      final request = await _quit(env, tester);

      await _tap(tester, 'exit-stop-${agent.paneId}');
      env.host.agentExit(agent.sessionId!);
      await flush(tester);
      await tester.pump();
      await _tap(tester, 'exit-cancel');

      expect(request.answer, AppExitResponse.cancel);
      expect(_dialog(), findsNothing);
      expect(agent.statusLabel, 'Saved, not running');
      expect(agent.canContinue, isTrue);
      expect(env.rig.layout.pane(agent.paneId), isNotNull);
      expect(env.terminals.statusOf(terminal), TerminalStatus.live);
      expect(env.host.closed, isEmpty);
      expect(env.shutdowns, 0);
      expect(env.host.quitAnnounced, isFalse);

      // Nothing polls any more.
      final polls = env.host.activityRequests.length;
      await _wait(tester, 3000);
      expect(env.host.activityRequests, hasLength(polls));
    });

    uiTest('Cancel at once changes nothing', (tester) async {
      final env = await _env(tester);
      final agent = await _agent(env, tester);
      final terminal = await _terminal(env, tester);
      _runTurn(env, agent);
      env.host.setBusy(_terminalIdOf(env, terminal));
      await _wait(tester, 3000); // the layout changes of the setup are stored
      final layoutBefore = layoutToJson(env.rig.layout);
      final saves = env.host.saves.length;
      final request = await _quit(env, tester);

      await _tap(tester, 'exit-cancel');

      expect(request.answer, AppExitResponse.cancel);
      expect(_dialog(), findsNothing);
      expect(layoutToJson(env.rig.layout), layoutBefore);
      expect(env.host.saves, hasLength(saves));
      expect(env.host.agentCloses, isEmpty);
      expect(env.host.agentStops, isEmpty);
      expect(env.host.closed, isEmpty);
      expect(agent.statusLabel, 'Running');
      expect(env.terminals.statusOf(terminal), TerminalStatus.live);
      expect(env.shutdowns, 0);

      // The app is usable again, and a new quit asks again.
      final again = await _quit(env, tester);
      expect(_dialog(), findsOneWidget);
      await _tap(tester, 'exit-cancel');
      expect(again.answer, AppExitResponse.cancel);
    });

    uiTest('the layout is frozen while the app quits', (tester) async {
      final env = await _env(tester);
      await _terminal(env, tester);
      final held = Completer<void>();
      final slow = track(
        ExitCoordinator(
          workbench: env.controller,
          navigatorKey: GlobalKey<NavigatorState>(),
          quit: () => held.future,
        ),
      );

      final request = _Request(slow.requestExit());
      await flush(tester);
      await tester.pump();
      expect(request.answer, isNull, reason: 'the host is still shutting down');

      final before = layoutToJson(env.rig.layout);
      final saves = env.host.saves.length;
      env.controller.setSidebarCollapsed(true);
      env.controller.selectPersonal();
      await _wait(tester, 3000);

      expect(layoutToJson(env.rig.layout), before);
      expect(env.host.saves, hasLength(saves));
      held.complete();
      await flush(tester);
      expect(request.answer, AppExitResponse.exit);
    });

    uiTest('host lost with every composer stored exits at once', (
      tester,
    ) async {
      final env = await _env(tester);
      final agent = await _agent(env, tester);
      agent.prompt.text = 'stored before the loss';
      await _wait(tester, 600);
      expect(env.host.storedDrafts[agent.sessionId]?.text, isNotNull);
      env.controller.detach();
      await flush(tester);

      final request = await _quit(env, tester);

      expect(request.answer, AppExitResponse.exit);
      expect(_dialog(), findsNothing);
      expect(env.shutdowns, 1);
      expect(env.host.quitAnnounced, isFalse);
    });

    uiTest('host lost with unsaved text lists Draft not saved: host lost', (
      tester,
    ) async {
      final env = await _env(tester);
      final agent = await _agent(env, tester);
      env.controller.detach();
      await flush(tester);
      agent.prompt.text = 'typed after the loss';

      final request = await _quit(env, tester);

      expect(request.answer, isNull);
      expect(_dialog(), findsOneWidget);
      expect(
        inside(
          'exit-item-${agent.paneId}',
          find.textContaining('Draft not saved: host lost'),
        ),
        findsOneWidget,
      );
      expect(_stop(agent.paneId), findsNothing);
      expect(
        tester.widget<Text>(key('exit-consequences')).data,
        contains('will be lost'),
      );
      await _tap(tester, 'exit-stop-all');
      await _wait(tester, 100);
      expect(request.answer, AppExitResponse.exit);
      expect(env.shutdowns, 1);
    });

    uiTest('host loss removes process items and keeps draft items', (
      tester,
    ) async {
      final env = await _env(tester);
      final agent = await _agent(env, tester);
      final terminal = await _terminal(env, tester);
      env.host.setBusy(_terminalIdOf(env, terminal));
      env.host.draftSaveAnswers.add(
        RpcException(
          ErrorCode.draftTooLarge,
          'a draft is at most 262144 bytes',
        ),
      );
      agent.prompt.text = 'a very long draft';
      final request = await _quit(env, tester);
      expect(_item(terminal), findsOneWidget);
      expect(_item(agent.paneId), findsOneWidget);

      env.controller.detach();
      await flush(tester);
      await tester.pump();

      expect(_item(terminal), findsNothing);
      expect(_item(agent.paneId), findsOneWidget);
      expect(
        inside(
          'exit-item-${agent.paneId}',
          find.textContaining('Draft not saved'),
        ),
        findsOneWidget,
      );
      await _wait(tester, 3000);
      expect(request.answer, isNull, reason: 'the user decides');
      expect(_dialog(), findsOneWidget);
      expect(env.shutdowns, 0);
      await _tap(tester, 'exit-cancel');
      expect(request.answer, AppExitResponse.cancel);
    });
  });
}
