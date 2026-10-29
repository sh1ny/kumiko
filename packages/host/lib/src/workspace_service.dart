import 'dart:math';

import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';
import 'package:sqlite3/sqlite3.dart';

import 'host_log.dart';
import 'host_options.dart';
import 'ledger.dart';
import 'store/store.dart';
import 'workspace_resolver.dart';

/// One `workspace` row.
class WorkspaceRow {
  const WorkspaceRow({
    required this.id,
    required this.path,
    required this.identity,
    required this.label,
  });

  factory WorkspaceRow.fromRow(Row r) => WorkspaceRow(
    id: r['id'] as String,
    path: r['path'] as String,
    identity: r['identity'] as String,
    label: r['label'] as String,
  );

  final String id;
  final String path;
  final String identity;
  final String label;
}

/// What the host shows of a workspace beyond its row (host memory).
class _Shown {
  const _Shown(this.availability, this.reason);
  final Availability availability;
  final String? reason;
}

/// Reasons a workspace is unavailable.
abstract final class UnavailableReason {
  static const String missing = 'target-unavailable';
  static const String notAnswering = 'not answering';
  static const String hostBusy = 'host busy resolving folders';
}

/// The workspaces: `workspace/open`, `workspace/check`, `workspace/list`, the
/// load-time checks and the ordering of resolutions (design D4, D5).
class WorkspaceService {
  WorkspaceService({
    required this._store,
    required this.ledger,
    required this.log,
    required this.options,
    required this.resolver,
    required this.notify,
  });

  final Store _store;
  final Ledger ledger;
  final HostLog log;
  final HostOptions options;
  final WorkspaceResolver resolver;

  /// Sends a notification to the desktop.
  final void Function(String method, Json params) notify;

  /// One host-wide counter: every resolution takes the next number when its
  /// request arrives, before it resolves.
  int _resolveSeq = 0;

  /// The `seq` last applied per workspace; host memory, reset on start.
  final Map<String, int> _applied = {};

  final Map<String, _Shown> _shown = {};

  static final Random _random = Random.secure();

  T _guard<T>(T Function() body) {
    try {
      return body();
    } on SqliteException catch (e) {
      throw RpcException(ErrorCode.storeError, 'workspace store failed: $e');
    }
  }

  // --- rows ----------------------------------------------------------------

  List<WorkspaceRow> rows() => _guard(
    () => [
      for (final r in _store.select(
        'SELECT id, path, identity, label FROM workspace ORDER BY rowid',
      ))
        WorkspaceRow.fromRow(r),
    ],
  );

  WorkspaceRow? row(String id) => _guard(() {
    final found = _store.select(
      'SELECT id, path, identity, label FROM workspace WHERE id = ?',
      [id],
    );
    return found.isEmpty ? null : WorkspaceRow.fromRow(found.single);
  });

  WorkspaceRow? _rowWhere(String column, String value) => _guard(() {
    final found = _store.select(
      'SELECT id, path, identity, label FROM workspace WHERE $column = ?',
      [value],
    );
    return found.isEmpty ? null : WorkspaceRow.fromRow(found.first);
  });

  WorkspaceRow requireRow(String id) =>
      row(id) ??
      (throw RpcException(ErrorCode.unknownWorkspace, 'no workspace $id'));

  /// The directory a workspace's cleanup state is attributed to.
  ({String identity, String path})? cleanupTarget(String id) {
    final r = row(id);
    return r == null ? null : (identity: r.identity, path: r.path);
  }

  /// Forgets what the host remembers of a workspace whose row is gone.
  void forget(String id) {
    _applied.remove(id);
    _shown.remove(id);
  }

  // --- records -------------------------------------------------------------

