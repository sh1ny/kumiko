import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:ffi/ffi.dart';

import 'contained_unit.dart';
import 'libc.dart';
import 'posix_process_table.dart';
import 'process_table.dart';
import 'pty.dart';
import 'pty_io.dart' show closePtyHandle;
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
  if (err != esrch) return KillOutcome.failed;
  // The leader is alive but its group does not exist yet: the shim has not
  // reached `setsid`, so the process is still alone in the host's group.
  // Nothing else belongs to the unit then; signal the process itself.
  final direct = posixKill(leaderPid, signal);
  if (direct == 0) return KillOutcome.signalled;
  return direct == esrch ? KillOutcome.leaderGone : KillOutcome.failed;
}

/// A unit on Linux or macOS: the leader of its own session, started through
/// the `--unit-exec` shim.
class PosixUnit implements ContainedUnit {
  PosixUnit._(this.process, this.startTime, this.containmentId, [this.pty]);

  /// The unit's pseudo-terminal handles when it was spawned with `pty`.
  final PtyHandles? pty;

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
///
/// With [pty] the unit runs on a new pseudo-terminal (design D2): the host
/// opens the master, sizes it, and the shim opens the slave as the unit's
/// controlling terminal and stdio. The future completes only after the shim's
/// status pipe reached end of file with nothing written, that is after
/// `execve` succeeded; the master is then in [PosixUnit.pty]
/// ([PtyHandles.readHandle]), and the unit's `Process.stdout` has been
/// consumed. A setup or `execve` failure, or no answer within 5 s, settles the
/// unit, closes the master and throws [SpawnFailed].
Future<PosixUnit> spawnPosixUnit({
  required String shimExecutable,
  List<String> shimArgs = const [],
  required String containmentId,
  required List<String> argv,
  Map<String, String>? environment,
  String? workingDirectory,
  PtyOptions? pty,
}) async {
  final master = pty == null ? null : _openMaster(pty.size);
  final Process process;
  try {
    process = await Process.start(
      shimExecutable,
      [
        ...shimArgs,
        '--unit-exec',
        containmentId,
        if (master != null) ...[
          '--pty',
          pty!.slavePathForTesting ?? master.slavePath,
        ],
        '--',
        ...argv,
      ],
      environment: {...?environment, unitMarkerVariable: containmentId},
      workingDirectory: workingDirectory,
    );
  } catch (_) {
    master?.close();
    rethrow;
  }
  final startTime = posixProcessStartTime(process.pid);
  if (master == null) {
    if (startTime == null) {
      process.kill(ProcessSignal.sigkill);
      throw StateError(
        'unit ${process.pid} ($containmentId) exited before its start time '
        'could be read',
      );
    }
    return PosixUnit._(process, startTime, containmentId);
  }

  // The start time does not change at `execve`, so reading it before the
  // status answer keeps a program that exits at once spawnable.
  final status = BytesBuilder();
  final eof = Completer<void>();
  process.stdout.listen(
    status.add,
    onDone: eof.complete,
    onError: (Object _) {
      if (!eof.isCompleted) eof.complete();
    },
  );
  unawaited(process.stderr.drain<void>().then((_) {}, onError: (Object _) {}));
  unawaited(process.stdin.close().then((_) {}, onError: (Object _) {}));
  var timedOut = false;
  await eof.future.timeout(_statusTimeout, onTimeout: () => timedOut = true);
  master.releaseSlave();

  final unit = startTime == null
      ? null
      : PosixUnit._(process, startTime, containmentId, master.handles);
  if (!timedOut && status.isEmpty && unit != null) return unit;

  // Failed: settle the unit before reporting.
  if (unit != null) {
    await unit.terminate();
  } else {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode.timeout(
      const Duration(seconds: 3),
      onTimeout: () => -1,
    );
  }
  master.close();
  if (timedOut) throw const SpawnFailed('status-timeout', 0);
  if (status.isEmpty) {
    throw StateError(
      'unit ${process.pid} ($containmentId) exited before its start time '
      'could be read',
    );
  }
  throw _parseStatus(status.takeBytes());
}

const Duration _statusTimeout = Duration(seconds: 5);

SpawnFailed _parseStatus(List<int> bytes) {
  try {
    final line = const LineSplitter().convert(utf8.decode(bytes)).first;
    final json = jsonDecode(line) as Map<String, Object?>;
    return SpawnFailed(json['stage']! as String, json['errno']! as int);
  } on Object {
    return const SpawnFailed('status-malformed', 0);
  }
}

class _Master {
  _Master(this.read, this.write, this.slavePath, this._sizer);

  final int read;
  final int write;
  final String slavePath;

  /// The host's own slave descriptor, held only until the shim has answered.
  /// The host must not keep the slave open once the unit runs: the master
  /// reaches end of file only after every slave descriptor is closed.
  int? _sizer;

  PtyHandles get handles => PtyHandles(readHandle: read, writeHandle: write);

  void releaseSlave() {
    final fd = _sizer;
    _sizer = null;
    if (fd != null) posixClose(fd);
  }

  void close() {
    releaseSlave();
    closePtyHandle(read);
    closePtyHandle(write);
  }
}

/// `posix_openpt`, `grantpt`, `unlockpt`, the slave path and the initial size.
/// Every descriptor is close-on-exec, so no unit inherits them.
///
/// The size is set on the slave, as BSD `openpty` does: macOS refuses
/// `TIOCSWINSZ` on a master whose slave was never opened (`ENOTTY`). The host
/// keeps that slave descriptor until the shim has answered
/// ([_Master.releaseSlave]), so the terminal is never without an open slave
/// before the unit holds its own.
_Master _openMaster(PtySize size) {
  errno(); // bind it before the first failing call
  final master = posixOpenpt(oRdwr | oNoctty);
  if (master == -1) throw SpawnFailed('posix_openpt', errno());
  SpawnFailed fail(String stage) {
    final err = errno();
    posixClose(master);
    return SpawnFailed(stage, err);
  }

  fcntlInt(master, fSetfd, fdCloexec);
  if (grantpt(master) != 0) throw fail('grantpt');
  if (unlockpt(master) != 0) throw fail('unlockpt');
  final slavePath = ptsnameOf(master);
  if (slavePath == null) throw fail('ptsname');
  final path = slavePath.toNativeUtf8();
  final int sizer;
  try {
    sizer = posixOpen(path, oRdwr | oNoctty, 0);
  } finally {
    calloc.free(path);
  }
  if (sizer == -1) throw fail('open-slave');
  fcntlInt(sizer, fSetfd, fdCloexec);
  if (setWindowSize(sizer, size.cols, size.rows) != 0) {
    final err = errno();
    posixClose(sizer);
    posixClose(master);
    throw SpawnFailed('tiocswinsz', err);
  }
  final write = posixDup(master);
  if (write == -1) {
    final err = errno();
    posixClose(sizer);
    posixClose(master);
    throw SpawnFailed('dup', err);
  }
  fcntlInt(write, fSetfd, fdCloexec);
  return _Master(master, write, slavePath, sizer);
}
