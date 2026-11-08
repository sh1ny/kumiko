import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:desktop/src/host_link.dart';
import 'package:host_protocol/host_protocol.dart';

HelloResult helloResult({
  HostState state = HostState.ready,
  String hostVersion = '0.1.0',
  int version = 1,
  Set<String> capabilities = const {Capability.workbench},
}) => HelloResult(
  version: version,
  capabilities: capabilities,
  instanceId: 'instance-1',
  hostVersion: hostVersion,
  state: state,
);

CleanupUnit unit(int n, {String reason = 'scan-unreadable'}) =>
    CleanupUnit(containmentId: 'unit-$n', kind: 'test', reason: reason, pid: n);

CleanupWorkspace workspace(
  int n, {
  int unitCount = 2,
  String? path,
  List<CleanupUnit>? units,
}) => CleanupWorkspace(
  targetIdentity: 'ws-$n',
  targetPath: path ?? '/work/project-$n',
  unitCount: unitCount,
  units:
      units ??
      [for (var i = 0; i < unitCount && i < 10; i++) unit(n * 1000 + i)],
);

WorkspaceRecord workspaceRecord(
  String id, {
  String? path,
  String? label,
  Availability availability = Availability.available,
  String? reason,
  int seq = 1,
  int cleanupGroups = 0,
}) => WorkspaceRecord(
  id: id,
  path: path ?? '/work/$id',
  label: label ?? id,
  identity: 'identity-$id',
  availability: availability,
  reason: reason,
  seq: seq,
  cleanup: WorkspaceCleanup(groups: cleanupGroups),
);

/// A scripted [HostLink]: no process, no wire.
///
/// The workbench methods answer from queued answers or a default; set a
/// `...Gate` to hold an answer until it completes, for example a save that
/// never answers.
class FakeHostLink implements HostLink {
  FakeHostLink({HelloResult? hello, List<CleanupWorkspace>? workspaces})
    : hello = hello ?? helloResult(),
      workspaces = [...?workspaces];

  @override
  final HelloResult hello;

  /// The host's unresolved workspaces, in cursor order.
  final List<CleanupWorkspace> workspaces;
  int revision = 1;
  int pageSize = 25;
  int unitsPageSize = 10;

  /// Every unit of a workspace, by `target_identity`; defaults to
  /// `unitCount` generated units (the list carries only the first ten).
  final Map<String, List<CleanupUnit>> allUnits = {};

  /// What [cleanupRetry] does: true clears the workspace.
  bool retryResolves = true;
  Object? retryError;
  Object? confirmError;

  final List<String> calls = [];
  bool quitCalled = false;

  // --- workbench / workspace scripting ------------------------------------

  /// The stored layout and its revision, as `workbench/load` answers them.
  Json? storedLayout;
  String? restoreError;
  int layoutRevision = 0;
  int cleanupRevision = 1;

  /// The known workspaces, in order.
  final List<WorkspaceRecord> records = [];

  /// Each save's layout and revision, in call order.
  final List<({Json layout, int revision})> saves = [];

  /// Per-call answers, consumed first-in first-out before the defaults: an
  /// `Exception` or `Error` is thrown, anything else is the result.
  final Queue<Object> loadAnswers = Queue();
  final Queue<Object> saveAnswers = Queue();
  final Queue<Object> openAnswers = Queue();
  final Queue<Object> checkAnswers = Queue();
  final Queue<Object> listAnswers = Queue();
  final Queue<Object> removeAnswers = Queue();

  /// Held answers: the call is recorded at once but does not answer until
  /// the gate completes.
  Completer<void>? loadGate;
  Completer<void>? saveGate;
  Completer<void>? openGate;
  Completer<void>? checkGate;
  Completer<void>? listGate;
  Completer<void>? removeGate;

  final StreamController<WorkspaceChanged> _changes =
      StreamController.broadcast();

  @override
  Stream<WorkspaceChanged> get workspaceChanges => _changes.stream;

  void emitWorkspaceChanged(WorkspaceRecord record, {int? cleanupRevision}) =>
      _changes.add(
        WorkspaceChanged(
          workspace: record,
          cleanupRevision: cleanupRevision ?? this.cleanupRevision,
        ),
      );

