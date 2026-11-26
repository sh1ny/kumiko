import 'dart:async';
import 'dart:convert';

import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:host_protocol/host_protocol.dart';

import 'agent_test.dart' show agents, chat, session;
import 'support/fake_host.dart';
import 'support/workbench_support.dart';

const _profile = RuntimeProfile(
  id: 'native-omp',
  name: 'Native OMP',
  runtimeKind: 'omp',
  executable: '/omp',
);

FakeHostLink _host({bool supportsOmp = true, bool supportsHistory = false}) {
  final host = FakeHostLink(
    hello: helloResult(
      capabilities: {
        Capability.workbench,
        Capability.terminal,
        Capability.agent,
        if (supportsOmp) Capability.omp,
        if (supportsHistory) 'omp-history',
      },
    ),
  );
  host.records.add(workspaceRecord('A'));
  host.storedLayout = jsonOf(docOf([], selected: 'A'));
  host.runtimes = const RuntimeListResult(
    profiles: [_profile],
    defaultId: 'native-omp',
    defaultAvailable: true,
  );
  return host;
}

Future<void> _menu(WidgetTester tester) async {
  await tester.tap(key('add-tab'));
  await tester.pumpAndSettle();
}

Future<Rig> _chat(WidgetTester tester, FakeHostLink host) async {
  final rig = await pumpRig(tester, host);
  await _menu(tester);
  await tester.tap(key('launch-omp'));
  await flush(tester);
  return rig;
}

