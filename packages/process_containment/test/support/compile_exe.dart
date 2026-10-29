import 'dart:io';

import 'package:path/path.dart' as p;

/// Compiles [entry] (relative to the package root, the cwd of `dart test`)
/// with `dart compile exe` into [outDir] and returns the executable path.
Future<String> compileExe(String entry, Directory outDir) async {
  final name = p.basenameWithoutExtension(entry);
  final out = p.join(outDir.path, Platform.isWindows ? '$name.exe' : name);
  final result = await Process.run(Platform.resolvedExecutable, [
    'compile',
    'exe',
    entry,
    '-o',
    out,
  ]);
  if (result.exitCode != 0) {
    throw StateError(
      'dart compile exe $entry failed (${result.exitCode})\n'
      '${result.stdout}\n${result.stderr}',
    );
  }
  return out;
}
