import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';

import '../host_extension.dart';
import '../host_faults.dart';
import '../host_options.dart';
import '../profiles/shell_detector.dart' show splitSearchPath;
import 'fixtures.dart';

/// The test build's registrations (design D10): the `test.*` capabilities,
/// the `test/*` methods and the `--test-fixture` modes. Only
/// `tool/kumiko_host_test.dart` imports this library, so only the test
/// executable contains it.
class TestHostExtension implements HostExtension {
  TestHostExtension({this.options = const HostOptions()});

  /// Options from `KUMIKO_TEST_*` variables, which make timing deterministic:
  /// `UNIT_CAP`, `RECONCILE_DELAY_MS`, `RETRY_DELAY_MS`,
  /// `SHUTDOWN_DEADLINE_MS`, `WORKSPACE_CAP`, `RESOLVE_TIMEOUT_MS`.
  /// `KUMIKO_TEST_SHELL_PATH` replaces `PATH` for shell detection (entries
  /// split by the platform's path separator) and switches the well-known
  /// install locations off; `KUMIKO_TEST_SHELL_DIRS` lists them instead.
  factory TestHostExtension.fromEnvironment(Map<String, String> env) {
    int? number(String name) => int.tryParse(env['KUMIKO_TEST_$name'] ?? '');
    Duration? millis(String name) {
      final n = number(name);
      return n == null ? null : Duration(milliseconds: n);
    }

    final separator = Platform.isWindows ? ';' : ':';
    final shellPath = env['KUMIKO_TEST_SHELL_PATH'];
    return TestHostExtension(
      options: HostOptions(
        shellSearchPath: shellPath == null
            ? null
            : splitSearchPath(shellPath, separator),
        shellWellKnownDirs: shellPath == null
            ? null
            : splitSearchPath(env['KUMIKO_TEST_SHELL_DIRS'] ?? '', separator),
        unitCap: number('UNIT_CAP') ?? HostOptions.defaultUnitCap,
        shutdownDeadline:
            millis('SHUTDOWN_DEADLINE_MS') ??
            HostOptions.defaultShutdownDeadline,
        reconcileDelay: millis('RECONCILE_DELAY_MS') ?? Duration.zero,
        retryDelay: millis('RETRY_DELAY_MS') ?? Duration.zero,
        workspaceCap:
            number('WORKSPACE_CAP') ?? HostOptions.defaultWorkspaceCap,
        resolveTimeout:
            millis('RESOLVE_TIMEOUT_MS') ?? HostOptions.defaultResolveTimeout,
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
      case Method.testResolveFault:
        final p = TestResolveFaultParams.fromJson(params);
        host.faults.setResolveFault(
          p.path,
          p.hang || p.delayMs != null
              ? ResolveFault(
                  delay: Duration(milliseconds: p.delayMs ?? 0),
                  hang: p.hang,
                )
              : null,
        );
        return <String, Object?>{};
      case Method.testResolveRelease:
        host.faults.releaseResolve(
          TestResolveReleaseParams.fromJson(params).path,
        );
        return <String, Object?>{};
      case Method.testChannelOpen:
        final p = TestChannelOpenParams.fromJson(params);
        final channel = host.connection.openOutbound();
        final producer = _producers[channel.id] = _Producer(channel);
        unawaited(producer.run(p.rateBytesPerSec, p.writeBytes));
        return TestChannelOpenResult(channel.id).toJson();
      case Method.testChannelStats:
        final p = TestChannelStatsParams.fromJson(params);
        final producer = _producers[p.channel];
        if (producer == null) {
          throw RpcException(
            ErrorCode.invalidParams,
            'no test channel ${p.channel}',
          );
        }
        return TestChannelStatsResult(
          producedBytes: producer.produced,
          sentBytes: producer.channel.sentBytes,
          queuedBytes: producer.channel.queuedBytes,
        ).toJson();
    }
    throw RpcException(ErrorCode.methodNotAvailable, method);
  }

  /// Test channels' producers by channel id, for `test/channel.stats`.
  final Map<int, _Producer> _producers = {};
}

/// The source of one test channel.
class _Producer {
  _Producer(this.channel);

  final ChannelWriter channel;

  /// Bytes read from the source so far.
  int produced = 0;

  /// Writes byte `i % 251` at stream offset `i` in writes of at most
  /// [chunk] bytes, at about [rate] bytes per second (unthrottled when
  /// [rate] is 0). The source is read only once the writer has room, and no
  /// more than that room, so a channel without credit stops its source and
  /// the host holds at most a window of it unsent (design D7).
  Future<void> run(int rate, int chunk) async {
    final clock = Stopwatch()..start();
    try {
      while (true) {
        await channel.ready;
        final n = math.min(chunk, channel.room);
        final bytes = Uint8List(n);
        for (var i = 0; i < n; i++) {
          bytes[i] = (produced + i) % 251;
        }
        produced += n;
        channel.write(bytes).ignore();
        if (rate > 0) {
          final due = Duration(microseconds: produced * 1000000 ~/ rate);
          final wait = due - clock.elapsed;
          if (wait > Duration.zero) await Future<void>.delayed(wait);
        }
      }
    } on ChannelClosedException {
      // The desktop closed the channel, or the connection ended.
    }
  }
}