  WorkspaceRecord record(WorkspaceRow r) {
    final shown = _shown[r.id];
    return WorkspaceRecord(
      id: r.id,
      path: r.path,
      label: r.label,
      identity: r.identity,
      availability: shown?.availability ?? Availability.checking,
      reason: shown?.reason,
      seq: _applied[r.id] ?? 0,
      cleanup: WorkspaceCleanup(
        groups: ledger.unresolvedGroupCountFor(
          identity: r.identity,
          path: r.path,
        ),
      ),
    );
  }

  List<WorkspaceRecord> records() => [for (final r in rows()) record(r)];

  WorkspaceListResult list() => WorkspaceListResult(
    workspaces: records(),
    cleanupRevision: ledger.revision,
  );

  void _publish(WorkspaceRow r) => notify(
    Method.workspaceChanged,
    WorkspaceChanged(
      workspace: record(r),
      cleanupRevision: ledger.revision,
    ).toJson(),
  );

  // --- ordering ------------------------------------------------------------

  /// Applies a resolution of workspace [id] that took [seq] and returns true,
  /// unless the row is gone or a later resolution was applied first.
  /// Applying writes back a changed identity, sets what is shown and
  /// publishes `workspace/changed`. With [relocate], the workspace also
  /// moves to the resolved path and its folder name.
  bool _apply(
    String id,
    int seq,
    ResolveResult result, {
    bool relocate = false,
  }) {
    final current = row(id);
    if (current == null || seq <= (_applied[id] ?? 0)) return false;
    var updated = current;
    switch (result) {
      case ResolveFound(:final directory):
        if (relocate && directory.realPath != current.path) {
          final label = _labelOf(directory.realPath);
          _guard(
            () => _store.execute(
              'UPDATE workspace SET path = ?, identity = ?, label = ? '
              'WHERE id = ?',
              [directory.realPath, directory.id, label, id],
            ),
          );
          updated = WorkspaceRow(
            id: id,
            path: directory.realPath,
            identity: directory.id,
            label: label,
          );
        } else if (directory.id != current.identity) {
          _guard(
            () => _store.execute(
              'UPDATE workspace SET identity = ? WHERE id = ?',
              [directory.id, id],
            ),
          );
          updated = WorkspaceRow(
            id: id,
            path: current.path,
            identity: directory.id,
            label: current.label,
          );
        }
        _shown[id] = const _Shown(Availability.available, null);
      case ResolveMissing():
        _shown[id] = const _Shown(
          Availability.unavailable,
          UnavailableReason.missing,
        );
      case ResolveTimedOut():
        _shown[id] = const _Shown(
          Availability.unavailable,
          UnavailableReason.notAnswering,
        );
      case ResolveStarved():
        _shown[id] = const _Shown(
          Availability.unavailable,
          UnavailableReason.hostBusy,
        );
      case ResolveBusy():
        return false;
    }
    _applied[id] = seq;
    _publish(updated);
    return true;
  }

  // --- requests ------------------------------------------------------------

  Future<WorkspaceOpenResult> open(String path) async {
    final seq = ++_resolveSeq;
    final result = await resolver.resolve(path, queue: false);
    switch (result) {
      case ResolveBusy():
        throw RpcException(
          ErrorCode.busy,
          'the host is resolving too many folders',
        );
      case ResolveTimedOut():
        throw RpcException(
          ErrorCode.resolveTimeout,
          'the folder did not answer in time',
        );
      case ResolveMissing(:final detail):
        throw RpcException(ErrorCode.targetUnavailable, detail);
      case ResolveStarved():
        throw RpcException(ErrorCode.busy, 'the host is resolving folders');
      case ResolveFound(:final directory):
        final known =
            _rowWhere('identity', directory.id) ??
            _rowWhere('path', directory.realPath);
        if (known != null) {
          final relocate = await _moved(known, directory);
          // Removed while its old path was checked: the folder is opened
          // again below, unless another open stored it meanwhile.
          final current =
              row(known.id) ??
              _rowWhere('identity', directory.id) ??
              _rowWhere('path', directory.realPath);
          if (current != null) {
            // An open that lost the ordering writes and publishes nothing.
            _apply(
              current.id,
              seq,
              result,
              relocate: current.id == known.id && relocate,
            );
            return WorkspaceOpenResult(
              workspace: record(row(current.id) ?? current),
              existing: true,
              cleanupRevision: ledger.revision,
            );
          }
        }
        final created = _create(directory);
        _applied[created.id] = seq;
        _shown[created.id] = const _Shown(Availability.available, null);
        _publish(created);
        return WorkspaceOpenResult(
          workspace: record(created),
          existing: false,
          cleanupRevision: ledger.revision,
        );
    }
  }

