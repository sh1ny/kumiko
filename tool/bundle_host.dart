/// Bundles the release host into the Flutter app bundle (ADR 0008, design D3).
///
/// Builds the release host with `dart build cli -o build/host` from
/// `packages/host`, then copies the resulting `build/host/bundle/` (`bin/` and
/// `lib/`) as `host/` into the app bundle, so the app finds
/// `host/bin/kumiko_host[.exe]` beside its own executable and the host loads
/// SQLite from `host/lib/`.
///
/// Usage, from the repository root, after `flutter build <os> --release`:
///
///     dart run tool/bundle_host.dart [--bundle <dir>] [--skip-build]
///
/// `--bundle` overrides the per-OS release bundle directory (for example the
/// debug runner, `packages/desktop/build/windows/x64/runner/Debug`).
/// `--skip-build` reuses an existing `packages/host/build/host/bundle/`.
///
/// `dart build cli` needs `FLUTTER_ROOT` because the workspace has a Flutter
/// package. The tool derives it from `flutter` on `PATH` when it is unset.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// The Flutter release bundle directory for [os] (`windows`, `linux` or
/// `macos`), relative to the repository root.
String defaultBundleDir(String os) => switch (os) {
  'windows' => p.join(
    'packages',
    'desktop',
    'build',
    'windows',
    'x64',
    'runner',
    'Release',
  ),
  'linux' => p.join(
    'packages',
    'desktop',
    'build',
    'linux',
    'x64',
    'release',
    'bundle',
  ),
  // The host sits beside the app executable inside the .app.
  'macos' => p.join(
    'packages',
    'desktop',
    'build',
    'macos',
    'Build',
    'Products',
    'Release',
    'Kumiko.app',
    'Contents',
    'MacOS',
  ),
  _ => throw ArgumentError('unsupported OS: $os'),
};

/// Copies the host build output [hostBundle] (`bin/`, `lib/`) to
/// `<bundleDir>/host`, replacing any earlier copy. Returns the destination.
Directory copyHostBundle({
  required Directory hostBundle,
  required Directory bundleDir,
}) {
  if (!bundleDir.existsSync()) {
    throw StateError(
      'app bundle ${bundleDir.path} does not exist; build the app first '
      '(flutter build <os> --release)',
    );
  }
  final exe = p.join(
    hostBundle.path,
    'bin',
    Platform.isWindows ? 'kumiko_host.exe' : 'kumiko_host',
  );
  if (!File(exe).existsSync()) {
    throw StateError('host build output has no $exe');
  }
  final dest = Directory(p.join(bundleDir.path, 'host'));
  if (dest.existsSync()) dest.deleteSync(recursive: true);
  _copy(hostBundle, dest);
  return dest;
}

void _copy(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final entity in from.listSync(followLinks: false)) {
    final target = p.join(to.path, p.basename(entity.path));
    if (entity is Directory) {
      _copy(entity, Directory(target));
    } else if (entity is File) {
      entity.copySync(target);
    }
  }
}

String? _flutterRootFromPath() {
  final names = Platform.isWindows
      ? ['flutter.bat', 'flutter.exe', 'flutter.cmd']
      : ['flutter'];
  final separator = Platform.isWindows ? ';' : ':';
  for (final dir in (Platform.environment['PATH'] ?? '').split(separator)) {
    if (dir.isEmpty) continue;
    for (final name in names) {
      final file = File(p.join(dir, name));
      if (file.existsSync()) {
        return p.dirname(p.dirname(file.resolveSymbolicLinksSync()));
      }
    }
  }
  return null;
}

Future<void> main(List<String> args) async {
  String? bundle;
  var skipBuild = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--bundle':
        if (++i >= args.length) {
          stderr.writeln('--bundle needs a directory');
          exitCode = 64;
          return;
        }
        bundle = args[i];
      case '--skip-build':
        skipBuild = true;
      default:
        stderr.writeln('unknown argument: ${args[i]}');
        exitCode = 64;
        return;
    }
  }

  final root = Directory.current.path;
  final hostDir = p.join(root, 'packages', 'host');
  if (!skipBuild) {
    final environment = Map<String, String>.of(Platform.environment);
    if ((environment['FLUTTER_ROOT'] ?? '').isEmpty) {
      final flutterRoot = _flutterRootFromPath();
      if (flutterRoot != null) environment['FLUTTER_ROOT'] = flutterRoot;
    }
    final build = await Process.start(
      Platform.resolvedExecutable,
      ['build', 'cli', '-o', 'build/host'],
      workingDirectory: hostDir,
      environment: environment,
      mode: ProcessStartMode.inheritStdio,
    );
    final code = await build.exitCode;
    if (code != 0) {
      stderr.writeln('dart build cli failed with exit code $code');
      exitCode = code;
      return;
    }
  }

  final os = Platform.isWindows
      ? 'windows'
      : Platform.isMacOS
      ? 'macos'
      : 'linux';
  final bundleDir = Directory(p.absolute(bundle ?? defaultBundleDir(os)));
  try {
    final dest = copyHostBundle(
      hostBundle: Directory(p.join(hostDir, 'build', 'host', 'bundle')),
      bundleDir: bundleDir,
    );
    stdout.writeln('Bundled the host into ${dest.path}');
  } on StateError catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
  }
}
