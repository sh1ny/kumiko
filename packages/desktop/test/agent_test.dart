import 'dart:async';
import 'dart:convert';

import 'package:desktop/src/agent/agent_controller.dart';
import 'package:desktop/src/workbench_controller.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:host_protocol/host_protocol.dart';

import 'support/fake_host.dart';
import 'support/fake_terminal_surface.dart';
import 'support/workbench_support.dart';

const agentCapabilities = {
  Capability.workbench,
  Capability.terminal,
  Capability.agent,
};
FakeHostLink agentHost({LayoutDocument? layout}) => linkWith(
  layout ?? docOf([], selected: 'A'),
  records: [workspaceRecord('A'), workspaceRecord('B')],
  hello: helloResult(capabilities: agentCapabilities),
);
PaneNode chat(Rig rig) =>
    rig.layout.panes.firstWhere((p) => p.kind == 'agent-chat');
AgentController agents(Rig rig) => rig.controller.agents;
Future<void> start(Rig rig, WidgetTester tester) async {
  await rig.controller.launchAgent();
  await flush(tester);
}

String session(Rig rig) => agents(rig).linkOf(chat(rig).id)!.sessionId!;
String transcript(Rig rig) =>
    agents(rig).linkOf(chat(rig).id)!.transcript.plainText;

/// Application-layer permutations: no workbench widget tree is mounted.
Future<Rig> controllerRig(WidgetTester tester, FakeHostLink host) async {
  final surfaces = FakeSurfaces();
  var id = 0;
  final controller = track(
    WorkbenchController(
      picker: NoPicker(),
      newId: (prefix) => '$prefix${++id}',
      surfaceFactory: surfaces.call,
    ),
  );
  await controller.attach(host);
  return Rig(controller, host, surfaces);
}

class _RejectingPromptHost extends FakeHostLink {
  _RejectingPromptHost()
    : super(hello: helloResult(capabilities: agentCapabilities));

  @override
  Future<void> promptAgent(AgentPromptParams params) async {
    await super.promptAgent(params);
    throw RpcException(ErrorCode.turnRunning, 'a turn is already running');
  }
}

