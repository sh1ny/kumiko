import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:host/src/agent/acp/acp_client.dart';
import 'package:host/src/agent/agent_session.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/acp_peer.dart';

/// The real Connection/FairWriter path, not a size-checking callback double.
class _Pipe implements ByteSink {
  final input = StreamController<List<int>>();

  @override
  void add(List<int> bytes) => input.add(Uint8List.fromList(bytes));

  @override
  Future<void> flush() => Future<void>.value();
}

void main() {
  late AcpPeer peer;
  late AgentSession session;
  late Connection host;
  late Connection desktop;
  late _Pipe toHost;
  late _Pipe toDesktop;
  late List<AgentStateParams> states;
  late List<AgentStopResultParams> stops;
  late List<AgentTurnEndedParams> ends;
  late List<AgentEvent> events;

  setUp(() async {
    peer = AcpPeer();
    toHost = _Pipe();
    toDesktop = _Pipe();
    states = [];
    stops = [];
    ends = [];
    events = [];
    desktop = Connection(
      input: toDesktop.input.stream,
      output: toHost,
      capabilities: {Capability.agent},
      onNotification: (method, params) {
        switch (method) {
          case Method.agentState:
            states.add(AgentStateParams.fromJson(params));
          case Method.agentStopResult:
            stops.add(AgentStopResultParams.fromJson(params));
          case Method.agentTurnEnded:
            ends.add(AgentTurnEndedParams.fromJson(params));
        }
      },
    );
    host = Connection(
      input: toHost.input.stream,
      output: toDesktop,
      capabilities: {Capability.agent},
      onHello: (_, _) => HelloInfo.ready('host'),
      onRequest: (method, params) {
        switch (method) {
          case Method.agentPrompt:
            session.acceptPrompt(AgentPromptParams.fromJson(params).text);
          case Method.agentStop:
            session.stop();
          default:
            throw RpcException(ErrorCode.methodNotAvailable, method);
        }
        return const EmptyResult().toJson();
      },
    );
    await desktop.hello();
    session = AgentSession(
      sessionId: 'host',
      client: peer.client,
      onState: (p) => host.notify(Method.agentState, p.toJson()),
      onPermissionRequested: (p) =>
          host.notify(Method.agentPermissionRequested, p.toJson()),
      onPermissionResolved: (p) =>
          host.notify(Method.agentPermissionResolved, p.toJson()),
      onStopResult: (p) => host.notify(Method.agentStopResult, p.toJson()),
      onTurnEnded: (p) => host.notify(Method.agentTurnEnded, p.toJson()),
      enqueueEvents: (lines) {
        final decoder = AgentEventDecoder();
        for (final line in lines) {
          events.addAll(decoder.add(line));
        }
        decoder.close();
      },
    );
    session.ready(nativeSessionId: 'native');
  });

  tearDown(() async {
    session.dispose();
    await peer.dispose();
    await host.close();
    await desktop.close();
    await toHost.input.close();
    await toDesktop.input.close();
  });

  Object promptId() => peer.writes.lastWhere(
    (message) => message['method'] == 'session/prompt',
  )['id']!;

  Future<void> prompt(String text) async {
    await desktop.request(
      Method.agentPrompt,
      AgentPromptParams(sessionId: 'host', text: text).toJson(),
    );
    expect(session.state, AgentState.running);
  }

  Future<void> receiveCompletion() async {
    // ACP parsing and the session's ordered event enqueue finish at the first
    // event-loop barrier. Drain the actual control writer, then let the peer
    // consume its frames; no sleeps or polling for an absent notification.
    await pumpAcp();
    await host.drain();
    await pumpAcp();
  }

  Future<void> expectNextTurn() async {
    expect(session.state, AgentState.idle);
    expect(states.last.state, AgentState.idle);
    expect(host.isClosed, isFalse);
    expect(desktop.isClosed, isFalse);
    expect(peer.client.isClosed, isFalse);
    await prompt('next prompt');
    peer.result(promptId(), {'stopReason': 'end_turn'});
    await receiveCompletion();
    expect(session.state, AgentState.idle);
    expect(states.last.state, AgentState.idle);
    expect(ends, hasLength(2));
    expect(ends.last.stopReason, 'end_turn');
    expect(ends.last.error, isNull);
  }

  test(
    'different stalled and idle sessions keep only bounded prompt diagnostics',
    () async {
      final peers = <AcpPeer>[];
      final sessions = <AgentSession>[];
      final credits = <Completer<void>>[];
      final completions = <List<AgentTurnEndedParams>>[];
      try {
        for (var i = 0; i < 4; i++) {
          final nextPeer = AcpPeer();
          peers.add(nextPeer);
          final credit = Completer<void>();
          credits.add(credit);
          final completed = <AgentTurnEndedParams>[];
          completions.add(completed);
          final nextSession = AgentSession(
            sessionId: 'session-$i',
            client: nextPeer.client,
            onState: (_) {},
            onPermissionRequested: (_) {},
            onPermissionResolved: (_) {},
            onStopResult: (_) {},
            onTurnEnded: completed.add,
            enqueueEvents: (_) => credit.future,
          )..ready(nativeSessionId: 'native');
          sessions.add(nextSession);
          nextSession.acceptPrompt('prompt $i');
          nextPeer.send({
            'jsonrpc': '2.0',
            'id': nextPeer.writes.single['id'],
            'error': {
              'code': -32000,
              'message': i.isEven
                  ? 'Authentication required'
                  : 'Authentication required${'$i' * (1024 * 1024 + 64)}',
              'data': {'payload': '$i' * (2 * 1024 * 1024)},
            },
          });
          await pumpAcp();
          expect(nextPeer.client.largeLineOwned, isFalse);
          expect(nextSession.state, AgentState.running);
          expect(completed, isEmpty);
          if (i.isEven) {
            credit.complete();
            await pumpAcp();
            expect(nextSession.state, AgentState.idle);
          }
        }
        // Hold earlier stalled sessions while later large errors complete.
        // The transport regression inspects the bounded delivered exception;
        // this checks the same path through credit-blocked turn ownership.
        expect(sessions.map((s) => s.state), [
          AgentState.idle,
          AgentState.running,
          AgentState.idle,
          AgentState.running,
        ]);
        for (var i = 0; i < credits.length; i++) {
          if (!credits[i].isCompleted) credits[i].complete();
        }
        await pumpAcp();
        for (var i = 0; i < sessions.length; i++) {
          final end = completions[i].single;
          expect(sessions[i].state, AgentState.idle);
          expect(
            end.error,
            i.isEven ? ErrorCode.authRequired : 'adapter-error',
          );
          expect(end.nativeMessageTruncated, i.isOdd);
          expect(
            utf8.encode(end.nativeMessage!).length,
            lessThanOrEqualTo(4096),
          );
          expect(
            utf8.encode(jsonEncode(end.message)).length - 2,
            lessThanOrEqualTo(4096),
          );
          expect(peers[i].client.isClosed, isFalse);
        }
      } finally {
        for (final credit in credits) {
          if (!credit.isCompleted) credit.complete();
        }
        for (final nextSession in sessions) {
          nextSession.dispose();
        }
        for (final nextPeer in peers) {
          await nextPeer.dispose();
        }
      }
    },
  );

  for (final stopped in [false, true]) {
    for (final escaped in [false, true]) {
      test(
        'oversized ${escaped ? 'escaped Unicode' : 'ASCII'} prompt error '
        '${stopped ? 'with Stop' : 'without Stop'} publishes controls and accepts next turn',
        () async {
          final message = escaped
              ? 'Authentication required${'\u0000值😀' * 90000}'
              : 'x' * (1024 * 1024 + 64);
          final encodedBytes = utf8.encode(jsonEncode(message)).length;
          expect(encodedBytes, greaterThan(1024 * 1024));
          expect(encodedBytes, lessThan(acpLineLimit - 1024));
          if (escaped) {
            // This fits a raw-byte-only 1 MiB cap but exceeds it on the wire.
            expect(utf8.encode(message).length, lessThan(1024 * 1024));
          }
          await prompt('first prompt');
          if (stopped) {
            await desktop.request(
              Method.agentStop,
              const AgentSessionParams('host').toJson(),
            );
            expect(session.state, AgentState.stopping);
            expect(peer.writes.last['method'], 'session/cancel');
          }
          peer.error(promptId(), -32000, message);
          await receiveCompletion();

          expect(session.state, AgentState.idle);
          expect(ends, hasLength(1));
          final end = ends.single;
          expect(end.error, 'adapter-error');
          expect(end.nativeCode, -32000);
          expect(end.nativeMessage, clampUtf8(message, 4096));
          expect(end.nativeMessageTruncated, isTrue);
          expect(end.message, isNotEmpty);
          expect(message, startsWith(end.message!));
          expect(
            utf8.encode(jsonEncode(end.message)).length - 2,
            lessThanOrEqualTo(4096),
          );
          expect(
            events
                .where((e) => e.kind == AgentEventKind.notice)
                .single
                .truncated,
            isTrue,
          );
          expect(events.first.text, 'first prompt');
          expect(events.any((e) => e.kind == AgentEventKind.notice), isTrue);
          if (stopped) {
            expect(stops, hasLength(1));
            expect(stops.single.outcome, AgentStopOutcome.endedWithError);
            expect(stops.single.message, end.message);
            expect(stops.single.late, isFalse);
          } else {
            expect(stops, isEmpty);
          }
          await expectNextTurn();
        },
      );
    }

    test(
      'oversized escaped Unicode stop reason ${stopped ? 'with Stop' : 'without Stop'} '
      'publishes controls and accepts next turn',
      () async {
        final reason = 'cancelled${'\u0000值😀' * 90000}';
        expect(utf8.encode(reason).length, lessThan(1024 * 1024));
        expect(
          utf8.encode(jsonEncode(reason)).length,
          greaterThan(1024 * 1024),
        );
        await prompt('first prompt');
        if (stopped) {
          await desktop.request(
            Method.agentStop,
            const AgentSessionParams('host').toJson(),
          );
        }
        peer.result(promptId(), {'stopReason': reason});
        await receiveCompletion();

        expect(session.state, AgentState.idle);
        expect(ends, hasLength(1));
        expect(ends.single.error, isNull);
        expect(ends.single.stopReason, isNotEmpty);
        expect(reason, startsWith(ends.single.stopReason!));
        expect(
          utf8.encode(jsonEncode(ends.single.stopReason)).length - 2,
          lessThanOrEqualTo(4096),
        );
        if (stopped) {
          expect(stops, hasLength(1));
          // Classification uses the full source, not its bounded prefix.
          expect(stops.single.outcome, AgentStopOutcome.finishedFirst);
          expect(stops.single.stopReason, ends.single.stopReason);
        } else {
          expect(stops, isEmpty);
        }
        await expectNextTurn();
      },
    );
  }
}
