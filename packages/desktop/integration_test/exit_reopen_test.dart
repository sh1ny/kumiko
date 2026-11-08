import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:desktop/src/terminal/alacritty_surface.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/agent_harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AlacrittySurface.init);

  testWidgets('stopped panes reopen in place with the layout', (tester) async {
    final harness = AgentHarness(
      Directory.systemTemp.createTempSync('kumiko-exit-reopen-'),
    );
    addTearDown(harness.dispose);
    await harness.launch(tester);
    await harness.configure(tester);
    final first = await harness.newChat(tester);
    final second = await harness.newChat(tester);
    final c = harness.controller(tester);
    final link = harness.agents(tester).linkOf(first)!;

    // A running turn (waiting for a permission reply) in the first chat.
    await tester.runAsync(
      () => harness.agents(tester).send(first, 'make the fixture change'),
    );
    await harness.until(
      tester,
      () => link.statusLabel == 'Waiting for approval',
      'running turn',
    );
    await tester.pump();
    final before = layoutToJson(c.layout!);

    final request = await harness.requestQuit(tester);
    expect(find.byKey(Key('exit-item-$first')), findsOneWidget);
    expect(find.byKey(Key('exit-item-$second')), findsNothing);

    // Stopping the only listed item ends the dialog and quits.
    await tester.tap(find.byKey(Key('exit-stop-$first')));
    await harness.until(
      tester,
      () =>
          find.byKey(const Key('exit-dialog')).evaluate().isEmpty ||
          link.statusLabel != 'Waiting for approval',
      'the stop to take effect',
    );
    expect(await request.answer, AppExitResponse.exit);
    await tester.pumpWidget(const SizedBox());
    harness.link = null;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );

    await harness.launch(tester);
    final reopened = harness.controller(tester);
    await harness.until(
      tester,
      () => [first, second].every(
        (id) =>
            harness.agents(tester).linkOf(id)?.statusLabel ==
            'Saved, not running',
      ),
      'both panes saved and in place',
    );
    expect(layoutToJson(reopened.layout!), before);
    expect(harness.agentUnits(), isEmpty);
  });

  testWidgets('composer text returns after quit and reopen', (tester) async {
    final harness = AgentHarness(
      Directory.systemTemp.createTempSync('kumiko-exit-draft-'),
    );
    addTearDown(harness.dispose);
    await harness.launch(tester);
    await harness.configure(tester);
    final pane = await harness.newChat(tester);
    await tester.enterText(
      find.byKey(Key('agent-prompt-$pane')),
      'half-written prompt',
    );
    await tester.pump();

    // Idle agent, a stored (or flushed) draft: no dialog, the quit just exits.
    await harness.quit(tester);
    await harness.launch(tester);
    await harness.until(
      tester,
      () =>
          harness.agents(tester).linkOf(pane)?.prompt.text ==
          'half-written prompt',
      'the stored draft in the composer',
    );
  });

  testWidgets('restored pane shows draft before Continue; nothing sent', (
    tester,
  ) async {
    final harness = AgentHarness(
      Directory.systemTemp.createTempSync('kumiko-exit-draft-shown-'),
    );
    addTearDown(harness.dispose);
    await harness.launch(tester);
    await harness.configure(tester);
    final pane = await harness.newChat(tester);
    await tester.enterText(
      find.byKey(Key('agent-prompt-$pane')),
      'half-written prompt',
    );
    await tester.pump();
    await harness.quit(tester);

    await harness.launch(tester);
    await harness.until(
      tester,
      () =>
          harness.agents(tester).linkOf(pane)?.statusLabel ==
          'Saved, not running',
      'the saved record',
    );
    final composer = tester.widget<TextField>(
      find.byKey(Key('agent-prompt-$pane')),
    );
    expect(composer.controller!.text, 'half-written prompt');
    final link = harness.agents(tester).linkOf(pane)!;
    expect(link.transcript.entries, isEmpty);
    expect(harness.agentUnits(), isEmpty);
  });
}
