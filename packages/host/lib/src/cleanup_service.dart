import 'dart:async';

import 'package:host_protocol/host_protocol.dart';

import 'host_log.dart';
import 'host_options.dart';
import 'ledger.dart';
import 'settler.dart';
import 'unit_manager.dart';

/// Reconciliation after `hello` and the cleanup API: `cleanup/state`,
/// `cleanup/list`, `cleanup/units`, `cleanup/retry` and `cleanup/confirm`
/// (design D5).
class CleanupService {
  CleanupService({
    required this.ledger,
    required this.log,
    required this.settler,
    required this.units,
    required this.options,
    required this.notify,
  });

  final Ledger ledger;
  final HostLog log;
  final Settler settler;
  final UnitManager units;
  final HostOptions options;

  /// Sends a notification to the desktop.
  final void Function(String method, Json params) notify;

  /// Workspaces (by identity) with a retry running; cleanup operations on one
  /// workspace are serialized.
  final Set<String> _busy = {};

  Future<void>? _reconciliation;
  WindowsEvidence _evidence = const WindowsEvidence();

  Future<void>? get reconciliation => _reconciliation;

  /// Reconciles every pending or running entry left by earlier instances,
  /// then lets launches in and tells the desktop (design D5).
  void startReconciliation(PriorHost? prior) {
    final attested = prior != null && prior.jobTerminated
        ? int.tryParse(prior.instanceId)
        : null;
    _evidence = WindowsEvidence(attestedInstance: attested);
    _reconciliation = _reconcile();
  }

  Future<void> _reconcile() async {
    final clock = Stopwatch()..start();
    // After the hello reply is on its way, not before.
    await Future<void>.delayed(options.reconcileDelay);
    final rows = ledger.earlierActive();
    try {
      final outcomes = await settler.settle(
        rows,
        live: const {},
        evidence: _evidence,
      );
      settler.apply(rows, outcomes);
    } on Object catch (e) {
      for (final row in rows) {
        if (ledger.unit(row.containmentId) != null) {
          ledger.markUnresolved(row.containmentId, 'reconcile-failed: $e');
        }
      }
    }
    ledger.deleteUnreferencedInstances();
    units.reconciling = false;
    log.event(
      'reconciled',
      duration: clock.elapsed,
      ids: {'units': rows.length},
    );
    sendState();
  }

  CleanupState state() => ledger.state(reconciling: units.reconciling);

  void sendState() => notify(Method.cleanupState, state().toJson());

  // --- paging --------------------------------------------------------------

  CleanupUnit _unit(UnitRow r) => CleanupUnit(
    containmentId: r.containmentId,
    kind: r.kind,
    reason: r.reason,
    pid: r.pid,
  );

  CleanupListResult list(CleanupListParams params) {
    final after = params.cursor == null
        ? null
        : CleanupCursor.decode(params.cursor!).targetIdentity;
    final revision = ledger.revision;
    final found = ledger.workspaces(afterIdentity: after, limit: params.limit);
    final page = found.take(params.limit).toList();
    final workspaces = [
      for (final w in page)
        CleanupWorkspace(
          targetIdentity: w.identity,
          targetPath: w.path,
          unitCount: w.count,
          units: [
            for (final u
                in ledger
                    .unitsPage(
                      identity: w.identity,
                      afterContainmentId: null,
                      limit: maxUnitsPerWorkspaceInList,
                    )
                    .take(maxUnitsPerWorkspaceInList))
              _unit(u),
          ],
        ),
    ];
    return CleanupListResult(
      revision: revision,
      stale: params.revision != null && params.revision != revision,
      workspaces: workspaces,
      nextCursor: found.length > params.limit
          ? CleanupCursor(page.last.identity, '').encode()
          : null,
    );
  }

  CleanupUnitsResult unitsOf(CleanupUnitsParams params) {
    final after = params.cursor == null
        ? null
        : CleanupCursor.decode(params.cursor!).containmentId;
    final revision = ledger.revision;
    final found = ledger.unitsPage(
      identity: params.workspace,
      afterContainmentId: after,
      limit: params.limit,
    );
    final page = found.take(params.limit).toList();
    return CleanupUnitsResult(
      revision: revision,
      stale: params.revision != null && params.revision != revision,
      units: [for (final u in page) _unit(u)],
      nextCursor: found.length > params.limit
          ? CleanupCursor(params.workspace, page.last.containmentId).encode()
          : null,
    );
  }

  // --- actions -------------------------------------------------------------

  void _requireSettled() {
    if (units.reconciling) {
      throw RpcException(
        ErrorCode.reconciling,
        'the host is reconciling earlier units',
      );
    }
  }

  /// Reruns reconciliation for every unresolved unit of the workspace.
  Future<CleanupActionResult> retry(String workspace) async {
    _requireSettled();
    if (!_busy.add(workspace)) {
      throw RpcException(
        ErrorCode.retryInProgress,
        'a cleanup retry is running for this workspace',
      );
    }
    try {
      final clock = Stopwatch()..start();
      await Future<void>.delayed(options.retryDelay);
      final rows = ledger.unresolvedIn(workspace);
      final outcomes = await settler.settle(
        rows,
        live: units.live,
        evidence: _evidence,
      );
      settler.apply(rows, outcomes);
      var resolved = 0;
      for (final row in rows) {
        if (outcomes[row.containmentId]!.cleaned) {
          resolved++;
          units.releaseAll([row.containmentId]);
        }
      }
      log.event(
        'cleanup-retry',
        duration: clock.elapsed,
        ids: {'workspace': workspace, 'units': rows.length},
      );
      sendState();
      return CleanupActionResult(
        resolvedUnits: resolved,
        unresolvedUnits: rows.length - resolved,
      );
    } finally {
      _busy.remove(workspace);
    }
  }

  /// The user's word that the workspace's processes are gone: deletes its
  /// unresolved rows and logs each unit id.
  CleanupActionResult confirm(String workspace) {
    _requireSettled();
    if (_busy.contains(workspace)) {
      throw RpcException(
        ErrorCode.retryInProgress,
        'a cleanup retry is running for this workspace',
      );
    }
    final rows = ledger.unresolvedIn(workspace);
    for (final row in rows) {
      ledger.delete(row.containmentId);
      log.event('unit-confirmed-by-user', ids: {'unit': row.containmentId});
    }
    units.releaseAll([for (final r in rows) r.containmentId]);
    ledger.deleteUnreferencedInstances();
    sendState();
    return CleanupActionResult(resolvedUnits: rows.length, unresolvedUnits: 0);
  }
}
