import 'dart:typed_data';

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

  /// The `cleanup/state` notifications (design D5). Each listener first
  /// receives the newest state already seen, if any.
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

  /// `workbench/save`. The host stores the layout only when [revision] is
  /// above its stored one; otherwise it fails with `stale-revision`
  /// ([storedRevisionOf]).
  Future<WorkbenchSaveResult> workbenchSave(Json layout, int revision);

  /// `workspace/open`: registers the folder at [path] (or finds it).
  Future<WorkspaceOpenResult> workspaceOpen(String path);

  /// `workspace/check`: re-checks the availability of workspace [id].
  Future<WorkspaceCheckResult> workspaceCheck(String id);

  /// `workspace/list`.
  Future<WorkspaceListResult> workspaceList();

  /// `workspace/remove`: forgets workspace [id].
  Future<WorkspaceRemoveResult> workspaceRemove(String id);

  /// `profile/list` (capability `terminal`).
  Future<ProfileListResult> profileList();

  /// `profile/save` (capability `terminal`): creates or replaces a
  /// user-defined profile and returns it as stored.
  Future<ShellProfile> saveProfile(ShellProfile profile);

  /// `profile/remove` (capability `terminal`): forgets a user profile.
  Future<void> removeProfile(String id);

  /// `profile/setDefault` (capability `terminal`).
  Future<void> setDefaultProfile(String id);

  /// `terminal/open`, then the attach handshake (design D4): both channels
  /// are registered, `terminal/attach` is sent, and only then is the output
  /// window granted. Pausing the returned output stream stops credit, so the
  /// host stops reading the terminal.
  Future<TerminalChannels> openTerminal(TerminalOpenParams params);

  /// `terminal/resize`.
  Future<void> resizeTerminal(String terminalId, int cols, int rows);

  /// `terminal/close`.
  Future<void> closeTerminal(String terminalId);

  /// `terminal/release`: closes an ended terminal's channels.
  Future<void> releaseTerminal(String terminalId);

  /// The `terminal/exited` notifications.
  Stream<TerminalExited> get terminalExits;

  /// The `terminal/closeFailed` notifications.
  Stream<TerminalCloseFailed> get terminalCloseFailures;

  /// Ends the host as the desktop quits.
  Future<void> quit();
}

/// An attached terminal's two data channels.
class TerminalChannels {
  TerminalChannels({
    required this.terminalId,
    required this.output,
    required this.write,
  });

  final String terminalId;

  /// The terminal's output, in order. Single subscription.
  final Stream<Uint8List> output;

  /// Sends input; completes once the bytes are within the input window.
  final Future<void> Function(Uint8List bytes) write;
}

/// Starts a host. Throws [HostStartException]; Restart host calls it again.
typedef HostConnector = Future<HostLink> Function();
