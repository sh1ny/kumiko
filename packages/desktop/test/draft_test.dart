import 'dart:async';

import 'package:desktop/src/agent/agent_controller.dart';
import 'package:desktop/src/workbench_controller.dart';
import 'package:domain/domain.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:host_protocol/host_protocol.dart';

import 'support/fake_host.dart';
import 'support/fake_terminal_surface.dart';
import 'support/workbench_support.dart';

const _capabilities = {
  Capability.workbench,
  Capability.terminal,
  Capability.agent,
};

/// A host holding [sessions] as restored chat panes with saved records.
FakeHostLink _host([List<String> sessions = const []]) {
  final host = FakeHostLink(hello: helloResult(capabilities: _capabilities));
  host.records.add(workspaceRecord('A'));
  host.storedLayout = jsonOf(_layout(sessions));
  for (final id in sessions) {
    host.agentRecordMap[id] = const AgentRecord(
      known: true,
      workspaceAvailable: true,
    );
  }
  return host;
}

LayoutDocument _layout(List<String> sessions) => docOf([
  for (final id in sessions)
    tabOf(
      'tab-$id',
      paneOf(
        'pane-$id',
        kind: 'agent-chat',
        ws: 'A',
        item: 'item-$id',
        state: {'sessionId': id, 'runtimeName': 'Claude Code'},
      ),
    ),
], selected: 'A');

Future<Rig> _rig(WidgetTester tester, FakeHostLink host) async {
  final surfaces = FakeSurfaces();
  var id = 0;
  final controller = track(
    WorkbenchController(
      picker: NoPicker(),
      newId: (prefix) => '$prefix${++id}',
      surfaceFactory: surfaces.call,
    ),
  );
  await controller.attach(host);
  await flush(tester);
  return Rig(controller, host, surfaces);
}

AgentController _agents(Rig rig) => rig.controller.agents;

/// Starts an agent in a new tab; it is idle and has a saved record.
Future<AgentLink> _started(Rig rig, WidgetTester tester) async {
  await rig.controller.launchAgent();
  await flush(tester);
  final pane = rig.layout.panes.firstWhere((p) => p.kind == agentChatKind);
  return _agents(rig).linkOf(pane.id)!;
}

/// Types [text] and lets the quiet period pass.
Future<void> _type(AgentLink link, WidgetTester tester, String text) async {
  link.prompt.text = text;
  await _wait(tester, 600);
}

Future<void> _wait(WidgetTester tester, int ms) async {
  await tester.pump(Duration(milliseconds: ms));
  await flush(tester);
}

Future<List<CloseWarning>> _closeWarnings(
  Rig rig,
  String paneId, {
  required bool confirm,
}) async {
  final named = <CloseWarning>[];
  await rig.controller.requestClose([paneId], (warnings) async {
    named.addAll(warnings);
    return confirm;
  });
  return named;
}

