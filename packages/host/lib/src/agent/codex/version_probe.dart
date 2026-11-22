import 'dart:io';

import '../../unit_manager.dart';
import '../../host_options.dart';
import '../native_version_probe.dart';
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
  try {
    return await probeNativeVersion(
      units,
      profile,
      [
        executable,
        ...?options.codexProbeArgs,
        if (options.codexProbeArgs == null) '--version',
      ],
      options,
      runtimeName: 'Codex',
      parse: parseCodexVersion,
      environment: environment,
    );
  } on NativeVersionProbeException catch (error) {
    throw CodexProtocolException(error.message);
  }
}
