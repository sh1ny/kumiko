import 'package:desktop/src/workbench_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:host_protocol/host_protocol.dart';

import 'agent_test.dart'
    show agentCapabilities, agentHost, agents, controllerRig;
import 'support/fake_host.dart';
import 'support/workbench_support.dart';

const _enter = LogicalKeyboardKey.enter;
const _up = LogicalKeyboardKey.arrowUp;
const _shift = LogicalKeyboardKey.shiftLeft;

void _windowsTest(String name, Future<void> Function(WidgetTester) body) {
  uiTest(name, (tester) async {
    final previous = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = previous;
    }
  });
}

FakeHostLink _runtimeHost(String kind) {
  final profile = RuntimeProfile(
    id: kind,
    name: kind,
    runtimeKind: kind,
    executable: '/agent',
  );
  return linkWith(
      docOf([], selected: 'A'),
      records: [workspaceRecord('A')],
      hello: helloResult(
        capabilities: {
          ...agentCapabilities,
          Capability.codex,
          Capability.agentExtensionsV1,
          Capability.omp,
        },
      ),
    )
    ..runtimes = RuntimeListResult(
      profiles: [profile],
      defaultId: profile.id,
      defaultAvailable: true,
    );
}

Future<Rig> _open(
  WidgetTester tester,
  FakeHostLink host, {
  String kind = 'claude-code',
}) async {
  final rig = await controllerRig(tester, host);
  await rig.controller.launchAgent(runtimeKind: kind);
  await tester.pumpWidget(
    MaterialApp(home: WorkbenchPage(controller: rig.controller)),
  );
  await tester.pump();
  if (kind == 'codex') {
    host.agentStateSource.add(
      AgentStateParams(
        sessionId: _session(rig),
        seq: 1,
        state: AgentState.idle,
        runId: 'test-run',
      ),
    );
    await tester.pump();
  }
  return rig;
}

Finder _prompt(Rig rig) => key('agent-prompt-${rig.layout.focusedPane}');
Finder _send(Rig rig) => key('agent-send-${rig.layout.focusedPane}');
TextEditingValue _value(WidgetTester tester, Rig rig) =>
    tester.widget<TextField>(_prompt(rig)).controller!.value;
String _session(Rig rig) =>
    agents(rig).linkOf(rig.layout.focusedPane!)!.sessionId!;

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key, platform: 'windows');
  await tester.pump();
}

void _finishTurn(FakeHostLink host, String session, {String? runId}) {
  host.agentTurnSource.add(
    AgentTurnEndedParams(sessionId: session, stopReason: 'end_turn'),
  );
  host.agentStateSource.add(
    AgentStateParams(
      sessionId: session,
      seq: 2,
      state: AgentState.idle,
      runId: runId,
    ),
  );
}

Future<void> _sendByButton(WidgetTester tester, Rig rig, String text) async {
  await tester.enterText(_prompt(rig), text);
  await tester.tap(_send(rig));
  await tester.pump();
}

