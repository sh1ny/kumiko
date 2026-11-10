import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:host_protocol/host_protocol.dart';

import 'package:desktop/src/agent/agent_controller.dart' show AgentLinkPhase;

import 'agent_test.dart' show agentHost, agents, chat, session;
import 'support/workbench_support.dart';
import 'support/fake_host.dart';

const codexProfile = RuntimeProfile(
  id: 'native',
  name: 'Native test',
  runtimeKind: 'codex',
  executable: '/codex',
);

FakeHostLink nativeHost({bool workspace = true}) {
  final host = FakeHostLink(
    hello: helloResult(capabilities: {...agentCapabilitiesForCodex}),
  );
  host.startAgentCapabilities = const ['steer'];
  host.records.add(workspaceRecord('A'));
  host.storedLayout = jsonOf(docOf([], selected: workspace ? 'A' : null));
  host.runtimes = const RuntimeListResult(
    profiles: [codexProfile],
    defaultId: 'native',
    defaultAvailable: true,
  );
  return host;
}

const agentCapabilitiesForCodex = {
  Capability.workbench,
  Capability.terminal,
  Capability.agent,
  Capability.codex,
  Capability.agentExtensionsV1,
};
Future<Rig> nativeChat(WidgetTester tester, FakeHostLink host) async {
  final rig = await pumpRig(tester, host);
  await tester.tap(key('add-tab'));
  await tester.pumpAndSettle();
  await tester.tap(key('launch-codex'));
  await flush(tester);
  return rig;
}

void running(
  FakeHostLink host,
  String id, {
  int seq = 1,
  String turn = 'turn',
}) => host.agentStateSource.add(
  AgentStateParams(
    sessionId: id,
    seq: seq,
    state: AgentState.running,
    runId: 'run',
    turnId: turn,
  ),
);
AgentQuestionRequestedParams question(
  String id, {
  int seq = 3,
  String request = 'question',
  bool secret = false,
}) => AgentQuestionRequestedParams(
  sessionId: id,
  seq: seq,
  runId: 'run',
  turnId: 'turn',
  requestId: request,
  questions: [
    AgentQuestion(
      id: 'q',
      header: 'Native question',
      text: 'Choose carefully',
      secret: secret,
      allowOther: secret,
      options: secret
          ? []
          : [
              const AgentQuestionOption(
                id: 'one',
                label: 'One',
                description: 'First option',
              ),
            ],
    ),
  ],
);
const replacementCodex = RuntimeProfile(
  id: 'replacement',
  name: 'Replacement native',
  runtimeKind: 'codex',
  executable: '/replacement',
);
const pickerClaude = RuntimeProfile(
  id: 'claude',
  name: 'Foreign Claude',
  runtimeKind: 'claude-code',
  executable: '/claude',
);
Future<Rig> nativeContinuePicker(WidgetTester tester, FakeHostLink host) async {
  final rig = await nativeChat(tester, host);
  final saved = session(rig);
  host.agentExit(saved);
  await flush(tester);
  final link = agents(rig).linkOf(chat(rig).id)!;
  link.saved = true;
  link.prompt.text = 'saved draft';
  link.transcript.add(
    AgentEvent.text(AgentEventKind.agentText, 'retained transcript'),
  );
  host.runtimes = const RuntimeListResult(
    profiles: [replacementCodex, pickerClaude],
    defaultId: 'claude',
    defaultAvailable: true,
  );
  host.agentContinueAnswers.add(
    RpcException(
      ErrorCode.noRuntimeProfile,
      'Choose a compatible codex runtime profile.',
    ),
  );
  host.agentContinueAnswers.add(
    RpcException(ErrorCode.resumeUnavailable, 'native history unavailable', {
      'resumeReason': 'native-history-unavailable',
    }),
  );
  await tester.tap(key('agent-continue-${chat(rig).id}'));
  await flush(tester);
  return rig;
}

