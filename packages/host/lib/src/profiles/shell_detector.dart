import 'dart:io';
import 'dart:isolate';

/// Shell detection (host-terminals design D6, Resource Bounds "Shell
/// detection"): look for the shells the host knows in `PATH` and the
/// well-known install locations, in the platform's probe order.

/// Most probes one detection runs.
const int maxShellProbes = 20;

/// Longest one detection may take.
const Duration shellDetectionCap = Duration(seconds: 2);

/// The shells probed on [os] (`windows`, `linux` or `macos`), in order. The
/// first one found is the first-launch default.
List<String> probeOrder(String os) => switch (os) {
  'windows' => const ['pwsh', 'powershell', 'nu', 'bash', 'fish'],
  'macos' => const ['zsh', 'bash', 'fish', 'nu', 'pwsh'],
  _ => const ['bash', 'zsh', 'fish', 'nu', 'pwsh'],
};

/// The name shown for a detected shell.
String shellDisplayName(String name, String os) => switch (name) {
  'pwsh' => 'PowerShell (pwsh)',
  'powershell' => 'Windows PowerShell',
  'nu' => 'Nushell',
  'bash' => os == 'windows' ? 'Git Bash' : 'Bash',
  'zsh' => 'Zsh',
  'fish' => 'fish',
  _ => name,
};

/// What a detection searches. Plain data, so it can cross to the isolate.
class DetectionConfig {
  const DetectionConfig({
    required this.os,
    required this.pathDirs,
    required this.wellKnownDirs,
    this.maxProbes = maxShellProbes,
    this.cap = shellDetectionCap,
  });

  final String os;

  /// The `PATH` directories, searched first.
  final List<String> pathDirs;

  /// Install locations searched after `PATH`.
  final List<String> wellKnownDirs;
  final int maxProbes;
  final Duration cap;
}

/// One shell found.
class DetectedShell {
  const DetectedShell({
    required this.name,
    required this.displayName,
    required this.path,
  });

  final String name;
  final String displayName;
  final String path;
}

class DetectionResult {
  const DetectionResult({required this.found, required this.skipped});

  /// Found shells, in probe order.
  final List<DetectedShell> found;

  /// Shells not probed because the probe limit or the time cap was reached.
  final List<String> skipped;
}

/// The `PATH` directories of [env] as the platform splits them.
List<String> pathDirectories(Map<String, String> env) {
  final raw = env['PATH'] ?? env['Path'] ?? '';
  final separator = Platform.isWindows ? ';' : ':';
  return splitSearchPath(raw, separator);
}

List<String> splitSearchPath(String raw, String separator) => [
  for (var part in raw.split(separator))
    if ((part = part.trim().replaceAll('"', '')).isNotEmpty) part,
];

/// The install locations searched after `PATH` on [os].
List<String> wellKnownShellDirs(String os, Map<String, String> env) {
  String? at(String key) {
    final value = env[key];
    return value == null || value.isEmpty ? null : value;
  }

  if (os == 'windows') {
    final programFiles = at('ProgramFiles');
    final systemRoot = at('SystemRoot');
    final local = at('LOCALAPPDATA');
    final home = at('USERPROFILE');
    return [
      if (programFiles != null) ...[
        '$programFiles\\PowerShell\\7',
        '$programFiles\\Git\\bin',
        '$programFiles\\nu\\bin',
      ],
      if (systemRoot != null) '$systemRoot\\System32\\WindowsPowerShell\\v1.0',
      if (local != null) '$local\\Programs\\nu\\bin',
      if (home != null) '$home\\.cargo\\bin',
    ];
  }
  final home = at('HOME');
  return [
    '/usr/local/bin',
    '/usr/bin',
    '/bin',
    if (os == 'macos') '/opt/homebrew/bin',
    '/snap/bin',
    if (home != null) ...['$home/.cargo/bin', '$home/.local/bin'],
  ];
}

/// Runs [detectShells] off the calling isolate.
Future<DetectionResult> detectShellsOffIsolate(DetectionConfig config) =>
    Isolate.run(() => detectShells(config));

/// Probes the shells of `config.os` in order. A probe is one shell looked up
/// in every directory; once `config.maxProbes` probes ran or `config.cap`
/// has passed, the remaining shells are skipped and reported.
DetectionResult detectShells(DetectionConfig config) {
  final clock = Stopwatch()..start();
  final found = <DetectedShell>[];
  final skipped = <String>[];
  var probes = 0;
  for (final name in probeOrder(config.os)) {
    if (probes >= config.maxProbes || clock.elapsed >= config.cap) {
      skipped.add(name);
      continue;
    }
    probes++;
    final path = _find(name, config);
    if (path != null) {
      found.add(
        DetectedShell(
          name: name,
          displayName: shellDisplayName(name, config.os),
          path: path,
        ),
      );
    }
  }
  return DetectionResult(found: found, skipped: skipped);
}

String? _find(String name, DetectionConfig config) {
  final windows = config.os == 'windows';
  final sep = windows ? '\\' : '/';
  final file = windows ? '$name.exe' : name;
  for (final dir in [...config.pathDirs, ...config.wellKnownDirs]) {
    // A relative or empty entry names the working directory of the moment,
    // which can be a checkout: only absolute directories are searched.
    if (!File(dir).isAbsolute) continue;
    final path = dir.endsWith(sep) ? '$dir$file' : '$dir$sep$file';
    if (windows && name == 'bash' && _isWslLauncher(path)) continue;
    if (_isRunnable(path, windows: windows)) return path;
  }
  return null;
}

/// `C:\Windows\System32\bash.exe` starts WSL, not Git Bash.
bool _isWslLauncher(String path) {
  final lower = path.toLowerCase().replaceAll('/', '\\');
  return lower.endsWith('\\windows\\system32\\bash.exe') ||
      lower.endsWith('\\windows\\sysnative\\bash.exe');
}

bool _isRunnable(String path, {required bool windows}) {
  try {
    final stat = FileStat.statSync(path);
    if (stat.type != FileSystemEntityType.file) return false;
    // Any execute bit; Windows has none.
    return windows || (stat.mode & 0x49) != 0;
  } on FileSystemException {
    return false;
  }
}
