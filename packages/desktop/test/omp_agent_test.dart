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
}
