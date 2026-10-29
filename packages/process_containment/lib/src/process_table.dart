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

  /// Exited but not yet reaped: nothing of it runs, so it counts as gone.
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

  /// Sends `SIGKILL` to [pid] only while its start time is still
  /// [startTime]. True when the signal was sent or the process is gone;
  /// false when the kill failed.
  bool kill(int pid, int startTime);
}
