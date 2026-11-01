import 'package:domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:host_protocol/host_protocol.dart';

import 'support/fake_host.dart';
import 'support/workbench_support.dart';

void main() {
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
