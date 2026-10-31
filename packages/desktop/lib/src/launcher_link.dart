import 'dart:async';

import 'package:host_protocol/host_protocol.dart';

import 'host_link.dart';

/// `cleanup/state` for several consumers: each listener first receives the
/// newest state seen so far, then the live ones. The cleanup list and the
/// workbench attach one after the other; without this, a state that ended
/// reconciliation before the second listened would never reach it.
class LatestCleanupState {
  LatestCleanupState(Stream<CleanupState> source) {
    source.listen((s) {
      _latest = s;
      _live.add(s);
    }, onDone: () => unawaited(_live.close()));
  }

  final StreamController<CleanupState> _live =
      StreamController<CleanupState>.broadcast(sync: true);
  CleanupState? _latest;

  Stream<CleanupState> get stream => Stream.multi((controller) {
    if (_latest case final latest?) controller.add(latest);
    final subscription = _live.stream.listen(
      controller.add,
      onDone: controller.close,
    );
    controller.onCancel = subscription.cancel;
  }, isBroadcast: true);
}

/// `terminal/open` then `terminal/attach` over [connection]: both channels
/// are registered before the attach, so the host's first output has a
/// receiver. A refused attach (the host's attach timeout may have run out
/// while the desktop was suspended) closes both channels again, so their
/// slots stop counting against [maxChannels], and asks the host to close the
/// terminal; the refusal is rethrown.
Future<TerminalChannels> openTerminalChannels(
  Connection connection,
  TerminalOpenParams params,
) async {
  Future<Json> request(String method, Json params) async =>
      ((await connection.request(method, params))! as Map<Object?, Object?>)
          .cast<String, Object?>();

  final opened = TerminalOpenResult.fromJson(
    await request(Method.terminalOpen, params.toJson()),
  );
  final output = connection.attachInbound(
    opened.outputChannel,
    grantInitial: false,
  );
  final input = connection.attachOutbound(opened.inputChannel);
  try {
    await connection.request(
      Method.terminalAttach,
      TerminalAttachParams(opened.terminalId).toJson(),
    );
  } on Object {
    for (final id in [opened.outputChannel, opened.inputChannel]) {
      await connection.closeChannel(id).then<void>((_) {}, onError: (_) {});
    }
    if (!connection.isClosed) {
      await connection
          .request(
            Method.terminalClose,
            TerminalCloseParams(opened.terminalId).toJson(),
          )
          .then<void>((_) {}, onError: (_) {});
    }
    rethrow;
  }
  connection.grantInitial(opened.outputChannel);
  return TerminalChannels(
    terminalId: opened.terminalId,
    output: output,
    write: input.write,
  );
}

/// The real [HostLink] over a started [HostSession].
///
/// The cleanup wire shapes are the ones in `host_protocol`'s `messages.dart`.
class SessionLink implements HostLink {
  SessionLink(this.session)
    : _cleanupStates = LatestCleanupState(session.cleanupStates);

  final HostSession session;

  /// Listens first, so it also receives the notifications the host sent
  /// before anyone listened (the session replays those to its first
  /// listener only).
  final LatestCleanupState _cleanupStates;

  @override
  HelloResult get hello => session.hello;

  @override
  Future<HostLoss> get lost => session.lost;

  @override
  Stream<CleanupState> get cleanupStates => _cleanupStates.stream;

  @override
  Stream<WorkspaceChanged> get workspaceChanges => session.notifications
      .where((n) => n.method == Method.workspaceChanged)
      .map((n) => WorkspaceChanged.fromJson(n.params));

  Json _json(Object? result) =>
      (result! as Map<Object?, Object?>).cast<String, Object?>();

  Future<Json> _request(String method, Json params) async =>
      _json(await session.connection.request(method, params));

  @override
  Future<CleanupListResult> cleanupList({
    String? cursor,
    int? revision,
    String? workspace,
  }) async {
    final params = CleanupListParams(
      cursor: cursor,
      revision: revision,
      workspace: workspace,
    );
    return CleanupListResult.fromJson(
      await _request(Method.cleanupList, params.toJson()),
    );
  }