  Future<T> _answer<T extends Object>(
    Queue<Object> queue,
    Completer<void>? gate,
    T Function() fallback,
  ) async {
    final scripted = queue.isEmpty ? null : queue.removeFirst();
    await gate?.future;
    if (scripted is Exception || scripted is Error) throw scripted!;
    return scripted == null ? fallback() : scripted as T;
  }

  @override
  Future<WorkbenchLoadResult> workbenchLoad() {
    calls.add('workbench/load');
    return _answer(
      loadAnswers,
      loadGate,
      () => WorkbenchLoadResult(
        layout: storedLayout,
        restoreError: storedLayout == null ? restoreError : null,
        revision: layoutRevision,
        workspaces: [...records],
        cleanupRevision: cleanupRevision,
      ),
    );
  }

  @override
  Future<WorkbenchSaveResult> workbenchSave(Json layout, int revision) {
    calls.add('workbench/save $revision');
    saves.add((layout: layout, revision: revision));
    return _answer(saveAnswers, saveGate, () {
      // The host stores a save only above its stored revision (design D6).
      if (revision <= layoutRevision) throw staleRevision(layoutRevision);
      storedLayout = layout;
      layoutRevision = revision;
      return WorkbenchSaveResult(revision);
    });
  }

  @override
  Future<WorkspaceOpenResult> workspaceOpen(String path) {
    calls.add('workspace/open $path');
    return _answer(openAnswers, openGate, () {
      final i = records.indexWhere((r) => r.path == path);
      final existing = i >= 0;
      final record = existing
          ? records[i]
          : workspaceRecord(
              'ws-open-${records.length + 1}',
              path: path,
              label: path.split('/').last,
            );
      if (!existing) records.add(record);
      return WorkspaceOpenResult(
        workspace: record,
        existing: existing,
        cleanupRevision: cleanupRevision,
      );
    });
  }

  @override
  Future<WorkspaceCheckResult> workspaceCheck(String id) {
    calls.add('workspace/check $id');
    return _answer(
      checkAnswers,
      checkGate,
      () => WorkspaceCheckResult(
        workspace: records.firstWhere((r) => r.id == id),
        cleanupRevision: cleanupRevision,
      ),
    );
  }

  @override
  Future<WorkspaceListResult> workspaceList() {
    calls.add('workspace/list');
    return _answer(
      listAnswers,
      listGate,
      () => WorkspaceListResult(
        workspaces: [...records],
        cleanupRevision: cleanupRevision,
      ),
    );
  }

  @override
  Future<WorkspaceRemoveResult> workspaceRemove(String id) {
    calls.add('workspace/remove $id');
    return _answer(removeAnswers, removeGate, () {
      records.removeWhere((r) => r.id == id);
      return WorkspaceRemoveResult(++layoutRevision);
    });
  }

  /// When set, a `cleanup/units` answer, computed when it was asked, is
  /// held until this completes.
  Completer<void>? unitsGate;

  final StreamController<CleanupState> _states = StreamController.broadcast();
  final Completer<HostLoss> _lost = Completer();

  @override
  Future<HostLoss> get lost => _lost.future;

  @override
  Stream<CleanupState> get cleanupStates => _states.stream;

  int get totalUnits => workspaces.fold(0, (n, w) => n + w.unitCount);

  CleanupState get state => CleanupState(
    reconciling: false,
    revision: revision,
    unresolvedWorkspaces: workspaces.length,
    unresolvedUnits: totalUnits,
  );

  void emitState([CleanupState? s]) => _states.add(s ?? state);

  void lose([
    HostLoss loss = const HostLoss(HostLossKind.exited, 1, null, ''),
  ]) => _lost.complete(loss);

  @override
  Future<CleanupListResult> cleanupList({
    String? cursor,
    int? revision,
    String? workspace,
  }) async {
    calls.add(
      'list ${cursor ?? '-'}${workspace == null ? '' : ' ws=$workspace'}',
    );
    final start = cursor == null ? 0 : int.parse(cursor);
    final end = (start + pageSize).clamp(0, workspaces.length);
    return CleanupListResult(
      revision: this.revision,
      stale: revision != null && revision != this.revision,
      workspaces: workspaces.sublist(start, end),
      nextCursor: end < workspaces.length ? '$end' : null,
    );
  }