void main() {
  group('drafts on the desktop', () {
    uiTest('pane close flushes the draft before agent/close', (tester) async {
      final host = _host();
      final rig = await _rig(tester, host);
      final link = await _started(rig, tester);
      final session = link.sessionId!;
      link.prompt.text = 'half-written prompt';
      // No quiet period has passed: the close itself must store it.
      await rig.controller.requestClose([
        link.paneId,
      ], (_) async => fail('a stored draft must not ask'));
      final save = host.calls.indexOf('agent/draftSave $session');
      final close = host.calls.indexOf('agent/close $session');
      expect(save, isNonNegative);
      expect(close, greaterThan(save));
      expect(host.storedDrafts[session]?.text, 'half-written prompt');
    });

    uiTest('starting link keeps text in memory and shows Draft not saved', (
      tester,
    ) async {
      final host = _host()..agentStartGate = Completer<void>();
      final rig = await _rig(tester, host);
      final link = await _started(rig, tester);
      expect(link.sessionId, isNull);
      link.prompt.text = 'typed while starting';
      await _wait(tester, 3000);
      expect(host.draftSaves, isEmpty);
      expect(link.prompt.text, 'typed while starting');
      expect(link.draftNotice, startsWith('Draft not saved'));
      host.agentStartGate!.complete();
      await flush(tester);
    });

    uiTest('draft-too-large shows reason and keeps text', (tester) async {
      final host = _host();
      final rig = await _rig(tester, host);
      final link = await _started(rig, tester);
      host.draftSaveAnswers.add(
        RpcException(
          ErrorCode.draftTooLarge,
          'a draft is at most 262144 bytes',
        ),
      );
      await _type(link, tester, 'a very long draft');
      expect(link.draftNotice, 'Draft not saved: too long');
      expect(link.prompt.text, 'a very long draft');
      expect(host.storedDrafts, isEmpty);
    });

    uiTest('host-lost save leaves link unsaved and visible', (tester) async {
      final host = _host(['s0'])..draftSaveGate = Completer<void>();
      final rig = await _rig(tester, host);
      final link = _agents(rig).linkOf('pane-s0')!;
      link.prompt.text = 'draft text';
      await _wait(tester, 600);
      expect(host.draftSaves, hasLength(1));
      rig.controller.detach();
      await flush(tester);
      expect(link.draftNotice, 'Draft not saved: host lost');
      expect(link.prompt.text, 'draft text');
      host.draftSaveGate!.complete();
      await flush(tester);
      expect(link.draftNotice, 'Draft not saved: host lost');

      final restarted = _host(['s0']);
      await rig.controller.attach(restarted);
      await flush(tester);
      link.prompt.text = 'draft text, edited after the restart';
      await _wait(tester, 600);
      expect(
        restarted.storedDrafts['s0']?.text,
        'draft text, edited after the restart',
      );
      expect(link.draftNotice, isNull);
    });

    uiTest('close confirmation names the unsaved draft; Cancel keeps it', (
      tester,
    ) async {
      final host = _host();
      final rig = await _rig(tester, host);
      final link = await _started(rig, tester);
      final session = link.sessionId!;
      host.draftSaveAnswers.add(RpcException(ErrorCode.draftCap, 'full'));
      await _type(link, tester, 'keep me');
      expect(link.draftNotice, 'Draft not saved: draft storage full');

      final named = await _closeWarnings(rig, link.paneId, confirm: false);
      expect(named, hasLength(1));
      expect(named.single.paneId, link.paneId);
      expect(
        named.single.reason,
        contains('Draft not saved: draft storage full'),
      );
      expect(named.single.reason, contains('lost'));
      expect(rig.layout.pane(link.paneId), isNotNull);
      expect(link.prompt.text, 'keep me');
      expect(host.agentCloses, isEmpty);

      await _closeWarnings(rig, link.paneId, confirm: true);
      await flush(tester);
      expect(host.agentCloses, [session]);
      expect(host.storedDrafts, isEmpty);
    });

    uiTest('stored idle draft closes silently and stays stored', (
      tester,
    ) async {
      final host = _host();
      final rig = await _rig(tester, host);
      final link = await _started(rig, tester);
      final session = link.sessionId!;
      await _type(link, tester, 'stored text');
      expect(host.storedDrafts[session]?.text, 'stored text');
      await rig.controller.requestClose([
        link.paneId,
      ], (_) async => fail('a stored draft must not ask'));
      await flush(tester);
      expect(host.agentCloses, [session]);
      expect(host.storedDrafts[session]?.text, 'stored text');
    });

    uiTest('New session starts empty and the old draft stays', (tester) async {
      final host = _host(['old']);
      host.storedDrafts['old'] = (text: 'old draft', revision: 7);
      final rig = await _rig(tester, host);
      final link = _agents(rig).linkOf('pane-old')!;
      expect(link.prompt.text, 'old draft');
      expect(link.canNewSession, isTrue);
      await _agents(rig).newSession('pane-old');
      await flush(tester);
      final fresh = _agents(rig).linkOf('pane-old')!;
      expect(fresh.sessionId, 'agent-1');
      expect(fresh.prompt.text, isEmpty);
      await _wait(tester, 3000);
      expect(host.storedDrafts['old'], (text: 'old draft', revision: 7));
      expect(host.draftSaves, isEmpty);
    });

    uiTest('failed load shows Draft not loaded, stored draft untouched', (
      tester,
    ) async {
      final host = _host(['s0']);
      host.storedDrafts['s0'] = (text: 'stored P', revision: 500);
      host.draftLoadAnswers.add(RpcException(ErrorCode.storeError, 'boom'));
      final rig = await _rig(tester, host);
      final link = _agents(rig).linkOf('pane-s0')!;
      expect(link.prompt.text, isEmpty);
      expect(link.draftNotice, startsWith('Draft not loaded'));
      await _wait(tester, 3000);
      expect(host.draftSaves, isEmpty);
      expect(host.storedDrafts['s0'], (text: 'stored P', revision: 500));
    });

    uiTest('late load raises revision and keeps typed text', (tester) async {
      final host = _host(['s0'])..draftLoadGate = Completer<void>();
      host.storedDrafts['s0'] = (text: 'stored P', revision: 500);
      final rig = await _rig(tester, host);
      final link = _agents(rig).linkOf('pane-s0')!;
      expect(host.draftLoads, ['s0']);
      link.prompt.text = 'typed Q';
      host.draftLoadGate!.complete();
      await flush(tester);
      expect(link.prompt.text, 'typed Q');
      expect(link.draftRevision, 501);
      await _wait(tester, 600);
      expect(host.storedDrafts['s0'], (text: 'typed Q', revision: 501));
      expect(link.draftNotice, isNull);
    });

    uiTest('Retry carries no draftRevision and Q stays', (tester) async {
      final host = _host();
      final rig = await _rig(tester, host);
      final link = await _started(rig, tester);
      final session = link.sessionId!;
      host.promptError = RpcException(ErrorCode.authRequired, 'sign in');
      link.prompt.text = 'prompt P';
      await _agents(rig).send(link.paneId, 'prompt P');
      await flush(tester);
      expect(link.canRetry, isTrue);
      expect(host.agentPrompts.single.draftRevision, isNotNull);

      await _type(link, tester, 'draft Q');
      expect(host.storedDrafts[session]?.text, 'draft Q');
      host.promptError = null;
      await _agents(rig).retry(link.paneId);
      await flush(tester);
      final retried = host.agentPrompts.last;
      expect(retried.text, 'prompt P');
      expect(retried.draftRevision, isNull);
      expect(retried.draftSynced, isNull);
      expect(link.prompt.text, 'draft Q');
      await _wait(tester, 3000);
      expect(host.storedDrafts[session]?.text, 'draft Q');
    });

    uiTest('guard skips stale re-save of the submitted snapshot', (
      tester,
    ) async {
      final host = _host();
      final rig = await _rig(tester, host);
      final link = await _started(rig, tester);
      final session = link.sessionId!;
      host.draftSaveGate = Completer<void>();
      host.promptGate = Completer<void>();
      link.prompt.text = 'prompt P';
      await _wait(tester, 600);
      expect(host.draftSaves, hasLength(1));

      final sending = _agents(rig).send(link.paneId, 'prompt P');
      await flush(tester);
      expect(host.agentPrompts.single.draftRevision, link.draftRevision);
      expect(host.agentPrompts.single.draftSynced, isTrue);

      // The host removed P: the in-flight save of P is refused as stale.
      host.draftSaveAnswers.add(staleRevision(5));
      host.draftSaveGate!.complete();
      await _wait(tester, 3000);
      expect(host.draftSaves, hasLength(1), reason: 'no re-save of P');

      host.promptGate!.complete();
      await sending;
      await _wait(tester, 3000);
      expect(link.prompt.text, isEmpty);
      expect(host.draftSaves, hasLength(1));
      expect(host.storedDrafts[session], isNull);
    });

    uiTest('adapter refusal re-saves composer above r', (tester) async {
      final host = _host();
      final rig = await _rig(tester, host);
      final link = await _started(rig, tester);
      final session = link.sessionId!;
      await _type(link, tester, 'prompt P');
      host.promptError = RpcException(ErrorCode.invalidParams, 'rejected');
      await _agents(rig).send(link.paneId, 'prompt P');
      await flush(tester);
      final sent = host.agentPrompts.single.draftRevision!;
      expect(link.prompt.text, 'prompt P');
      await _wait(tester, 600);
      expect(host.draftSaves.last.text, 'prompt P');
      expect(host.draftSaves.last.revision, greaterThan(sent));
      expect(host.storedDrafts[session]?.text, 'prompt P');
    });

    uiTest('draftStoreReady retries the unsaved link without typing', (
      tester,
    ) async {
      final host = _host();
      final rig = await _rig(tester, host);
      final link = await _started(rig, tester);
      final session = link.sessionId!;
      host.draftSaveAnswers.add(
        RpcException(
          ErrorCode.draftUnavailable,
          'the draft store is not responding',
        ),
      );
      await _type(link, tester, 'kept text');
      expect(link.draftNotice, startsWith('Draft not saved'));
      expect(host.storedDrafts, isEmpty);
      host.draftReadySource.add(null);
      await flush(tester);
      expect(host.draftSaves, hasLength(2));
      expect(host.storedDrafts[session]?.text, 'kept text');
      expect(link.draftNotice, isNull);
    });

    // --- the saver's own bounds ---------------------------------------------

    uiTest('a save waits for 500 ms of quiet and for no more than 2 s', (
      tester,
    ) async {
      final host = _host();
      final rig = await _rig(tester, host);
      final link = await _started(rig, tester);
      link.prompt.text = 'a';
      await tester.pump(const Duration(milliseconds: 300));
      link.prompt.text = 'ab';
      await tester.pump(const Duration(milliseconds: 300));
      await flush(tester);
      expect(host.draftSaves, isEmpty, reason: 'only 300 ms of quiet');
      await tester.pump(const Duration(milliseconds: 250));
      await flush(tester);
      expect(host.draftSaves.map((s) => s.text), ['ab']);

      // Typing without a pause is still stored within the maximum age.
      host.draftSaves.clear();
      var elapsed = 0;
      var n = 0;
      while (host.draftSaves.isEmpty && elapsed < 3000) {
        link.prompt.text = 'typing ${n++}';
        await tester.pump(const Duration(milliseconds: 100));
        elapsed += 100;
      }
      await flush(tester);
      expect(host.draftSaves, isNotEmpty);
      expect(elapsed, lessThanOrEqualTo(2100));
    });

    uiTest('one save is in flight and one text is coalesced behind it', (
      tester,
    ) async {
      final host = _host()..draftSaveGate = Completer<void>();
      final rig = await _rig(tester, host);
      final link = await _started(rig, tester);
      await _type(link, tester, 'one');
      await _type(link, tester, 'two');
      await _type(link, tester, 'three');
      expect(host.draftSaves, hasLength(1));
      expect(host.draftSaves.single.text, 'one');
      host.draftSaveGate!.complete();
      await flush(tester);
      expect(host.draftSaves.map((s) => s.text), ['one', 'three']);
    });

    uiTest('at most 8 saves are in flight across links', (tester) async {
      final ids = [for (var i = 0; i < 10; i++) 's$i'];
      final host = _host(ids)..draftSaveGate = Completer<void>();
      final rig = await _rig(tester, host);
      for (final id in ids) {
        _agents(rig).linkOf('pane-$id')!.prompt.text = 'text of $id';
      }
      await _wait(tester, 600);
      expect(host.draftSaves, hasLength(8));
      host.draftSaveGate!.complete();
      await flush(tester);
      expect(host.draftSaves, hasLength(10));
      expect(host.maxDraftSavesInFlight, 8);
    });

    uiTest('restore loads at most 8 drafts at a time', (tester) async {
      final ids = [for (var i = 0; i < 12; i++) 's$i'];
      final host = _host(ids)..draftLoadGate = Completer<void>();
      for (final id in ids) {
        host.storedDrafts[id] = (text: 'draft of $id', revision: 3);
      }
      final rig = await _rig(tester, host);
      expect(host.draftLoads, hasLength(8));
      host.draftLoadGate!.complete();
      await flush(tester);
      expect(host.draftLoads, hasLength(12));
      expect(host.maxDraftLoadsInFlight, 8);
      for (final id in ids) {
        expect(_agents(rig).linkOf('pane-$id')!.prompt.text, 'draft of $id');
      }
    });

    uiTest('a save with no answer fails at the 10 s deadline', (tester) async {
      final host = _host()..draftSaveGate = Completer<void>();
      final rig = await _rig(tester, host);
      final link = await _started(rig, tester);
      await _type(link, tester, 'waiting');
      await _wait(tester, 9000);
      expect(link.draftNotice, isNull);
      await _wait(tester, 1500);
      expect(link.draftNotice, 'Draft not saved: the host did not answer');
      host.draftSaveGate!.complete();
      await flush(tester);
    });

    uiTest('a session id has one link with a composer', (tester) async {
      final host = _host(['same']);
      host.storedDrafts['same'] = (text: 'the draft', revision: 2);
      host.storedLayout = jsonOf(
        docOf([
          tabOf(
            'tab-1',
            paneOf(
              'pane-1',
              kind: 'agent-chat',
              ws: 'A',
              item: 'item-1',
              state: {'sessionId': 'same', 'runtimeName': 'Claude Code'},
            ),
          ),
          tabOf(
            'tab-2',
            paneOf(
              'pane-2',
              kind: 'agent-chat',
              ws: 'A',
              item: 'item-2',
              state: {'sessionId': 'same', 'runtimeName': 'Claude Code'},
            ),
          ),
        ], selected: 'A'),
      );
      final rig = await _rig(tester, host);
      final first = _agents(rig).linkOf('pane-1')!;
      final second = _agents(rig).linkOf('pane-2')!;
      expect(first.composerHidden, isFalse);
      expect(second.composerHidden, isTrue);
      expect(host.draftLoads, ['same']);
      second.prompt.text = 'ignored';
      await _wait(tester, 3000);
      expect(host.draftSaves, isEmpty);
    });

    uiTest('Reset draft storage asks first, then saves each unsaved link', (
      tester,
    ) async {
      final host = _host();
      final rig = await _rig(tester, host);
      final link = await _started(rig, tester);
      final session = link.sessionId!;
      host.draftSaveAnswers.add(
        RpcException(ErrorCode.draftUnavailable, 'drafts are disabled: bad'),
      );
      await _type(link, tester, 'text to keep');
      expect(_agents(rig).draftsDisabled, isTrue);
      expect(link.draftNotice, 'Draft not saved: draft storage unavailable');

      await _agents(rig).resetDraftStorage(link.paneId, () async => false);
      expect(host.draftResets, 0);

      await _agents(rig).resetDraftStorage(link.paneId, () async => true);
      await flush(tester);
      expect(host.draftResets, 1);
      expect(_agents(rig).draftsDisabled, isFalse);
      expect(host.storedDrafts[session]?.text, 'text to keep');
      expect(link.draftNotice, isNull);
    });

    uiTest('Reset draft storage saves a clean link whose draft it deleted', (
      tester,
    ) async {
      final host = _host(['s0', 's1']);
      final rig = await _rig(tester, host);
      final saved = _agents(rig).linkOf('pane-s0')!;
      final failing = _agents(rig).linkOf('pane-s1')!;
      await _type(saved, tester, 'stored and clean');
      expect(host.storedDrafts['s0']?.text, 'stored and clean');
      expect(saved.draft.dirty, isFalse);

      // The store becomes disabled; another pane notices it first.
      host.draftSaveAnswers.add(
        RpcException(ErrorCode.draftUnavailable, 'drafts are disabled: bad'),
      );
      await _type(failing, tester, 'second pane text');
      expect(_agents(rig).draftsDisabled, isTrue);

      await _agents(rig).resetDraftStorage(failing.paneId, () async => true);
      await _wait(tester, 100);
      expect(host.draftResets, 1);
      expect(host.storedDrafts['s1']?.text, 'second pane text');
      expect(
        host.storedDrafts['s0']?.text,
        'stored and clean',
        reason: 'the reset deleted it; the clean link must store it again',
      );
    });

    uiTest('Reset draft storage leaves a submitting composer alone', (
      tester,
    ) async {
      final host = _host();
      final rig = await _rig(tester, host);
      final sending = await _started(rig, tester);
      await rig.controller.launchAgent();
      await flush(tester);
      final failing = rig.layout.panes
          .where((p) => p.kind == agentChatKind)
          .map((p) => _agents(rig).linkOf(p.id)!)
          .firstWhere((l) => !identical(l, sending));
      await _type(sending, tester, 'being sent');
      expect(sending.canSend, isTrue);
      host.promptGate = Completer<void>();
      final send = _agents(rig).send(sending.paneId, 'being sent');
      await flush(tester);
      host.draftSaveAnswers.add(
        RpcException(ErrorCode.draftUnavailable, 'drafts are disabled: bad'),
      );
      await _type(failing, tester, 'other text');
      final before = host.draftSaves.length;
      await _agents(rig).resetDraftStorage(failing.paneId, () async => true);
      await _wait(tester, 100);
      expect(
        host.draftSaves
            .skip(before)
            .where((s) => s.sessionId == sending.sessionId),
        isEmpty,
        reason: 'the submission guard holds',
      );
      host.promptGate!.complete();
      await send;
      await flush(tester);
    });

    uiTest('a failed save of an emptied composer shows and warns on close', (
      tester,
    ) async {
      final host = _host();
      final rig = await _rig(tester, host);
      final link = await _started(rig, tester);
      final session = link.sessionId!;
      await _type(link, tester, 'prompt P');
      expect(host.storedDrafts[session]?.text, 'prompt P');

      host.draftSaveAnswers.add(RpcException(ErrorCode.storeError, 'boom'));
      link.prompt.clear();
      await _wait(tester, 600);
      expect(host.storedDrafts[session]?.text, 'prompt P');
      expect(link.draftNotice, 'Draft not saved: boom');

      final named = await _closeWarnings(rig, link.paneId, confirm: false);
      expect(named, hasLength(1));
      expect(named.single.reason, contains('Draft not saved: boom'));
      expect(rig.layout.pane(link.paneId), isNotNull);
      expect(host.agentCloses, isEmpty);

      await _closeWarnings(rig, link.paneId, confirm: true);
      await flush(tester);
      expect(host.agentCloses, [session]);
    });

    uiTest('the pane shows the notice and asks before Reset draft storage', (
      tester,
    ) async {
      final host = _host(['s0']);
      final rig = await pumpRig(tester, host);
      final link = _agents(rig).linkOf('pane-s0')!;
      host.draftSaveAnswers.add(
        RpcException(ErrorCode.draftUnavailable, 'drafts are disabled: bad'),
      );
      link.prompt.text = 'kept in the composer';
      await tester.pump(const Duration(milliseconds: 600));
      await flush(tester);
      expect(
        tester.widget<Text>(key('agent-draft-notice-pane-s0')).data,
        'Draft not saved: draft storage unavailable',
      );
      await tester.tap(key('agent-draft-reset-pane-s0'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Every stored draft will be lost'), findsOne);
      await tester.tap(key('draft-reset-cancel'));
      await tester.pumpAndSettle();
      expect(host.draftResets, 0);

      await tester.tap(key('agent-draft-reset-pane-s0'));
      await tester.pumpAndSettle();
      await tester.tap(key('draft-reset-ok'));
      await tester.pumpAndSettle();
      expect(host.draftResets, 1);
      expect(key('agent-draft-reset-pane-s0'), findsNothing);
      expect(host.storedDrafts['s0']?.text, 'kept in the composer');
    });
  });
}
