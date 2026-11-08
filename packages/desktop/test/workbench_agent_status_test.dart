import 'package:domain/domain.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:host_protocol/host_protocol.dart';

import 'support/fake_host.dart';
import 'support/workbench_support.dart';

void main() {
  uiTest('chat pane shows each Kumiko tools status line', (tester) async {
    final host = linkWith(
      docOf([], selected: 'A'),
      records: [workspaceRecord('A')],
      hello: helloResult(
        capabilities: {
          Capability.workbench,
          Capability.terminal,
          Capability.agent,
        },
      ),
    );
    final rig = await pumpRig(tester, host);
    await rig.controller.launchAgent();
    await flush(tester);
    final pane = rig.layout.active!.panes.single.id;
    final session = rig.controller.agents.linkOf(pane)!.sessionId!;
    final line = find.byKey(Key('agent-tools-$pane'));
    var seq = 0;
    for (final (tools, text) in [
      (
        const AgentTools(AgentToolsStatus.notYetUsed),
        'Kumiko tools: not yet used',
      ),
      (const AgentTools(AgentToolsStatus.connected), 'Kumiko tools: connected'),
      (
        const AgentTools(AgentToolsStatus.notStarted),
        'Kumiko tools: not started by the adapter',
      ),
      (
        const AgentTools(
          AgentToolsStatus.unavailable,
          reason: 'endpoint-unavailable: path too long',
        ),
        'Kumiko tools unavailable: endpoint-unavailable: path too long',
      ),
      (
        const AgentTools(
          AgentToolsStatus.unavailable,
          reason: 'for claude-agent-acp 0.99.1: no MCP server started',
        ),
        'Kumiko tools unavailable for claude-agent-acp 0.99.1: '
            'no MCP server started',
      ),
    ]) {
      host.agentState(session, AgentState.idle, ++seq, tools);
      await tester.pump();
      expect(
        tester.widget<Text>(line).data,
        text,
        reason: 'status ${tools.status.name}',
      );
    }
  });

  uiTest('no tools line before the host reports a status', (tester) async {
    final host = linkWith(
      docOf([], selected: 'A'),
      records: [workspaceRecord('A')],
      hello: helloResult(
        capabilities: {
          Capability.workbench,
          Capability.terminal,
          Capability.agent,
        },
      ),
    );
    final rig = await pumpRig(tester, host);
    await rig.controller.launchAgent();
    await flush(tester);
    final pane = rig.layout.active!.panes.single.id;
    expect(find.byKey(Key('agent-tools-$pane')), findsNothing);
  });

  uiTest(
    'inactive split tab reports later agent activity and failure over first idle agent',
    (tester) async {
      final host = linkWith(
        docOf([
          tabOf('overview', overviewOf('overview-pane', 'A')),
        ], selected: 'A'),
        records: [workspaceRecord('A')],
        hello: helloResult(
          capabilities: {
            Capability.workbench,
            Capability.terminal,
            Capability.agent,
          },
        ),
      );
      final rig = await pumpRig(tester, host);
      await rig.controller.launchAgent();
      await flush(tester);
      final first = rig.layout.active!.panes.single;
      final splitTab = rig.layout.activeTab!;
      final firstSession = rig.controller.agents.linkOf(first.id)!.sessionId!;
      await rig.controller.launchAgent();
      await flush(tester);
      final second = rig.layout.active!.panes.single;
      final secondTab = rig.layout.activeTab!;
      final secondSession = rig.controller.agents.linkOf(second.id)!.sessionId!;

      rig.controller.activateTab(splitTab);
      rig.controller.moveTabIntoSplit(secondTab, SplitDirection.horizontal);
      rig.controller.activateTab('overview');
      await flush(tester);
      expect(rig.layout.tab(splitTab)!.panes.map((pane) => pane.id), [
        first.id,
        second.id,
      ]);
      expect(rig.controller.agents.linkOf(first.id)!.statusLabel, 'Idle');
      final badge = 'tab-agent-status-$splitTab';
      expect(inside(badge, find.text('Idle')), findsOneWidget);

      var seq = 0;
      for (final (state, label) in [
        (AgentState.running, 'Running'),
        (AgentState.stopping, 'Stopping'),
        (AgentState.failed, 'Failed'),
      ]) {
        host.agentState(secondSession, state, ++seq);
        await tester.pump();
        expect(
          inside(badge, find.text(label)),
          findsOneWidget,
          reason: '$label in a later pane must not be masked by Idle',
        );
        expect(inside(badge, find.text('Idle')), findsNothing);
        expect(rig.layout.activeTab, 'overview');
      }

      // Approval stays visible even when another contained session failed.
      host.agentState(firstSession, AgentState.waitingApproval);
      await tester.pump();
      expect(inside(badge, find.text('Waiting for approval')), findsOneWidget);
      expect(rig.layout.activeTab, 'overview');

      // The aggregate must depend on urgency, not the order of the panes.
      host.agentState(firstSession, AgentState.failed, 2);
      host.agentState(secondSession, AgentState.running, ++seq);
      await tester.pump();
      expect(inside(badge, find.text('Failed')), findsOneWidget);
      expect(rig.layout.activeTab, 'overview');
    },
  );
}
