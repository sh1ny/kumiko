/// The guarded kill of a unit's process group, as a decision over injected
/// process reads and signals (design D1-D3).
///
/// Internal: the package barrel does not export this library; only this
/// package's code and tests import it. The public entry is
/// `killProcessGroup` in `posix_unit.dart`, whose signature stays as main
/// has it (its optional `snapshotForTesting`, from #18, passes through to
/// the guard's snapshot read), so this seam adds no test-only parameter to
/// the interface the host imports (design D2, C4).
library;

import 'libc.dart' show esrch;
import 'posix_process_table.dart';
import 'posix_unit.dart' show startTimeNotRead;
import 'process_table.dart';

/// Result of a guarded `killpg`.
enum KillOutcome {
  /// The signal was sent to the group, or directly to the confirmed leader.
  signalled,

  /// The leader is gone, so the group is only reachable through the marker
  /// scan.
  leaderGone,

  /// The pid now belongs to a process with another start time.
  startTimeMismatch,

  /// The kernel refused, and the host could not confirm that the leader is
  /// gone or replaced.
  failed,
}

/// Signals the group of a unit this host instance started in its current
/// run. Only such a unit can still lack a group (stopped before its shim
/// reached `setsid`), so only it gets the direct fallback (design D3).
KillOutcome killLiveUnitGroup(int leaderPid, int startTime, int signal) =>
    killUnitGroup(leaderPid, startTime, signal, directFallback: true);

/// [guardedKill] with the real process table and signals. One table
/// instance serves the entry read and every recheck, so a recheck never
/// reads `/proc/uptime` again (design C8). [snapshotForTesting] replaces
/// the process read.
KillOutcome killUnitGroup(
  int leaderPid,
  int startTime,
  int signal, {
  required bool directFallback,
  ProcessSnapshot? Function(int pid)? snapshotForTesting,
}) {
  return guardedKill(
    pid: leaderPid,
    startTime: startTime,
    signal: signal,
    directFallback: directFallback,
    snapshot: snapshotForTesting ?? PosixProcessTable().snapshot,
    killpg: posixKillpg,
    kill: posixKill,
  );
}

/// The decision. [snapshot] may throw [ProcessReadDenied]; [killpg] and
/// [kill] return 0 or the errno of their own call.
///
/// A leader recorded as [startTimeNotRead] exited before its start time
/// was read: it is [KillOutcome.leaderGone] before any read or signal by
/// its pid, which may belong to another process by now (#18).
///
/// The first check keeps its mapping (design C5). After a refused signal (any
/// error but `ESRCH`) the leader is rechecked, and only a confirmed exit or
/// replacement changes the `failed` outcome (D1). On `killpg` `ESRCH`, the
/// pid is signalled directly only when [directFallback] is set and the
/// recheck confirms the leader (D3).
KillOutcome guardedKill({
  required int pid,
  required int startTime,
  required int signal,
  required bool directFallback,
  required ProcessSnapshot? Function(int pid) snapshot,
  required int Function(int pgrp, int signal) killpg,
  required int Function(int pid, int signal) kill,
}) {
  if (startTime == startTimeNotRead) return KillOutcome.leaderGone;
  final ProcessSnapshot? leader;
  try {
    leader = snapshot(pid);
  } on ProcessReadDenied {
    return KillOutcome.failed;
  }
  if (leader == null || leader.zombie) return KillOutcome.leaderGone;
  if (leader.startTime != startTime) return KillOutcome.startTimeMismatch;

  _Recheck recheck() => _recheck(pid, startTime, snapshot, kill);

  final group = killpg(pid, signal);
  if (group == 0) return KillOutcome.signalled;
  if (group != esrch) return _afterRefusal(recheck());

  // No group: the leader may not have reached `setsid` yet.
  final state = recheck();
  if (state != _Recheck.leader) return _afterRefusal(state);
  if (!directFallback) return KillOutcome.failed;
  final direct = kill(pid, signal);
  if (direct == 0) return KillOutcome.signalled;
  if (direct == esrch) return KillOutcome.leaderGone;
  return _afterRefusal(recheck());
}

enum _Recheck { exited, replaced, leader, unknown }

KillOutcome _afterRefusal(_Recheck state) => switch (state) {
  _Recheck.exited => KillOutcome.leaderGone,
  _Recheck.replaced => KillOutcome.startTimeMismatch,
  _Recheck.leader || _Recheck.unknown => KillOutcome.failed,
};

/// Looks at the leader again, sending no signal. A no-signal probe first:
/// its `ESRCH` proves absence, and then no snapshot is read. Otherwise one
/// snapshot, of which only the start time and the state are used; both come
/// from one read for one process (Linux `stat`, macOS `proc_pidinfo`), while
/// the owner can come from a second read on Linux. A start time of 0 is the
/// macOS placeholder and confirms nothing.
_Recheck _recheck(
  int pid,
  int startTime,
  ProcessSnapshot? Function(int pid) snapshot,
  int Function(int pid, int signal) kill,
) {
  if (kill(pid, 0) == esrch) return _Recheck.exited;
  final ProcessSnapshot? now;
  try {
    now = snapshot(pid);
  } on ProcessReadDenied {
    return _Recheck.unknown;
  }
  if (now == null) return _Recheck.unknown;
  if (now.zombie) return _Recheck.exited;
  if (startTime == 0 || now.startTime == 0) return _Recheck.unknown;
  return now.startTime == startTime ? _Recheck.leader : _Recheck.replaced;
}
