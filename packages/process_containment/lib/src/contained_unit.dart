/// Outcome of ending a unit's containment.
class TerminationResult {
  const TerminationResult.terminated() : terminated = true, reason = null;

  const TerminationResult.failed(String this.reason) : terminated = false;

  /// True when the containment is confirmed gone: the leader (POSIX) or every
  /// process of the job (Windows) has exited.
  final bool terminated;

  /// Why it could not be confirmed, for example `kill-failed:1` or
  /// `termination-timeout`.
  final String? reason;

  @override
  String toString() => terminated ? 'terminated' : 'not terminated ($reason)';
}

/// One running containment unit, on either OS.
abstract interface class ContainedUnit {
  /// The unit's own process id, the one `Process.start` or `CreateProcessW`
  /// returned.
  int get pid;

  /// The OS start time of [pid], an opaque value compared for equality; see
  /// `processStartTime`.
  int get startTime;

  String get containmentId;

  /// Completes with the unit process's exit code.
  Future<int> get exitCode;

  /// Terminates the containment. Idempotent; safe after the unit exited.
  Future<TerminationResult> terminate();
}