  /// The directory of [known], matched by identity, was opened at another
  /// path: it moved when its stored path no longer resolves to it (missing
  /// or another directory). A link to it leaves the stored path, and so
  /// does a stored path that cannot be resolved now, or one another
  /// workspace already holds.
  Future<bool> _moved(WorkspaceRow known, ResolvedDirectory directory) async {
    if (known.path == directory.realPath ||
        known.identity != directory.id ||
        _rowWhere('path', directory.realPath) != null) {
      return false;
    }
    return switch (await resolver.resolve(known.path, queue: false)) {
      ResolveMissing() => true,
      ResolveFound(directory: final at) => at.id != directory.id,
      _ => false,
    };
  }

  WorkspaceRow _create(ResolvedDirectory directory) {
    final count =
        _guard(() => _store.select('SELECT COUNT(*) AS n FROM workspace'))
                .single['n']
            as int;
    if (count >= options.workspaceCap) {
      throw RpcException(
        ErrorCode.workspaceCap,
        'at most ${options.workspaceCap} workspaces',
      );
    }
    final created = WorkspaceRow(
      id: _newId(),
      path: directory.realPath,
      identity: directory.id,
      label: _labelOf(directory.realPath),
    );
    _guard(
      () => _store.execute(
        'INSERT INTO workspace(id, path, identity, label, added_at) '
        'VALUES (?, ?, ?, ?, ?)',
        [
          created.id,
          created.path,
          created.identity,
          created.label,
          DateTime.now().toUtc().toIso8601String(),
        ],
      ),
    );
    return created;
  }

  Future<WorkspaceCheckResult> check(String id) async {
    final target = requireRow(id);
    final seq = ++_resolveSeq;
    final result = await resolver.resolve(target.path, queue: false);
    if (result is ResolveBusy) {
      throw RpcException(
        ErrorCode.busy,
        'the host is resolving too many folders',
      );
    }
    // Removed while it resolved: nothing is applied or published.
    final now = requireRow(id);
    _apply(id, seq, result);
    return WorkspaceCheckResult(
      workspace: record(row(id) ?? now),
      cleanupRevision: ledger.revision,
    );
  }

  /// Marks every workspace *checking* and resolves each of them, queueing for
  /// a slot; one `workspace/changed` follows per workspace. Returns at once.
  List<WorkspaceRecord> startLoadChecks() {
    final all = rows();
    for (final r in all) {
      _shown[r.id] = const _Shown(Availability.checking, null);
      final seq = ++_resolveSeq;
      resolver.resolve(r.path, queue: true).then((result) {
        try {
          _apply(r.id, seq, result);
        } on RpcException catch (e) {
          log.event('workspace-check-failed', code: e.reason);
        }
      });
    }
    return [for (final r in all) record(r)];
  }

  /// Deletes the row of [id]; the caller holds the transaction.
  void deleteRow(String id) =>
      _guard(() => _store.execute('DELETE FROM workspace WHERE id = ?', [id]));

  // --- helpers -------------------------------------------------------------

  static String _newId() => [
    for (var i = 0; i < 16; i++)
      _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();

  /// The folder name; the path itself for a root.
  static String _labelOf(String path) {
    final parts = path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty);
    return parts.isEmpty ? path : parts.last;
  }
}