  @override
  Future<CleanupUnitsResult> cleanupUnits(
    String workspace, {
    String? cursor,
    int? revision,
  }) async {
    calls.add('units $workspace ${cursor ?? '-'}');
    final w = workspaces.firstWhere((w) => w.targetIdentity == workspace);
    final n = int.parse(workspace.substring(3));
    final all =
        allUnits[workspace] ??
        [for (var i = 0; i < w.unitCount; i++) unit(n * 1000 + i)];
    final start = cursor == null ? 0 : int.parse(cursor);
    final end = (start + unitsPageSize).clamp(0, all.length);
    final result = CleanupUnitsResult(
      revision: this.revision,
      stale: revision != null && revision != this.revision,
      units: all.sublist(start, end),
      nextCursor: end < all.length ? '$end' : null,
    );
    await unitsGate?.future;
    return result;
  }

  @override
  Future<CleanupActionResult> cleanupRetry(String workspace) async {
    calls.add('retry $workspace');
    final error = retryError;
    if (error != null) throw error;
    final w = workspaces.firstWhere((w) => w.targetIdentity == workspace);
    revision++;
    if (retryResolves) {
      workspaces.remove(w);
      emitState();
      return CleanupActionResult(
        resolvedUnits: w.unitCount,
        unresolvedUnits: 0,
      );
    }
    emitState();
    return CleanupActionResult(resolvedUnits: 0, unresolvedUnits: w.unitCount);
  }

  @override
  Future<CleanupActionResult> cleanupConfirm(String workspace) async {
    calls.add('confirm $workspace');
    final error = confirmError;
    if (error != null) throw error;
    final w = workspaces.firstWhere((w) => w.targetIdentity == workspace);
    workspaces.remove(w);
    revision++;
    emitState();
    return CleanupActionResult(resolvedUnits: w.unitCount, unresolvedUnits: 0);
  }

  // --- terminals -----------------------------------------------------------

  /// What `profile/list` answers.
  ProfileListResult profiles = const ProfileListResult(
    profiles: [
      ShellProfile(id: 'builtin:pwsh', name: 'pwsh', executable: '/bin/pwsh'),
      ShellProfile(id: 'builtin:bash', name: 'bash', executable: '/bin/bash'),
    ],
    defaultId: 'builtin:pwsh',
    defaultAvailable: true,
  );

  /// Per-call answers for `terminal/open`, consumed first-in first-out: an
  /// `Exception` or `Error` is thrown. The default opens a [FakeTerminal].
  final Queue<Object> terminalOpenAnswers = Queue();

  /// Holds the `terminal/open` answer until it completes.
  Completer<void>? terminalOpenGate;

  /// Holds the `terminal/close` answer until it completes.
  Completer<void>? terminalCloseGate;

  /// Thrown by `terminal/close` when set.
  Object? closeError;

  final List<TerminalOpenParams> opened = [];
  final List<({String id, int cols, int rows})> resizes = [];
  final List<String> closed = [];
  final List<String> released = [];
  final List<ShellProfile> savedProfiles = [];
  final List<String> removedProfiles = [];
  final List<String> defaultsSet = [];
  final Map<String, FakeTerminal> terminals = {};
  int _terminalCount = 0;

  final StreamController<TerminalExited> _exits = StreamController.broadcast(
    sync: true,
  );
  final StreamController<TerminalCloseFailed> _closeFailures =
      StreamController.broadcast(sync: true);

  /// The newest terminal opened.
  FakeTerminal get lastTerminal => terminals.values.last;

  @override
  Future<ProfileListResult> profileList() async {
    calls.add('profile/list');
    return profiles;
  }

  @override
  Future<ShellProfile> saveProfile(ShellProfile profile) async {
    calls.add('profile/save ${profile.id}');
    if (profile.isBuiltin) throw RpcException(ErrorCode.profileLocked);
    savedProfiles.add(profile);
    profiles = ProfileListResult(
      profiles: [
        for (final p in profiles.profiles)
          if (p.id != profile.id) p,
        profile,
      ],
      defaultId: profiles.defaultId,
      defaultAvailable: profiles.defaultAvailable,
    );
    return profile;
  }

  @override
  Future<void> removeProfile(String id) async {
    calls.add('profile/remove $id');
    removedProfiles.add(id);
    profiles = ProfileListResult(
      profiles: [
        for (final p in profiles.profiles)
          if (p.id != id) p,
      ],
      defaultId: profiles.defaultId,
      defaultAvailable: profiles.defaultId != id && profiles.defaultAvailable,
    );
  }

