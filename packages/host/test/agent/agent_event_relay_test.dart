import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:host/src/agent/acp/acp_client.dart';
import 'package:host/src/agent/agent_service.dart';
import 'package:host/src/agent/agent_session.dart';
import 'package:host/src/agent/normalizer.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/acp_peer.dart';

class _MemoryPipe implements ByteSink {
  final controller = StreamController<List<int>>();
  @override
  void add(List<int> bytes) => controller.add(Uint8List.fromList(bytes));
  @override
  Future<void> flush() async {}
}

void main() {
  test('escaped control text pauses at the relay bound without retaining the large-line permit and resumes losslessly', () async {
    final forward = _MemoryPipe();
    final reverse = _MemoryPipe();
    final desktop = Connection(
      input: reverse.controller.stream,
      output: forward,
    );
    final host = Connection(
      input: forward.controller.stream,
      output: reverse,
      onHello: (_, _) => HelloInfo.ready('relay-test'),
    );
    addTearDown(() async {
      await desktop.close();
      await host.close();
      await forward.controller.close();
      await reverse.controller.close();
    });
    await desktop.hello();
    final id = host.reserveChannels(1).ids.single;
    final paused = Completer<void>();
    final relay = AgentEventRelay(
      onPauseChanged: (value) {
        if (value && !paused.isCompleted) paused.complete();
      },
    );
    addTearDown(relay.close);
    relay.attach(host.attachOutbound(id));
    final decoder = AgentEventDecoder();
    var textBytes = 0;
    final delivered = Completer<void>();
    final reading = desktop.attachInbound(id, grantInitial: false).listen((
      bytes,
    ) {
      for (final event in decoder.add(bytes)) {
        expect(event.kind, AgentEventKind.agentText);
        expect(event.text!.runes.every((r) => r == 1), isTrue);
        textBytes += event.text!.length;
        if (textBytes == maxAgentTextChunkBytes && !delivered.isCompleted) {
          delivered.complete();
        }
      }
    });
    addTearDown(reading.cancel);
    final permit = LargeLinePermit();
    final first = AcpPeer(permit: permit);
    final second = AcpPeer(permit: permit);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final session = AgentSession(
      sessionId: 'relay',
      client: first.client,
      onState: (_) {},
      onPermissionRequested: (_) {},
      onPermissionResolved: (_) {},
      onStopResult: (_) {},
      onTurnEnded: (_) {},
      enqueueEvents: relay.enqueue,
    );
    addTearDown(session.dispose);
    session.ready(nativeSessionId: 'native');
    addChunks(
      first,
      utf8.encode(
        '${jsonEncode({
          'jsonrpc': '2.0',
          'method': 'session/update',
          'params': {
            'sessionId': 'native',
            'update': {
              'sessionUpdate': 'agent_message_chunk',
              'content': {'type': 'text', 'text': '\u0001' * maxAgentTextChunkBytes},
            },
          },
        })}\n',
      ),
    );
    await paused.future;
    expect(relay.isPaused, isTrue);
    expect(
      relay.queuedBytes,
      lessThanOrEqualTo(1024 * 1024 + maxAgentEventBytes + 1),
    );
    expect(textBytes, 0);
    final otherNormalized = Completer<void>();
    second.client.normalizeNotification = (_, params) {
      final value = normalizeAcpUpdate(params['update'] as Json);
      otherNormalized.complete();
      return value;
    };
    addChunks(second, largeUpdate(1100000));
    await otherNormalized.future;
    expect(first.client.isClosed, isFalse);
    desktop.grantInitial(id);
    await delivered.future;
    await pumpAcp();
    expect(relay.queuedBytes, 0);
    expect(relay.isPaused, isFalse);
    decoder.close();
  });
}
