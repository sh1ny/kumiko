import 'dart:io';

/// Builds the test host once per run (design D10, ADR 0008):
/// `dart build cli -t tool/kumiko_host_test.dart -o build/host-test` from
/// `packages/host`. `dart compile exe` cannot build the sqlite3 hooks.
///
/// Integration test files run in separate processes, so the build is guarded
/// by a lock, and an existing build newer than every source it depends
/// on is reused. A build goes to a directory of its own first and is moved
/// into place.
const String _out = 'build/host-test';

/// The release host (ADR 0008): `dart build cli -o <dir>` (a directory of its own, apart from the
/// packaged `build/host`) from
/// `packages/host`, which builds `bin/kumiko_host.dart`.
const String _releaseOut = 'build/host-release';

String get _exeName =>
    Platform.isWindows ? 'kumiko_host_test.exe' : 'kumiko_host_test';

String get _releaseExeName =>
    Platform.isWindows ? 'kumiko_host.exe' : 'kumiko_host';

String? _built;
String? _releaseBuilt;
String? _standin;
String? _terminalFixture;

/// The compiled desktop stand-in (`dart run` would rebuild the native assets
/// the test process has loaded). Call `buildTestHost` first.
String desktopStandinExecutable() =>
    _standin ?? (throw StateError('call buildTestHost() in setUpAll first'));

/// The compiled fixture shell of the terminal tests
/// (`test/it/fixtures/term_fixture.dart`). Call `buildTestHost` first.
String terminalFixtureExecutable() =>
    _terminalFixture ??
    (throw StateError('call buildTestHost() in setUpAll first'));

/// The built test host executable. Call it from `setUpAll`.
String testHostExecutable() =>
    _built ?? (throw StateError('call buildTestHost() in setUpAll first'));

/// The built release host executable. Call `buildReleaseHost` first.
String releaseHostExecutable() =>
    _releaseBuilt ??
    (throw StateError('call buildReleaseHost() in setUpAll first'));

Future<void> buildTestHost() async {
  if (_built != null) return;
  final packageDir = Directory.current;
  final exe = _bundleExe(packageDir, _out, _exeName);
  Directory('${packageDir.path}/build').createSync(recursive: true);
  final lock = await _acquire(_lockFile(packageDir, 'host-test'));
  try {
    if (!_upToDate(exe, packageDir)) {
      await _build(packageDir, exe, _out, _exeName, [
        '-t',
        'tool/kumiko_host_test.dart',
      ]);
    }
    _standin = await _compile(
      packageDir,
      'test/it/support/desktop_standin.dart',
      'build/standin',
      'desktop_standin',
    );
    _terminalFixture = await _compile(
      packageDir,
      'test/it/fixtures/term_fixture.dart',
      'build/term-fixture',
      'term_fixture',
    );
  } finally {
    lock.deleteSync();
  }
  _built = exe.path;
}

/// Builds the release host the same safe way as the test host: an exclusive
/// lock between test files, a build into a directory of its own, and a move
/// into place.
Future<void> buildReleaseHost() async {
  if (_releaseBuilt != null) return;
  final packageDir = Directory.current;
  final exe = _bundleExe(packageDir, _releaseOut, _releaseExeName);
  Directory('${packageDir.path}/build').createSync(recursive: true);
  final lock = await _acquire(_lockFile(packageDir, 'host-release'));
  try {
    if (!_upToDate(exe, packageDir)) {
      await _build(packageDir, exe, _releaseOut, _releaseExeName, const []);
    }
  } finally {
    lock.deleteSync();
  }
  _releaseBuilt = exe.path;
}

File _bundleExe(Directory packageDir, String out, String name) => File(
  '${packageDir.path}/$out/bundle/bin/$name'.replaceAll(
    '/',
    Platform.pathSeparator,
  ),
);

File _lockFile(Directory packageDir, String name) => File(
  '${packageDir.path}/build/$name.lock'.replaceAll('/', Platform.pathSeparator),
);

