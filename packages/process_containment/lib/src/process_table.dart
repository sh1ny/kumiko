/// What the marker scan needs to know about one process.
class ProcessSnapshot {
  const ProcessSnapshot({
    required this.startTime,
    required this.startedAt,
    required this.uid,
    this.zombie = false,
  });

  /// OS start time as an opaque value; two snapshots of the same process are
  /// equal, a reused pid differs.
  final int startTime;

  /// The start as a wall-clock time, for the scan's population window.
  final DateTime startedAt;

  final int uid;

  /// Exited but not yet reaped. On Linux this is the state of the thread
  /// group's leader only: other threads of the process can still run, and
  /// start processes. The kill guard, spawn and unit listing read it as
  /// exited; the marker scan asks [ProcessTable.confirmedExits] instead.
  final bool zombie;
}

/// The process does not exist (any more).
class ProcessGone implements Exception {
  const ProcessGone();
  @override
  String toString() => 'ProcessGone';
}

/// The process exists but the OS refused the read (EACCES/EPERM).
class ProcessReadDenied implements Exception {
  const ProcessReadDenied();
  @override
  String toString() => 'ProcessReadDenied';
}

/// The process table cannot be listed at all.
class ProcessTableUnlistable implements Exception {
  const ProcessTableUnlistable(this.detail);
  final String detail;
  @override
  String toString() => 'ProcessTableUnlistable($detail)';
}

/// A reader of the OS process table, injectable so the marker scan's gone,
/// reused and unreadable cases are deterministic (design D9).
abstract interface class ProcessTable {
  int get currentUid;

  /// Every pid the table lists. Throws [ProcessTableUnlistable].
  List<int> listPids();

  /// The process, or null when it no longer exists. Throws
  /// [ProcessReadDenied] when it exists but cannot be inspected.
  ProcessSnapshot? snapshot(int pid);

  /// The process's `NAME=value` environment entries. Throws [ProcessGone] or
  /// [ProcessReadDenied].
  List<String> environment(int pid);

  /// The pids of [pids] (pid to start time, or null when unknown) whose full
  /// exit the kernel confirms: no thread of the process remains, or the pid
  /// now belongs to another process. Every other answer, including a refused
  /// or failed read, leaves the pid out. No call behind it waits.
  ///
  /// A null or zombie snapshot alone is not that evidence, and neither is
  /// the exit-in-progress flag, a macOS `proc_pidinfo` failure or errno, a
  /// Linux `Threads:` count other than exactly 1, a stat state paired with a
  /// separate `Threads:` read, or a Linux ENOENT while `/proc` is mounted
  /// with `hidepid`. Linux ENOENT or ESRCH on `/proc/<pid>` is evidence only
  /// without `hidepid` (issue #40, design D2, C3).
  ///
  /// Only the marker scan uses it. The kill guard, spawn and unit listing
  /// keep their snapshot-based zombie handling, and the macOS errno binding
  /// stays with issue #31 (C5).
  Set<int> confirmedExits(Map<int, int?> pids);

  /// The pids of [pids] that the table can show belong to another user,
  /// for pids whose snapshot was null and so gave no uid. It names a pid
  /// only on that evidence, names none when its read fails, and never waits.
  ///
  /// On macOS every zombie answers a null snapshot. A zombie keeps its
  /// credentials until it is reaped, so a listing of the current user's
  /// processes still holds our own zombies: only another user's pids are
  /// named. On Linux a null snapshot means the pid is gone, which
  /// [confirmedExits] judges, so none are named (issue #40, design D1).
  Set<int> foreignPids(Set<int> pids);

  /// Sends `SIGKILL` to [pid] only while its start time is still
  /// [startTime]. True when the signal was sent or the process is gone;
  /// false when the kill failed.
  bool kill(int pid, int startTime);
}
