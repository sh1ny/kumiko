import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../host_options.dart';
import '../unit_manager.dart';

final class NativeVersionProbeException implements Exception {
  const NativeVersionProbeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Probe in a separate ledgered unit with no inherited environment or grant.
/// Settle it before returning an identity that can admit a runtime launch.
Future<String> probeNativeVersion(
  UnitManager units,
  Directory profile,
  List<String> argv,
  HostOptions options, {
  required String runtimeName,
  required String Function(String) parse,
  required Map<String, String> environment,
}) async {
  final launch = await units.launch(
    target: profile.path,
    kind: 'agent',
    argv: argv,
    workingDirectory: profile.path,
    environment: environment,
    inheritParentEnvironment: false,
    pipes: true,
  );
  final pipes = launch.pipes!;
  final output = <int>[];
  var combinedBytes = 0;
  final failure = Completer<Never>();
  void fail(Object error) {
    if (!failure.isCompleted) failure.completeError(error);
  }

  void count(List<int> bytes, {bool identityOutput = true}) {
    combinedBytes += bytes.length;
    if (combinedBytes > 4096) {
      fail(
        NativeVersionProbeException('$runtimeName version probe exceeds 4 KiB'),
      );
    } else if (identityOutput) {
      output.addAll(bytes);
    }
  }

  final outDone = Completer<void>();
  final errDone = Completer<void>();
  final out = pipes.stdout.listen(
    count,
    onDone: outDone.complete,
    onError: fail,
  );
  final err = pipes.stderr.listen(
    (bytes) => count(bytes, identityOutput: false),
    onDone: errDone.complete,
    onError: fail,
  );
  try {
    final status = await Future.any([launch.unit.exitCode, failure.future])
        .timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw NativeVersionProbeException(
            '$runtimeName version probe timed out',
          ),
        );
    if (status != 0) {
      throw NativeVersionProbeException(
        '$runtimeName version probe exited $status',
      );
    }
    // Exit precedes pipe EOF on Windows; settle then join bounded streams below.
    if (units.live.containsKey(launch.id)) {
      final result = await units.end(launch.id).timeout(options.settleDeadline);
      if (!result.cleaned) {
        throw NativeVersionProbeException(
          '$runtimeName version probe cleanup unresolved',
        );
      }
    }
    await Future.wait([outDone.future, errDone.future])
        .timeout(options.postExitReadDeadline);
    if (failure.isCompleted) await failure.future;
    return parse(utf8.decode(output, allowMalformed: true));
  } finally {
    if (units.live.containsKey(launch.id)) {
      await units.end(launch.id).timeout(options.settleDeadline);
    }
    await out.cancel();
    await err.cancel();
    await pipes.close();
  }
}