void main() {
  uiTest('Codex: Codex restores through native history', (tester) async {
    final host = nativeHost();
    final rig = await nativeChat(tester, host);
    final pane = chat(rig).id;
    final id = session(rig);
    final link = agents(rig).linkOf(pane)!;
    host.agentExit(id);
    await flush(tester);
    link.saved = true;
    link.prompt.text = 'unsent saved draft';
    expect(link.statusLabel, 'Saved, not running');
    expect(host.agentContinues, isEmpty);
    host.agentContinueAnswers.add(
      const AgentContinueResult(
        eventChannel: 120,
        adapter: AgentAdapter(name: 'codex-app-server', version: '0.166.0'),
        capabilities: ['load'],
        mode: AgentContinueMode.load,
      ),
    );
    await tester.tap(key('agent-continue-$pane'));
    await flush(tester);
    host.agentEvent(id, AgentEvent.replay(AgentReplayPhase.start));
    host.agentEvent(
      id,
      AgentEvent.text(AgentEventKind.user, 'native old question'),
    );
    host.agentEvent(
      id,
      AgentEvent.text(AgentEventKind.agentText, 'native old answer'),
    );
    host.agentEvent(id, AgentEvent.replay(AgentReplayPhase.end));
    host.agentStateSource.add(
      AgentStateParams(
        sessionId: id,
        seq: 2,
        state: AgentState.idle,
        runId: 'restored-run',
      ),
    );
    await flush(tester);
    expect(link.transcript.plainText, contains('native old question'));
    expect(link.transcript.plainText, contains('native old answer'));
    expect(link.prompt.text, 'unsent saved draft');
    expect(host.agentContinues.single.sessionId, id);
    expect(host.agentStarts, hasLength(1));
    expect(host.agentPrompts, isEmpty);
    expect(link.canSend, true);
  });
  uiTest('Codex: Codex without a workspace', (tester) async {
    final host = nativeHost(workspace: false);
    await pumpRig(tester, host);
    await tester.tap(key('add-tab'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<PopupMenuItem<String>>(key('launch-codex')).enabled,
      false,
    );
    expect(host.agentStarts, isEmpty);
  });
  uiTest('Codex: Explicit steering is separate from Send', (tester) async {
    final host = nativeHost();
    final rig = await nativeChat(tester, host);
    final pane = chat(rig).id;
    running(host, session(rig));
    await flush(tester);
    expect(
      tester.widget<FilledButton>(key('agent-send-$pane')).onPressed,
      isNull,
    );
    expect(key('agent-steer-$pane'), findsOneWidget);
    await tester.enterText(key('agent-prompt-$pane'), 'change direction');
    await tester.tap(key('agent-steer-$pane'));
    await flush(tester);
    expect(host.agentSteers.single.expectedTurnId, 'turn');
    expect(host.agentSteers.single.runId, 'run');
    expect(host.agentPrompts, isEmpty);
    expect(agents(rig).linkOf(pane)!.prompt.text, isEmpty);
    expect(agents(rig).linkOf(pane)!.state, AgentState.running);
  });
  uiTest('Codex: Answer a structured question', (tester) async {
    final host = nativeHost();
    final rig = await nativeChat(tester, host);
    running(host, session(rig));
    host.questionSource.add(question(session(rig)));
    await flush(tester);
    expect(find.text('Choose carefully'), findsOneWidget);
    await tester.tap(key('question-choice-question-q-one'));
    await tester.pump();
    await tester.tap(key('question-submit-question'));
    await flush(tester);
    expect(host.questionAnswers.single.answers.single.values, ['one']);
    expect(host.questionAnswers.single.runId, 'run');
  });

  uiTest('Codex: Unrecognized Codex auth-like error', (tester) async {
    final host = nativeHost();
    final rig = await nativeChat(tester, host);
    host.agentTurnSource.add(
      AgentTurnEndedParams(
        sessionId: session(rig),
        error: 'native-error',
        nativeCode: -32000,
        nativeMessage: 'login token might be invalid',
      ),
    );
    await flush(tester);
    expect(find.textContaining('login token might be invalid'), findsOneWidget);
    expect(find.textContaining('Run codex in a terminal'), findsNothing);
    expect(find.textContaining('Claude Code is not signed in'), findsNothing);
  });
  uiTest('Codex: secret answers are obscured and disposed on resolution', (
    tester,
  ) async {
    final host = nativeHost();
    final rig = await nativeChat(tester, host);
    running(host, session(rig));
    host.questionSource.add(question(session(rig), secret: true));
    await flush(tester);
    final field = key('question-text-question-q');
    expect(tester.widget<TextField>(field).obscureText, true);
    await tester.enterText(field, 'ephemeral secret');
    host.questionResolvedSource.add(
      AgentQuestionResolvedParams(
        sessionId: session(rig),
        seq: 4,
        runId: 'run',
        turnId: 'turn',
        requestId: 'question',
        outcome: AgentQuestionOutcome.cancelled,
      ),
    );
    await flush(tester);
    expect(field, findsNothing);
    expect(
      agents(rig).linkOf(chat(rig).id)!.transcript.plainText,
      isNot(contains('ephemeral secret')),
    );
    expect(host.draftSaves.where((p) => p.text == 'ephemeral secret'), isEmpty);
  });
  uiTest('Codex: Running turn identity published', (tester) async {
    final host = nativeHost();
    final rig = await nativeChat(tester, host);
    final link = agents(rig).linkOf(chat(rig).id)!;
    running(host, session(rig));
    await flush(tester);
    expect(link.runId, 'run');
    expect(link.turnId, 'turn');
    expect(link.canSteer, true);
    host.agentStateSource.add(
      AgentStateParams(
        sessionId: session(rig),
        seq: 2,
        state: AgentState.idle,
        runId: 'run',
      ),
    );
    await flush(tester);
    expect(link.turnId, isNull);
    expect(link.canSteer, false);
    expect(link.canSend, true);
  });
  uiTest('Codex: Delayed prior-turn state', (tester) async {
    final host = nativeHost();
    final rig = await nativeChat(tester, host);
    final link = agents(rig).linkOf(chat(rig).id)!;
    running(host, session(rig), seq: 10, turn: 'new');
    running(host, session(rig), seq: 9, turn: 'old');
    host.agentStateSource.add(
      AgentStateParams(
        sessionId: session(rig),
        seq: 20,
        state: AgentState.running,
        runId: 'prior-run',
        turnId: 'old',
      ),
    );
    await flush(tester);
    expect(link.turnId, 'new');
    expect(link.runId, 'run');
  });
  uiTest('Codex: stale question state never loses current requests', (
    tester,
  ) async {
    final host = nativeHost();
    final rig = await nativeChat(tester, host);
    running(host, session(rig));
    host.questionSource.add(question(session(rig)));
    host.questionResolvedSource.add(
      AgentQuestionResolvedParams(
        sessionId: session(rig),
        seq: 2,
        runId: 'run',
        turnId: 'turn',
        requestId: 'question',
        outcome: AgentQuestionOutcome.cancelled,
      ),
    );
    host.questionSource.add(question(session(rig), seq: 2, request: 'stale'));
    await flush(tester);
    expect(find.text('Choose carefully'), findsOneWidget);
    final q = agents(rig).linkOf(chat(rig).id)!.questions['question']!;
    host.agentStateSource.add(
      AgentStateParams(
        sessionId: session(rig),
        seq: 4,
        state: AgentState.idle,
        runId: 'run',
      ),
    );
    await flush(tester);
    await agents(rig).answerQuestion(chat(rig).id, q, [
      const AgentQuestionAnswer(questionId: 'q', values: ['one']),
    ]);
    expect(host.questionAnswers, isEmpty);
    expect(find.text('Choose carefully'), findsNothing);
  });
  for (final outcome in ['accepted-edit', 'refused', 'unknown']) {
    uiTest('Codex: Steer draft transaction $outcome', (tester) async {
      final host = nativeHost();
      final rig = await nativeChat(tester, host);
      final pane = chat(rig).id;
      final link = agents(rig).linkOf(pane)!;
      running(host, session(rig));
      await flush(tester);
      host.steerGate = Completer<void>();
      if (outcome == 'refused') {
        host.steerError = RpcException(
          ErrorCode.methodNotAvailable,
          'steer is unavailable for this run',
        );
      }
      if (outcome == 'unknown') {
        host.steerError = TimeoutException('admission lost');
      }
      await tester.enterText(key('agent-prompt-$pane'), 'draft input');
      await tester.tap(key('agent-steer-$pane'));
      await flush(tester);
      if (outcome == 'accepted-edit') {
        await tester.enterText(
          key('agent-prompt-$pane'),
          'edited during admission',
        );
      }
      host.steerGate!.complete();
      await flush(tester);
      expect(
        link.prompt.text,
        outcome == 'accepted-edit' ? 'edited during admission' : 'draft input',
      );
      expect(host.agentSteers.single.draftRevision, isNotNull);
      expect(host.agentSteers.single.draftSynced, isNotNull);
      expect(link.state, AgentState.running);
      if (outcome != 'accepted-edit') {
        expect(link.canSteer, false);
        await agents(rig).steer(pane, link.prompt.text);
        await flush(tester);
        expect(host.agentSteers, hasLength(1));
        if (outcome == 'unknown') {
          expect(link.error, contains('outcome unknown'));
        }
      }
    });
  }
  uiTest(
    'Codex: unavailable question path preserves ordinary chat and later blocking questions',
    (tester) async {
      final host = nativeHost();
      final rig = await nativeChat(tester, host);
      final pane = chat(rig).id;
      running(host, session(rig));
      host.questionSource.add(question(session(rig)));
      await flush(tester);
      host.questionError = RpcException(
        ErrorCode.methodNotAvailable,
        'async answer unavailable',
      );
      await tester.tap(key('question-choice-question-q-one'));
      await tester.pump();
      await tester.tap(key('question-submit-question'));
      await flush(tester);
      expect(find.textContaining('async answer unavailable'), findsOneWidget);
      await tester.tap(key('question-submit-question'));
      await flush(tester);
      expect(host.questionAnswers, hasLength(1));
      host.questionResolvedSource.add(
        AgentQuestionResolvedParams(
          sessionId: session(rig),
          seq: 4,
          runId: 'run',
          turnId: 'turn',
          requestId: 'question',
          outcome: AgentQuestionOutcome.unavailable,
        ),
      );
      host.questionError = null;
      host.questionSource.add(
        question(session(rig), seq: 5, request: 'blocking'),
      );
      await flush(tester);
      await tester.tap(key('question-choice-blocking-q-one'));
      await tester.pump();
      await tester.tap(key('question-submit-blocking'));
      await flush(tester);
      expect(host.questionAnswers, hasLength(2));
      host.agentStateSource.add(
        AgentStateParams(
          sessionId: session(rig),
          seq: 6,
          state: AgentState.idle,
          runId: 'run',
        ),
      );
      await flush(tester);
      expect(agents(rig).linkOf(pane)!.canSend, true);
    },
  );
  uiTest('Codex: Approve a command', (tester) async {
    final host = nativeHost();
    final rig = await nativeChat(tester, host);
    final pane = chat(rig).id;
    running(host, session(rig));
    host.agentRequestSource.add(
      AgentPermissionRequestedParams(
        sessionId: session(rig),
        requestId: 'run:approval',
        title: 'Additional permissions',
        preview:
            'cwd: /work\nnetwork: enabled\nfileSystem: /scope\nreason: fixture',
        options: [
          const AgentPermissionOption(
            optionId: 'native-choice',
            name: 'Allow requested permissions for this turn',
            kind: 'allow_once',
          ),
          const AgentPermissionOption(
            optionId: 'reject',
            name: 'Decline',
            kind: 'reject_once',
          ),
        ],
      ),
    );
    await flush(tester);
    expect(find.textContaining('fileSystem: /scope'), findsOneWidget);
    expect(
      find.text('Allow requested permissions for this turn'),
      findsOneWidget,
    );
    await tester.tap(key('agent-option-$pane-run:approval-native-choice'));
    await flush(tester);
    expect(host.agentReplies.single.optionId, 'native-choice');
    expect(find.text('Allow always'), findsNothing);
  });
  uiTest('Codex: Codex authentication is required', (tester) async {
    final host = nativeHost();
    final rig = await nativeChat(tester, host);
    // Trust the host's confirmed classification only; this is not signature evidence.
    host.agentTurnSource.add(
      AgentTurnEndedParams(
        sessionId: session(rig),
        error: ErrorCode.authRequired,
      ),
    );
    await flush(tester);
    expect(find.textContaining('Run codex in a terminal'), findsOneWidget);
    expect(find.textContaining('Claude Code is not signed in'), findsNothing);
  });
  uiTest('Codex: Codex launcher with incompatible default', (tester) async {
    final host = nativeHost();
    host.runtimes = const RuntimeListResult(
      profiles: [
        RuntimeProfile(
          id: 'claude',
          name: 'Claude',
          runtimeKind: 'claude-code',
          executable: '/claude',
        ),
        codexProfile,
      ],
      defaultId: 'claude',
      defaultAvailable: true,
    );
    await nativeChat(tester, host);
    expect(host.agentStarts, isEmpty);
    expect(key('pick-runtime-native'), findsOneWidget);
    expect(key('pick-runtime-claude'), findsNothing);
    await tester.tap(key('pick-runtime-native'));
    await flush(tester);
    expect(host.agentStarts.single.runtimeKind, 'codex');
  });
  uiTest('Codex: Fresh Claude recovery with Codex default', (tester) async {
    final host = nativeHost();
    const claude = RuntimeProfile(
      id: 'claude',
      name: 'Claude',
      runtimeKind: 'claude-code',
      executable: '/claude',
    );
    host.runtimes = const RuntimeListResult(
      profiles: [claude, codexProfile],
      defaultId: 'claude',
      defaultAvailable: true,
    );
    final rig = await pumpRig(tester, host);
    await rig.controller.launchAgent();
    await flush(tester);
    final pane = chat(rig).id;
    host.agentExit(session(rig));
    await flush(tester);
    host.runtimes = const RuntimeListResult(
      profiles: [
        RuntimeProfile(
          id: 'replacement',
          name: 'Replacement',
          runtimeKind: 'claude-code',
          executable: '/replacement',
        ),
        codexProfile,
      ],
      defaultId: 'native',
      defaultAvailable: true,
    );
    await tester.tap(key('agent-new-$pane'));
    await flush(tester);
    expect(key('pick-runtime-replacement'), findsOneWidget);
    expect(key('pick-runtime-native'), findsNothing);
    await tester.tap(key('pick-runtime-replacement'));
    await flush(tester);
    expect(host.agentStarts.last.runtimeKind, 'claude-code');
    expect(host.agentStarts.last.runtimeProfileId, 'replacement');
  });
  uiTest('Codex: Continue keeps saved identity despite incompatible default', (
    tester,
  ) async {
    final host = nativeHost();
    final rig = await nativeChat(tester, host);
    final saved = session(rig);
    host.agentExit(saved);
    await flush(tester);
    host.runtimes = const RuntimeListResult(
      profiles: [],
      defaultAvailable: false,
    );
    await tester.tap(key('agent-continue-${chat(rig).id}'));
    await flush(tester);
    expect(host.calls.where((c) => c == 'agent/continue $saved'), hasLength(1));
    expect(host.agentStarts, hasLength(1));
  });
  for (final failure in ['unsupported', 'unknown']) {
    uiTest('Codex: permission refusal does not resend $failure', (
      tester,
    ) async {
      final host = nativeHost();
      final rig = await nativeChat(tester, host);
      final pane = chat(rig).id;
      running(host, session(rig));
      host.agentRequestSource.add(
        AgentPermissionRequestedParams(
          sessionId: session(rig),
          requestId: 'run:permission',
          title: 'Command approval',
          options: [
            const AgentPermissionOption(
              optionId: 'accept',
              name: 'accept',
              kind: 'allow_once',
            ),
          ],
        ),
      );
      host.permissionError = failure == 'unsupported'
          ? RpcException(
              ErrorCode.methodNotAvailable,
              'permission reply unavailable',
            )
          : TimeoutException('reply lost');
      await agents(rig).replyPermission(pane, 'run:permission', 'accept');
      await flush(tester);
      await agents(rig).replyPermission(pane, 'run:permission', 'accept');
      expect(host.agentReplies, hasLength(1));
      expect(
        find.textContaining(
          failure == 'unsupported'
              ? 'permission reply unavailable'
              : 'outcome unknown',
        ),
        findsOneWidget,
      );
    });
  }
  uiTest('Codex: prior run approval never becomes answerable', (tester) async {
    final host = nativeHost();
    final rig = await nativeChat(tester, host);
    running(host, session(rig));
    host.agentRequestSource.add(
      AgentPermissionRequestedParams(
        sessionId: session(rig),
        requestId: 'old-run:permission',
        title: 'Retired approval',
        options: [
          const AgentPermissionOption(
            optionId: 'accept',
            name: 'accept',
            kind: 'allow_once',
          ),
        ],
      ),
    );
    await flush(tester);
    expect(find.text('Retired approval'), findsNothing);
    await agents(rig)
        .replyPermission(chat(rig).id, 'old-run:permission', 'accept');
    expect(host.agentReplies, isEmpty);
  });
  uiTest('Codex: new profile selects native runtime kind', (tester) async {
    final host = nativeHost();
    await pumpRig(tester, host);
    await tester.tap(key('add-tab'));
    await tester.pumpAndSettle();
    await tester.tap(key('runtime-profiles'));
    await flush(tester);
    await tester.tap(key('add-runtime-profile'));
    await flush(tester);
    expect(key('runtime-kind'), findsOneWidget);
    await tester.tap(key('runtime-kind'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Codex native App Server').last);
    await tester.pumpAndSettle();
    await tester.enterText(key('runtime-profile-name'), 'Custom native');
    await tester.enterText(key('runtime-profile-executable'), '/custom/codex');
    await tester.enterText(key('runtime-profile-args'), 'app-server');
    await tester.tap(key('runtime-profile-save'));
    await flush(tester);
    expect(host.runtimes.profiles.last.runtimeKind, 'codex');
    expect(host.runtimes.profiles.last.args, ['app-server']);
  });
  uiTest('Codex: secret unknown answer remains ephemeral through run loss', (
    tester,
  ) async {
    final host = nativeHost();
    final rig = await nativeChat(tester, host);
    final pane = chat(rig).id;
    running(host, session(rig));
    host.questionSource.add(question(session(rig), secret: true));
    await flush(tester);
    await tester.enterText(key('question-text-question-q'), 'private answer');
    await tester.pump();
    host.questionError = TimeoutException('answer admission lost');
    await tester.tap(key('question-submit-question'));
    await flush(tester);
    expect(find.textContaining('Answer outcome unknown'), findsOneWidget);
    final q = agents(rig).linkOf(pane)!.questions['question']!;
    await agents(rig).answerQuestion(pane, q, [
      const AgentQuestionAnswer(questionId: 'q', values: ['private answer']),
    ]);
    expect(host.questionAnswers, hasLength(1));
    rig.controller.detach();
    await flush(tester);
    expect(key('question-text-question-q'), findsNothing);
    expect(
      host.draftSaves.where((p) => p.text.contains('private answer')),
      isEmpty,
    );
  });
  uiTest('Codex: unsupported optional question never becomes free text', (
    tester,
  ) async {
    final host = nativeHost();
    final rig = await nativeChat(tester, host);
    running(host, session(rig));
    host.questionSource.add(
      AgentQuestionRequestedParams(
        sessionId: session(rig),
        seq: 3,
        runId: 'run',
        turnId: 'turn',
        requestId: 'malformed',
        questions: [
          const AgentQuestion(
            id: 'unsupported',
            header: 'Unsupported',
            text: 'No safe answer shape',
          ),
        ],
      ),
    );
    await flush(tester);
    expect(key('question-text-malformed-unsupported'), findsNothing);
    expect(
      tester.widget<FilledButton>(key('question-submit-malformed')).onPressed,
      isNull,
    );
    expect(host.questionAnswers, isEmpty);
  });
  uiTest('Codex: explicit launcher profile choice filters runtime kind', (
    tester,
  ) async {
    final host = nativeHost();
    final rig = await pumpRig(tester, host);
    await tester.tap(key('add-tab'));
    await tester.pumpAndSettle();
    expect(key('launch-codex-profile'), findsOneWidget);
    await tester.tap(key('launch-codex-profile'));
    await flush(tester);
    expect(key('pick-runtime-native'), findsOneWidget);
    expect(host.agentStarts, isEmpty);
    await tester.tap(key('pick-runtime-native'));
    await flush(tester);
    expect(host.agentStarts.single.runtimeKind, 'codex');
    expect(chat(rig).state['runtimeKind'], 'codex');
  });
  uiTest('Codex: Send and Steer share draft admission ownership', (
    tester,
  ) async {
    final host = nativeHost();
    final rig = await nativeChat(tester, host);
    final pane = chat(rig).id;
    final link = agents(rig).linkOf(pane)!;
    host.agentStateSource.add(
      AgentStateParams(
        sessionId: session(rig),
        seq: 1,
        state: AgentState.idle,
        runId: 'run',
      ),
    );
    host.promptGate = Completer<void>();
    link.prompt.text = 'first';
    final sending = agents(rig).send(pane, 'first');
    running(host, session(rig), seq: 2);
    await flush(tester);
    expect(
      link.canSteer,
      false,
      reason: 'the existing draft submission still owns admission',
    );
    host.promptGate!.complete();
    await sending;
    await flush(tester);
    expect(link.canSteer, true);
    host.steerGate = Completer<void>();
    link.prompt.text = 'second';
    final steering = agents(rig).steer(pane, 'second');
    host.agentTurnSource.add(AgentTurnEndedParams(sessionId: session(rig)));
    host.agentStateSource.add(
      AgentStateParams(
        sessionId: session(rig),
        seq: 3,
        state: AgentState.idle,
        runId: 'run',
      ),
    );
    await flush(tester);
    expect(link.canSend, false, reason: 'Steer still owns draft admission');
    host.steerGate!.complete();
    await steering;
    await flush(tester);
    expect(link.canSend, true);
  });
  uiTest('Codex: Steer requires the native runtime claim', (tester) async {
    final host = nativeHost();
    host.startAgentCapabilities = const [];
    final rig = await nativeChat(tester, host);
    final pane = chat(rig).id;
    running(host, session(rig));
    await flush(tester);
    final link = agents(rig).linkOf(pane)!;
    expect(link.runId, 'run');
    expect(link.turnId, 'turn');
    expect(link.canSteer, false);
    expect(
      tester.widget<OutlinedButton>(key('agent-steer-$pane')).onPressed,
      isNull,
    );
    await agents(rig).steer(pane, 'not admitted');
    expect(host.agentSteers, isEmpty);
  });
  for (final missing in [Capability.codex, Capability.agentExtensionsV1]) {
    uiTest('Codex: native controls require negotiated $missing', (
      tester,
    ) async {
      final host = nativeHost();
      final rig = await nativeChat(tester, host);
      final pane = chat(rig).id;
      running(host, session(rig));
      host.questionSource.add(question(session(rig)));
      await flush(tester);
      final q = agents(rig).linkOf(pane)!.questions['question']!;
      final unnegotiated = FakeHostLink(
        hello: helloResult(
          capabilities: agentCapabilitiesForCodex.difference({missing}),
        ),
      );
      agents(rig).attach(unnegotiated);
      final link = agents(rig).linkOf(pane)!;
      // Simulate a live/stale control consumer trying to use its old identity.
      link.phase = AgentLinkPhase.live;
      link.connected = true;
      link.state = AgentState.running;
      link.runId = 'run';
      link.turnId = 'turn';
      link.questions['question'] = q;
      expect(link.canSteer, false);
      await agents(rig).steer(pane, 'not negotiated');
      await agents(rig).answerQuestion(pane, q, [
        const AgentQuestionAnswer(questionId: 'q', values: ['one']),
      ]);
      expect(unnegotiated.agentSteers, isEmpty);
      expect(unnegotiated.questionAnswers, isEmpty);
    });
  }
  for (final action in ['start', 'fresh', 'continue']) {
    uiTest(
      'Codex: incompatible saved peer refuses $action without losing draft',
      (tester) async {
        final original = nativeHost();
        final rig = await nativeChat(tester, original);
        final pane = chat(rig).id;
        final saved = session(rig);
        original.agentExit(saved);
        await flush(tester);
        final oldPeer = FakeHostLink(
          hello: helloResult(
            capabilities: {Capability.workbench, Capability.agent},
          ),
        );
        oldPeer.runtimes = original.runtimes;
        agents(rig).attach(oldPeer);
        final link = agents(rig).linkOf(pane)!;
        link.connected = true;
        link.known = true;
        link.saved = true;
        link.prompt.text = 'preserve saved draft';
        if (action == 'start') {
          await agents(rig).start(
            pane,
            workspaceId: 'A',
            runtimeName: 'Native test',
            runtimeProfileId: 'native',
            runtimeKind: 'codex',
          );
        } else if (action == 'fresh') {
          await agents(rig).newSession(pane);
        } else {
          await agents(rig).continueSession(pane);
        }
        await flush(tester);
        expect(oldPeer.agentStarts, isEmpty);
        expect(
          oldPeer.calls.where((c) => c.startsWith('agent/continue')),
          isEmpty,
        );
        expect(agents(rig).linkOf(pane), same(link));
        expect(link.sessionId, saved);
        expect(link.saved, true);
        expect(link.prompt.text, 'preserve saved draft');
        expect(link.errorCode, ErrorCode.methodNotAvailable);
        expect(find.textContaining('Codex requires'), findsOneWidget);
      },
    );
  }
  uiTest('Codex: future runtime kind remains visible and read only', (
    tester,
  ) async {
    final host = nativeHost();
    const future = RuntimeProfile(
      id: 'future',
      name: 'Future runtime',
      runtimeKind: 'future-native',
      executable: '/future',
    );
    host.runtimes = const RuntimeListResult(
      profiles: [future],
      defaultId: 'future',
      defaultAvailable: false,
    );
    await pumpRig(tester, host);
    await tester.tap(key('add-tab'));
    await tester.pumpAndSettle();
    await tester.tap(key('runtime-profiles'));
    await flush(tester);
    await tester.tap(key('runtime-edit-future'));
    await flush(tester);
    expect(tester.takeException(), isNull);
    expect(
      find.textContaining('Unsupported runtime kind: future-native'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(key('runtime-kind'))
          .onChanged,
      isNull,
    );
    expect(
      tester.widget<FilledButton>(key('runtime-profile-save')).onPressed,
      isNull,
    );
    expect(host.runtimes.profiles.single.runtimeKind, 'future-native');
    expect(host.calls.where((c) => c.startsWith('runtime/save')), isEmpty);
  });
  for (final reason in [ErrorCode.busy, ErrorCode.invalidParams]) {
    uiTest(
      'Codex: refused question remains editable for explicit retry $reason',
      (tester) async {
        final host = nativeHost();
        final rig = await nativeChat(tester, host);
        running(host, session(rig));
        host.questionSource.add(question(session(rig), secret: true));
        await flush(tester);
        final field = key('question-text-question-q');
        final submit = key('question-submit-question');
        await tester.enterText(field, 'private original');
        await tester.pump();
        host.questionError = RpcException(
          reason,
          reason == ErrorCode.busy
              ? 'native input queue full'
              : 'answer exceeds input limit',
        );
        await tester.tap(submit);
        await flush(tester);
        expect(host.questionAnswers, hasLength(1));
        final input = tester.widget<TextField>(field);
        expect(input.enabled, true);
        expect(input.obscureText, true);
        expect(input.controller!.text, 'private original');
        expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
        expect(
          find.textContaining(
            reason == ErrorCode.busy
                ? 'native input queue full'
                : 'answer exceeds input limit',
          ),
          findsOneWidget,
        );
        await flush(tester);
        expect(host.questionAnswers, hasLength(1));
        host.questionError = null;
        await tester.enterText(field, 'corrected private answer');
        await tester.pump();
        await tester.tap(submit);
        await flush(tester);
        expect(host.questionAnswers, hasLength(2));
        expect(host.questionAnswers.last.answers.single.values, [
          'corrected private answer',
        ]);
        expect(tester.widget<FilledButton>(submit).onPressed, isNull);
        expect(
          agents(rig).linkOf(chat(rig).id)!.transcript.plainText,
          isNot(contains('private')),
        );
        host.questionResolvedSource.add(
          AgentQuestionResolvedParams(
            sessionId: session(rig),
            seq: 4,
            runId: 'run',
            turnId: 'turn',
            requestId: 'question',
            outcome: AgentQuestionOutcome.answered,
          ),
        );
        await flush(tester);
        expect(field, findsNothing);
      },
    );
  }
  uiTest('Codex: pending and unknown question answer never claims admission', (
    tester,
  ) async {
    final host = nativeHost();
    final rig = await nativeChat(tester, host);
    running(host, session(rig));
    host.questionSource.add(question(session(rig), secret: true));
    await flush(tester);
    await tester.enterText(key('question-text-question-q'), 'private answer');
    await tester.pump();
    host.questionGate = Completer<void>();
    host.questionError = TimeoutException('answer outcome lost');
    await tester.tap(key('question-submit-question'));
    await flush(tester);
    expect(host.questionAnswers, hasLength(1));
    expect(find.textContaining('admitted'), findsNothing);
    expect(find.text('Waiting for answer outcome'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(key('question-submit-question')).onPressed,
      isNull,
    );
    host.questionGate!.complete();
    await flush(tester);
    expect(find.textContaining('Answer outcome unknown'), findsOneWidget);
    expect(find.text('Answer unavailable'), findsOneWidget);
    expect(find.textContaining('admitted'), findsNothing);
    expect(find.textContaining('completed'), findsNothing);
    expect(host.questionAnswers, hasLength(1));
  });
  uiTest('Codex: Continue selects a compatible replacement profile', (
    tester,
  ) async {
    final host = nativeHost();
    final rig = await nativeContinuePicker(tester, host);
    expect(key('runtime-profile-picker'), findsOneWidget);
    expect(key('pick-runtime-replacement'), findsOneWidget);
    expect(key('pick-runtime-claude'), findsNothing);
    await tester.tap(key('pick-runtime-replacement'));
    await flush(tester);
    expect(host.runtimes.defaultId, 'claude');
    expect(host.agentContinues.map((p) => p.runtimeProfileId), [
      null,
      'replacement',
    ]);
    expect(host.agentStarts, hasLength(1));
    expect(agents(rig).linkOf(chat(rig).id)!.prompt.text, 'saved draft');
  });
  for (final choice in ['cancel', 'disappeared', 'foreign-kind']) {
    uiTest('Codex: Continue picker preserves saved draft on $choice', (
      tester,
    ) async {
      final host = nativeHost();
      final rig = await nativeContinuePicker(tester, host);
      final pane = chat(rig).id;
      final link = agents(rig).linkOf(pane)!;
      final saved = link.sessionId;
      expect(key('runtime-profile-picker'), findsOneWidget);
      if (choice == 'cancel') {
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      } else {
        host.runtimes = RuntimeListResult(
          profiles: [
            pickerClaude,
            if (choice == 'foreign-kind')
              const RuntimeProfile(
                id: 'replacement',
                name: 'Changed kind',
                runtimeKind: 'claude-code',
                executable: '/foreign',
              ),
          ],
          defaultId: 'claude',
          defaultAvailable: true,
        );
        await tester.tap(key('pick-runtime-replacement'));
      }
      await flush(tester);
      expect(host.agentContinues, hasLength(1));
      expect(host.agentContinues.single.runtimeProfileId, isNull);
      expect(host.agentStarts, hasLength(1));
      expect(host.runtimes.defaultId, 'claude');
      expect(agents(rig).linkOf(pane), same(link));
      expect(link.sessionId, saved);
      expect(link.saved, true);
      expect(link.prompt.text, 'saved draft');
      expect(link.transcript.plainText, contains('retained transcript'));
      if (choice != 'cancel') {
        expect(link.errorCode, ErrorCode.noRuntimeProfile);
      }
    });
  }
  uiTest('Codex: Codex launcher', (tester) async {
    final host = nativeHost();
    host.runtimes = const RuntimeListResult(
      profiles: [codexProfile],
      defaultId: 'native',
      defaultAvailable: true,
    );
    final rig = await pumpRig(tester, host);
    await tester.tap(key('add-tab'));
    await tester.pumpAndSettle();
    expect(key('launch-codex'), findsOneWidget);
    await tester.tap(key('launch-codex'));
    await flush(tester);
    expect(host.agentStarts.single.workspaceId, 'A');
    expect(host.agentStarts.single.runtimeKind, 'codex');
    expect(host.agentStarts.single.runtimeProfileId, 'native');
    expect(agents(rig).linkOf(chat(rig).id)!.runtimeName, 'Native test');
  });

  uiTest('Codex: native profile kind survives editing', (tester) async {
    final host = agentHost();
    host.runtimes = const RuntimeListResult(
      profiles: [codexProfile],
      defaultId: 'native',
      defaultAvailable: true,
    );
    await pumpRig(tester, host);
    await tester.tap(key('add-tab'));
    await tester.pumpAndSettle();
    await tester.tap(key('runtime-profiles'));
    await flush(tester);
    await tester.tap(key('runtime-edit-native'));
    await flush(tester);
    await tester.tap(key('runtime-profile-save'));
    await flush(tester);
    expect(host.runtimes.profiles.single.runtimeKind, 'codex');
  });
}
