import 'package:host_protocol/host_protocol.dart';

/// What the desktop UI needs from a started host. The real one wraps a
/// [HostSession] (`launcher_link.dart`); widget tests script a fake, so no UI
/// test starts a process.
abstract interface class HostLink {
  /// The host's answer to `hello`.
  HelloResult get hello;

  /// Completes when the host exits, its connection ends, or it breaks the
  /// protocol. Never completes after [quit].
  Future<HostLoss> get lost;

  /// The `cleanup/state` notifications (design D5).
  Stream<CleanupState> get cleanupStates;

  /// `cleanup/list`. [revision] is the one the caller last saw.
  Future<CleanupListResult> cleanupList({String? cursor, int? revision});

  /// `cleanup/units`: one page of every unit of [workspace] (a
  /// `target_identity`), from the start or after [cursor].
  Future<CleanupUnitsResult> cleanupUnits(
    String workspace, {
    String? cursor,
    int? revision,
  });

  /// `cleanup/retry`, for every unit of [workspace] (a `target_identity`).
  Future<CleanupActionResult> cleanupRetry(String workspace);

  /// `cleanup/confirm`, for every unit of [workspace].
  Future<CleanupActionResult> cleanupConfirm(String workspace);

  /// Ends the host as the desktop quits.
  Future<void> quit();
}

/// Starts a host. Throws [HostStartException]; Restart host calls it again.
typedef HostConnector = Future<HostLink> Function();