void main() {
  group('agent controller', () {
    uiTest(
      'launcher Claude Code opens a new tab with a chat pane bound to the selected workspace',
      (tester) async {
        final host = agentHost()..agentStartGate = Completer<void>();
        final rig = await controllerRig(tester, host);
        await start(rig, tester);
        final first = chat(rig);
        expect(first.workspace, 'A');
        expect(rig.layout.focusedPane, first.id);
        expect(agents(rig).linkOf(first.id)!.statusLabel, 'Starting');
        await start(rig, tester);
        final panes = rig.layout.panes
            .where((p) => p.kind == 'agent-chat')
            .toList();
        expect(panes, hasLength(2));
        expect(panes[0].item, isNot(panes[1].item));
        expect(host.agentStarts.every((p) => p.workspaceId == 'A'), isTrue);
        host.agentStartGate!.complete();
        await flush(tester);
      },
    );

    uiTest(
      'orphan pending start closes and releases without resurrecting its pane',
      (tester) async {
        final host = agentHost()..agentStartGate = Completer<void>();
        final rig = await controllerRig(tester, host);
        await start(rig, tester);
        final id = chat(rig).id;
        await rig.controller.requestClose([
          id,
        ], (_) async => fail('pending start must not warn'));
        expect(rig.layout.panes, isEmpty);
        host.agentStartGate!.complete();
        await flush(tester);
        expect(host.agentCloses, ['agent-1']);
        host.agentExit('agent-1');
        await flush(tester);
        expect(host.agentReleases, ['agent-1']);
        expect(rig.layout.panes, isEmpty);
      },
    );

    uiTest('state seq ordering ignores stale state notifications', (
      tester,
    ) async {
      final host = agentHost();
      final rig = await controllerRig(tester, host);
      await start(rig, tester);
      host.agentState(session(rig), AgentState.waitingApproval, 5);
      host.agentState(session(rig), AgentState.idle, 4);
      expect(
        agents(rig).linkOf(chat(rig).id)!.statusLabel,
        'Waiting for approval',
      );
    });

    uiTest(
      '40 scripted chunks arrive as ordered agentText events; final text equals concatenation',
      (tester) async {
        final host = agentHost();
        final rig = await controllerRig(tester, host);
        await start(rig, tester);
        final chunks = [for (var i = 0; i < 40; i++) 'chunk-$i '];
        for (final chunk in chunks) {
          host.agentEvent(
            session(rig),
            AgentEvent.text(AgentEventKind.agentText, chunk),
          );
        }
        expect(transcript(rig), chunks.join());
      },
    );

    uiTest(
      'tool updates preserve title status history and sparse content in one card',
      (tester) async {
        final host = agentHost();
        final rig = await controllerRig(tester, host);
        await start(rig, tester);
        final id = session(rig);
        host.agentEvent(
          id,
          AgentEvent.tool(
            toolCallId: 'edit',
            title: 'Edit lib/a.dart',
            status: 'pending',
            toolKind: 'edit',
          ),
        );
        host.agentEvent(
          id,
          AgentEvent.tool(
            toolCallId: 'edit',
            update: true,
            status: 'in_progress',
          ),
        );
        host.agentEvent(
          id,
          AgentEvent.tool(
            toolCallId: 'edit',
            update: true,
            status: 'completed',
            content: [
              {
                'type': 'diff',
                'path': 'lib/a.dart',
                'oldText': 'old',
                'newText': 'new',
              },
            ],
          ),
        );
        final model = agents(rig).linkOf(chat(rig).id)!.transcript;
        expect(model.entries, hasLength(1));
        expect(model.entries.single.fields['title'], 'Edit lib/a.dart');
        expect(model.entries.single.statuses, [
          'pending',
          'in_progress',
          'completed',
        ]);
        expect(transcript(rig), contains('new'));
        host.agentEvent(
          id,
          AgentEvent.tool(
            toolCallId: 'edit',
            update: true,
            status: 'completed',
          ),
        );
        expect(transcript(rig), contains('new'));
      },
    );

    uiTest(
      'moving a running chat pane keeps link transcript session and pending permissions and sends nothing',
      (tester) async {
        final host = agentHost();
        final rig = await controllerRig(tester, host);
        await start(rig, tester);
        final pane = chat(rig);
        final link = agents(rig).linkOf(pane.id)!;
        final id = session(rig);
        host.agentEvent(id, AgentEvent.text(AgentEventKind.agentText, 'kept'));
        host.agentState(id, AgentState.waitingApproval);
        host.agentRequestSource.add(
          AgentPermissionRequestedParams(
            sessionId: id,
            requestId: 'request',
            title: 'npm test',
            options: const [
              AgentPermissionOption(
                optionId: 'allow',
                name: 'Allow',
                kind: 'allow_once',
              ),
              AgentPermissionOption(
                optionId: 'reject',
                name: 'Reject',
                kind: 'reject_once',
              ),
            ],
          ),
        );
        await rig.controller.splitWithTerminal(
          pane.id,
          SplitDirection.horizontal,
        );
        await flush(tester);
        final calls = List<String>.of(host.calls);
        final transcriptBefore = link.transcript.plainText;
        final entriesBefore = link.transcript.entries.toList();
        final permissionBefore = link.permissions.single;
        rig.controller.movePaneToNewTab(pane.id);
        rig.controller.moveTabIntoSplit(
          rig.layout.tabs.first.id,
          SplitDirection.vertical,
        );
        rig.controller.selectWorkspace('B');
        expect(identical(agents(rig).linkOf(pane.id)!, link), isTrue);
        expect(link.sessionId, id);
        expect(link.transcript.plainText, transcriptBefore);
        expect(link.transcript.entries, orderedEquals(entriesBefore));
        expect(link.transcript.entries.first.text, 'kept');
        expect(identical(link.permissions.single, permissionBefore), isTrue);
        expect(link.permissions.single.pending, isTrue);
        expect(link.permissions.single.request.options.map((p) => p.optionId), [
          'allow',
          'reject',
        ]);
        expect(link.workspaceId, 'A');
        expect(host.calls, calls);
      },
    );

    uiTest(
      'selecting workspace B then sending a prompt sends the same session id',
      (tester) async {
        final host = agentHost();
        final rig = await controllerRig(tester, host);
        await start(rig, tester);
        final id = session(rig);
        host.agentState(id, AgentState.idle);
        rig.controller.selectWorkspace('B');
        await agents(rig).send(chat(rig).id, 'explain');
        expect(host.agentPrompts.single.sessionId, id);
        expect(host.agentStarts.single.workspaceId, 'A');
        expect(chat(rig).state.keys.toSet(), {'sessionId', 'runtimeName'});
        expect(
          jsonEncode(layoutToJson(rig.layout)),
          isNot(contains('explain')),
        );
      },
    );

    uiTest('host canonical prompt appears once in channel order after Send', (
      tester,
    ) async {
      final host = agentHost();
      final rig = await controllerRig(tester, host);
      await start(rig, tester);
      final pane = chat(rig).id;
      final id = session(rig);
      final link = agents(rig).linkOf(pane)!;
      link.prompt.text = 'sent prompt';
      await agents(rig).send(pane, link.prompt.text);
      expect(host.agentPrompts.single.text, 'sent prompt');
      expect(link.prompt.text, isEmpty);

      // Control acceptance can precede trailing data from the previous turn.
      host.agentEvent(
        id,
        AgentEvent.text(AgentEventKind.agentText, 'previous trailing reply'),
      );
      expect(transcript(rig), 'previous trailing reply');
      host.agentEvent(id, AgentEvent.text(AgentEventKind.user, 'sent prompt'));
      host.agentEvent(
        id,
        AgentEvent.text(AgentEventKind.agentText, 'next reply'),
      );
      expect(link.transcript.entries.map((entry) => entry.kind), [
        AgentEventKind.agentText,
        AgentEventKind.user,
        AgentEventKind.agentText,
      ]);
      expect(link.transcript.entries.map((entry) => entry.text), [
        'previous trailing reply',
        'sent prompt',
        'next reply',
      ]);
    });

    uiTest(
      'host canonical identical prompts remain distinct across accepted turns',
      (tester) async {
        final host = agentHost();
        final rig = await controllerRig(tester, host);
        await start(rig, tester);
        final pane = chat(rig).id;
        final id = session(rig);
        final link = agents(rig).linkOf(pane)!;
        for (var turn = 1; turn <= 2; turn++) {
          await agents(rig).send(pane, 'same prompt');
          host.agentState(id, AgentState.running, turn * 2 - 1);
          host.agentEvent(
            id,
            AgentEvent.text(AgentEventKind.user, 'same prompt'),
          );
          host.agentEvent(
            id,
            AgentEvent.text(AgentEventKind.agentText, 'reply $turn'),
          );
          host.agentTurnSource.add(
            AgentTurnEndedParams(sessionId: id, stopReason: 'end_turn'),
          );
          host.agentState(id, AgentState.idle, turn * 2);
        }
        expect(host.agentPrompts.map((prompt) => prompt.text), [
          'same prompt',
          'same prompt',
        ]);
        expect(
          link.transcript.entries
              .where((entry) => entry.kind == AgentEventKind.user)
              .map((entry) => entry.text),
          ['same prompt', 'same prompt'],
        );
        expect(link.transcript.entries.map((entry) => entry.text), [
          'same prompt',
          'reply 1',
          'same prompt',
          'reply 2',
        ]);
      },
    );

    uiTest('host canonical prompt survives adapter failure after acceptance', (
      tester,
    ) async {
      final host = agentHost();
      final rig = await controllerRig(tester, host);
      await start(rig, tester);
      final pane = chat(rig).id;
      final id = session(rig);
      final link = agents(rig).linkOf(pane)!;
      link.prompt.text = 'accepted prompt';
      await agents(rig).send(pane, link.prompt.text);
      host.agentEvent(
        id,
        AgentEvent.text(AgentEventKind.user, 'accepted prompt'),
      );
      host.agentTurnSource.add(
        AgentTurnEndedParams(
          sessionId: id,
          error: 'adapter-error',
          message: 'native prompt failed',
        ),
      );
      host.agentState(id, AgentState.idle, 2);
      expect(
        link.transcript.entries
            .where((entry) => entry.kind == AgentEventKind.user)
            .map((entry) => entry.text),
        ['accepted prompt'],
      );
      expect(transcript(rig), contains('native prompt failed'));
      expect(link.prompt.text, isEmpty);
      expect(link.canSend, isTrue);
    });

    uiTest(
      'host canonical RPC rejection keeps draft without accepted prompt history',
      (tester) async {
        final host = _RejectingPromptHost()
          ..storedLayout = jsonOf(docOf([], selected: 'A'))
          ..records.addAll([workspaceRecord('A'), workspaceRecord('B')]);
        final rig = await controllerRig(tester, host);
        await start(rig, tester);
        final pane = chat(rig).id;
        final link = agents(rig).linkOf(pane)!;
        link.prompt.text = 'rejected draft';
        await agents(rig).send(pane, link.prompt.text);
        expect(host.agentPrompts.single.text, 'rejected draft');
        expect(link.prompt.text, 'rejected draft');
        expect(
          link.transcript.entries.where(
            (entry) => entry.kind == AgentEventKind.user,
          ),
          isEmpty,
        );
        expect(link.errorCode, ErrorCode.turnRunning);
        expect(link.error, contains('a turn is already running'));
        expect(link.canSend, isTrue);
      },
    );

    for (final outcome in AgentStopOutcome.values) {
      uiTest(
        'Stop outcome ${outcome.name} is visible and late result replaces deadline line',
        (tester) async {
          final host = agentHost();
          final rig = await controllerRig(tester, host);
          await start(rig, tester);
          final id = session(rig);
          host.agentStopSource.add(
            AgentStopResultParams(
              sessionId: id,
              outcome: outcome,
              message: 'adapter detail',
            ),
          );
          expect(
            agents(rig).linkOf(chat(rig).id)!.stopResult!.outcome,
            outcome,
          );
          host.agentStopSource.add(
            AgentStopResultParams(
              sessionId: id,
              outcome: AgentStopOutcome.notConfirmed,
            ),
          );
          host.agentStopSource.add(
            AgentStopResultParams(
              sessionId: id,
              outcome: AgentStopOutcome.stopped,
              late: true,
            ),
          );
          expect(
            agents(rig).linkOf(chat(rig).id)!.stopLabel,
            'Stopped (after the deadline)',
          );
        },
      );
    }

    uiTest(
      'idle close sends close without dialog and pane closes only on exited closed',
      (tester) async {
        final host = agentHost();
        final rig = await controllerRig(tester, host);
        await start(rig, tester);
        final pane = chat(rig);
        final id = session(rig);
        host.agentState(id, AgentState.idle);
        await rig.controller.requestClose([
          pane.id,
        ], (_) async => fail('idle must not warn'));
        expect(host.agentCloses, [id]);
        expect(rig.layout.pane(pane.id), isNotNull);
        host.agentCloseFailureSource.add(
          AgentCloseFailedParams(sessionId: id, reason: 'cleanup-unresolved'),
        );
        expect(rig.layout.pane(pane.id), isNotNull);
        expect(
          agents(rig).linkOf(pane.id)!.error,
          contains('cleanup-unresolved'),
        );
        await rig.controller.requestClose([pane.id], (_) async => true);
        host.agentExit(id);
        expect(rig.layout.pane(pane.id), isNull);
        expect(host.agentReleases, [id]);
      },
    );

    for (final state in [
      AgentState.running,
      AgentState.waitingApproval,
      AgentState.stopping,
    ]) {
      uiTest(
        'cancel close of ${state.name} keeps split and sends nothing; idle confirmation rechecks evidence',
        (tester) async {
          final host = agentHost();
          final rig = await controllerRig(tester, host);
          await start(rig, tester);
          final pane = chat(rig);
          final id = session(rig);
          host.agentState(id, state);
          final before = jsonOf(rig.layout);
          await rig.controller.requestClose([pane.id], (warnings) async {
            expect(
              warnings.single.reason,
              'Are you sure you want to stop the running agent?',
            );
            return false;
          });
          expect(jsonOf(rig.layout), before);
          expect(host.agentCloses, isEmpty);
          expect(host.agentStops, isEmpty);
          await rig.controller.requestClose([pane.id], (_) async {
            host.agentState(id, AgentState.idle, 2);
            return true;
          });
          expect(host.agentCloses, [id]);
          expect(host.agentStops, isEmpty);
        },
      );
    }

    uiTest(
      'mixed running agent and live terminal uses one generic close confirmation',
      (tester) async {
        final host = agentHost();
        final rig = await controllerRig(tester, host);
        await start(rig, tester);
        final pane = chat(rig);
        host.agentState(session(rig), AgentState.running);
        await rig.controller.splitWithTerminal(
          pane.id,
          SplitDirection.horizontal,
        );
        await flush(tester);
        var dialogs = 0;
        await rig.controller.requestClose(
          rig.controller.panesOfTab(rig.layout.activeTab!),
          (warnings) async {
            dialogs++;
            expect(warnings, hasLength(2));
            expect(
              warnings.map((w) => w.reason),
              contains('Are you sure you want to stop the running agent?'),
            );
            return true;
          },
        );
        expect(dialogs, 1);
        expect(host.agentCloses, hasLength(1));
        expect(host.closed, hasLength(1));
        host.agentExit(session(rig));
        host.emitExit(host.lastTerminal.id);
        await flush(tester);
        expect(rig.layout.tabs, isEmpty);
      },
    );

    uiTest(
      'host loss disables actions; restart restores Saved without automatic Continue or stale mutation',
      (tester) async {
        final host = agentHost();
        final rig = await controllerRig(tester, host);
        await start(rig, tester);
        final pane = chat(rig);
        final id = session(rig);
        host.agentState(id, AgentState.running, 10);
        rig.controller.detach();
        expect(agents(rig).linkOf(pane.id)!.statusLabel, 'Stopped or unknown');
        expect(agents(rig).linkOf(pane.id)!.canSend, isFalse);
        expect(agents(rig).linkOf(pane.id)!.canStop, isFalse);
        final next = agentHost()
          ..agentRecordMap[id] = const AgentRecord(
            known: true,
            workspaceAvailable: true,
          );
        await rig.controller.attach(next);
        expect(agents(rig).linkOf(pane.id)!.statusLabel, 'Saved, not running');
        expect(agents(rig).linkOf(pane.id)!.canContinue, isTrue);
        expect(
          next.calls.where((c) => c.startsWith('agent/continue')),
          isEmpty,
        );
        host.agentState(id, AgentState.running, 100);
        expect(agents(rig).linkOf(pane.id)!.statusLabel, 'Saved, not running');
      },
    );

    uiTest('restored missing records show Ended New session and no Continue', (
      tester,
    ) async {
      final layout = docOf([
        tabOf(
          't1',
          paneOf(
            'p1',
            kind: 'agent-chat',
            ws: 'A',
            item: 'one',
            state: {'runtimeName': 'Claude Code'},
          ),
        ),
        tabOf(
          't2',
          paneOf(
            'p2',
            kind: 'agent-chat',
            ws: 'A',
            item: 'two',
            state: {'runtimeName': 'Claude Code', 'sessionId': 'unknown'},
          ),
        ),
      ]);
      final rig = await pumpRig(tester, agentHost(layout: layout));
      for (final id in ['p1', 'p2']) {
        expect(agents(rig).linkOf(id)!.statusLabel, 'Ended');
        expect(agents(rig).linkOf(id)!.canContinue, isFalse);
      }
      expect(find.text('New session'), findsOneWidget);
      expect(find.text('Continue'), findsNothing);
    });

    uiTest(
      'Continue load shows ordered history and resume notice without sending a prompt',
      (tester) async {
        final host = agentHost();
        final rig = await controllerRig(tester, host);
        await start(rig, tester);
        final id = session(rig);
        host.agentExit(id, reason: AgentExitReason.ended);
        await agents(rig).continueSession(chat(rig).id);
        host.agentEvent(id, AgentEvent.replay(AgentReplayPhase.start));
        host.agentEvent(
          id,
          AgentEvent.text(AgentEventKind.user, 'old question'),
        );
        host.agentEvent(
          id,
          AgentEvent.text(AgentEventKind.agentText, 'old answer'),
        );
        host.agentEvent(id, AgentEvent.replay(AgentReplayPhase.end));
        host.agentState(id, AgentState.idle);
        expect(transcript(rig), contains('old question'));
        expect(transcript(rig), contains('old answer'));
        expect(transcript(rig), contains('Replay'));
        expect(host.agentPrompts, isEmpty);
        host.agentExit(id, reason: AgentExitReason.ended);
        host.agentContinueAnswers.add(
          const AgentContinueResult(
            eventChannel: 121,
            adapter: AgentAdapter(name: 'scripted-acp', version: 'test-only'),
            capabilities: ['resume'],
            mode: AgentContinueMode.resume,
          ),
        );
        await agents(rig).continueSession(chat(rig).id);
        host.agentEvent(id, AgentEvent.notice('earlier messages not shown'));
        expect(transcript(rig), contains('earlier messages not shown'));
      },
    );

    uiTest(
      'resume unavailable shows reason; New session uses original workspace and never old id',
      (tester) async {
        final host = agentHost();
        final rig = await controllerRig(tester, host);
        await start(rig, tester);
        final old = session(rig);
        host.agentExit(old, reason: AgentExitReason.ended);
        host.agentContinueAnswers.add(
          resumeUnavailable('not-qualified', detail: 'test-only'),
        );
        await agents(rig).continueSession(chat(rig).id);
        expect(
          agents(rig).linkOf(chat(rig).id)!.error,
          contains('not-qualified'),
        );
        rig.controller.selectWorkspace('B');
        await agents(rig).newSession(chat(rig).id);
        expect(host.agentStarts.last.workspaceId, 'A');
        expect(session(rig), isNot(old));
      },
    );

    uiTest(
      'event stream errors show Failed and close only affected agent while record remains continuable',
      (tester) async {
        final host = agentHost();
        final rig = await controllerRig(tester, host);
        await start(rig, tester);
        final id = session(rig);
        final pane = chat(rig).id;
        host.agentChannels[id]!.addError(const FormatException('bad NDJSON'));
        await flush(tester);
        expect(agents(rig).linkOf(pane)!.statusLabel, 'Failed');
        expect(agents(rig).linkOf(pane)!.error, contains('event stream error'));
        expect(host.agentCloses, [id]);
        expect(agents(rig).linkOf(pane)!.canContinue, isFalse);
        host.agentExit(id);
        expect(rig.layout.pane(pane), isNotNull);
        expect(agents(rig).linkOf(pane)!.canContinue, isTrue);
      },
    );

    uiTest(
      'eviction never hides an unanswered permission or loses its exact options',
      (tester) async {
        final host = agentHost();
        final rig = await controllerRig(tester, host);
        await start(rig, tester);
        final id = session(rig);
        final pane = chat(rig).id;
        host.agentRequestSource.add(
          AgentPermissionRequestedParams(
            sessionId: id,
            requestId: 'kept',
            title: 'Approval',
            options: const [
              AgentPermissionOption(
                optionId: 'exact-id',
                name: 'Allow',
                kind: 'allow_once',
              ),
            ],
          ),
        );
        for (var i = 0; i < 2001; i++) {
          host.agentEvent(id, AgentEvent.notice('entry $i'));
        }
        final link = agents(rig).linkOf(pane)!;
        expect(link.transcript.entries, hasLength(2000));
        expect(link.hiddenPendingPermissions.single.request.requestId, 'kept');
        expect(
          link.permissions.single.request.options.single.optionId,
          'exact-id',
        );
        await agents(rig).replyPermission(pane, 'kept', 'exact-id');
        expect(host.agentReplies.single.optionId, 'exact-id');
      },
    );

    uiTest(
      'control idle arriving before trailing channel data never reorders transcript or derives status',
      (tester) async {
        final host = agentHost();
        final rig = await controllerRig(tester, host);
        await start(rig, tester);
        final id = session(rig);
        host.agentState(id, AgentState.running);
        host.agentEvent(
          id,
          AgentEvent.text(AgentEventKind.agentText, 'first '),
        );
        host.agentTurnSource.add(
          AgentTurnEndedParams(sessionId: id, stopReason: 'end_turn'),
        );
        host.agentState(id, AgentState.idle, 2);
        host.agentEvent(
          id,
          AgentEvent.text(AgentEventKind.agentText, 'trailing'),
        );
        expect(transcript(rig), 'first trailing');
        expect(agents(rig).linkOf(chat(rig).id)!.statusLabel, 'Idle');
      },
    );

    uiTest(
      'Continue for a record already live focuses existing pane and creates no duplicate link',
      (tester) async {
        final layout = docOf([
          tabOf(
            'one',
            paneOf(
              'p1',
              kind: 'agent-chat',
              ws: 'A',
              item: 'one',
              state: {'sessionId': 'saved', 'runtimeName': 'Claude Code'},
            ),
          ),
          tabOf(
            'two',
            paneOf(
              'p2',
              kind: 'agent-chat',
              ws: 'A',
              item: 'two',
              state: {'sessionId': 'saved', 'runtimeName': 'Claude Code'},
            ),
          ),
        ], selected: 'A');
        final host = agentHost(layout: layout);
        host.agentRecordMap['saved'] = const AgentRecord(
          known: true,
          workspaceAvailable: true,
        );
        final rig = await controllerRig(tester, host);
        await agents(rig).continueSession('p1');
        host.agentState('saved', AgentState.idle);
        rig.controller.activateTab('two');
        await agents(rig).continueSession('p2');
        expect(rig.layout.focusedPane, 'p1');
        expect(rig.layout.activeTab, 'one');
        expect(
          host.calls.where((c) => c == 'agent/continue saved'),
          hasLength(1),
        );
        expect(agents(rig).linkOf('p2')!.statusLabel, 'Saved, not running');
      },
    );

    test('past 2,000 entries or 8 MiB oldest entries are hidden and new events still render without retained tools', () {
      final model = AgentTranscript();
      for (var i = 0; i < 2100; i++) {
        model.add(AgentEvent.tool(toolCallId: 'tool-$i', title: '$i'));
      }
      expect(model.entries.length, lessThanOrEqualTo(2000));
      expect(model.hiddenEntries, greaterThanOrEqualTo(100));
      expect(model.retainedTools, lessThanOrEqualTo(2000));
      for (var i = 0; i < 150; i++) {
        model.add(AgentEvent.text(AgentEventKind.agentText, 'x' * 65500));
      }
      expect(model.bytes, lessThanOrEqualTo(8 * 1024 * 1024));
      model.add(AgentEvent.notice('newest still arrives'));
      expect(model.plainText, endsWith('newest still arrives'));
      expect(model.retainedTools, 0);
    });

    uiTest('evicted transcript shows a visible hidden-entry marker', (
      tester,
    ) async {
      final host = agentHost();
      final rig = await pumpRig(tester, host);
      await start(rig, tester);
      final id = session(rig);
      for (var i = 0; i < 2001; i++) {
        host.agentEvent(id, AgentEvent.notice('entry $i'));
      }
      await tester.pump();
      expect(find.textContaining('Earlier messages hidden'), findsOneWidget);
    });
  });

  group('focused agent UI', () {
    uiTest(
      'Send disabled while running keeps unsent text; refusal and errors retain sent prompt',
      (tester) async {
        final host = agentHost();
        final rig = await pumpRig(tester, host);
        await start(rig, tester);
        final id = session(rig);
        final pane = chat(rig).id;
        host.agentState(id, AgentState.idle);
        await tester.pump();
        await tester.enterText(key('agent-prompt-$pane'), 'sent prompt');
        await tester.tap(key('agent-send-$pane'));
        await flush(tester);
        expect(host.agentPrompts.single.text, 'sent prompt');
        host.agentEvent(
          id,
          AgentEvent.text(AgentEventKind.user, 'sent prompt'),
        );
        host.agentState(id, AgentState.running, 2);
        await tester.pump();
        await tester.enterText(key('agent-prompt-$pane'), 'unsent draft');
        expect(
          tester.widget<FilledButton>(key('agent-send-$pane')).onPressed,
          isNull,
        );
        host.agentTurnSource.add(
          AgentTurnEndedParams(sessionId: id, stopReason: 'refusal'),
        );
        host.agentState(id, AgentState.idle, 3);
        await tester.pump();
        expect(find.textContaining('refusal'), findsWidgets);
        expect(find.text('sent prompt'), findsOneWidget);
        expect(
          tester.widget<TextField>(key('agent-prompt-$pane')).controller!.text,
          'unsent draft',
        );
        host.agentTurnSource.add(
          AgentTurnEndedParams(
            sessionId: id,
            error: 'adapter-error',
            message: 'exact adapter error',
          ),
        );
        await tester.pump();
        expect(find.textContaining('exact adapter error'), findsWidgets);
      },
    );

    uiTest(
      'thinking fenced code diff terminal plan and truncated marks render as selectable text',
      (tester) async {
        final host = agentHost();
        final rig = await pumpRig(tester, host);
        await start(rig, tester);
        final id = session(rig);
        host.agentEvent(
          id,
          AgentEvent.text(AgentEventKind.thought, 'thinking text'),
        );
        host.agentEvent(
          id,
          AgentEvent.text(
            AgentEventKind.agentText,
            '```dart\nfinal answer = 42;\n```',
          ),
        );
        host.agentEvent(
          id,
          AgentEvent.fromJson({
            'kind': 'tool',
            'toolCallId': 'tool',
            'title': 'Edit a.dart',
            'status': 'completed',
            'truncated': true,
            'content': [
              {
                'type': 'diff',
                'path': 'a.dart',
                'oldText': 'before',
                'newText': 'after',
              },
              {'type': 'terminal', 'terminalId': 'terminal-1'},
            ],
          }),
        );
        host.agentEvent(
          id,
          AgentEvent.plan([
            {
              'content': 'Review changes',
              'status': 'pending',
              'priority': 'high',
            },
          ]),
        );
        await tester.pump();
        expect(find.textContaining('Thinking'), findsWidgets);
        expect(find.textContaining('final answer = 42;'), findsOneWidget);
        expect(find.textContaining('after'), findsWidgets);
        expect(find.textContaining('terminal-1'), findsWidgets);
        expect(find.textContaining('truncated'), findsWidgets);
        expect(find.textContaining('Review changes'), findsWidgets);
        expect(find.byType(SelectableText), findsWidgets);
        host.agentEvent(id, AgentEvent.notice('later still renders'));
        await tester.pump();
        expect(find.textContaining('later still renders'), findsWidgets);
      },
    );

    uiTest(
      'Stop button sends once, cancellation is visible, and late result replaces the deadline',
      (tester) async {
        final host = agentHost();
        final rig = await pumpRig(tester, host);
        await start(rig, tester);
        final pane = chat(rig).id;
        final id = session(rig);
        host.agentState(id, AgentState.waitingApproval, 1);
        host.agentRequestSource.add(
          AgentPermissionRequestedParams(
            sessionId: id,
            requestId: 'r',
            title: 'Tool approval',
            options: const [
              AgentPermissionOption(
                optionId: 'yes',
                name: 'Allow',
                kind: 'allow_once',
              ),
            ],
          ),
        );
        await tester.pump();
        await tester.tap(key('agent-stop-$pane'));
        await flush(tester);
        expect(host.agentStops, [id]);
        host.agentResolvedSource.add(
          AgentPermissionResolvedParams(
            sessionId: id,
            requestId: 'r',
            outcome: AgentPermissionOutcome.cancelled,
          ),
        );
        host.agentState(id, AgentState.stopping, 2);
        host.agentStopSource.add(
          AgentStopResultParams(
            sessionId: id,
            outcome: AgentStopOutcome.notConfirmed,
          ),
        );
        await tester.pump();
        expect(find.text('Cancelled'), findsOneWidget);
        expect(find.text('Stop not confirmed'), findsOneWidget);
        host.agentStopSource.add(
          AgentStopResultParams(
            sessionId: id,
            outcome: AgentStopOutcome.endedWithError,
            late: true,
            message: 'adapter failure',
          ),
        );
        host.agentState(id, AgentState.idle, 3);
        await tester.pump();
        expect(
          find.textContaining(
            'Turn ended with an error after Stop (after the deadline): adapter failure',
          ),
          findsOneWidget,
        );
        expect(find.text('Stop not confirmed'), findsNothing);
      },
    );

    uiTest('host loss disables pending permission options and Send and Stop', (
      tester,
    ) async {
      final host = agentHost();
      final rig = await pumpRig(tester, host);
      await start(rig, tester);
      final pane = chat(rig).id;
      final id = session(rig);
      host.agentRequestSource.add(
        AgentPermissionRequestedParams(
          sessionId: id,
          requestId: 'r',
          title: 'Tool approval',
          options: const [
            AgentPermissionOption(
              optionId: 'yes',
              name: 'Allow',
              kind: 'allow_once',
            ),
          ],
        ),
      );
      host.agentState(id, AgentState.waitingApproval);
      rig.controller.detach();
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(key('agent-option-$pane-r-yes'))
            .onPressed,
        isNull,
      );
      expect(
        tester.widget<FilledButton>(key('agent-send-$pane')).onPressed,
        isNull,
      );
      expect(
        tester.widget<OutlinedButton>(key('agent-stop-$pane')).onPressed,
        isNull,
      );
      expect(find.text('Stopped or unknown'), findsWidgets);
    });

    uiTest(
      'permission choices use exact adapter ids; inactive tab status never activates it',
      (tester) async {
        final host = agentHost();
        final rig = await pumpRig(tester, host);
        await start(rig, tester);
        final first = chat(rig);
        final id = session(rig);
        await start(rig, tester);
        final active = rig.layout.activeTab;
        host.agentRequestSource.add(
          AgentPermissionRequestedParams(
            sessionId: id,
            requestId: 'r',
            title: 'npm test',
            options: const [
              AgentPermissionOption(
                optionId: 'exact-allow',
                name: 'Allow',
                kind: 'allow_once',
              ),
              AgentPermissionOption(
                optionId: 'exact-always',
                name: 'Always allow',
                kind: 'allow_always',
              ),
              AgentPermissionOption(
                optionId: 'exact-reject',
                name: 'Reject',
                kind: 'reject_once',
              ),
            ],
          ),
        );
        host.agentState(id, AgentState.waitingApproval);
        await tester.pump();
        expect(rig.layout.activeTab, active);
        expect(find.text('Waiting for approval'), findsWidgets);
        expect(host.agentReplies, isEmpty);
        rig.controller.activateTab(rig.layout.tabOf(first.id)!.id);
        await tester.pump();
        await tester.tap(key('agent-option-${first.id}-r-exact-allow'));
        await flush(tester);
        expect(host.agentReplies.single.optionId, 'exact-allow');
        host.agentResolvedSource.add(
          AgentPermissionResolvedParams(
            sessionId: id,
            requestId: 'r',
            outcome: AgentPermissionOutcome.selected,
            optionId: 'exact-allow',
          ),
        );
        host.agentState(id, AgentState.running, 2);
        await tester.pump();
        expect(find.textContaining('Answered: Allow'), findsOneWidget);
      },
    );

    uiTest(
      'start failure Retry and typed authentication guidance preserve native error',
      (tester) async {
        final host = agentHost()
          ..agentStartAnswers.add(
            RpcException(ErrorCode.authRequired, 'native sign-in detail'),
          );
        final rig = await pumpRig(tester, host);
        await start(rig, tester);
        expect(
          find.textContaining('Claude Code is not signed in'),
          findsWidgets,
        );
        expect(find.textContaining('native sign-in detail'), findsWidgets);
        expect(find.textContaining('claude'), findsWidgets);
        await tester.tap(key('agent-retry-${chat(rig).id}'));
        await flush(tester);
        expect(host.agentStarts, hasLength(2));
        final id = session(rig);
        host.agentState(id, AgentState.idle);
        host.agentTurnSource.add(
          AgentTurnEndedParams(
            sessionId: id,
            error: ErrorCode.authRequired,
            message: 'expired detail',
          ),
        );
        await tester.pump();
        expect(find.textContaining('expired detail'), findsWidgets);
        host.agentExit(id, reason: AgentExitReason.failed, status: 1);
        await tester.pump();
        expect(find.textContaining('status 1'), findsWidgets);
        expect(find.text('Continue'), findsOneWidget);
      },
    );

    uiTest(
      'launcher with no runtime profile offers Add profile naming package and Node >= 22',
      (tester) async {
        final host = agentHost()
          ..runtimes = const RuntimeListResult(
            profiles: [],
            defaultAvailable: false,
            defaultReason: 'adapter not installed',
          );
        final rig = await pumpRig(tester, host);
        await launch(tester, entry: 'launch-agent-chat');
        expect(rig.layout.tabs, isEmpty);
        expect(
          find.textContaining('@agentclientprotocol/claude-agent-acp'),
          findsWidgets,
        );
        expect(find.textContaining('22'), findsWidgets);
        expect(find.text('Add profile'), findsOneWidget);
        expect(host.agentStarts, isEmpty);
      },
    );

    uiTest(
      'unavailable default asks to choose or add without silent fallback',
      (tester) async {
        final host = agentHost();
        host.runtimes = RuntimeListResult(
          profiles: host.runtimes.profiles,
          defaultAvailable: false,
          defaultId: 'missing',
          defaultReason: 'adapter removed from PATH',
        );
        final rig = await pumpRig(tester, host);
        await launch(tester, entry: 'launch-agent-chat');
        expect(find.textContaining('adapter removed from PATH'), findsWidgets);
        expect(find.text('Add profile'), findsOneWidget);
        expect(rig.layout.tabs, isEmpty);
        expect(host.agentStarts, isEmpty);
      },
    );

    uiTest('Personal needs workspace and Open folder sends no agent start', (
      tester,
    ) async {
      final rig = await pumpRig(tester, agentHost());
      rig.controller.selectPersonal();
      await tester.pump();
      await tester.tap(key('add-tab'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<PopupMenuItem<String>>(key('launch-agent-chat')).enabled,
        isFalse,
      );
      expect(
        inside(
          'launch-agent-chat',
          find.textContaining(RegExp('workspace', caseSensitive: false)),
        ),
        findsOneWidget,
      );
      expect(key('open-folder').hitTestable(), findsOneWidget);
      expect(
        tester.widget<PopupMenuItem<String>>(key('open-folder')).enabled,
        isTrue,
      );
      expect(rig.link.agentStarts, isEmpty);
      expect(rig.layout.tabs, isEmpty);
    });

    uiTest(
      'host without agent disables launcher with reason and terminals keep working',
      (tester) async {
        final host = agentHost();
        final noAgent = linkWith(
          docOf([], selected: 'A'),
          records: host.records,
          hello: helloResult(capabilities: terminalCapabilities),
        );
        final rig = await pumpRig(tester, noAgent);
        await tester.tap(key('add-tab'));
        await tester.pumpAndSettle();
        final entry = tester.widget<PopupMenuItem<String>>(
          key('launch-agent-chat'),
        );
        expect(entry.enabled, isFalse);
        expect(find.textContaining('does not support agents'), findsOneWidget);
        await tester.tap(key('launch-terminal'));
        await flush(tester);
        expect(rig.terminalPanes, hasLength(1));
      },
    );
  });
}
