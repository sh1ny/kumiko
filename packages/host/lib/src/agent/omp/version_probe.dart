import '../native_version_probe.dart';

const _minimumVersion = '18.20.1';
final _versionLine = RegExp(
  r'^omp/((0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?)(?:\r?\n)?$',
);

/// Parse one native version line. A prerelease does not meet its stable minimum.
String parseOmpVersion(String output) {
  const invalid = NativeVersionProbeException('invalid native OMP version');
  final match = _versionLine.firstMatch(output);
  if (match == null || match.end != output.length) throw invalid;
  final major = int.tryParse(match.group(2)!);
  final minor = int.tryParse(match.group(3)!);
  final patch = int.tryParse(match.group(4)!);
  if (major == null || minor == null || patch == null) throw invalid;
  final version = match.group(1)!;
  if (major < 18 ||
      (major == 18 &&
          (minor < 20 ||
              (minor == 20 &&
                  (patch < 1 || (patch == 1 && match.group(5) != null)))))) {
    throw NativeVersionProbeException(
      'OMP version $version is below the minimum $_minimumVersion',
    );
  }
  return version;
}

/// OMP's version probe needs resolution and profile directories, not keys.
Map<String, String> ompProbeEnvironment(Map<String, String> source) => {
  for (final key in const [
    'SystemRoot',
    'WINDIR',
    'PATH',
    'PATHEXT',
    'TEMP',
    'TMP',
    'HOME',
    'USERPROFILE',
    'LOCALAPPDATA',
  ])
    if (source[key] case final String value) key: value,
};
