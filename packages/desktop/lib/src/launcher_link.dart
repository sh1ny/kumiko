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
  Future<TerminalActivityResult> terminalActivity(
    List<String> terminalIds,
  ) async => TerminalActivityResult.fromJson(
    await _request(
      Method.terminalActivity,
      TerminalActivityParams(terminalIds).toJson(),
    ),
  );

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
  Future<RuntimeListResult> runtimeList() async =>
      RuntimeListResult.fromJson(await _request(Method.runtimeList, {}));

  @override
  Future<RuntimeProfile> saveRuntimeProfile(RuntimeProfile profile) async {
    await _request(Method.runtimeSave, RuntimeSaveParams(profile).toJson());
    return profile;
  }

  @override
  Future<void> removeRuntimeProfile(String id) =>
      _request(Method.runtimeRemove, RuntimeRemoveParams(id).toJson());

  @override
  Future<void> setDefaultRuntimeProfile(String id) =>
      _request(Method.runtimeSetDefault, RuntimeSetDefaultParams(id).toJson());

  @override
  Future<AgentStartResult> startAgent(AgentStartParams params) async =>
      AgentStartResult.fromJson(
        await _request(Method.agentStart, params.toJson()),
      );

  @override
  Future<AgentContinueResult> continueAgent(String sessionId) async =>
      AgentContinueResult.fromJson(
        await _request(
          Method.agentContinue,
          AgentSessionParams(sessionId).toJson(),
        ),
      );

  @override
  Stream<AgentEvent> attachAgent(String sessionId, int eventChannel) {
    final connection = session.connection;
    final decoder = AgentEventDecoder();
    StreamSubscription<Object?>? input;
    var cancelled = false;
    late final StreamController<AgentEvent> events;
    Future<void> cancel() async {
      cancelled = true;
      await input?.cancel();
      await connection
          .closeChannel(eventChannel)
          .then<void>((_) {}, onError: (Object _) {});
    }

    events = StreamController<AgentEvent>(
      sync: true,
      onListen: () {
        final bytes = connection.attachInbound(
          eventChannel,
          grantInitial: false,
        );
        input = bytes.listen(
          (chunk) {
            if (cancelled) return;
            try {
              for (final event in decoder.add(chunk)) {
                events.add(event);
              }
            } on Object catch (error, stack) {
              events.addError(error, stack);
              unawaited(cancel());
              unawaited(events.close());
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!cancelled) events.addError(error, stack);
            unawaited(cancel());
            unawaited(events.close());
          },
          onDone: () {
            if (!cancelled) {
              try {
                decoder.close();
              } on Object catch (error, stack) {
                events.addError(error, stack);
              }
            }
            unawaited(events.close());
          },
        );
        unawaited(() async {
          try {
            await _request(
              Method.agentAttach,
              AgentSessionParams(sessionId).toJson(),
            );
            if (!cancelled) connection.grantInitial(eventChannel);
          } on Object catch (error, stack) {
            if (!cancelled) events.addError(error, stack);
            await cancel();
            unawaited(events.close());
          }
        }());
      },
      onPause: () => input?.pause(),
      onResume: () => input?.resume(),
      onCancel: cancel,
    );
    return events.stream;
  }

  @override
  Future<void> promptAgent(AgentPromptParams params) =>
      _request(Method.agentPrompt, params.toJson());
  @override
  Future<void> stopAgent(String sessionId) =>
      _request(Method.agentStop, AgentSessionParams(sessionId).toJson());
  @override
  Future<void> replyAgentPermission(AgentPermissionReplyParams params) =>
      _request(Method.agentPermissionReply, params.toJson());
  @override
  Future<void> closeAgent(String sessionId) =>
      _request(Method.agentClose, AgentSessionParams(sessionId).toJson());
  @override
  Future<void> releaseAgent(String sessionId) =>
      _request(Method.agentRelease, AgentSessionParams(sessionId).toJson());
  @override
  Future<AgentRecordsResult> agentRecords(List<String> sessionIds) async =>
      AgentRecordsResult.fromJson(
        await _request(
          Method.agentRecords,
          AgentRecordsParams(sessionIds).toJson(),
        ),
      );

  @override
  Future<AgentDraftSaveResult> draftSave(AgentDraftSaveParams params) async =>
      AgentDraftSaveResult.fromJson(
        await _request(Method.agentDraftSave, params.toJson()),
      );
  @override
  Future<AgentDraftLoadResult> draftLoad(String sessionId) async =>
      AgentDraftLoadResult.fromJson(
        await _request(
          Method.agentDraftLoad,
          AgentSessionParams(sessionId).toJson(),
        ),
      );
  @override
  Future<void> draftReset() => _request(Method.agentDraftReset, const {});
  @override
  Stream<void> get draftStoreReady => session.notifications
      .where((n) => n.method == Method.agentDraftStoreReady)
      .map((_) {});

  @override
  Stream<AgentStateParams> get agentStates => session.notifications
      .where((n) => n.method == Method.agentState)
      .map((n) => AgentStateParams.fromJson(n.params));
  @override
  Stream<AgentPermissionRequestedParams> get agentPermissionRequests => session
      .notifications
      .where((n) => n.method == Method.agentPermissionRequested)
      .map((n) => AgentPermissionRequestedParams.fromJson(n.params));
  @override
  Stream<AgentPermissionResolvedParams> get agentPermissionResolutions =>
      session.notifications
          .where((n) => n.method == Method.agentPermissionResolved)
          .map((n) => AgentPermissionResolvedParams.fromJson(n.params));
  @override
  Stream<AgentStopResultParams> get agentStopResults => session.notifications
      .where((n) => n.method == Method.agentStopResult)
      .map((n) => AgentStopResultParams.fromJson(n.params));
  @override
  Stream<AgentTurnEndedParams> get agentTurnEnds => session.notifications
      .where((n) => n.method == Method.agentTurnEnded)
      .map((n) => AgentTurnEndedParams.fromJson(n.params));
  @override
  Stream<AgentExitedParams> get agentExits => session.notifications
      .where((n) => n.method == Method.agentExited)
      .map((n) => AgentExitedParams.fromJson(n.params));
  @override
  Stream<AgentCloseFailedParams> get agentCloseFailures => session.notifications
      .where((n) => n.method == Method.agentCloseFailed)
      .map((n) => AgentCloseFailedParams.fromJson(n.params));

  @override
  Future<void> quit() async {
    await session.quit();
  }
}

/// A connector that starts [launcher]'s host.
HostConnector launcherConnector(HostLauncher launcher) =>
    () async => SessionLink(await launcher.start());

/// A connector for when there is no absolute profile directory to start the
/// host with (`defaultProfileDir` returned null): every start fails, naming
/// [homeVariable], so the status window shows why.
HostConnector noProfileDirConnector(String homeVariable) =>
    () async => throw HostStartException(
      HostStartFailure.spawnFailed,
      'no absolute profile directory: set $homeVariable to an absolute path',
    );
