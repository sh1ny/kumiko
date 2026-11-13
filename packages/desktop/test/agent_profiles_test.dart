import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:host_protocol/host_protocol.dart';

import 'agent_test.dart'
    show agentCapabilities, agentHost, agents, chat, session;
import 'support/fake_host.dart';
import 'support/workbench_support.dart';

Future<void> editor(WidgetTester tester) async {
  await tester.tap(key('add-tab'));
  await tester.pumpAndSettle();
  await tester.tap(key('runtime-profiles'));
  await flush(tester);
}

const _originalRuntime = RuntimeProfile(
  id: 'P',
  name: 'Original runtime',
  runtimeKind: 'claude-code',
  executable: '/original-adapter',
);
const _currentRuntime = RuntimeProfile(
  id: 'Q',
  name: 'Current runtime',
  runtimeKind: 'claude-code',
  executable: '/current-adapter',
);

/// Enforces the host's profile-selection contract instead of accepting a
/// deleted explicit id, and retains the immutable launch behind each saved id.
class _RecoveryProfileHost extends FakeHostLink {
  _RecoveryProfileHost({Set<String> extra = const {}})
    : super(
        hello: helloResult(capabilities: {...agentCapabilities, ...extra}),
      ) {
    records.addAll([workspaceRecord('A'), workspaceRecord('B')]);
    storedLayout = jsonOf(docOf([], selected: 'A'));
    runtimes = const RuntimeListResult(
      profiles: [_originalRuntime, _currentRuntime],
      defaultAvailable: true,
      defaultId: 'P',
    );
  }

  final savedLaunches = <String, AgentStartParams>{};

  @override
  Future<AgentStartResult> startAgent(AgentStartParams params) async {
    final wanted =
        params.runtimeProfileId ??
        (runtimes.defaultAvailable ? runtimes.defaultId : null);
    final profile = runtimes.profiles.where((p) => p.id == wanted).firstOrNull;
    if (profile == null) {
      agentStartAnswers.addFirst(
        RpcException(
          ErrorCode.noRuntimeProfile,
          'The requested runtime profile is unavailable.',
        ),
      );
    }
    final result = await super.startAgent(params);
    savedLaunches[result.sessionId] = AgentStartParams(
      workspaceId: params.workspaceId,
      runtimeProfileId: profile!.id,
    );
    return result;
  }
}

Future<Rig> _endedProfileChat(
  WidgetTester tester,
  _RecoveryProfileHost host,
) async {
  final rig = await pumpRig(tester, host);
  await rig.controller.launchAgent(profileId: 'P');
  await flush(tester);
  expect(agents(rig).linkOf(chat(rig).id)!.canSend, isTrue);
  host.agentExit(session(rig), reason: AgentExitReason.ended);
  await flush(tester);
  return rig;
}

Future<void> _continueUnavailable(WidgetTester tester, Rig rig) async {
  rig.link.agentContinueAnswers.add(
    resumeUnavailable('history-unavailable', detail: 'saved history is gone'),
  );
  await tester.tap(key('agent-continue-${chat(rig).id}'));
  await flush(tester);
  expect(find.textContaining('history-unavailable'), findsOneWidget);
}

