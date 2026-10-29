/// Host settings. The release host uses the defaults; a test build can change
/// them to make timing deterministic.
class HostOptions {
  const HostOptions({
    this.unitCap = defaultUnitCap,
    this.shutdownDeadline = defaultShutdownDeadline,
    this.reconcileDelay = Duration.zero,
    this.retryDelay = Duration.zero,
    this.workspaceCap = defaultWorkspaceCap,
    this.resolveTimeout = defaultResolveTimeout,
    this.shellSearchPath,
    this.shellWellKnownDirs,
  });

  /// Concurrent units per host (design D4, Resource Bounds).
  static const int defaultUnitCap = 64;

  /// Total time to end units and exit after the desktop is lost.
  static const Duration defaultShutdownDeadline = Duration(seconds: 30);

  /// Workspaces per profile (design D4).
  static const int defaultWorkspaceCap = 64;

  /// How long a folder resolution may take (design D5).
  static const Duration defaultResolveTimeout = Duration(seconds: 5);

  /// Folder resolutions that may run at once (design D5).
  static const int resolveSlots = 4;

  final int unitCap;
  final int workspaceCap;
  final Duration resolveTimeout;
  final Duration shutdownDeadline;

  /// The directories shell detection searches instead of `PATH` (tests only).
  final List<String>? shellSearchPath;

  /// The install locations shell detection searches after the path; empty
  /// disables them (tests only).
  final List<String>? shellWellKnownDirs;

  /// Extra wait at the start of reconciliation (tests only).
  final Duration reconcileDelay;

  /// Extra wait inside a cleanup retry (tests only).
  final Duration retryDelay;
}
