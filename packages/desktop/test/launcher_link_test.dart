import 'dart:async';
import 'dart:typed_data';

import 'package:desktop/src/agent/agent_controller.dart';
import 'package:desktop/src/launcher_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:host_protocol/host_protocol.dart';

CleanupState stateOf(int revision, {bool reconciling = false}) => CleanupState(
  reconciling: reconciling,
  revision: revision,
  unresolvedWorkspaces: 0,
  unresolvedUnits: 0,
);

class _Pipe implements ByteSink {
  final StreamController<List<int>> controller = StreamController();

  @override
  void add(List<int> data) => controller.add(Uint8List.fromList(data));

  @override
  Future<void> flush() => Future.value();
}

/// Only process ownership is substituted: SessionLink and both wire endpoints
/// are real, so JSON escaping and request admission remain in the test path.
class _MemorySession implements HostSession {
  _MemorySession(this.connection, this.hello, this.notifications);

  @override
  final Connection connection;
  @override
  final HelloResult hello;
  @override
  final Stream<HostNotification> notifications;
  @override
  Stream<CleanupState> get cleanupStates => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PromptRig {
  final toHost = _Pipe();
  final toDesktop = _Pipe();
  final notifications = StreamController<HostNotification>.broadcast(
    sync: true,
  );
  final attached = Completer<void>();
  final prompts = <AgentPromptParams>[];
  final calls = <String>[];
  int starts = 0;
  late final Connection host;
  late final Connection desktop;
  late final AgentController controller;

  Future<void> start({bool earlyCloseFailure = false}) async {
    var failStart = earlyCloseFailure;
    host = Connection(
      input: toHost.controller.stream,
      output: toDesktop,
      capabilities: const {Capability.agent},
      onHello: (_, _) => const HelloInfo.ready('host-1'),
      onRequest: (method, params) {
        calls.add(method);
        switch (method) {
          case Method.agentStart:
            final id = 'agent-${++starts}';
            final channel = host.openOutbound().id;
            if (failStart) {
              failStart = false;
              host.notify(
                Method.agentCloseFailed,
                AgentCloseFailedParams(
                  sessionId: id,
                  reason: 'cleanup-unresolved',
                  message: 'early native cleanup could not be confirmed',
                ).toJson(),
              );
            }
            return AgentStartResult(
              sessionId: id,
              eventChannel: channel,
              adapter: const AgentAdapter(name: 'scripted', version: 'test'),
              capabilities: const [],
            ).toJson();
          case Method.agentAttach:
            if (!attached.isCompleted) attached.complete();
            return <String, Object?>{};
          case Method.agentPrompt:
            prompts.add(AgentPromptParams.fromJson(params));
            return <String, Object?>{};
          default:
            return <String, Object?>{};
        }
      },
    );
    desktop = Connection(
      input: toDesktop.controller.stream,
      output: toHost,
      capabilities: const {Capability.agent},
      onNotification: (method, params) =>
          notifications.add(HostNotification(method, params)),
    );
    final hello = await desktop.hello();
    controller = AgentController(
      removePane: (_) {},
      savePaneState: (_, _) {},
      focusPane: (_) {},
    );
    controller.attach(
      SessionLink(_MemorySession(desktop, hello, notifications.stream)),
    );
    await controller.start(
      'pane',
      workspaceId: 'workspace',
      runtimeName: 'Claude Code',
    );
    if (earlyCloseFailure) {
      await desktop.request(Method.agentRecords, {'sessionIds': <String>[]});
      return;
    }
    await attached.future;
    host.notify(
      Method.agentState,
      AgentStateParams(
        sessionId: 'agent-1',
        state: AgentState.idle,
        seq: 1,
      ).toJson(),
    );
    // The reply follows all prior host control records on the same wire.
    await desktop.request(Method.agentRecords, {'sessionIds': <String>[]});
    expect(link.canSend, isTrue);
  }

  AgentLink get link => controller.linkOf('pane')!;

  Future<void> close() async {
    controller.dispose();
    await desktop.close();
    await host.close();
    await notifications.close();
    await toHost.controller.close();
    await toDesktop.controller.close();
  }

  Future<void> proveRecovery() async {
    link.prompt.text = 'smaller prompt';
    await controller.send('pane', link.prompt.text);
    expect(prompts.map((prompt) => prompt.text), ['smaller prompt']);
    expect(link.prompt.text, isEmpty);
    expect(link.error, isNull);
    expect(desktop.isClosed, isFalse);
  }
}

void main() {
  test(
    'early new-start close failure stays terminal over the real wire',
    () async {
      final rig = _PromptRig();
      await rig.start(earlyCloseFailure: true);
      addTearDown(rig.close);
      final link = rig.link;
      expect(link.phase, AgentLinkPhase.ended);
      expect(link.state, AgentState.failed);
      expect(
        link.error,
        contains('early native cleanup could not be confirmed'),
      );
      expect(link.known, isTrue);
      expect(link.canContinue, isTrue);
      expect(link.canNewSession, isTrue);
      expect(link.canSend, isFalse);
      expect(rig.calls, isNot(contains(Method.agentAttach)));
      expect(rig.calls, isNot(contains(Method.agentClose)));
      expect(rig.calls, isNot(contains(Method.agentRelease)));

      await rig.controller.newSession('pane');
      await rig.attached.future;
      rig.host.notify(
        Method.agentState,
        AgentStateParams(
          sessionId: rig.link.sessionId!,
          state: AgentState.idle,
          seq: 1,
        ).toJson(),
      );
      await rig.desktop.request(Method.agentRecords, {
        'sessionIds': <String>[],
      });
      expect(rig.link.sessionId, 'agent-2');
      expect(rig.link.canSend, isTrue);
      expect(rig.link.error, isNull);
      await rig.proveRecovery();
    },
  );

  test('with no profile directory the connector fails to start, naming the '
      'variable to set', () async {
    final error = await noProfileDirConnector(
      'HOME',
    )().then<Object?>((_) => null, onError: (Object e) => e);
    expect(
      error,
      isA<HostStartException>()
          .having((e) => e.kind, 'kind', HostStartFailure.spawnFailed)
          .having((e) => e.message, 'message', contains('HOME')),
    );
  });

  test('a refused terminal/attach closes both channels and asks the host to '
      'close the terminal', () async {
    final toHost = _Pipe();
    final toDesktop = _Pipe();
    final hostCalls = <String>[];
    late final Connection host;
    host = Connection(
      input: toHost.controller.stream,
      output: toDesktop,
      capabilities: const {Capability.terminal},
      onHello: (params, negotiated) => const HelloInfo.ready('host-1'),
      onRequest: (method, params) {
        hostCalls.add(method);
        switch (method) {
          case Method.terminalOpen:
            final ids = host.reserveChannels(2).ids;
            return TerminalOpenResult(
              terminalId: 't1',
              outputChannel: ids[0],
              inputChannel: ids[1],
            ).toJson();
          case Method.terminalAttach:
            // The host's attach timeout ran out while the desktop slept.
            throw RpcException(ErrorCode.invalidParams, 'unknown terminal t1');
          default:
            return <String, Object?>{};
        }
      },
    );
    final desktop = Connection(
      input: toDesktop.controller.stream,
      output: toHost,
      capabilities: const {Capability.terminal},
    );
    await desktop.hello();

    await expectLater(
      openTerminalChannels(
        desktop,
        const TerminalOpenParams(profileId: 'p', cols: 80, rows: 24),
      ),
      throwsA(isA<RpcException>()),
    );
    // Every desktop slot is free again.
    desktop.reserveChannels(maxChannels).release();
    expect(hostCalls, contains(Method.terminalClose));
    await desktop.close();
    await host.close();
  });

  group('agent prompt size admission over SessionLink and Connection', () {
    for (final entry in {
      'exact raw UTF-8 ceiling': 'é' * (maxAgentPromptBytes ~/ 2),
      'escaped text within the control ceiling': '\u0001' * (170 * 1024),
    }.entries) {
      test('${entry.key} remains accepted', () async {
        final rig = _PromptRig();
        await rig.start();
        addTearDown(rig.close);
        rig.link.prompt.text = entry.value;

        await rig.controller.send('pane', entry.value);

        expect(rig.prompts.single.text, entry.value);
        expect(rig.link.prompt.text, isEmpty);
        expect(rig.link.error, isNull);
        expect(rig.link.sending, isTrue);
        expect(rig.desktop.isClosed, isFalse);
      });
    }

    for (final entry in {
      'raw UTF-8 over 256 KiB': 'é' * (maxAgentPromptBytes ~/ 2 + 1),
      'raw text over the control ceiling': 'x' * (maxControlMessage + 1),
    }.entries) {
      test(
        '${entry.key} is refused before sending and preserves the draft',
        () async {
          final rig = _PromptRig();
          await rig.start();
          addTearDown(rig.close);
          final sendingStates = <bool>[];
          rig.controller.addListener(() => sendingStates.add(rig.link.sending));
          rig.link.prompt.text = entry.value;

          await rig.controller.send('pane', entry.value);

          expect(rig.prompts, isEmpty);
          expect(sendingStates, everyElement(isFalse));
          expect(rig.link.sending, isFalse);
          expect(rig.link.canSend, isTrue);
          expect(rig.link.state, AgentState.idle);
          expect(rig.link.prompt.text, entry.value);
          expect(rig.link.errorCode, ErrorCode.invalidParams);
          expect(
            rig.link.error,
            allOf(contains('256 KiB'), contains('shorten')),
          );
          expect(
            rig.link.transcript.entries.every(
              (entry) => entry.kind == AgentEventKind.notice,
            ),
            isTrue,
          );
          await rig.proveRecovery();
        },
      );
    }

    test('JSON-escaped prompt over control ceiling is refused without latching '
        'sending or creating a turn', () async {
      final rig = _PromptRig();
      await rig.start();
      addTearDown(rig.close);
      final text = '\u0001' * (200 * 1024);
      rig.link.prompt.text = text;

      await rig.controller.send('pane', text);

      expect(rig.prompts, isEmpty);
      expect(rig.link.sending, isFalse);
      expect(rig.link.canSend, isTrue);
      expect(rig.link.state, AgentState.idle);
      expect(rig.link.prompt.text, text);
      expect(rig.link.errorCode, ErrorCode.invalidParams);
      expect(rig.link.error, allOf(contains('encoded'), contains('shorten')));
      expect(
        rig.link.transcript.entries.every(
          (entry) => entry.kind == AgentEventKind.notice,
        ),
        isTrue,
      );
      await rig.proveRecovery();
    });
  });

  group('cleanup state replay', () {
    test('a late listener receives the newest state first', () async {
      final source = StreamController<CleanupState>(sync: true);
      final states = LatestCleanupState(source.stream);

      // The first consumer (the cleanup list) sees everything.
      final first = <CleanupState>[];
      states.stream.listen(first.add);
      source
        ..add(stateOf(1, reconciling: true))
        ..add(stateOf(2));
      await pumpEventQueue();

      // The workbench attaches after reconciliation ended.
      final late = <CleanupState>[];
      states.stream.listen(late.add);
      await pumpEventQueue();
      expect(late.map((s) => s.revision), [2]);
      expect(late.single.reconciling, isFalse);

      source.add(stateOf(3));
      await pumpEventQueue();
      expect(first.map((s) => s.revision), [1, 2, 3]);
      expect(late.map((s) => s.revision), [2, 3]);
      await source.close();
    });

    test('a listener before any state receives only live states', () async {
      final source = StreamController<CleanupState>(sync: true);
      final states = LatestCleanupState(source.stream);
      final seen = <CleanupState>[];
      states.stream.listen(seen.add);
      await pumpEventQueue();
      expect(seen, isEmpty);

      source.add(stateOf(1));
      await pumpEventQueue();
      expect(seen.map((s) => s.revision), [1]);
      await source.close();
    });
  });
}
