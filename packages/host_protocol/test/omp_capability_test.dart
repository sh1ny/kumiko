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
