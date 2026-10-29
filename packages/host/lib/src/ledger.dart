import 'package:host_protocol/host_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import 'store/store.dart';

/// One `unit` row (design D4).
class UnitRow {
  const UnitRow({
    required this.containmentId,
    required this.hostInstanceId,
    required this.kind,
    required this.targetPath,
    required this.targetIdentity,
    required this.state,
    required this.createdAt,
    this.pid,
    this.startedAt,
    this.reason,
  });

  factory UnitRow.fromRow(Row r) => UnitRow(
    containmentId: r['containment_id'] as String,
    hostInstanceId: r['host_instance_id'] as int,
    kind: r['kind'] as String,
    targetPath: r['target_path'] as String,
    targetIdentity: r['target_identity'] as String,
    state: r['state'] as String,
    createdAt: DateTime.parse(r['created_at'] as String),
    pid: r['pid'] as int?,
    startedAt: int.tryParse((r['process_started_at'] as String?) ?? ''),
    reason: r['unresolved_reason'] as String?,
  );

  final String containmentId;
  final int hostInstanceId;
  final String kind;
  final String targetPath;
  final String targetIdentity;

  /// `pending`, `running` or `unresolved`.
  final String state;
  final DateTime createdAt;
  final int? pid;

  /// The OS start time recorded with [pid].
  final int? startedAt;
  final String? reason;
}

/// A `host_instance` row.
class InstanceRow {
  const InstanceRow(this.id, this.desktopPid, this.desktopStartedAt);
  final int id;
  final int? desktopPid;
  final int? desktopStartedAt;
}

/// The process ledger over the store: `host_instance` and `unit` rows
/// (design D4). It is the only code that writes them. A store failure is
/// reported as a `store-error` [RpcException].
class Ledger {
  Ledger(this._store);

  final Store _store;

  /// Changes whenever the set of unresolved units does, so a cleanup page
  /// read across a change can be flagged stale (design D5).
  int revision = 1;

  late final int instanceId;

  T _guard<T>(T Function() body) {
    try {
      return body();
    } on SqliteException catch (e) {
      throw RpcException(ErrorCode.storeError, 'ledger write failed: $e');
    }
  }

  static String _now() => DateTime.now().toUtc().toIso8601String();

  /// Records this host run and makes it the current instance.
  int openInstance({
    required int hostPid,
    required int? hostStartedAt,
    required int? desktopPid,
    required int? desktopStartedAt,
    required String os,
  }) => _guard(() {
    _store.execute(
      'INSERT INTO host_instance(host_pid, host_started_at, desktop_pid, '
      'desktop_started_at, os, opened_at, closed_cleanly) '
      'VALUES (?, ?, ?, ?, ?, ?, 0)',
      [
        hostPid,
        '${hostStartedAt ?? 0}',
        desktopPid,
        desktopStartedAt?.toString(),
        os,
        _now(),
      ],
    );
    instanceId =
        _store.select('SELECT last_insert_rowid() AS id').single['id'] as int;
    return instanceId;
  });

  void closeInstance({required bool cleanly}) => _guard(
    () => _store.execute(
      'UPDATE host_instance SET closed_cleanly = ? WHERE id = ?',
      [cleanly ? 1 : 0, instanceId],
    ),
  );

  InstanceRow? instance(int id) => _guard(() {
    final rows = _store.select(
      'SELECT id, desktop_pid, desktop_started_at FROM host_instance '
      'WHERE id = ?',
      [id],
    );
    if (rows.isEmpty) return null;
    final r = rows.single;
    return InstanceRow(
      r['id'] as int,
      r['desktop_pid'] as int?,
      int.tryParse((r['desktop_started_at'] as String?) ?? ''),
    );
  });

  // --- units -------------------------------------------------------------

  /// The pending entry, committed (`synchronous=FULL`) before the spawn.
  void insertPending({
    required String containmentId,
    required String kind,
    required String targetPath,
    required String targetIdentity,
  }) => _guard(() {
    final now = _now();
    _store.execute(
      'INSERT INTO unit(containment_id, host_instance_id, kind, target_path, '
      "target_identity, state, created_at, updated_at) VALUES (?, ?, ?, ?, ?, 'pending', ?, ?)",
      [containmentId, instanceId, kind, targetPath, targetIdentity, now, now],
    );
  });

  void markRunning(String containmentId, int pid, int startedAt) => _guard(() {
    _store.execute(
      "UPDATE unit SET state = 'running', pid = ?, process_started_at = ?, "
      'updated_at = ? WHERE containment_id = ?',
      [pid, '$startedAt', _now(), containmentId],
    );
  });

