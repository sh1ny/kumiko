import 'dart:convert';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/sinks.dart';

void main() {
  test('hello negotiates the OMP wire capability', () async {
    final (desktop, host) = connectedPair(
      capabilitiesA: {Capability.agent, Capability.omp},
      capabilitiesB: {'agent', 'omp'},
    );
    addTearDown(host.close);
    addTearDown(desktop.close);

    final hello = await desktop.hello();

    expect(hello.capabilities, {'agent', 'omp'});
    expect(host.negotiated?.capabilities, {'agent', 'omp'});
    requireOmpCapabilities(hello.capabilities);
  });

  test('supported runtime kinds include OMP after Claude and Codex', () {
    expect(supportedRuntimeKinds, ['claude-code', 'codex', 'omp']);
  });

  test('OMP: Child shape without direct parent is gated', () {
    final bytes = utf8.encode(
      '${jsonEncode({'kind': 'agentText', 'text': 'child-only', 'rootThreadId': 'run', 'threadId': 'run:child:1'})}\n',
    );
    expect(() => AgentEventDecoder().add(bytes), throwsFormatException);
    final event = AgentEventDecoder(allowOmpChildEvents: true)
        .add(bytes)
        .single;
    expect(event.rootThreadId, 'run');
    expect(event.threadId, 'run:child:1');
    expect(event.parentThreadId, isNull);
    expect(event.text, 'child-only');
  });

  test('OMP: History capability gates only new operations', () async {
    final (desktop, host) = connectedPair(
      capabilitiesA: {'agent', 'omp'},
      capabilitiesB: {'agent', 'omp', 'omp-history'},
      onRequestB: (method, _) => method,
    );
    addTearDown(host.close);
    addTearDown(desktop.close);
    await desktop.hello();
    expect(await desktop.request(Method.agentStart, {}), Method.agentStart);
    await expectLater(
      desktop.request('agent/childHistory', {}),
      throwsA(
        isA<RpcException>().having(
          (e) => e.reason,
          'reason',
          ErrorCode.methodNotAvailable,
        ),
      ),
    );
  });

  for (final missing in ['agent', 'omp']) {
    test('OMP gate names missing $missing capability', () {
      expect(
        () => requireOmpCapabilities({'agent', 'omp'}..remove(missing)),
        throwsA(
          isA<RpcException>()
              .having(
                (error) => error.reason,
                'reason',
                ErrorCode.methodNotAvailable,
              )
              .having(
                (error) => error.message,
                'message',
                'OMP requires $missing',
              ),
        ),
      );
    });
  }
}