  @override
  Future<void> setDefaultProfile(String id) async {
    calls.add('profile/setDefault $id');
    defaultsSet.add(id);
    profiles = ProfileListResult(
      profiles: profiles.profiles,
      defaultId: id,
      defaultAvailable: profiles.profiles.any((p) => p.id == id),
    );
  }

  @override
  Future<TerminalChannels> openTerminal(TerminalOpenParams params) async {
    calls.add('terminal/open ${params.profileId}');
    opened.add(params);
    final scripted = terminalOpenAnswers.isEmpty
        ? null
        : terminalOpenAnswers.removeFirst();
    await terminalOpenGate?.future;
    if (scripted is Exception || scripted is Error) throw scripted!;
    final terminal = FakeTerminal('t${++_terminalCount}');
    terminals[terminal.id] = terminal;
    return TerminalChannels(
      terminalId: terminal.id,
      output: terminal.output.stream,
      write: terminal.write,
    );
  }

  @override
  Future<void> resizeTerminal(String terminalId, int cols, int rows) async {
    calls.add('terminal/resize $terminalId');
    resizes.add((id: terminalId, cols: cols, rows: rows));
  }

  @override
  Future<void> closeTerminal(String terminalId) async {
    calls.add('terminal/close $terminalId');
    closed.add(terminalId);
    await terminalCloseGate?.future;
    if (closeError case final error?) throw error;
  }

  /// What `terminal/activity` reports per terminal id; an open terminal not
  /// listed is idle, any other id is ended. Set [activityError] to fail the
  /// request, or [activityGate] to hold its answer.
  final Map<String, TerminalActivity> activities = {};
  Object? activityError;
  Completer<void>? activityGate;

  /// Every `terminal/activity` request's ids, in call order.
  final List<List<String>> activityRequests = [];

  /// Makes [terminalId] busy with [programs].
  void setBusy(String terminalId, [List<String> programs = const ['vim']]) =>
      activities[terminalId] = TerminalActivity(
        terminalId: terminalId,
        state: TerminalActivityState.busy,
        programs: programs,
        processCount: programs.length,
      );

  /// Makes [terminalId]'s activity unknown.
  void setUnknown(String terminalId) =>
      activities[terminalId] = TerminalActivity(
        terminalId: terminalId,
        state: TerminalActivityState.unknown,
      );

  @override
  Future<TerminalActivityResult> terminalActivity(
    List<String> terminalIds,
  ) async {
    calls.add('terminal/activity ${terminalIds.join(',')}');
    activityRequests.add([...terminalIds]);
    await activityGate?.future;
    if (activityError case final error?) throw error;
    return TerminalActivityResult([
      for (final id in terminalIds)
        activities[id] ??
            TerminalActivity(
              terminalId: id,
              state: terminals.containsKey(id)
                  ? TerminalActivityState.idle
                  : TerminalActivityState.ended,
            ),
    ]);
  }

  @override
  Future<void> releaseTerminal(String terminalId) async {
    calls.add('terminal/release $terminalId');
    released.add(terminalId);
  }

  @override
  Stream<TerminalExited> get terminalExits => _exits.stream;

  @override
  Stream<TerminalCloseFailed> get terminalCloseFailures =>
      _closeFailures.stream;

  /// The host reports that [terminalId] ended.
  void emitExit(
    String terminalId, {
    int? status = 0,
    TerminalExitReason reason = TerminalExitReason.exited,
    bool outputComplete = true,
  }) => _exits.add(
    TerminalExited(
      terminalId: terminalId,
      status: status,
      reason: reason,
      outputComplete: outputComplete,
    ),
  );

  void emitCloseFailed(
    String terminalId, [
    String reason = 'scan-unreadable',
  ]) => _closeFailures.add(
    TerminalCloseFailed(terminalId: terminalId, reason: reason),
  );