void main() {
  uiTest(
    'fresh recovery replaces deleted runtime with current default in the same workspace',
    (tester) async {
      final host = _RecoveryProfileHost();
      final rig = await _endedProfileChat(tester, host);
      final pane = chat(rig).id;
      final old = session(rig);
      final saved = host.savedLaunches[old]!;
      await rig.controller.removeRuntimeProfile('P');
      await rig.controller.setDefaultRuntimeProfile('Q');
      await _continueUnavailable(tester, rig);
      rig.controller.selectWorkspace('B');

      await tester.tap(key('agent-new-$pane'));
      await flush(tester);

      final recovered = agents(rig).linkOf(pane)!;
      expect(recovered.statusLabel, 'Idle');
      expect(recovered.canSend, isTrue);
      expect(recovered.sessionId, isNot(old));
      expect(recovered.workspaceId, 'A');
      expect(
        rig.layout.panes.where((p) => p.kind == 'agent-chat'),
        hasLength(1),
      );
      expect(host.savedLaunches[recovered.sessionId]!.runtimeProfileId, 'Q');
      expect(host.savedLaunches[old], same(saved));
      expect(saved.runtimeProfileId, 'P');
      expect(saved.workspaceId, 'A');
      expect(host.agentRecordMap[old]!.known, isTrue);
      expect(host.agentCloses, isNot(contains(old)));
      await tester.enterText(key('agent-prompt-$pane'), 'new conversation');
      await tester.tap(key('agent-send-$pane'));
      await flush(tester);
      expect(host.agentPrompts.single.sessionId, recovered.sessionId);
      expect(host.agentPrompts.single.text, 'new conversation');
    },
  );

  uiTest(
    'fresh recovery retains an existing explicit runtime despite a new default',
    (tester) async {
      final host = _RecoveryProfileHost();
      final rig = await _endedProfileChat(tester, host);
      final pane = chat(rig).id;
      final old = session(rig);
      final saved = host.savedLaunches[old]!;
      await rig.controller.setDefaultRuntimeProfile('Q');
      await _continueUnavailable(tester, rig);

      await tester.tap(key('agent-new-$pane'));
      await flush(tester);

      final recovered = agents(rig).linkOf(pane)!;
      expect(recovered.statusLabel, 'Idle');
      expect(recovered.sessionId, isNot(old));
      expect(host.savedLaunches[recovered.sessionId]!.runtimeProfileId, 'P');
      expect(host.savedLaunches[old], same(saved));
      expect(key('runtime-profile-picker'), findsNothing);
    },
  );

  uiTest(
    'fresh recovery with a deleted runtime and missing default requires an explicit picker choice',
    (tester) async {
      final host = _RecoveryProfileHost();
      final rig = await _endedProfileChat(tester, host);
      final pane = chat(rig).id;
      final old = session(rig);
      final original = agents(rig).linkOf(pane)!;
      final saved = host.savedLaunches[old]!;
      await rig.controller.removeRuntimeProfile('P');
      await _continueUnavailable(tester, rig);
      original.prompt.text = 'keep my unsent recovery draft';
      rig.controller.selectWorkspace('B');

      await tester.tap(key('agent-new-$pane'));
      await flush(tester);

      expect(key('runtime-profile-picker'), findsOneWidget);
      expect(key('pick-runtime-Q'), findsOneWidget);
      expect(host.agentStarts, hasLength(1));
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await flush(tester);
      expect(agents(rig).linkOf(pane), same(original));
      expect(session(rig), old);
      expect(original.prompt.text, 'keep my unsent recovery draft');
      expect(host.savedLaunches[old], same(saved));

      await tester.tap(key('agent-new-$pane'));
      await flush(tester);
      await tester.tap(key('pick-runtime-Q'));
      await flush(tester);
      final recovered = agents(rig).linkOf(pane)!;
      expect(recovered.statusLabel, 'Idle');
      expect(recovered.workspaceId, 'A');
      expect(recovered.sessionId, isNot(old));
      expect(host.savedLaunches[recovered.sessionId]!.runtimeProfileId, 'Q');
      expect(
        rig.layout.panes.where((p) => p.kind == 'agent-chat'),
        hasLength(1),
      );
      expect(host.savedLaunches[old], same(saved));
    },
  );

  uiTest(
    'fresh recovery refuses a picker choice deleted while the picker is open',
    (tester) async {
      final host = _RecoveryProfileHost();
      final rig = await _endedProfileChat(tester, host);
      final pane = chat(rig).id;
      final old = session(rig);
      final saved = host.savedLaunches[old]!;
      final original = agents(rig).linkOf(pane)!;
      await rig.controller.removeRuntimeProfile('P');
      await _continueUnavailable(tester, rig);
      original.prompt.text = 'do not discard this draft';
      await tester.tap(key('agent-new-$pane'));
      await flush(tester);
      expect(key('runtime-profile-picker'), findsOneWidget);
      await rig.controller.saveRuntimeProfile(
        const RuntimeProfile(
          id: 'R',
          name: 'Different default',
          runtimeKind: 'claude-code',
          executable: '/different-adapter',
        ),
      );
      await rig.controller.removeRuntimeProfile('Q');
      await rig.controller.setDefaultRuntimeProfile('R');

      await tester.tap(key('pick-runtime-Q'));
      await flush(tester);

      expect(agents(rig).linkOf(pane), same(original));
      expect(original.errorCode, ErrorCode.noRuntimeProfile);
      expect(
        find.textContaining('selected runtime profile is unavailable'),
        findsOneWidget,
      );
      expect(original.prompt.text, 'do not discard this draft');
      expect(session(rig), old);
      expect(host.agentStarts, hasLength(1));
      expect(host.savedLaunches[old], same(saved));
    },
  );

  uiTest(
    'fresh recovery without any runtime offers configuration without discarding the saved chat',
    (tester) async {
      final host = _RecoveryProfileHost();
      final rig = await _endedProfileChat(tester, host);
      final pane = chat(rig).id;
      final old = session(rig);
      final original = agents(rig).linkOf(pane)!;
      final saved = host.savedLaunches[old]!;
      await rig.controller.removeRuntimeProfile('P');
      await rig.controller.removeRuntimeProfile('Q');
      await _continueUnavailable(tester, rig);

      await tester.tap(key('agent-new-$pane'));
      await flush(tester);

      expect(key('no-runtime-profile-prompt'), findsOneWidget);
      expect(host.agentStarts, hasLength(1));
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await flush(tester);
      expect(agents(rig).linkOf(pane), same(original));
      expect(session(rig), old);
      expect(host.savedLaunches[old], same(saved));
      await tester.tap(key('agent-new-$pane'));
      await flush(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Add profile'));
      await flush(tester);
      expect(key('runtime-profiles-dialog'), findsOneWidget);
      expect(key('runtime-profile-executable'), findsOneWidget);
      expect(host.agentStarts, hasLength(1));
      expect(host.savedLaunches[old], same(saved));
    },
  );

  uiTest(
    'recovery without any runtime keeps the saved Codex kind in its guidance',
    (tester) async {
      final host = _RecoveryProfileHost(
        extra: {Capability.codex, Capability.agentExtensionsV1},
      );
      final rig = await _endedProfileChat(tester, host);
      final pane = chat(rig).id;
      await rig.controller.removeRuntimeProfile('P');
      await rig.controller.removeRuntimeProfile('Q');
      await _continueUnavailable(tester, rig);
      // The saved conversation is a Codex one.
      agents(rig).linkOf(pane)!.runtimeKind = 'codex';

      await tester.tap(key('agent-new-$pane'));
      await flush(tester);

      expect(key('no-runtime-profile-prompt'), findsOneWidget);
      expect(find.textContaining('Install Codex CLI'), findsOneWidget);
      expect(find.textContaining('claude-agent-acp'), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await flush(tester);
    },
  );

  uiTest(
    'fresh recovery Retry reselects a deleted runtime and preserves the draft',
    (tester) async {
      final host = _RecoveryProfileHost();
      final rig = await _endedProfileChat(tester, host);
      final pane = chat(rig).id;
      final old = session(rig);
      final saved = host.savedLaunches[old]!;
      await rig.controller.removeRuntimeProfile('P');
      await rig.controller.setDefaultRuntimeProfile('Q');
      await _continueUnavailable(tester, rig);
      host.agentStartAnswers.add(
        RpcException(ErrorCode.authRequired, 'native authentication required'),
      );
      await tester.tap(key('agent-new-$pane'));
      await flush(tester);
      expect(agents(rig).linkOf(pane)!.canRetry, isTrue);
      await tester.enterText(
        key('agent-prompt-$pane'),
        'retry draft stays unsent',
      );
      await rig.controller.saveRuntimeProfile(
        const RuntimeProfile(
          id: 'R',
          name: 'Replacement runtime',
          runtimeKind: 'claude-code',
          executable: '/replacement-adapter',
        ),
      );
      await rig.controller.removeRuntimeProfile('Q');
      await rig.controller.setDefaultRuntimeProfile('R');

      await tester.tap(key('agent-retry-$pane'));
      await flush(tester);

      final recovered = agents(rig).linkOf(pane)!;
      expect(recovered.statusLabel, 'Idle');
      expect(recovered.prompt.text, 'retry draft stays unsent');
      expect(recovered.workspaceId, 'A');
      expect(host.savedLaunches[recovered.sessionId]!.runtimeProfileId, 'R');
      expect(host.agentPrompts, isEmpty);
      expect(host.savedLaunches[old], same(saved));
    },
  );

  uiTest(
    'runtime editor validates argv profiles adds edits sets default and removes',
    (tester) async {
      final host = agentHost();
      await pumpRig(tester, host);
      await editor(tester);
      await tester.tap(key('add-runtime-profile'));
      await tester.pump();
      expect(
        find.textContaining('@agentclientprotocol/claude-agent-acp@<version>'),
        findsOneWidget,
      );
      await tester.tap(key('runtime-profile-save'));
      await tester.pump();
      expect(find.text('The executable is required.'), findsOneWidget);
      await tester.enterText(key('runtime-profile-name'), 'My runtime');
      await tester.enterText(key('runtime-profile-executable'), 'node');
      await tester.enterText(
        key('runtime-profile-args'),
        '/path with spaces/adapter.js\n--setting="a b"',
      );
      await tester.enterText(key('runtime-profile-env'), 'LOCAL_ONLY=value');
      await tester.tap(key('runtime-profile-save'));
      await flush(tester);
      final profile = host.runtimes.profiles.last;
      expect(profile.args, ['/path with spaces/adapter.js', '--setting="a b"']);
      expect(profile.env, {'LOCAL_ONLY': 'value'});
      expect(profile.runtimeKind, 'claude-code');
      await tester.tap(key('runtime-set-default-${profile.id}'));
      await flush(tester);
      expect(host.runtimes.defaultId, profile.id);
      await tester.tap(key('runtime-edit-${profile.id}'));
      await tester.pump();
      await tester.enterText(key('runtime-profile-name'), 'Edited runtime');
      await tester.tap(key('runtime-profile-save'));
      await flush(tester);
      expect(host.runtimes.profiles.last.name, 'Edited runtime');
      await tester.tap(key('runtime-remove-${profile.id}'));
      await flush(tester);
      expect(host.runtimes.profiles.any((p) => p.id == profile.id), isFalse);
    },
  );

  uiTest(
    'built-ins are read only; copy preserves unrepresentable exact argv and env',
    (tester) async {
      final host = agentHost();
      host.runtimes = const RuntimeListResult(
        profiles: [
          RuntimeProfile(
            id: 'builtin:claude',
            name: 'Claude Code',
            runtimeKind: 'claude-code',
            executable: '/node',
            args: ['', 'line\nbreak'],
            env: {'VALUE': 'one\ntwo'},
          ),
        ],
        defaultAvailable: true,
        defaultId: 'builtin:claude',
      );
      await pumpRig(tester, host);
      await editor(tester);
      expect(key('runtime-edit-builtin:claude'), findsNothing);
      expect(key('runtime-remove-builtin:claude'), findsNothing);
      await tester.tap(key('runtime-copy-builtin:claude'));
      await tester.pump();
      expect(
        tester.widget<TextField>(key('runtime-profile-args')).readOnly,
        isTrue,
      );
      expect(
        tester.widget<TextField>(key('runtime-profile-env')).readOnly,
        isTrue,
      );
      await tester.tap(key('runtime-profile-save'));
      await flush(tester);
      final copy = host.runtimes.profiles.last;
      expect(copy.isBuiltin, isFalse);
      expect(copy.args, ['', 'line\nbreak']);
      expect(copy.env, {'VALUE': 'one\ntwo'});
      expect(copy.name, 'Claude Code copy');
    },
  );
}
