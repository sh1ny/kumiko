import 'dart:async';
import 'dart:io';
import 'dart:convert';

import '../../unit_manager.dart';
import '../../host_options.dart';
import 'codex_client.dart';

/// Exact native identity grammar; prereleases do not become stable by stripping.
String parseCodexVersion(String output) {
  final m = RegExp(
    r'^codex-cli ((0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?)$',
  ).firstMatch(output.trim());
  if (m == null) throw CodexProtocolException('invalid native Codex version');
  final prerelease = m.group(5);
  if (prerelease != null) {
    for (final part in prerelease.split('.')) {
      if (RegExp(r'^[0-9]+$').hasMatch(part) &&
          part.length > 1 &&
          part.startsWith('0')) {
        throw CodexProtocolException('invalid native Codex version prerelease');
      }
    }
  }
  final major = int.tryParse(m.group(2)!);
  final minor = int.tryParse(m.group(3)!);
  final patch = int.tryParse(m.group(4)!);
  if (major == null || minor == null || patch == null) {
    throw CodexProtocolException('invalid native Codex version');
  }
  if (major == 0 &&
      (minor < 166 || (minor == 166 && patch == 0 && prerelease != null))) {
    throw CodexProtocolException('Codex minimum version is 0.166.0');
  }
  return m.group(1)!;
}

/// Separate ledgered unit: no workspace config or grant. Parent inheritance is
/// replaced, retaining only OS/executable resolution needs; UnitManager inserts
/// the mandatory containment marker. Always settle before root admission.
Future<String> probeCodexVersion(
  UnitManager units,
  Directory profile,
  String executable,
  HostOptions options, {
  Map<String, String>? resolutionEnvironment,
}) async {
  final source = resolutionEnvironment ?? Platform.environment;
  final environment = <String, String>{
    for (final key in [
      'SystemRoot',
      'WINDIR',
      'PATH',
      'Path',
      'PATHEXT',
      'TEMP',
      'TMP',
      'CODEX_MANAGED_PACKAGE_ROOT',
      'CODEX_MANAGED_BY_NPM',
      'CODEX_MANAGED_BY_BUN',
      'CODEX_MANAGED_BY_PNPM',
      'CODEX_MANAGED_BY_VITE_PLUS',
    ])
      if (source[key] case final String value) key: value,
  };
  final launch = await units.launch(
    target: profile.path,
    kind: 'agent',
    argv: [
      executable,
      ...?options.codexProbeArgs,
      if (options.codexProbeArgs == null) '--version',
    ],
    workingDirectory: profile.path,
    environment: environment,
    inheritParentEnvironment: false,
    pipes: true,
  );
  final output = <int>[];
  var combinedBytes = 0;
  final failure = Completer<void>();
  void add(List<int> bytes, {bool identityOutput = true}) {
    combinedBytes += bytes.length;
    if (combinedBytes > 4096) {
      if (!failure.isCompleted) {
        failure.completeError(
          CodexProtocolException('Codex version probe exceeds 4 KiB'),
        );
      }
    } else if (identityOutput) {
      output.addAll(bytes);
    }
  }

  final outDone = Completer<void>();
  final errDone = Completer<void>();
  final out = launch.pipes!.stdout.listen(
    add,
    onDone: outDone.complete,
    onError: (Object e) {
      if (!failure.isCompleted) failure.completeError(e);
    },
  );
  final err = launch.pipes!.stderr.listen(
    (bytes) => add(bytes, identityOutput: false),
    onDone: errDone.complete,
    onError: (Object e) {
      if (!failure.isCompleted) failure.completeError(e);
    },
  );
  try {
    final status =
        await Future.any([launch.unit.exitCode, failure.future.then((_) => 0)])
            .timeout(
              const Duration(seconds: 5),
              onTimeout: () =>
                  throw CodexProtocolException('Codex version probe timed out'),
            );
    if (status != 0) {
      throw CodexProtocolException('Codex version probe exited $status');
    }
    // Exit precedes pipe EOF on Windows; settle then join bounded streams below.
    if (units.live.containsKey(launch.id)) {
      final result = await units.end(launch.id).timeout(options.settleDeadline);
      if (!result.cleaned) {
        throw CodexProtocolException('Codex version probe cleanup unresolved');
      }
    }
    await Future.wait([outDone.future, errDone.future])
        .timeout(options.postExitReadDeadline);
    if (failure.isCompleted) await failure.future;
    return parseCodexVersion(utf8.decode(output, allowMalformed: true));
  } finally {
    if (units.live.containsKey(launch.id)) {
      await units.end(launch.id).timeout(options.settleDeadline);
    }
    await out.cancel();
    await err.cancel();
    await launch.pipes!.close();
  }
}
