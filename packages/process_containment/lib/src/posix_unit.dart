import 'dart:async';
import 'dart:io';

import 'contained_unit.dart';
import 'libc.dart' show esrch;
import 'posix_process_table.dart';
import 'process_table.dart';
import 'unit_exec.dart';

/// The start time of [pid] on POSIX (Linux `/proc/<pid>/stat`, macOS
/// `proc_pidinfo`), or null when it is gone or cannot be read. Opaque: only
/// equality is meaningful.
int? posixProcessStartTime(int pid) {
  try {
    return PosixProcessTable().snapshot(pid)?.startTime;
  } on ProcessReadDenied {
    return null;
  }
}

/// True while [pid] runs with start time [startTime]; a zombie or a reused
/// pid is not alive.
bool posixIsProcessAlive(int pid, int startTime) {
  try {
    final s = PosixProcessTable().snapshot(pid);
    return s != null && !s.zombie && s.startTime == startTime;
  } on ProcessReadDenied {
    return true; // exists; we cannot show it is gone
  }
}

/// Result of a guarded `killpg`.
enum KillOutcome {
  /// The signal was sent to the group.
  signalled,

  /// The leader is gone, so the group is only reachable through the marker
  /// scan.
  leaderGone,

  /// The pid now belongs to a process with another start time.
  startTimeMismatch,

  /// The kernel refused (for example `EPERM`).
  failed,
}

/// Signals the process group led by [leaderPid] only while that leader is
/// alive with [startTime]. A pid that was reused is never signalled
/// (design: Flow & State Gaps).
KillOutcome killProcessGroup(int leaderPid, int startTime, int signal) {
  final ProcessSnapshot? leader;
  try {
    leader = PosixProcessTable().snapshot(leaderPid);
  } on ProcessReadDenied {
    return KillOutcome.failed;
  }
  if (leader == null || leader.zombie) return KillOutcome.leaderGone;
  if (leader.startTime != startTime) return KillOutcome.startTimeMismatch;
  final err = posixKillpg(leaderPid, signal);
  if (err == 0) return KillOutcome.signalled;
  return err == esrch ? KillOutcome.leaderGone : KillOutcome.failed;
}

/// A unit on Linux or macOS: the leader of its own session, started through
/// the `--unit-exec` shim.
class PosixUnit implements ContainedUnit {
  PosixUnit._(this.process, this.startTime, this.containmentId);

  /// The `dart:io` handle; callers own its stdio.
  final Process process;

  @override
  final int startTime;

  @override
  final String containmentId;

  @override
  int get pid => process.pid;

  @override
  Future<int> get exitCode => process.exitCode;

  /// SIGTERM to the session, a grace period, SIGKILL, then a bounded wait
  /// (design: Resource Bounds). Processes outside the session are the marker
  /// scan's business.
  @override
  Future<TerminationResult> terminate({
    Duration grace = const Duration(seconds: 2),
    Duration killWait = const Duration(seconds: 3),
  }) async {
    var exited = false;
    unawaited(exitCode.then((_) => exited = true));

    switch (killProcessGroup(pid, startTime, posixSigterm)) {
      case KillOutcome.signalled:
        break;
      case KillOutcome.leaderGone || KillOutcome.startTimeMismatch:
        // The leader is gone already; wait for its exit to be observed.
        return _await(killWait, () => exited);
      case KillOutcome.failed:
        return const TerminationResult.failed('kill-failed');
    }
    if (await _await(grace, () => exited) case TerminationResult(
      terminated: true,
    )) {
      return const TerminationResult.terminated();
    }

    switch (killProcessGroup(pid, startTime, posixSigkill)) {
      case KillOutcome.signalled || KillOutcome.leaderGone:
        break;
      case KillOutcome.startTimeMismatch:
        return _await(killWait, () => exited);
      case KillOutcome.failed:
        return const TerminationResult.failed('kill-failed');
    }
    return _await(killWait, () => exited);
  }

  static Future<TerminationResult> _await(
    Duration limit,
    bool Function() done,
  ) async {
    final clock = Stopwatch()..start();
    while (!done()) {
      if (clock.elapsed >= limit) {
        return const TerminationResult.failed('termination-timeout');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return const TerminationResult.terminated();
  }
}

/// Starts a unit: `shimExecutable [shimArgs] --unit-exec containmentId --
/// argv...` with `KUMIKO_UNIT` set to the containment id in its environment. The host
/// passes its own executable as [shimExecutable]. The shim makes the process a
/// session leader and `execve`s [argv], so the returned pid and start time are
/// the unit's own.
Future<PosixUnit> spawnPosixUnit({
  required String shimExecutable,
  List<String> shimArgs = const [],
  required String containmentId,
  required List<String> argv,
  Map<String, String>? environment,
  String? workingDirectory,
}) async {
  final process = await Process.start(
    shimExecutable,
    [...shimArgs, '--unit-exec', containmentId, '--', ...argv],
    environment: {...?environment, unitMarkerVariable: containmentId},
    workingDirectory: workingDirectory,
  );
  final startTime = posixProcessStartTime(process.pid);
  if (startTime == null) {
    process.kill(ProcessSignal.sigkill);
    throw StateError(
      'unit ${process.pid} ($containmentId) exited before its start time '
      'could be read',
    );
  }
  return PosixUnit._(process, startTime, containmentId);
}
