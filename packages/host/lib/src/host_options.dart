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
    this.attachTimeout = defaultAttachTimeout,
    this.settleDeadline = defaultSettleDeadline,
    this.consoleCloseTimeout = defaultConsoleCloseTimeout,
    this.postExitReadDeadline = defaultPostExitReadDeadline,
  });

  /// Concurrent units per host (design D4, Resource Bounds).
  static const int defaultUnitCap = 64;

  /// Total time to end units and exit after the desktop is lost.
  static const Duration defaultShutdownDeadline = Duration(seconds: 30);

  /// Workspaces per profile (design D4).
  static const int defaultWorkspaceCap = 64;

  /// How long a folder resolution may take (design D5).
  static const Duration defaultResolveTimeout = Duration(seconds: 5);

  /// A terminal not attached within this is closed (design D4).
  static const Duration defaultAttachTimeout = Duration(seconds: 10);

  /// The overall settlement deadline of a terminal's end (Resource Bounds).
  static const Duration defaultSettleDeadline = Duration(seconds: 30);

  /// How long `ClosePseudoConsole` may take before it becomes a pending
  /// console cleanup (design D3).
  static const Duration defaultConsoleCloseTimeout = Duration(seconds: 5);

  /// Active reading time a PTY gets to reach end of output after its shell
  /// exited (design D5).
  static const Duration defaultPostExitReadDeadline = Duration(seconds: 1);

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

  final Duration attachTimeout;
  final Duration settleDeadline;
  final Duration consoleCloseTimeout;
  final Duration postExitReadDeadline;

  /// Extra wait at the start of reconciliation (tests only).
  final Duration reconcileDelay;

  /// Extra wait inside a cleanup retry (tests only).
  final Duration retryDelay;
}
