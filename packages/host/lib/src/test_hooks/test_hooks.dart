import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';

import '../host_extension.dart';
import '../host_options.dart';
import 'fixtures.dart';

/// The test build's registrations (design D10): the `test.*` capabilities,
/// the `test/*` methods and the `--test-fixture` modes. Only
/// `tool/kumiko_host_test.dart` imports this library, so only the test
/// executable contains it.
class TestHostExtension implements HostExtension {
  TestHostExtension({this.options = const HostOptions()});

  /// Options from `KUMIKO_TEST_*` variables, which make timing deterministic:
  /// `UNIT_CAP`, `RECONCILE_DELAY_MS`, `RETRY_DELAY_MS`,
  /// `SHUTDOWN_DEADLINE_MS`.
  factory TestHostExtension.fromEnvironment(Map<String, String> env) {
    int? number(String name) => int.tryParse(env['KUMIKO_TEST_$name'] ?? '');
    Duration? millis(String name) {
      final n = number(name);
      return n == null ? null : Duration(milliseconds: n);
    }

    return TestHostExtension(
      options: HostOptions(
        unitCap: number('UNIT_CAP') ?? HostOptions.defaultUnitCap,
        shutdownDeadline:
            millis('SHUTDOWN_DEADLINE_MS') ??
            HostOptions.defaultShutdownDeadline,
        reconcileDelay: millis('RECONCILE_DELAY_MS') ?? Duration.zero,
        retryDelay: millis('RETRY_DELAY_MS') ?? Duration.zero,
      ),
    );
  }

  @override
  final HostOptions options;

  @override
  Set<String> get capabilities => const {
    Capability.testUnits,
    Capability.testChannels,
    Capability.testFaults,
  };

  @override
  Future<int> runFixture(List<String> args) => runTestFixture(args);

  @override
  Future<Object?> handle(HostServices host, String method, Json params) async {
    switch (method) {
      case Method.testUnitLaunch:
        final p = TestUnitLaunchParams.fromJson(params);
        final id = await host.units.launch(
          target: p.target,
          kind: 'test',
          argv: [Platform.resolvedExecutable, '--test-fixture', p.fixture.name],
        );
        return TestUnitLaunchResult(id).toJson();
      case Method.testUnitEnd:
        final p = TestUnitEndParams.fromJson(params);
        final outcome = await host.units.end(p.containmentId);
        return TestUnitEndResult(
          cleaned: outcome.cleaned,
          reason: outcome.reason,
        ).toJson();
      case Method.testFaultSet:
        final p = TestFaultSetParams.fromJson(params);
        host.faults.set(p.fault, enabled: p.enabled);
        return <String, Object?>{};
      case Method.testChannelOpen:
        final p = TestChannelOpenParams.fromJson(params);
        final channel = host.connection.openOutbound();
        unawaited(_produce(channel, p.rateBytesPerSec));
        return TestChannelOpenResult(channel.id).toJson();
    }
    throw RpcException(ErrorCode.methodNotAvailable, method);
  }

  /// Writes byte `i % 251` at stream offset `i`, at about [rate] bytes per
  /// second (unthrottled when [rate] is 0). Each write waits for credit, so a
  /// channel without credit stops its source (design D7).
  Future<void> _produce(ChannelWriter channel, int rate) async {
    const chunk = 16 * 1024;
    var offset = 0;
    final clock = Stopwatch()..start();
    try {
      while (true) {
        final bytes = Uint8List(chunk);
        for (var i = 0; i < chunk; i++) {
          bytes[i] = (offset + i) % 251;
        }
        await channel.write(bytes);
        offset += chunk;
        if (rate > 0) {
          final due = Duration(microseconds: offset * 1000000 ~/ rate);
          final wait = due - clock.elapsed;
          if (wait > Duration.zero) await Future<void>.delayed(wait);
        }
      }
    } on ChannelClosedException {
      // The desktop closed the channel, or the connection ended.
    }
  }
}
