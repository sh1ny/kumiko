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
import 'unit_pipes.dart';

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

/// The start time of a unit whose process was proved gone before its start
/// time could be read (#18). It matches no process: real start times are
/// non-negative. Every leader check treats it as a leader known to be gone
/// and never reads or signals the pid, which may since have been reused.
const int startTimeNotRead = -1;

/// Reads one process (`PosixProcessTable.snapshot`); replaced in tests.
typedef SnapshotReader = ProcessSnapshot? Function(int pid);

ProcessSnapshot? _readSnapshot(int pid) => PosixProcessTable().snapshot(pid);

/// True while [pid] runs with start time [startTime]; a zombie or a reused
/// pid is not alive, and neither is a leader recorded as [startTimeNotRead].
/// [snapshotForTesting] replaces the process read.
bool posixIsProcessAlive(
  int pid,
  int startTime, {
  SnapshotReader? snapshotForTesting,
}) {
  if (startTime == startTimeNotRead) return false;
  try {
    final s = (snapshotForTesting ?? _readSnapshot)(pid);
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
///
/// A leader recorded as [startTimeNotRead] is gone: this returns
/// [KillOutcome.leaderGone] before reading or signalling [leaderPid], whose
/// pid may belong to another process by now (#18), so a reused pid the host
/// cannot read never turns a gone leader into a kill failure. Its
/// descendants are reached only by the marker scan, which does not depend on
/// this check. [posixIsProcessAlive] answers false for it the same way.
/// [snapshotForTesting] replaces the process read.
KillOutcome killProcessGroup(
  int leaderPid,
  int startTime,
  int signal, {
  SnapshotReader? snapshotForTesting,
}) {
  if (startTime == startTimeNotRead) return KillOutcome.leaderGone;
  final ProcessSnapshot? leader;
  try {
    leader = (snapshotForTesting ?? _readSnapshot)(leaderPid);
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
  PosixUnit._(
    this.process,
    this.startTime,
    this.containmentId, [
    this.pty,
    this.pipes,
  ]);

  @override
  final UnitPipes? pipes;

  /// The unit's pseudo-terminal handles when it was spawned with `pty`.
  final PtyHandles? pty;

  /// The `dart:io` handle. With [pipes], use that endpoint rather than listening
  /// to Process stdio a second time; otherwise callers own the raw stdio.
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

/// What the spawn learned about a new unit's identity right after
/// `Process.start` (#18, design D1).
sealed class _Identity {
  const _Identity();
}

/// The start time was read.
final class _Read extends _Identity {
  const _Read(this.startTime);
  final int startTime;
}

/// No process has the pid: the snapshot was null and `kill(pid, 0)` answered
/// `ESRCH`. The unit exited and was reaped before the read.
final class _Gone extends _Identity {
  const _Gone();
}

/// The read was refused (`ProcessReadDenied`).
final class _Refused extends _Identity {
  const _Refused();
}

/// The snapshot was null, but the probe did not prove the pid free: something
/// may run there, and nothing shows whether it is the unit.
final class _Unconfirmed extends _Identity {
  const _Unconfirmed();
}

_Identity _readIdentity(
  int pid,
  SnapshotReader snapshot,
  int Function(int) probe,
) {
  final ProcessSnapshot? read;
  try {
    read = snapshot(pid);
  } on ProcessReadDenied {
    return const _Refused();
  }
  if (read != null) return _Read(read.startTime);
  return probe(pid) == esrch ? const _Gone() : const _Unconfirmed();
}

int _probe(int pid) => posixKill(pid, 0);

/// Starts a unit: `shimExecutable [shimArgs] --unit-exec containmentId --
/// argv...` with `KUMIKO_UNIT` set to the containment id in its environment. The host
/// passes its own executable as [shimExecutable]. The shim makes the process a
/// session leader and `execve`s [argv], so the returned pid and start time are
/// the unit's own.
///
/// The start time is read right after `Process.start` (#18, design D1):
/// - read: the unit carries it;
/// - the snapshot finds no process and `kill(pid, 0)` answers `ESRCH`: the
///   unit already exited and was reaped, and is returned with
///   [startTimeNotRead] unless something else failed. Only this positive
///   evidence of absence returns such a unit. The probe is a leaf FFI call
///   (`isLeaf: true`), and `kill` and `errno` are bound before
///   `Process.start`, so no Dart code runs between the call and the errno
///   read and the errno is the probe's own;
/// - the read is refused: the spawn kills the process and throws
///   [StateError], as before;
/// - the snapshot finds no process but the probe does not prove the pid
///   free: the spawn sends no signal by that pid and throws
///   [SpawnIdentityUnconfirmed] (or, on the PTY path, a [SpawnFailed] that
///   carries [SpawnFailed.unconfirmedPid]). The host then keeps the unit's row
///   unresolved, since its marker scan cannot see a process whose read fails.
///
/// A pid reused between the unit's reaping and the read is not guarded: the
/// spawn then records the other process's start time. A failed spawn is
/// never retried, since the program may already have run.
///
/// A successful spawn never waits for the unit's exit: a terminal must open,
/// and a piped caller get its endpoints, while the unit runs.
///
/// With [pty] the unit runs on a new pseudo-terminal (design D2): the host
/// opens the master, sizes it, and the shim opens the slave as the unit's
/// controlling terminal and stdio. The future completes only after the shim's
/// status pipe reached end of file with nothing written. That empty end of
/// file is the handshake outcome the spawn treats as success; it is not
/// proof that `execve` ran (see below). The master is then in
/// [PosixUnit.pty]
/// ([PtyHandles.readHandle]), and the unit's `Process.stdout` has been
/// consumed. The outcome order is: no answer within 5 s
/// (`status-timeout`), a read error on the pipe (`status-read`), a reported
/// setup or `execve` failure, then a readable or proved-gone success, else the
/// refused or unconfirmed error. Each [SpawnFailed] carries
/// [SpawnFailed.unconfirmedPid] when the identity was unconfirmed. Three
/// cases stay distinct: a non-empty status (a reported setup or `execve`
/// failure) fails; a read error on the pipe fails (`status-read`); a shim
/// that exits before `execve` without writing a report, for any reason
/// (empty status, #33), is indistinguishable from a started program and is
/// treated as one, now also when it was reaped before the read.
///
/// [SpawnFailed], [SpawnIdentityUnconfirmed] and [StateError] describe the
/// spawn's own cleanup: it ends the process it could identify, kills a
/// process whose read was refused, and signals nothing else. On every
/// failure path, plain or PTY, it closes stdin and stops reading stdout
/// and stderr (a stream already listened to is cancelled by its listener),
/// and on the PTY path it cancels the status subscription and closes the
/// master, before it throws and without waiting for an unsignalled process
/// to exit. A status stream that throws on listen or cancel, or a
/// termination that throws, does not skip this cleanup or replace the
/// classified error, so an unconfirmed spawn's error still carries its pid
/// (design D3, C10). Whether the unit's row is
/// deleted or left unresolved is the host's settlement.
///
/// With [pipes], the existing Process pipes are handed to the caller in
/// [PosixUnit.pipes], without reading stdout as shim status. Exec failures
/// therefore remain exit 126/127 with stderr. [pipes] and [pty] are mutually
/// exclusive; plain units retain their existing Process stdio behavior.
///
/// Test-only parameters: [beforeStartTimeReadForTesting] runs between
/// `Process.start` and the read (a test awaits the exit there);
/// [snapshotForTesting] and [probeForTesting] replace the read and the
/// `kill(pid, 0)` probe; [statusStreamForTesting] wraps the status stream
/// on the PTY path. If one of them throws, the spawn closes the master and
/// releases the stdio and rethrows; it sends no signal, since nothing has
/// identified the pid as the unit's.
Future<PosixUnit> spawnPosixUnit({
  required String shimExecutable,
  List<String> shimArgs = const [],
  required String containmentId,
  required List<String> argv,
  Map<String, String>? environment,
  String? workingDirectory,
  PtyOptions? pty,
  bool pipes = false,
  // False supplies only explicit variables plus the containment marker; the
  // exec shim inherits this already-filtered environment, never the host copy.
  bool inheritParentEnvironment = true,
  Future<void> Function(Process process)? beforeStartTimeReadForTesting,
  SnapshotReader? snapshotForTesting,
  int Function(int pid)? probeForTesting,
  Stream<List<int>> Function(Stream<List<int>> status)? statusStreamForTesting,
}) async {
  if (pipes && pty != null) {
    throw ArgumentError('pipes and pty are mutually exclusive');
  }
  bindPosixProbe();
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
      includeParentEnvironment: inheritParentEnvironment,
      workingDirectory: workingDirectory,
    );
  } catch (_) {
    master?.close();
    rethrow;
  }
  final _Identity identity;
  final Stream<List<int>> statusStream;
  try {
    // Awaited only when supplied: a release spawn reads at once.
    final before = beforeStartTimeReadForTesting;
    if (before != null) await before(process);
    identity = _readIdentity(
      process.pid,
      snapshotForTesting ?? _readSnapshot,
      probeForTesting ?? _probe,
    );
    statusStream = master == null
        ? process.stdout
        : statusStreamForTesting?.call(process.stdout) ?? process.stdout;
  } catch (_) {
    // Nothing identified the pid as the unit's: release, never signal.
    _abandonStdio(process);
    master?.close();
    rethrow;
  }
  if (master == null) {
    switch (identity) {
      case _Read(:final startTime):
        return PosixUnit._(
          process,
          startTime,
          containmentId,
          null,
          pipes ? UnitPipes.process(process) : null,
        );
      case _Gone():
        return PosixUnit._(
          process,
          startTimeNotRead,
          containmentId,
          null,
          pipes ? UnitPipes.process(process) : null,
        );
      case _Refused():
        process.kill(ProcessSignal.sigkill);
        _abandonStdio(process);
        throw StateError(
          'unit ${process.pid} ($containmentId): its start time could not be '
          'read',
        );
      case _Unconfirmed():
        _abandonStdio(process);
        throw SpawnIdentityUnconfirmed(process.pid, containmentId);
    }
  }

  // The start time does not change at `execve`, so reading it before the
  // status answer keeps a program that exits at once spawnable.
  final status = BytesBuilder();
  final eof = Completer<void>();
  Object? readError;
  StreamSubscription<List<int>>? subscription;
  StreamSubscription<List<int>>? stderr;
  var timedOut = false;
  try {
    subscription = statusStream.listen(
      status.add,
      onDone: () {
        if (!eof.isCompleted) eof.complete();
      },
      onError: (Object error) {
        readError ??= error;
        if (!eof.isCompleted) eof.complete();
      },
    );
    // Discarded while the unit runs; released at once if the spawn fails.
    stderr = process.stderr.listen(null, onError: (Object _) {});
    unawaited(process.stdin.close().then((_) {}, onError: (Object _) {}));
    await eof.future.timeout(_statusTimeout, onTimeout: () => timedOut = true);
  } catch (e) {
    // A status stream that cannot be read is a read error.
    readError ??= e;
  }
  master.releaseSlave();

  if (!timedOut && readError == null && status.isEmpty) {
    switch (identity) {
      case _Read(:final startTime):
        return PosixUnit._(process, startTime, containmentId, master.handles);
      case _Gone():
        return PosixUnit._(
          process,
          startTimeNotRead,
          containmentId,
          master.handles,
        );
      case _Refused() || _Unconfirmed():
        break;
    }
  }

  // Failed: settle what the spawn can identify before reporting. The
  // handles are released and the master closed even if a cancellation or
  // the termination throws, and the classified error below still wins.
  try {
    try {
      await subscription?.cancel();
    } on Object {
      // The status stream is abandoned either way.
    }
    unawaited(stderr?.cancel().then((_) {}, onError: (Object _) {}));
    _abandonStdio(process);
    switch (identity) {
      case _Read(:final startTime):
        try {
          await PosixUnit._(process, startTime, containmentId).terminate();
        } on Object {
          // The classified spawn error below is what the caller gets.
        }
      case _Gone():
        break; // proved gone: nothing to signal
      case _Refused():
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(
          const Duration(seconds: 3),
          onTimeout: () => -1,
        );
      case _Unconfirmed():
        break; // nothing shows the pid is the unit's: no signal
    }
  } finally {
    master.close();
  }
  final unconfirmedPid = identity is _Unconfirmed ? process.pid : null;
  if (timedOut) {
    throw SpawnFailed('status-timeout', 0, unconfirmedPid: unconfirmedPid);
  }
  if (readError != null) {
    throw SpawnFailed('status-read', 0, unconfirmedPid: unconfirmedPid);
  }
  if (status.isNotEmpty) {
    throw _parseStatus(status.takeBytes(), unconfirmedPid);
  }
  if (unconfirmedPid != null) {
    throw SpawnIdentityUnconfirmed(unconfirmedPid, containmentId);
  }
  throw StateError(
    'unit ${process.pid} ($containmentId): its start time could not be read',
  );
}

/// Releases the stdio of a process the spawn gives up on without signalling
/// it, so no host-side handle waits on a process nobody owns (design D3).
void _abandonStdio(Process process) {
  unawaited(process.stdin.close().then((_) {}, onError: (Object _) {}));
  for (final output in [process.stdout, process.stderr]) {
    try {
      unawaited(output.listen(null, onError: (Object _) {}).cancel());
    } on StateError {
      // Already listened to: its listener owns it.
    }
  }
}

const Duration _statusTimeout = Duration(seconds: 5);

SpawnFailed _parseStatus(List<int> bytes, int? unconfirmedPid) {
  try {
    final line = const LineSplitter().convert(utf8.decode(bytes)).first;
    final json = jsonDecode(line) as Map<String, Object?>;
    return SpawnFailed(
      json['stage']! as String,
      json['errno']! as int,
      unconfirmedPid: unconfirmedPid,
    );
  } on Object {
    return SpawnFailed('status-malformed', 0, unconfirmedPid: unconfirmedPid);
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
