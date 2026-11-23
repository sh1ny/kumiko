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

FakeHostLink _host({bool supportsOmp = true}) {
  final host = FakeHostLink(
    hello: helloResult(
      capabilities: {
        Capability.workbench,
        Capability.terminal,
        Capability.agent,
        if (supportsOmp) Capability.omp,
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

  uiTest('OMP: Continue on a saved OMP session', (tester) async {
    const reason = 'OMP Continue is not supported in this Kumiko version';
    final host = _host();
    final rig = await _chat(tester, host);
    host.agentExit(session(rig));
    await flush(tester);
    agents(rig).linkOf(chat(rig).id)!.saved = true;
    host.agentContinueAnswers.add(
      RpcException(ErrorCode.methodNotAvailable, reason),
    );
    await tester.tap(key('agent-continue-${chat(rig).id}'));
    await flush(tester);
    expect(find.textContaining(reason), findsOneWidget);
    expect(host.agentStarts, hasLength(1));
  });
}
