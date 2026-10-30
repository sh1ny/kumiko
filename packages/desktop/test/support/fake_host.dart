import 'dart:async';
import 'dart:collection';

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

  // --- terminals: not scripted yet ---------------------------------------

  @override
  Future<ProfileListResult> profileList() =>
      throw UnimplementedError('profile/list is not scripted');

  @override
  Future<ShellProfile> saveProfile(ShellProfile profile) =>
      throw UnimplementedError('profile/save is not scripted');

  @override
  Future<TerminalChannels> openTerminal(TerminalOpenParams params) =>
      throw UnimplementedError('terminal/open is not scripted');

  @override
  Future<void> resizeTerminal(String terminalId, int cols, int rows) =>
      throw UnimplementedError('terminal/resize is not scripted');

  @override
  Future<void> closeTerminal(String terminalId) =>
      throw UnimplementedError('terminal/close is not scripted');

  @override
  Future<void> releaseTerminal(String terminalId) =>
      throw UnimplementedError('terminal/release is not scripted');

  @override
  Stream<TerminalExited> get terminalExits => const Stream.empty();

  @override
  Future<void> quit() async => quitCalled = true;
}
