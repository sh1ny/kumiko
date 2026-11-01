import 'dart:io';

import 'package:desktop/src/terminal/alacritty_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:integration_test/integration_test.dart';

import 'support/agent_harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AlacrittySurface.init);

  testWidgets(
    'real app streams tool activity answers permission stops and confirms close',
    (tester) async {
      final harness = AgentHarness(
        Directory.systemTemp.createTempSync('kumiko-agent-'),
      );
      addTearDown(harness.dispose);
      await harness.launch(tester);
      await harness.configure(tester);
      final pane = await harness.newChat(tester);
      final c = harness.controller(tester);
      final link = harness.agents(tester).linkOf(pane)!;
      await tester.enterText(
        find.byKey(Key('agent-prompt-$pane')),
        'make the fixture change',
      );
      await tester.tap(find.byKey(Key('agent-send-$pane')));
      await harness.until(
        tester,
        () => find.text('Allow').evaluate().isNotEmpty,
        'permission card',
      );
      expect(find.textContaining('streamed fixture reply'), findsWidgets);
      expect(find.textContaining('Edit fixture.txt'), findsWidgets);
      expect(
        link.transcript.entries
            .where((entry) => entry.kind == AgentEventKind.user)
            .map((entry) => entry.text),
        ['make the fixture change'],
      );
      expect(find.text('make the fixture change'), findsOneWidget);
      final requestId = link.permissions.last.request.requestId;
      await tester.tap(
        find.byKey(Key('agent-option-$pane-$requestId-allow-once')),
      );
      await harness.until(
        tester,
        () =>
            link.statusLabel == 'Running' &&
            find.textContaining('new').evaluate().isNotEmpty,
        'tool completion after explicit permission',
      );
      await tester.tap(find.byKey(Key('agent-stop-$pane')));
      await harness.until(
        tester,
        () => link.statusLabel == 'Idle' && link.stopLabel == 'Stopped',
        'Stop result',
      );
      // A second running turn proves the native confirmation flow too.
      await tester.enterText(
        find.byKey(Key('agent-prompt-$pane')),
        'another turn',
      );
      await tester.tap(find.byKey(Key('agent-send-$pane')));
      await harness.until(
        tester,
        () => link.statusLabel == 'Waiting for approval',
        'running turn',
      );
      expect(
        link.transcript.entries
            .where((entry) => entry.kind == AgentEventKind.user)
            .map((entry) => entry.text),
        ['make the fixture change', 'another turn'],
      );
      expect(find.text('another turn'), findsOneWidget);
      await tester.tap(find.byKey(Key('close-pane-$pane')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Are you sure you want to stop the running agent?'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('close-warning-confirm')));
      await harness.until(
        tester,
        () => c.layout!.pane(pane) == null,
        'confirmed close exit',
      );
      expect(harness.agentUnits(), isEmpty);
      await harness.quit(tester);
    },
  );
}