  /// Runs [body] in one transaction: its writes are committed together, or
  /// none of them is.
  T inTransaction<T>(T Function() body) {
    _guard(() => _store.execute('BEGIN IMMEDIATE'));
    try {
      final result = body();
      _guard(() => _store.execute('COMMIT'));
      return result;
    } on Object {
      try {
        _store.execute('ROLLBACK');
      } on Object {
        // Already rolled back by SQLite.
      }
      rethrow;
    }
  }

  void markUnresolved(String containmentId, String reason) => _guard(() {
    _store.execute(
      "UPDATE unit SET state = 'unresolved', unresolved_reason = ?, "
      'updated_at = ? WHERE containment_id = ?',
      [clampUtf8(reason, maxReasonBytes), _now(), containmentId],
    );
    revision++;
  });

  /// Deletes a unit's row (cleaned, confirmed, or never spawned).
  void delete(String containmentId) => _guard(() {
    final was = _store.select(
      'SELECT state FROM unit WHERE containment_id = ?',
      [containmentId],
    );
    _store.execute('DELETE FROM unit WHERE containment_id = ?', [
      containmentId,
    ]);
    if (was.isNotEmpty && was.single['state'] == 'unresolved') revision++;
  });

  UnitRow? unit(String containmentId) => _guard(() {
    final rows = _store.select('SELECT * FROM unit WHERE containment_id = ?', [
      containmentId,
    ]);
    return rows.isEmpty ? null : UnitRow.fromRow(rows.single);
  });

  /// Every row left by earlier host instances, which the reconciliation at
  /// startup handles: pending, running and unresolved alike, so a unit an
  /// earlier host could not end is tried again before any launch.
  List<UnitRow> earlierUnits() => _guard(
    () => [
      for (final r in _store.select(
        'SELECT * FROM unit WHERE host_instance_id != ? '
        'ORDER BY created_at, containment_id',
        [instanceId],
      ))
        UnitRow.fromRow(r),
    ],
  );

  /// Every unresolved unit of the workspace with identity [identity].
  List<UnitRow> unresolvedIn(String identity) => _guard(
    () => [
      for (final r in _store.select(
        "SELECT * FROM unit WHERE state = 'unresolved' AND target_identity = ? "
        'ORDER BY containment_id',
        [identity],
      ))
        UnitRow.fromRow(r),
    ],
  );

  /// True while an unresolved unit targets this directory: the same file
  /// identity, or the same resolved path byte for byte (design D4).
  bool isUnresolved({required String identity, required String path}) => _guard(
    () => _store.select(
      "SELECT 1 FROM unit WHERE state = 'unresolved' AND "
      '(target_identity = ? OR target_path = ?) LIMIT 1',
      [identity, path],
    ).isNotEmpty,
  );

  /// Deletes `host_instance` rows no unit references, except the current one.
  void deleteUnreferencedInstances() => _guard(
    () => _store.execute(
      'DELETE FROM host_instance WHERE id != ? AND id NOT IN '
      '(SELECT host_instance_id FROM unit)',
      [instanceId],
    ),
  );

  // --- cleanup listings ----------------------------------------------------

  CleanupState state({required bool reconciling}) => _guard(() {
    final r = _store
        .select(
          'SELECT COUNT(DISTINCT target_identity) AS w, COUNT(*) AS u '
          "FROM unit WHERE state = 'unresolved'",
        )
        .single;
    return CleanupState(
      reconciling: reconciling,
      revision: revision,
      unresolvedWorkspaces: r['w'] as int,
      unresolvedUnits: r['u'] as int,
    );
  });

  /// Up to [limit] + 1 unresolved workspaces after [afterIdentity], ordered by
  /// identity: identity, a path and the unit count of each.
  List<({String identity, String path, int count})> workspaces({
    required String? afterIdentity,
    required int limit,
  }) => _guard(
    () => [
      for (final r in _store.select(
        'SELECT target_identity, MIN(target_path) AS path, COUNT(*) AS n '
        "FROM unit WHERE state = 'unresolved' AND target_identity > ? "
        'GROUP BY target_identity ORDER BY target_identity LIMIT ?',
        [afterIdentity ?? '', limit + 1],
      ))
        (
          identity: r['target_identity'] as String,
          path: r['path'] as String,
          count: r['n'] as int,
        ),
    ],
  );

  /// Up to [limit] + 1 unresolved units of a workspace after
  /// [afterContainmentId], ordered by containment id.
  List<UnitRow> unitsPage({
    required String identity,
    required String? afterContainmentId,
    required int limit,
  }) => _guard(
    () => [
      for (final r in _store.select(
        "SELECT * FROM unit WHERE state = 'unresolved' AND target_identity = ? "
        'AND containment_id > ? ORDER BY containment_id LIMIT ?',
        [identity, afterContainmentId ?? '', limit + 1],
      ))
        UnitRow.fromRow(r),
    ],
  );
}