  // Agent RPCs are scripted independently of terminal RPCs.
  RuntimeListResult runtimes = const RuntimeListResult(
    profiles: [
      RuntimeProfile(
        id: 'runtime-1',
        name: 'Claude Code',
        runtimeKind: 'claude-code',
        executable: '/bin/node',
      ),
    ],
    defaultAvailable: true,
    defaultId: 'runtime-1',
  );
  final Queue<Object> agentStartAnswers = Queue();
  final Queue<Object> agentContinueAnswers = Queue();
  Completer<void>? agentStartGate;
  final List<AgentStartParams> agentStarts = [];
  final List<AgentPromptParams> agentPrompts = [];
  final List<AgentPermissionReplyParams> agentReplies = [];
  final List<String> agentStops = [];
  final List<String> agentCloses = [];
  final List<String> agentReleases = [];
  final Map<String, AgentRecord> agentRecordMap = {};
  final Map<String, StreamController<AgentEvent>> agentChannels = {};
  final Map<String, int> _agentEventCounts = {};
  final StreamController<AgentStateParams> agentStateSource =
      StreamController.broadcast(sync: true);
  final StreamController<AgentPermissionRequestedParams> agentRequestSource =
      StreamController.broadcast(sync: true);
  final StreamController<AgentPermissionResolvedParams> agentResolvedSource =
      StreamController.broadcast(sync: true);
  final StreamController<AgentStopResultParams> agentStopSource =
      StreamController.broadcast(sync: true);
  final StreamController<AgentTurnEndedParams> agentTurnSource =
      StreamController.broadcast(sync: true);
  final StreamController<AgentExitedParams> agentExitSource =
      StreamController.broadcast(sync: true);
  final StreamController<AgentCloseFailedParams> agentCloseFailureSource =
      StreamController.broadcast(sync: true);

  @override
  Stream<AgentStateParams> get agentStates => agentStateSource.stream;
  @override
  Stream<AgentPermissionRequestedParams> get agentPermissionRequests =>
      agentRequestSource.stream;
  @override
  Stream<AgentPermissionResolvedParams> get agentPermissionResolutions =>
      agentResolvedSource.stream;
  @override
  Stream<AgentStopResultParams> get agentStopResults => agentStopSource.stream;
  @override
  Stream<AgentTurnEndedParams> get agentTurnEnds => agentTurnSource.stream;
  @override
  Stream<AgentExitedParams> get agentExits => agentExitSource.stream;
  @override
  Stream<AgentCloseFailedParams> get agentCloseFailures =>
      agentCloseFailureSource.stream;

  @override
  Future<RuntimeListResult> runtimeList() async {
    calls.add('runtime/list');
    return runtimes;
  }

  @override
  Future<RuntimeProfile> saveRuntimeProfile(RuntimeProfile profile) async {
    calls.add('runtime/save ${profile.id}');
    if (profile.isBuiltin) throw RpcException(ErrorCode.profileLocked);
    runtimes = RuntimeListResult(
      profiles: [
        for (final p in runtimes.profiles)
          if (p.id != profile.id) p,
        profile,
      ],
      defaultId: runtimes.defaultId ?? profile.id,
      defaultAvailable: true,
    );
    return profile;
  }

  @override
  Future<void> removeRuntimeProfile(String id) async {
    calls.add('runtime/remove $id');
    runtimes = RuntimeListResult(
      profiles: [
        for (final p in runtimes.profiles)
          if (p.id != id) p,
      ],
      defaultId: runtimes.defaultId,
      defaultAvailable: runtimes.defaultAvailable && runtimes.defaultId != id,
    );
  }

  @override
  Future<void> setDefaultRuntimeProfile(String id) async {
    calls.add('runtime/setDefault $id');
    runtimes = RuntimeListResult(
      profiles: runtimes.profiles,
      defaultId: id,
      defaultAvailable: runtimes.profiles.any((p) => p.id == id),
    );
  }

  @override
  Future<AgentStartResult> startAgent(AgentStartParams params) async {
    calls.add('agent/start ${params.workspaceId}');
    agentStarts.add(params);
    return _answer(agentStartAnswers, agentStartGate, () {
      final id = 'agent-${agentStarts.length}';
      agentRecordMap[id] = const AgentRecord(
        known: true,
        workspaceAvailable: true,
      );
      return AgentStartResult(
        sessionId: id,
        eventChannel: 100 + agentStarts.length,
        adapter: const AgentAdapter(name: 'scripted-acp', version: 'test-only'),
        capabilities: const [],
      );
    });
  }

