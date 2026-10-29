import 'dart:async';

import 'package:desktop/src/host_link.dart';
import 'package:host_protocol/host_protocol.dart';

HelloResult helloResult({
  HostState state = HostState.ready,
  String hostVersion = '0.1.0',
  int version = 1,
}) => HelloResult(
  version: version,
  capabilities: const {},
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

/// A scripted [HostLink]: no process, no wire.
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

  void lose() =>
      _lost.complete(const HostLoss(HostLossKind.exited, 1, null, ''));

  @override
  Future<CleanupListResult> cleanupList({String? cursor, int? revision}) async {
    calls.add('list ${cursor ?? '-'}');
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
    return CleanupUnitsResult(
      revision: this.revision,
      stale: revision != null && revision != this.revision,
      units: all.sublist(start, end),
      nextCursor: end < all.length ? '$end' : null,
    );
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

  @override
  Future<void> quit() async => quitCalled = true;
}