  @override
  Future<CleanupUnitsResult> cleanupUnits(
    String workspace, {
    String? cursor,
    int? revision,
  }) async {
    final params = CleanupUnitsParams(
      workspace: workspace,
      cursor: cursor,
      revision: revision,
    );
    return CleanupUnitsResult.fromJson(
      await _request(Method.cleanupUnits, params.toJson()),
    );
  }

  @override
  Future<CleanupActionResult> cleanupRetry(String workspace) async =>
      CleanupActionResult.fromJson(
        await _request(
          Method.cleanupRetry,
          CleanupActionParams(workspace).toJson(),
        ),
      );

  @override
  Future<CleanupActionResult> cleanupConfirm(String workspace) async =>
      CleanupActionResult.fromJson(
        await _request(
          Method.cleanupConfirm,
          CleanupActionParams(workspace).toJson(),
        ),
      );

  @override
  Future<WorkbenchLoadResult> workbenchLoad() async =>
      WorkbenchLoadResult.fromJson(await _request(Method.workbenchLoad, {}));

  @override
  Future<WorkbenchSaveResult> workbenchSave(Json layout, int revision) async =>
      WorkbenchSaveResult.fromJson(
        await _request(
          Method.workbenchSave,
          WorkbenchSaveParams(layout: layout, revision: revision).toJson(),
        ),
      );

  @override
  Future<WorkspaceOpenResult> workspaceOpen(String path) async =>
      WorkspaceOpenResult.fromJson(
        await _request(
          Method.workspaceOpen,
          WorkspaceOpenParams(path).toJson(),
        ),
      );

  @override
  Future<WorkspaceCheckResult> workspaceCheck(String id) async =>
      WorkspaceCheckResult.fromJson(
        await _request(
          Method.workspaceCheck,
          WorkspaceCheckParams(id).toJson(),
        ),
      );

  @override
  Future<WorkspaceListResult> workspaceList() async =>
      WorkspaceListResult.fromJson(await _request(Method.workspaceList, {}));

  @override
  Future<WorkspaceRemoveResult> workspaceRemove(String id) async =>
      WorkspaceRemoveResult.fromJson(
        await _request(
          Method.workspaceRemove,
          WorkspaceRemoveParams(id).toJson(),
        ),
      );

  @override
  Future<ProfileListResult> profileList() async =>
      ProfileListResult.fromJson(await _request(Method.profileList, {}));

  @override
  Future<ShellProfile> saveProfile(ShellProfile profile) async =>
      ProfileSaveResult.fromJson(
        await _request(Method.profileSave, ProfileSaveParams(profile).toJson()),
      ).profile;

  @override
  Future<void> removeProfile(String id) =>
      _request(Method.profileRemove, ProfileRemoveParams(id).toJson());

  @override
  Future<void> setDefaultProfile(String id) =>
      _request(Method.profileSetDefault, ProfileSetDefaultParams(id).toJson());

  @override
  Future<TerminalChannels> openTerminal(TerminalOpenParams params) =>
      openTerminalChannels(session.connection, params);

  @override
  Future<void> resizeTerminal(String terminalId, int cols, int rows) =>
      _request(
        Method.terminalResize,
        TerminalResizeParams(
          terminalId: terminalId,
          cols: cols,
          rows: rows,
        ).toJson(),
      );

  @override
  Future<void> closeTerminal(String terminalId) =>
      _request(Method.terminalClose, TerminalCloseParams(terminalId).toJson());

  @override
  Future<void> releaseTerminal(String terminalId) => _request(
    Method.terminalRelease,
    TerminalReleaseParams(terminalId).toJson(),
  );

  @override
  Stream<TerminalExited> get terminalExits => session.notifications
      .where((n) => n.method == Method.terminalExited)
      .map((n) => TerminalExited.fromJson(n.params));

  @override
  Stream<TerminalCloseFailed> get terminalCloseFailures => session.notifications
      .where((n) => n.method == Method.terminalCloseFailed)
      .map((n) => TerminalCloseFailed.fromJson(n.params));

  @override
  Future<void> quit() async {
    await session.quit();
  }
}

/// A connector that starts [launcher]'s host.
HostConnector launcherConnector(HostLauncher launcher) =>
    () async => SessionLink(await launcher.start());
