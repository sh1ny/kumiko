import 'agent/codex/codex_auth_signal.dart';
import 'agent/codex/codex_auth_signatures.dart';

/// Host settings. The release host uses the defaults; a test build can change
/// them to make timing deterministic.
class HostOptions {
  /// Version/OS are provenance, never a runtime-version classifier gate.
  /// An unknown signal name is a registry defect and is refused.
  static Set<CodexAuthSignal> projectCodexAuthSignatures(
    List<(String, String, String)> observations,
  ) => {
    for (final row in observations)
      CodexAuthSignal.named(row.$3) ??
          (throw ArgumentError.value(row.$3, 'signal', 'unknown Codex signal')),
  };

  const HostOptions({
    this.unitCap = defaultUnitCap,
    this.shutdownDeadline = defaultShutdownDeadline,
    this.reconcileDelay = Duration.zero,
    this.retryDelay = Duration.zero,
    this.workspaceCap = defaultWorkspaceCap,
    this.resolveTimeout = defaultResolveTimeout,
    this.shellSearchPath,
    this.shellWellKnownDirs,
    this.runtimeSearchPath,
    this.runtimeWellKnownDirs,
    this.attachTimeout = defaultAttachTimeout,
    this.settleDeadline = defaultSettleDeadline,
    this.consoleCloseTimeout = defaultConsoleCloseTimeout,
    this.postExitReadDeadline = defaultPostExitReadDeadline,
    this.toolEndpointFault,
    this.revokedSecretsKept = defaultRevokedSecretsKept,
    this.draftDeadline = defaultDraftDeadline,
    this.draftOpenHold = Duration.zero,
    this.advertiseLifecycle = true,
    this.codexProbeArgs,
    // Keep the existing public named override while storing its nullable sentinel.
    Set<CodexAuthSignal>? codexAuthSignatures,
    // ignore: prefer_initializing_formals
  }) : _codexAuthSignatures = codexAuthSignatures;

  /// Secrets of revoked tool grants still redacted from adapter text.
  static const int defaultRevokedSecretsKept = 32;

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

  /// How long one draft operation may take before the store counts as not
  /// responding (app-exit-and-reopen design D4, ADR 0014 decision 14).
  static const Duration defaultDraftDeadline = Duration(seconds: 5);

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

  /// Independent runtime detection search overrides for test hosts.
  final List<String>? runtimeSearchPath;
  final List<String>? runtimeWellKnownDirs;

  final Duration attachTimeout;
  final Duration settleDeadline;
  final Duration consoleCloseTimeout;
  final Duration postExitReadDeadline;

  /// Makes creating the tool endpoint fail with this cause (tests only).
  final String? toolEndpointFault;

  /// How many revoked secrets stay redacted; each run always redacts its own.
  final int revokedSecretsKept;

  /// The deadline of one draft operation.
  final Duration draftDeadline;

  /// Extra wait before the draft worker opens its file (tests only).
  final Duration draftOpenHold;

  /// Whether `hello` offers the `lifecycle` capability; a test build turns it
  /// off to play a host that predates it.
  final bool advertiseLifecycle;

  /// Test entry-point only: overrides probe argv, never executable or containment.
  /// Release does not read candidate environment variables.
  final List<String>? codexProbeArgs;

  final Set<CodexAuthSignal>? _codexAuthSignatures;

  /// Confirmed Codex sign-in signals across every admitted runtime version.
  /// Only the test entrypoint may supply candidate overrides.
  Set<CodexAuthSignal> get codexAuthSignatures =>
      _codexAuthSignatures ??
      projectCodexAuthSignatures(confirmedCodexAuthSignatures);

  /// Extra wait at the start of reconciliation (tests only).
  final Duration reconcileDelay;

  /// Extra wait inside a cleanup retry (tests only).
  final Duration retryDelay;
}
