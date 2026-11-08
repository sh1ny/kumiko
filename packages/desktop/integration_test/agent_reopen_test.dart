import 'dart:convert';
import 'dart:io';

import 'package:desktop/src/terminal/alacritty_surface.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:host_protocol/host_protocol.dart';

import 'support/agent_harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AlacrittySurface.init);

  testWidgets(
    'fresh recovery uses current runtime after the original profile is deleted',
    (tester) async {
      final harness = AgentHarness(
        Directory.systemTemp.createTempSync('kumiko-agent-profile-recovery-'),
      );
      addTearDown(harness.dispose);
      await harness.launch(tester);
      await harness.configure(tester);
      final pane = await harness.newChat(tester);
      final c = harness.controller(tester);
      final original = harness.agents(tester).linkOf(pane)!;
      final old = original.sessionId!;
      final workspace = original.workspaceId;
      await tester.runAsync(() => harness.link!.closeAgent(old));
      await harness.until(
        tester,
        () => original.canContinue,
        'original chat ended and released',
      );
      await tester.runAsync(() async {
        await c.saveRuntimeProfile(
          RuntimeProfile(
            id: 'replacement-profile',
            name: 'Replacement ACP',
            runtimeKind: 'claude-code',
            executable: harness.host,
            args: const ['--test-fixture', 'acp-agent'],
            env: {
              'KUMIKO_TEST_ACP_SCRIPT': jsonEncode({
                'agentCapabilities': <String, Object?>{},
                'prompt': [
                  {
                    'update': {
                      'sessionUpdate': 'agent_message_chunk',
                      'content': {
                        'type': 'text',
                        'text': 'replacement runtime answered',
                      },
                    },
                  },
                ],
              }),
            },
          ),
        );
        await c.removeRuntimeProfile('fixture-profile');
        await c.setDefaultRuntimeProfile('replacement-profile');
      });
      await tester.pump();
      await tester.tap(find.byKey(Key('agent-continue-$pane')));
      await harness.until(
        tester,
        () =>
            original.canNewSession &&
            original.errorCode == ErrorCode.resumeUnavailable,
        'current runtime cannot recover old history',
      );

      await tester.tap(find.byKey(Key('agent-new-$pane')));
      await harness.until(
        tester,
        () => harness.agents(tester).linkOf(pane)!.canSend,
        'fresh chat started with replacement runtime',
      );
      final recovered = harness.agents(tester).linkOf(pane)!;
      expect(recovered.sessionId, isNot(old));
      expect(recovered.workspaceId, workspace);
      expect(
        c.layout!.panes.where((p) => p.kind == 'agent-chat'),
        hasLength(1),
      );
      final records = await tester.runAsync(
        () => harness.link!.agentRecords([old]),
      );
      expect(records!.records[old]!.known, isTrue);
      await tester.enterText(
        find.byKey(Key('agent-prompt-$pane')),
        'confirm replacement is live',
      );
      await tester.tap(find.byKey(Key('agent-send-$pane')));
      await harness.until(
        tester,
        () => find
            .textContaining('replacement runtime answered')
            .evaluate()
            .isNotEmpty,
        'replacement runtime serves the recovered pane',
      );
      await harness.quit(tester);
    },
  );

  testWidgets(
    'three saved chats and terminal split reopen unchanged with no agent unit; explicit Continue loads history',
    (tester) async {
      final harness = AgentHarness(
        Directory.systemTemp.createTempSync('kumiko-agent-reopen-'),
      );
      addTearDown(harness.dispose);
      await harness.launch(tester);
      await harness.configure(tester);
      final panes = <String>[];
      for (var i = 0; i < 3; i++) {
        panes.add(await harness.newChat(tester));
      }
      final c = harness.controller(tester);
      final ids = {
        for (final pane in panes)
          pane: harness.agents(tester).linkOf(pane)!.sessionId,
      };
      await tester.runAsync(
        () => c.splitWithTerminal(panes.last, SplitDirection.horizontal),
      );
      await tester.pump();
      final split = c.layout!.active!.root as SplitNode;
      c.setRatio(split.id, 0.37);
      await tester.pump();
      final before = layoutToJson(c.layout!);
      await harness.quit(tester);
      await harness.launch(tester);
      final reopened = harness.controller(tester);
      await harness.until(
        tester,
        () => panes.every(
          (id) =>
              harness.agents(tester).linkOf(id)?.statusLabel ==
              'Saved, not running',
        ),
        'all saved records resolved',
      );
      expect(layoutToJson(reopened.layout!), before);
      expect(reopened.layout!.splitNode(split.id)!.ratio, 0.37);
      for (final pane in panes) {
        expect(harness.agents(tester).linkOf(pane)!.sessionId, ids[pane]);
        expect(
          harness.agents(tester).linkOf(pane)!.transcript.entries,
          isEmpty,
        );
      }
      expect(find.textContaining('Ended, not restored'), findsOneWidget);
      expect(harness.agentUnits(), isEmpty);
      final pane = panes.last;
      await tester.tap(find.byKey(Key('agent-continue-$pane')));
      await harness.until(
        tester,
        () =>
            harness.agents(tester).linkOf(pane)!.statusLabel == 'Idle' &&
            find.textContaining('loaded history').evaluate().isNotEmpty,
        'explicit load replay',
      );
      expect(find.textContaining('saved question'), findsWidgets);
      expect(harness.agentUnits(), hasLength(1));
      expect(
        harness.agents(tester).linkOf(panes.first)!.statusLabel,
        'Saved, not running',
      );
      await harness.quit(tester);
    },
  );
}