  @override
  Future<AgentContinueResult> continueAgent(String id) async {
    calls.add('agent/continue $id');
    return _answer(
      agentContinueAnswers,
      null,
      () => const AgentContinueResult(
        eventChannel: 120,
        adapter: AgentAdapter(name: 'scripted-acp', version: 'test-only'),
        capabilities: ['load'],
        mode: AgentContinueMode.load,
      ),
    );
  }

  @override
  Stream<AgentEvent> attachAgent(String id, int channel) {
    calls.add('agent/attach $id');
    final source = StreamController<AgentEvent>(
      sync: true,
      onListen: () =>
          scheduleMicrotask(() => agentState(id, AgentState.idle, 0)),
      // Keep cancellation completion in the test's zone rather than the
      // SDK's shared root-zone completed future, which pump cannot flush.
      onCancel: () => Future<void>.value(),
    );
    // Allocate done before close cancels the synchronous subscription;
    // otherwise close can also return the root-zone completed future.
    unawaited(source.done);
    agentChannels[id] = source;
    _agentEventCounts[id] = 0;
    return source.stream;
  }

  @override
  Future<void> promptAgent(AgentPromptParams params) async {
    calls.add('agent/prompt ${params.sessionId}');
    agentPrompts.add(params);
  }

  @override
  Future<void> stopAgent(String id) async {
    calls.add('agent/stop $id');
    agentStops.add(id);
  }

  @override
  Future<void> replyAgentPermission(AgentPermissionReplyParams params) async {
    calls.add('agent/permissionReply ${params.requestId}');
    agentReplies.add(params);
  }

  @override
  Future<void> closeAgent(String id) async {
    calls.add('agent/close $id');
    agentCloses.add(id);
  }

  @override
  Future<void> releaseAgent(String id) async {
    calls.add('agent/release $id');
    agentReleases.add(id);
  }

  @override
  Future<AgentRecordsResult> agentRecords(List<String> ids) async {
    calls.add('agent/records ${ids.join(",")}');
    return AgentRecordsResult({
      for (final id in ids)
        id:
            agentRecordMap[id] ??
            const AgentRecord(known: false, workspaceAvailable: false),
    });
  }

  void agentState(
    String id,
    AgentState state, [
    int seq = 1,
    AgentTools? tools,
  ]) => agentStateSource.add(
    AgentStateParams(sessionId: id, seq: seq, state: state, tools: tools),
  );

  void agentEvent(String id, AgentEvent event) {
    _agentEventCounts[id] = (_agentEventCounts[id] ?? 0) + 1;
    agentChannels[id]!.add(event);
  }

  void agentExit(
    String id, {
    AgentExitReason reason = AgentExitReason.closed,
    int? status,
  }) => agentExitSource.add(
    AgentExitedParams(
      sessionId: id,
      reason: reason,
      eventCount: _agentEventCounts[id] ?? 0,
      status: status,
    ),
  );

  @override
  Future<void> quit() async => quitCalled = true;
}

/// A host terminal as the desktop sees it: an output channel that, like the
/// real one (`_Inbound.pump` in `host_protocol`), hands a chunk to its
/// listener only while the listener is not paused, and counts the credit it
/// would have returned for it. A listener that pauses therefore stops the
/// delivery and the credit, and the rest waits in [queue].
class FakeTerminal {
  FakeTerminal(this.id) {
    output = StreamController<Uint8List>(
      sync: true,
      onListen: _pump,
      onResume: _pump,
    );
  }

  final String id;
  late final StreamController<Uint8List> output;

  /// Chunks the host sent that the listener has not taken.
  final Queue<Uint8List> queue = Queue();

  /// Bytes handed to the listener; the credit returned equals this.
  int delivered = 0;

  /// Every `write` the desktop made, in order.
  final List<Uint8List> written = [];

  /// Holds the `write` answers until it completes.
  Completer<void>? writeGate;

  bool get listening => output.hasListener;
  bool get paused => output.isPaused;
  int get queuedBytes => queue.fold(0, (n, c) => n + c.length);

  /// The host sends [bytes] on the output channel.
  void send(Uint8List bytes) {
    queue.add(bytes);
    _pump();
  }

  void _pump() {
    while (queue.isNotEmpty && output.hasListener && !output.isPaused) {
      final chunk = queue.removeFirst();
      delivered += chunk.length;
      output.add(chunk);
    }
  }

  Future<void> write(Uint8List bytes) async {
    await writeGate?.future;
    written.add(bytes);
  }
}