void main() {
  uiTest('OMP: Compatible host enables both OMP launch items', (tester) async {
    final host = _host();
    await pumpRig(tester, host);
    await _menu(tester);
    for (final id in ['launch-omp', 'launch-omp-profile']) {
      expect(tester.widget<PopupMenuItem<String>>(key(id)).enabled, isTrue);
    }
    await tester.tap(key('launch-omp-profile'));
    await flush(tester);
    await tester.tap(find.text('Native OMP'));
    await flush(tester);
    expect(host.agentStarts.single.runtimeProfileId, _profile.id);
  });

  uiTest('OMP: Older host disables launch with the missing capability', (
    tester,
  ) async {
    final host = _host(supportsOmp: false);
    await pumpRig(tester, host);
    await _menu(tester);
    for (final id in ['launch-omp', 'launch-omp-profile']) {
      final item = tester.widget<PopupMenuItem<String>>(key(id));
      expect(item.enabled, isFalse);
      expect((item.child as Text).data, contains('OMP requires omp'));
    }
    expect(host.agentStarts, isEmpty);
  });

  uiTest('OMP: Runtime profiles offer the native RPC kind', (tester) async {
    await pumpRig(tester, _host());
    await _menu(tester);
    await tester.tap(key('runtime-profiles'));
    await flush(tester);
    await tester.tap(key('add-runtime-profile'));
    await flush(tester);
    await tester.tap(key('runtime-kind'));
    await tester.pumpAndSettle();
    expect(find.text('OMP native RPC'), findsOneWidget);
  });

  uiTest('OMP: Composer has its own hint and no Steer button', (tester) async {
    final rig = await _chat(tester, _host());
    final pane = chat(rig).id;
    final composer = tester.widget<TextField>(key('agent-prompt-$pane'));
    expect(composer.decoration!.hintText, 'Message OMP');
    expect(key('agent-steer-$pane'), findsNothing);
    expect(find.text('OMP · A'), findsWidgets);
  });

  uiTest('OMP: Sign-in and model guidance stays native', (tester) async {
    final host = _host();
    final rig = await _chat(tester, host);
    host.agentTurnSource.add(
      AgentTurnEndedParams(
        sessionId: session(rig),
        error: ErrorCode.authRequired,
      ),
    );
    await flush(tester);
    expect(
      find.text(
        'OMP sign-in and models are managed by OMP; run `omp` in a terminal to set them up',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Claude Code is not signed in'), findsNothing);
  });

  AgentPermissionRequestedParams permission(String id) =>
      AgentPermissionRequestedParams(
        sessionId: id,
        requestId: 'omp:permission-1',
        title: 'OMP tool approval',
        preview: 'Allow tool: bash\nCommand: echo demo',
        options: const [
          AgentPermissionOption(
            optionId: 'choice-0',
            name: 'Approve Once',
            kind: 'allow_once',
          ),
          AgentPermissionOption(
            optionId: 'choice-1',
            name: 'Deny',
            kind: 'reject_once',
          ),
        ],
      );

  uiTest('OMP: Permission card offers only one-shot Approve and Deny', (
    tester,
  ) async {
    final host = _host();
    final rig = await _chat(tester, host);
    final id = session(rig);
    host.agentState(id, AgentState.waitingApproval);
    host.agentRequestSource.add(permission(id));
    await flush(tester);
    expect(
      find.text('Allow tool: bash\nCommand: echo demo', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('Approve Once'), findsOneWidget);
    expect(find.textContaining('Always Approve'), findsNothing);
    expect(host.agentReplies, isEmpty);
    await tester.tap(find.text('Deny'));
    await flush(tester);
    expect(host.agentReplies.single.optionId, 'choice-1');
  });

  uiTest('OMP: Withdrawn approval disables its choices', (tester) async {
    final host = _host();
    final rig = await _chat(tester, host);
    final id = session(rig);
    final request = permission(id);
    host.agentState(id, AgentState.waitingApproval);
    host.agentRequestSource.add(request);
    await flush(tester);
    host.agentResolvedSource.add(
      AgentPermissionResolvedParams(
        sessionId: id,
        requestId: request.requestId,
        outcome: AgentPermissionOutcome.cancelled,
      ),
    );
    await flush(tester);
    final choice = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Approve Once'),
    );
    expect(choice.onPressed, isNull);
    expect(host.agentReplies, isEmpty);
  });

  uiTest('OMP: Approval guidance states native policy and limits', (
    tester,
  ) async {
    await _chat(tester, _host());
    expect(
      find.textContaining('OMP settings decide when tools ask'),
      findsOneWidget,
    );
    expect(find.textContaining('does not sandbox OMP'), findsOneWidget);
  });

  uiTest('OMP: Tool cards show separate final results', (tester) async {
    final host = _host();
    final rig = await _chat(tester, host);
    final id = session(rig);
    for (final (call, name) in [('first', 'read'), ('second', 'write')]) {
      host.agentEvent(
        id,
        AgentEvent.tool(toolCallId: call, title: name, status: 'in_progress'),
      );
    }
    void result(String call, String status, String text) {
      host.agentEvent(
        id,
        AgentEvent.tool(
          toolCallId: call,
          update: true,
          status: status,
          content: [
            {'type': 'text', 'text': text},
          ],
        ),
      );
    }

    result('first', 'in_progress', 'work in progress');
    await flush(tester);
    expect(find.text('work in progress', findRichText: true), findsOneWidget);
    result('second', 'failed', 'write failed');
    result('first', 'completed', 'read finished');
    await flush(tester);
    for (final (name, text) in [
      ('read', 'read finished'),
      ('write', 'write failed'),
    ]) {
      final card = find.ancestor(
        of: find.text(name, findRichText: true),
        matching: find.byType(Card),
      );
      expect(
        find.descendant(
          of: card,
          matching: find.text(text, findRichText: true),
        ),
        findsOneWidget,
      );
    }
    expect(find.text('work in progress', findRichText: true), findsNothing);
  });

  FakeHostLink savedOmp({required bool history, String? unavailable}) {
    final host = _host(supportsHistory: history);
    host.storedLayout = jsonOf(
      docOf([
        tabOf(
          'saved-tab',
          paneOf(
            'saved-pane',
            kind: 'agent-chat',
            ws: 'A',
            item: 'saved-item',
            state: {
              'sessionId': 'saved',
              'runtimeName': 'OMP',
              'runtimeKind': 'omp',
            },
          ),
        ),
      ], selected: 'A'),
    );
    host.agentRecordMap['saved'] = AgentRecord.fromJson({
      'known': true,
      'workspaceAvailable': true,
      'continueUnavailable': ?unavailable,
    });
    return host;
  }

  for (final history in [false, true]) {
    uiTest(
      'OMP: ${history ? 'Missing locator' : 'Old peer'} disables Continue before a request',
      (tester) async {
        final host = savedOmp(
          history: history,
          unavailable: history ? 'omp-locator-unavailable' : null,
        );
        final rig = await pumpRig(tester, host);
        expect(agents(rig).linkOf('saved-pane')!.canContinue, isFalse);
        expect(
          find.textContaining(history ? 'native session file' : 'omp-history'),
          findsOneWidget,
        );
        expect(host.agentContinues, isEmpty);
      },
    );
  }

  uiTest('OMP: Explicit Continue loads the saved chat, without sending', (
    tester,
  ) async {
    final host = savedOmp(history: true);
    final rig = await pumpRig(tester, host);
    expect(host.agentContinues, isEmpty);
    expect(agents(rig).linkOf('saved-pane')!.canContinue, isTrue);
    host.agentContinueAnswers.add(
      const AgentContinueResult(
        eventChannel: 121,
        adapter: AgentAdapter(name: 'omp-rpc', version: '18.20.1'),
        capabilities: ['load'],
        mode: AgentContinueMode.load,
      ),
    );
    await tester.tap(key('agent-continue-saved-pane'));
    await flush(tester);
    host.agentEvent('saved', AgentEvent.replay(AgentReplayPhase.start));
    host.agentEvent(
      'saved',
      AgentEvent.text(AgentEventKind.agentText, 'The old answer.'),
    );
    host.agentEvent('saved', AgentEvent.replay(AgentReplayPhase.end));
    await flush(tester);
    expect(find.text('The old answer.', findRichText: true), findsOneWidget);
    expect(host.agentContinues.single.sessionId, 'saved');
    expect(host.agentStarts, isEmpty);
    expect(host.agentPrompts, isEmpty);
  });

  const run = 'omp-run';
  String childKey(int n) => '$run:child:$n';
  String opener(int n) => 'omp-open-child-${childKey(n)}';
  AgentEvent childEvent(int n, AgentEvent event, {String? token}) =>
      event.forOmpChild(rootId: run, childKey: childKey(n), viewToken: token);

  Future<Rig> children(
    WidgetTester tester,
    FakeHostLink host,
    int count,
  ) async {
    final rig = await _chat(tester, host);
    final root = session(rig);
    host.agentStateSource.add(
      AgentStateParams(
        sessionId: root,
        seq: 10,
        state: AgentState.idle,
        runId: run,
        delegated: AgentDelegated(activeChildren: count),
      ),
    );
    for (var i = 1; i <= count; i++) {
      host.agentEvent(
        root,
        AgentEvent.ompChildLifecycle(
          rootId: run,
          childKey: childKey(i),
          ordinal: i,
          status: 'running',
        ),
      );
    }
    await flush(tester);
    return rig;
  }

  Future<PaneNode> openChild(WidgetTester tester, Rig rig, int n) async {
    expect(key(opener(n)), findsOneWidget);
    await tester.ensureVisible(key(opener(n)));
    await tester.tap(key(opener(n)));
    await flush(tester);
    return rig.layout.panes.singleWhere(
      (pane) => pane.state['childKey'] == childKey(n),
    );
  }

  const queued = AgentChildHistoryResult(AgentChildHistoryStatus.queued);

  uiTest(
    'OMP: Child pane opens within its parent tab and moves and closes without stopping work',
    (tester) async {
      final host = _host(supportsHistory: true)
        ..childHistoryAnswers.add(queued);
      final rig = await children(tester, host, 1);
      final root = chat(rig);
      final id = session(rig);
      final child = await openChild(tester, rig, 1);
      expect(rig.layout.tabOf(child.id)?.id, rig.layout.tabOf(root.id)?.id);
      expect(child.workspace, root.workspace);
      expect(rig.layout.focusedPane, child.id);
      expect((await openChild(tester, rig, 1)).id, child.id);
      final read = host.childHistoryRequests.single;
      expect(
        (read.sessionId, read.runId, read.childKey),
        (id, run, childKey(1)),
      );
      expect(
        inside('omp-child-view-${child.id}', find.byType(TextField)),
        findsNothing,
      );
      for (final control in ['Send', 'Stop', 'Steer', 'Continue', 'Approve']) {
        expect(
          inside('omp-child-view-${child.id}', find.text(control)),
          findsNothing,
        );
      }
      host.agentEvent(
        id,
        childEvent(
          1,
          AgentEvent.text(AgentEventKind.agentText, 'private child reply'),
        ),
      );
      await flush(tester);
      expect(
        inside(
          'omp-child-view-${child.id}',
          find.text('private child reply', findRichText: true),
        ),
        findsOneWidget,
      );
      unawaited(rig.controller.flushForExit());
      await flush(tester);
      expect(
        jsonEncode(host.saves.last.layout),
        isNot(contains('private child reply')),
      );
      expect(child.state, {
        'rootSessionId': id,
        'childKey': childKey(1),
        'ordinal': 1,
      });

      await tester.tap(key('move-${child.id}'));
      await flush(tester);
      expect(
        rig.layout.tabOf(child.id)?.id,
        isNot(rig.layout.tabOf(root.id)?.id),
      );
      expect(rig.layout.pane(child.id)!.workspace, root.workspace);
      expect(
        inside(
          'omp-child-view-${child.id}',
          find.text('private child reply', findRichText: true),
        ),
        findsOneWidget,
      );
      rig.controller.activateTab(rig.layout.tabOf(root.id)!.id);
      await flush(tester);
      expect((await openChild(tester, rig, 1)).id, child.id);
      expect(rig.layout.activeTab, rig.layout.tabOf(child.id)?.id);
      expect(host.childHistoryRequests, hasLength(1));
      await tester.tap(key('close-pane-${child.id}'));
      await flush(tester);
      expect(rig.layout.pane(child.id), isNull);
      expect(rig.layout.pane(root.id), isNotNull);
      expect(host.agentCloses, isEmpty);
      expect(host.agentStops, isEmpty);
    },
  );

  uiTest(
    'OMP: Two child panes separate history, live content and tool results from the parent',
    (tester) async {
      final host = _host(supportsHistory: true)
        ..childHistoryAnswers.addAll([queued, queued]);
      final rig = await children(tester, host, 2);
      final id = session(rig);
      final root = chat(rig).id;
      final first = await openChild(tester, rig, 1);
      final second = await openChild(tester, rig, 2);
      for (final n in [1, 2]) {
        final token = host.childHistoryRequests[n - 1].viewToken;
        for (final event in [
          AgentEvent.replay(AgentReplayPhase.start),
          AgentEvent.text(AgentEventKind.agentText, 'history $n'),
          AgentEvent.replay(AgentReplayPhase.end),
        ]) {
          host.agentEvent(id, childEvent(n, event, token: token));
        }
        host.agentEvent(
          id,
          childEvent(n, AgentEvent.text(AgentEventKind.agentText, 'live $n')),
        );
        host.agentEvent(
          id,
          childEvent(
            n,
            AgentEvent.tool(toolCallId: 'same-tool', title: 'read $n'),
          ),
        );
        host.agentEvent(
          id,
          childEvent(
            n,
            AgentEvent.tool(
              toolCallId: 'same-tool',
              update: true,
              status: 'completed',
              content: [
                {'type': 'text', 'text': 'output $n'},
              ],
            ),
          ),
        );
      }
      await flush(tester);
      for (final (pane, own, other) in [(first, 1, 2), (second, 2, 1)]) {
        final view = 'omp-child-view-${pane.id}';
        expect(inside(view, find.text('Earlier history')), findsOneWidget);
        expect(inside(view, find.text('Live activity')), findsOneWidget);
        for (final text in ['history', 'live', 'output']) {
          expect(
            inside(view, find.text('$text $own', findRichText: true)),
            findsOneWidget,
          );
          expect(
            inside(view, find.text('$text $other', findRichText: true)),
            findsNothing,
          );
        }
      }
      expect(
        agents(rig).linkOf(root)!.transcript.plainText,
        isNot(contains('history 1')),
      );
      expect(
        agents(rig).linkOf(root)!.transcript.plainText,
        isNot(contains('live 2')),
      );
      expect(host.agentStarts, hasLength(1));
    },
  );

  uiTest(
    'OMP: Stale child replay is ignored and parent exit keeps displayed data',
    (tester) async {
      final host = _host(supportsHistory: true)
        ..childHistoryAnswers.add(queued);
      final rig = await children(tester, host, 1);
      final root = session(rig);
      final first = await openChild(tester, rig, 1);
      final stale = host.childHistoryRequests.single.viewToken;
      await tester.tap(key('close-pane-${first.id}'));
      await flush(tester);
      final current = await openChild(tester, rig, 1);
      expect(host.childHistoryRequests.last.viewToken, isNot(stale));
      host.agentEvent(
        root,
        childEvent(1, AgentEvent.replay(AgentReplayPhase.start), token: stale),
      );
      host.agentEvent(
        root,
        childEvent(
          1,
          AgentEvent.text(AgentEventKind.agentText, 'outdated snapshot'),
          token: stale,
        ),
      );
      host.agentEvent(
        root,
        childEvent(1, AgentEvent.replay(AgentReplayPhase.end), token: stale),
      );
      host.agentEvent(
        root,
        childEvent(
          1,
          AgentEvent.text(AgentEventKind.agentText, 'current live output'),
        ),
      );
      await flush(tester);
      expect(find.textContaining('History unavailable'), findsOneWidget);
      expect(find.text('outdated snapshot', findRichText: true), findsNothing);
      expect(
        find.text('current live output', findRichText: true),
        findsOneWidget,
      );
      host.agentExit(root);
      await flush(tester);
      expect(rig.layout.pane(current.id), isNotNull);
      expect(find.textContaining('parent OMP run ended'), findsOneWidget);
      expect(
        find.text('current live output', findRichText: true),
        findsOneWidget,
      );
      expect(host.agentContinues, isEmpty);
      expect(host.agentStarts, hasLength(1));
    },
  );

  uiTest(
    'OMP: Restore keeps an inert child location without opening a runtime',
    (tester) async {
      final host = savedOmp(history: true);
      final savedRoot = paneOf(
        'saved-pane',
        kind: 'agent-chat',
        ws: 'A',
        item: 'saved-item',
        state: {
          'sessionId': 'saved',
          'runtimeName': 'OMP',
          'runtimeKind': 'omp',
        },
      );
      final savedChild = paneOf(
        'saved-child',
        kind: 'omp-child',
        ws: 'A',
        state: {
          'rootSessionId': 'saved',
          'childKey': childKey(1),
          'ordinal': 1,
        },
      );
      host.storedLayout = jsonOf(
        docOf([
          tabOf('saved-tab', splitOf('saved-split', savedRoot, savedChild)),
        ], selected: 'A'),
      );
      final rig = await pumpRig(tester, host);
      expect(rig.layout.tabOf('saved-child')?.id, 'saved-tab');
      expect(
        find.textContaining('This subagent view is from an earlier run'),
        findsOneWidget,
      );
      expect(find.text('Continue'), findsOneWidget);
      expect(host.childHistoryRequests, isEmpty);
      expect(host.agentStarts, isEmpty);
      expect(host.agentContinues, isEmpty);
      await _menu(tester);
      expect(find.text('Subagent'), findsNothing);
    },
  );

  uiTest('OMP: Child pane reports the layout limit without replacing a pane', (
    tester,
  ) async {
    final host = _host(supportsHistory: true);
    final rig = await children(tester, host, 1);
    final root = chat(rig).id;
    rig.controller.splitPane(root, SplitDirection.horizontal, paneOf('other'));
    final others = ['other'];
    var direction = SplitDirection.vertical;
    while (others.length < maxPanesPerTab - 1) {
      for (final parent in others.toList()) {
        if (others.length == maxPanesPerTab - 1) break;
        final id = 'other-${others.length}';
        rig.controller.splitPane(parent, direction, paneOf(id));
        others.add(id);
      }
      direction = direction == SplitDirection.vertical
          ? SplitDirection.horizontal
          : SplitDirection.vertical;
    }
    rig.controller.focusPane(root);
    await flush(tester);
    final before = jsonOf(rig.layout);
    await tester.ensureVisible(key(opener(1)));
    await tester.tap(key(opener(1)));
    await flush(tester);
    expect(rig.controller.message, contains('a tab holds at most'));
    expect(jsonOf(rig.layout), before);
    expect(host.childHistoryRequests, isEmpty);
    expect(host.agentCloses, isEmpty);
  });

  uiTest('OMP: Unopened child content cannot displace the root transcript', (
    tester,
  ) async {
    final host = _host(supportsHistory: true);
    final rig = await children(tester, host, 1);
    final root = session(rig);
    host.agentEvent(
      root,
      AgentEvent.text(AgentEventKind.agentText, 'held root text'),
    );
    host.agentEvent(
      root,
      AgentEvent.tool(toolCallId: 'id', title: 'root card'),
    );
    for (var n = 0; n < 2010; n++) {
      host.agentEvent(
        root,
        childEvent(1, AgentEvent.notice('discarded child output')),
      );
    }
    host.agentEvent(
      root,
      childEvent(
        1,
        AgentEvent.tool(toolCallId: 'id', update: true, title: 'child title'),
      ),
    );
    await flush(tester);
    final parent = agents(rig).linkOf(chat(rig).id)!.transcript;
    expect(parent.hiddenEntries, 0);
    expect(parent.plainText, contains('held root text'));
    expect(parent.plainText, contains('root card'));
    expect(parent.plainText, isNot(contains('child title')));
    expect(parent.plainText, isNot(contains('discarded child output')));
  });
}
