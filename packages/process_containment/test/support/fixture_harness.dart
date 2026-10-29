import 'dart:io';

import 'package:process_containment/process_containment.dart';

import 'compile_exe.dart';

/// Compiles `pc_main.dart`, the stand-in for the host executable, into a new
/// temporary directory and returns it with the executable path.
Future<(Directory, String)> compileFixtureHost() async {
  final tmp = Directory.systemTemp.createTempSync('pc_fixture_');
  final exe = await compileExe('test/fixtures/pc_main.dart', tmp);
  return (tmp, exe);
}

/// Starts `pc_main --fixture <fixtureArgs>` as a contained unit on the
/// current OS: through the `--unit-exec` shim on POSIX, in a suspended
/// process assigned to its own job on Windows. Fixtures report to [out].
Future<ContainedUnit> startFixtureUnit(
  String exe,
  List<String> fixtureArgs, {
  required String id,
  required File out,
}) async {
  final environment = {'PC_FIXTURE_OUT': out.path};
  if (Platform.isWindows) {
    return spawnWindowsUnit(
      executable: exe,
      args: ['--fixture', ...fixtureArgs],
      containmentId: id,
      environment: environment,
    );
  }
  return spawnPosixUnit(
    shimExecutable: exe,
    containmentId: id,
    argv: [exe, '--fixture', ...fixtureArgs],
    environment: environment,
  );
}

/// Deletes [dir], retrying while Windows still holds the executable of a
/// process that exited a moment ago. Gives up quietly: a temp directory is
/// not worth failing a test run.
Future<void> deleteTempDir(Directory dir) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}
