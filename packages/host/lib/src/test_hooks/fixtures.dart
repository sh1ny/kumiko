import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:process_containment/process_containment.dart';

import '../profile_lock.dart';

/// Where fixtures report themselves: each process writes one
/// `role pid startTime marker sid` line to its own
/// `kumiko-fixture-<pid>.out` in the unit's working directory (its target
/// workspace). One file per process, because appends from several processes
/// to one file are not atomic on Windows and can overwrite each other.
const String fixtureReportPrefix = 'kumiko-fixture-';
const String fixtureReportSuffix = '.out';

/// Runs a `--test-fixture` mode (design D10): `tree`, `escaper`, `sleeper`,
/// `stubborn` run as units; `lock-holder <profile>` holds the profile lock and
/// writes nothing. [args] are the mode and its arguments.
Future<int> runTestFixture(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: --test-fixture <mode> [args]');
    return 64;
  }
  switch (args.first) {
    case 'tree':
      _report('tree');
      await _startChild('tree-child');
    case 'tree-child':
      _report('child');
      await _startEscaped('sleeper');
    case 'escaper':
      _report('escaper');
      await _startEscaped('escapee');
    case 'escapee' || 'sleeper':
      _report(args.first);
    case 'stubborn':
      if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen((_) {});
      _report('stubborn');
    case 'lock-holder':
      return _holdLock(args);
    default:
      stderr.writeln('unknown test fixture ${args.first}');
      return 64;
  }
  ReceivePort(); // keeps the isolate, and so the process, alive
  await Completer<void>().future;
  return 0;
}

String get _self => Platform.resolvedExecutable;

void _report(String role) {
  final marker = Platform.environment[unitMarkerVariable] ?? '-';
  final sid = Platform.isWindows ? '-' : '${sessionIdOf(pid)}';
  // Written under a temporary name and renamed, so a reader never sees a
  // partial report.
  final name = '$fixtureReportPrefix$pid';
  File('$name.tmp')
    ..writeAsStringSync(
      '$role $pid ${processStartTime(pid)} $marker $sid\n',
      flush: true,
    )
    ..renameSync('$name$fixtureReportSuffix');
}

Future<void> _startChild(String mode) async {
  await Process.start(_self, ['--test-fixture', mode]);
}

/// A descendant that leaves the unit's POSIX session (it still inherits the
/// marker); on Windows a plain child, which stays in the unit's job.
Future<void> _startEscaped(String mode) async {
  if (Platform.isWindows) return _startChild(mode);
  final id = Platform.environment[unitMarkerVariable]!;
  await Process.start(_self, [
    '--unit-exec',
    id,
    '--',
    _self,
    '--test-fixture',
    mode,
  ]);
}

/// Holds the profile lock and prints `held`, until stdin ends. It writes
/// nothing to the profile except what taking the lock does.
Future<int> _holdLock(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: --test-fixture lock-holder <profile>');
    return 64;
  }
  final lock = await ProfileLock.tryAcquire(Directory(args[1]));
  if (lock == null) {
    stdout.writeln('busy');
    await stdout.flush();
    return 3;
  }
  stdout.writeln('held');
  await stdout.flush();
  await stdin.drain<void>();
  await lock.release();
  return 0;
}
