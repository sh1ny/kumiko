/// Host settings. The release host uses the defaults; a test build can change
/// them to make timing deterministic.
class HostOptions {
  const HostOptions({
    this.unitCap = defaultUnitCap,
    this.shutdownDeadline = defaultShutdownDeadline,
    this.reconcileDelay = Duration.zero,
    this.retryDelay = Duration.zero,
  });

  /// Concurrent units per host (design D4, Resource Bounds).
  static const int defaultUnitCap = 64;

  /// Total time to end units and exit after the desktop is lost.
  static const Duration defaultShutdownDeadline = Duration(seconds: 30);

  final int unitCap;
  final Duration shutdownDeadline;

  /// Extra wait at the start of reconciliation (tests only).
  final Duration reconcileDelay;

  /// Extra wait inside a cleanup retry (tests only).
  final Duration retryDelay;
}