void main() {
  for (final kind in ['claude-code', 'codex', 'omp']) {
    group(kind, () {
      _windowsTest('Enter sends the draft once', (tester) async {
        final host = _runtimeHost(kind);
        final rig = await _open(tester, host, kind: kind);
        const text = '  first\nsecond  ';
        await tester.enterText(_prompt(rig), text);
        await tester.sendKeyDownEvent(_enter, platform: 'windows');
        try {
          await tester.pump();
          expect(host.agentPrompts.map((p) => p.text), [text]);
          expect(host.agentPrompts.single.sessionId, _session(rig));
          expect(host.agentPrompts.single.draftRevision, isNotNull);
          expect(_value(tester, rig).text, isEmpty);

          _finishTurn(
            host,
            _session(rig),
            runId: kind == 'codex' ? 'test-run' : null,
          );
          await tester.pump();
          expect(tester.widget<FilledButton>(_send(rig)).onPressed, isNotNull);
          await tester.enterText(_prompt(rig), 'next draft');
          await tester.sendKeyRepeatEvent(_enter, platform: 'windows');
          await tester.pump();
          expect(host.agentPrompts.map((p) => p.text), [text]);
          expect(_value(tester, rig).text, 'next draft');
        } finally {
          await tester.sendKeyUpEvent(_enter, platform: 'windows');
        }
      });
    });
  }

  _windowsTest('Enter leaves blank and streaming drafts untouched', (
    tester,
  ) async {
    final host = agentHost();
    final rig = await _open(tester, host);
    for (final text in ['', ' \t\n ']) {
      await tester.enterText(_prompt(rig), text);
      await _press(tester, _enter);
      expect(_value(tester, rig).text, text);
      expect(host.agentPrompts, isEmpty);
    }

    await _sendByButton(tester, rig, 'first');
    final id = _session(rig);
    host.agentState(id, AgentState.running);
    host.agentEvent(
      id,
      AgentEvent.text(AgentEventKind.agentText, 'partial reply'),
    );
    await tester.pump();
    expect(tester.widget<FilledButton>(_send(rig)).onPressed, isNull);
    await tester.enterText(_prompt(rig), 'next');
    await _press(tester, _enter);
    expect(_value(tester, rig).text, 'next');
    expect(host.agentPrompts.map((p) => p.text), ['first']);

    _finishTurn(host, id);
    await tester.pump();
    expect(host.agentPrompts.map((p) => p.text), ['first']);
    await _press(tester, _enter);
    expect(host.agentPrompts.map((p) => p.text), ['first', 'next']);
  });

  _windowsTest('Enter leaves IME confirmation to the input method', (
    tester,
  ) async {
    final host = agentHost();
    final rig = await _open(tester, host);
    await tester.showKeyboard(_prompt(rig));
    const composing = TextEditingValue(
      text: 'nihon',
      selection: TextSelection.collapsed(offset: 5),
      composing: TextRange(start: 0, end: 5),
    );
    tester.testTextInput.updateEditingValue(composing);
    await tester.pump();
    // An unhandled raw Windows Enter would fall through to the engine's
    // multiline newline path. IME-processed keys never reach this handler.
    expect(await tester.sendKeyEvent(_enter, platform: 'windows'), isTrue);
    await tester.pump();
    await tester.sendKeyDownEvent(_shift, platform: 'windows');
    try {
      expect(await tester.sendKeyEvent(_enter, platform: 'windows'), isTrue);
    } finally {
      await tester.sendKeyUpEvent(_shift, platform: 'windows');
    }
    await tester.pump();
    expect(host.agentPrompts, isEmpty);
    expect(_value(tester, rig), composing);

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '日本',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();
    await _press(tester, _enter);
    expect(host.agentPrompts.map((p) => p.text), ['日本']);
  });

  _windowsTest('Shift+Enter replaces the selection with a line break', (
    tester,
  ) async {
    final host = agentHost();
    final rig = await _open(tester, host);
    await tester.showKeyboard(_prompt(rig));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'a bc d',
        selection: TextSelection(baseOffset: 5, extentOffset: 1),
      ),
    );
    await tester.pump();
    await tester.sendKeyDownEvent(_shift, platform: 'windows');
    try {
      await _press(tester, _enter);
    } finally {
      await tester.sendKeyUpEvent(_shift, platform: 'windows');
    }
    expect(_value(tester, rig).text, 'a\nd');
    expect(
      _value(tester, rig).selection,
      const TextSelection.collapsed(offset: 2),
    );
    expect(host.agentPrompts, isEmpty);
    await _press(tester, _enter);
    expect(host.agentPrompts.single.text, 'a\nd');
  });

  _windowsTest('Up recalls only the latest accepted prompt', (tester) async {
    final host = agentHost();
    final rig = await _open(tester, host);
    await _sendByButton(tester, rig, 'older');
    _finishTurn(host, _session(rig));
    await tester.pump();
    await _sendByButton(tester, rig, 'last\nprompt');
    await tester.showKeyboard(_prompt(rig));
    await _press(tester, _up);
    expect(_value(tester, rig).text, 'last\nprompt');
    expect(
      _value(tester, rig).selection,
      const TextSelection.collapsed(offset: 11),
    );
    expect(host.agentPrompts.map((p) => p.text), ['older', 'last\nprompt']);
  });

  _windowsTest('Up skips a host-refused prompt', (tester) async {
    final host = agentHost();
    final rig = await _open(tester, host);
    await _sendByButton(tester, rig, 'accepted');
    _finishTurn(host, _session(rig));
    await tester.pump();
    host.promptError = RpcException(
      ErrorCode.storeError,
      'draft removal failed',
    );
    await _sendByButton(tester, rig, 'refused');
    expect(_value(tester, rig).text, 'refused');
    tester.widget<TextField>(_prompt(rig)).controller!.clear();
    await tester.showKeyboard(_prompt(rig));
    expect(_value(tester, rig).text, isEmpty);
    await _press(tester, _up);
    expect(_value(tester, rig).text, 'accepted');
    expect(
      _value(tester, rig).selection,
      const TextSelection.collapsed(offset: 8),
    );
    expect(host.agentPrompts.map((p) => p.text), ['accepted', 'refused']);
  });

  _windowsTest('Up does not reuse another conversation or restored history', (
    tester,
  ) async {
    const restored = 'restored';
    const saved = 'saved';
    final host = agentHost(
      layout: docOf([
        tabOf(
          'saved-tab',
          paneOf(
            restored,
            kind: 'agent-chat',
            ws: 'A',
            item: 'saved-item',
            state: const {'sessionId': saved},
          ),
        ),
      ], selected: 'A'),
    );
    host.agentRecordMap[saved] = const AgentRecord(
      known: true,
      workspaceAvailable: true,
    );
    final rig = await _open(tester, host);
    await _sendByButton(tester, rig, 'other conversation');
    final active = rig.layout.activeTab!;
    await tester.showKeyboard(_prompt(rig));
    await _press(tester, _up);
    expect(_value(tester, rig).text, 'other conversation');

    rig.controller.activateTab('saved-tab');
    await agents(rig).continueSession(restored);
    host.agentEvent(saved, AgentEvent.replay(AgentReplayPhase.start));
    host.agentEvent(
      saved,
      AgentEvent.text(AgentEventKind.user, 'restored transcript text'),
    );
    host.agentEvent(saved, AgentEvent.replay(AgentReplayPhase.end));
    await tester.pump();
    expect(find.text('restored transcript text'), findsOneWidget);
    await tester.showKeyboard(_prompt(rig));
    await _press(tester, _up);
    expect(_value(tester, rig).text, isEmpty);
    expect(host.agentPrompts.map((p) => p.text), ['other conversation']);

    rig.controller.activateTab(active);
    await tester.pump();
    expect(_value(tester, rig).text, 'other conversation');
  });

  _windowsTest('Up uses native caret movement when the draft is nonempty', (
    tester,
  ) async {
    final host = agentHost();
    final rig = await _open(tester, host);
    await _sendByButton(tester, rig, 'prior');
    await tester.showKeyboard(_prompt(rig));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'abc\nabc',
        selection: TextSelection.collapsed(offset: 5),
      ),
    );
    await tester.pump();
    await _press(tester, _up);
    expect(_value(tester, rig).text, 'abc\nabc');
    expect(
      _value(tester, rig).selection,
      const TextSelection.collapsed(offset: 1),
    );
    tester.widget<TextField>(_prompt(rig)).controller!.clear();
    // Let EditableText lay out the empty value before moving the caret.
    await tester.pump();
    expect(_value(tester, rig).text, isEmpty);
    await _press(tester, _up);
    expect(_value(tester, rig).text, 'prior');
    expect(host.agentPrompts.single.text, 'prior');
  });
}
