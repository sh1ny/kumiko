import 'dart:async';
import 'dart:convert';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/sinks.dart';

void main() {
  test(
    'agent/start result names a session id and a unique host-allocated channel',
    () async {
      late Connection host;
      final channels = <String, int>{};
      final pair = connectedPair(
        capabilitiesA: {Capability.agent},
        capabilitiesB: {Capability.agent},
        onRequestB: (method, params) {
          if (method == Method.agentStart) {
            final id = 's${channels.length}';
            final channel = host.reserveChannels(1).ids.single;
            channels[id] = channel;
            return AgentStartResult(
              sessionId: id,
              eventChannel: channel,
              adapter: const AgentAdapter(name: 'fixture', version: '1'),
              capabilities: const ['prompt'],
            ).toJson();
          }
          if (method == Method.agentAttach) {
            final id = AgentSessionParams.fromJson(params).sessionId;
            final writer = host.attachOutbound(channels[id]!);
            unawaited(
              writer.write(encodeAgentEvent(AgentEvent.notice(id)).single),
            );
            return const EmptyResult().toJson();
          }
          throw RpcException(ErrorCode.methodNotAvailable);
        },
      );
      final desktop = pair.$1;
      host = pair.$2;
      await desktop.hello();
      // Existing terminal channels and other agent channels occupy the same id space.
      final existing = host.reserveChannels(2).ids;
      final results = <AgentStartResult>[];
      for (var i = 0; i < 4; i++) {
        results.add(
          AgentStartResult.fromJson(
            await desktop.request(
              Method.agentStart,
              const AgentStartParams(workspaceId: 'w').toJson(),
            ) as Json,
          ),
        );
      }
      expect({
        ...existing,
        ...results.map((r) => r.eventChannel),
      }, hasLength(6));
      expect(results.map((r) => r.sessionId).toSet(), hasLength(4));
      final received = <String, List<AgentEvent>>{};
      for (final result in results) {
        final decoder = AgentEventDecoder();
        final events = received[result.sessionId] = [];
        desktop
            .attachInbound(result.eventChannel, grantInitial: false)
            .listen((bytes) => events.addAll(decoder.add(bytes)));
        await desktop.request(
          Method.agentAttach,
          AgentSessionParams(result.sessionId).toJson(),
        );
        desktop.grantInitial(result.eventChannel);
      }
      await settle();
      for (final result in results) {
        expect(received[result.sessionId]!.single.text, result.sessionId);
      }
      expect(desktop.isClosed, isFalse);
      expect(host.isClosed, isFalse);
      await desktop.close();
      await host.close();
    },
  );

  test('agent reservation sends no frame before attach', () async {
    final output = RecordingSink();
    final connection = Connection(
      input: const Stream<List<int>>.empty(),
      output: output,
    );
    final reservation = connection.reserveChannels(1);
    expect(reservation.ids, hasLength(1));
    await settle();
    expect(output.frames, isEmpty);
    reservation.release();
    await connection.close();
  });

  test('agent attach result and first event coalesced in one read keep connection open', () async {
    final input = StreamController<List<int>>();
    final output = RecordingSink();
    final desktop = Connection(input: input.stream, output: output);
    final start = desktop.request(Method.agentStart, {'workspaceId': 'w'});
    input.add(
      _response(
        1,
        const AgentStartResult(
          sessionId: 's',
          eventChannel: 11,
          adapter: AgentAdapter(name: 'fixture', version: '1'),
          capabilities: ['prompt'],
        ).toJson(),
      ),
    );
    final result = AgentStartResult.fromJson(await start as Json);
    final decoder = AgentEventDecoder();
    final events = <AgentEvent>[];
    desktop
        .attachInbound(result.eventChannel, grantInitial: false)
        .listen((bytes) => events.addAll(decoder.add(bytes)));
    final attach = desktop.request(
      Method.agentAttach,
      const AgentSessionParams('s').toJson(),
    );
    await settle();
    expect(output.frames.where((f) => f.kind == FrameKind.credit), isEmpty);
    input.add([
      ..._response(2, {}),
      ...encodeFrame(
        11,
        FrameKind.data,
        encodeAgentEvent(AgentEvent.text(AgentEventKind.agentText, 'first'))
            .single,
      ),
    ]);
    await attach;
    await settle();
    expect(events.single.text, 'first');
    expect(desktop.isClosed, isFalse);
    desktop.grantInitial(11);
    await desktop.close();
    await input.close();
  });
}

List<int> _response(int id, Object result) => [
  for (final frame in encodeMessageFrames(
    controlChannel,
    utf8.encode(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result})),
  ))
    ...frame,
];