/// Compiles [sourcePath] (relative to the package) to `<outDir>/<name>` with
/// `dart compile exe` unless that is newer than the source and every
/// package it can depend on (`dart run` would rebuild the native assets the
/// test process has loaded). Returns the executable's path.
Future<String> _compile(
  Directory packageDir,
  String sourcePath,
  String outDir,
  String name,
) async {
  final sep = Platform.pathSeparator;
  final exe = File(
    '${packageDir.path}/$outDir/${Platform.isWindows ? '$name.exe' : name}'
        .replaceAll('/', sep),
  );
  final source = File('${packageDir.path}/$sourcePath'.replaceAll('/', sep));
  var stale = !exe.existsSync();
  if (!stale) {
    final built = exe.lastModifiedSync();
    stale = source.lastModifiedSync().isAfter(built);
    for (final root in ['host_protocol', 'process_containment']) {
      for (final e in Directory(
        '${packageDir.path}/../$root/lib',
      ).listSync(recursive: true)) {
        if (e is File && e.lastModifiedSync().isAfter(built)) stale = true;
      }
    }
  }
  if (stale) {
    exe.parent.createSync(recursive: true);
    final result = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      source.path,
      '-o',
      exe.path,
    ], workingDirectory: packageDir.path);
    if (result.exitCode != 0 || !exe.existsSync()) {
      throw StateError(
        'dart compile exe failed (${result.exitCode}):\n'
        '${result.stdout}\n${result.stderr}',
      );
    }
  }
  return exe.path;
}

/// Builds into a directory of its own and moves it into place, so a build
/// never shares its output with another one and nobody sees a half-written
/// bundle.
Future<void> _build(
  Directory packageDir,
  File exe,
  String outPath,
  String exeName,
  List<String> entryArgs,
) async {
  final sep = Platform.pathSeparator;
  final out = Directory(
    '${packageDir.path}$sep${outPath.replaceAll('/', sep)}',
  );
  final temp = '$outPath-$pid';
  final tempDir = Directory(
    '${packageDir.path}$sep${temp.replaceAll('/', sep)}',
  );
  if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  try {
    final result = await Process.run(Platform.resolvedExecutable, [
      'build',
      'cli',
      ...entryArgs,
      '-o',
      temp,
    ], workingDirectory: packageDir.path);
    final built = File('${tempDir.path}${sep}bundle${sep}bin$sep$exeName');
    if (result.exitCode != 0 || !built.existsSync()) {
      throw StateError(
        'dart build cli failed (${result.exitCode}):\n'
        '${result.stdout}\n${result.stderr}',
      );
    }
    if (out.existsSync()) out.deleteSync(recursive: true);
    tempDir.renameSync(out.path);
  } finally {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  }
  if (!exe.existsSync()) throw StateError('no host at ${exe.path}');
}

/// A lock that works between test files, which `dart test` loads as isolates
/// of one process (a file lock is per process on POSIX) as well as between
/// processes: creating a file exclusively succeeds for one caller only. A lock left
/// by a killed run goes stale after five minutes.
Future<File> _acquire(File lock) async {
  while (true) {
    try {
      lock.createSync(exclusive: true);
      return lock;
    } on FileSystemException {
      try {
        final stat = lock.statSync();
        final age = DateTime.now().difference(stat.modified);
        if (stat.type != FileSystemEntityType.notFound &&
            age > const Duration(minutes: 5)) {
          lock.deleteSync();
        }
      } on FileSystemException {
        // released in the meantime
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

bool _upToDate(File exe, Directory packageDir) {
  if (!exe.existsSync()) return false;
  final built = exe.lastModifiedSync();
  final roots = [
    Directory('${packageDir.path}/lib'),
    Directory('${packageDir.path}/tool'),
    Directory('${packageDir.path}/../host_protocol/lib'),
    Directory('${packageDir.path}/../process_containment/lib'),
    Directory('${packageDir.path}/../domain/lib'),
  ];
  for (final root in roots) {
    if (!root.existsSync()) continue;
    for (final e in root.listSync(recursive: true)) {
      if (e is File && e.path.endsWith('.dart')) {
        if (e.lastModifiedSync().isAfter(built)) return false;
      }
    }
  }
  for (final name in ['pubspec.yaml', '../../pubspec.lock']) {
    final f = File('${packageDir.path}/$name');
    if (f.existsSync() && f.lastModifiedSync().isAfter(built)) return false;
  }
  return true;
}
