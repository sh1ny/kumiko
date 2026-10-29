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

  /// `cleanup/list`. [revision] is the one the caller last saw; [workspace]
  /// (a workspace `id`) limits the list to that workspace.
  Future<CleanupListResult> cleanupList({
    String? cursor,
    int? revision,
    String? workspace,
  });

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

  /// The `workspace/changed` notifications.
  Stream<WorkspaceChanged> get workspaceChanges;

  /// `workbench/load`: the stored layout, the workspaces and the cleanup
  /// revision.
  Future<WorkbenchLoadResult> workbenchLoad();

  /// `workbench/save`. [revision] is the stored one the caller last saw; a
  /// different one fails with `stale-revision` ([storedRevisionOf]).
  Future<WorkbenchSaveResult> workbenchSave(Json layout, int revision);

  /// `workspace/open`: registers the folder at [path] (or finds it).
  Future<WorkspaceOpenResult> workspaceOpen(String path);

  /// `workspace/check`: re-checks the availability of workspace [id].
  Future<WorkspaceCheckResult> workspaceCheck(String id);

  /// `workspace/list`.
  Future<WorkspaceListResult> workspaceList();

  /// `workspace/remove`: forgets workspace [id].
  Future<WorkspaceRemoveResult> workspaceRemove(String id);

  /// Ends the host as the desktop quits.
  Future<void> quit();
}

/// Starts a host. Throws [HostStartException]; Restart host calls it again.
typedef HostConnector = Future<HostLink> Function();
