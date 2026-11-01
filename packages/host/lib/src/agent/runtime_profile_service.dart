import 'dart:convert';

import 'package:domain/domain.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../host_faults.dart';
import '../host_log.dart';
import '../host_options.dart';
import '../store/store.dart';
import 'adapter_detector.dart';

const String defaultRuntimeKey = 'default_runtime';

/// Runtime profile lifecycle: detected profiles are read-only and memory-only;
/// user argv profiles and the selected default live in schema v5. No method
/// starts an adapter, changes a session record, or modifies a process env.
class RuntimeProfileService {
  RuntimeProfileService({
    required this._store,
    required this._log,
    required this._faults,
    required HostOptions options,
  }) {
    _detected = AdapterDetector(
      AdapterDetectionConfig(
        pathDirs: options.runtimeSearchPath,
        wellKnownDirs: options.runtimeWellKnownDirs,
      ),
    ).detect();
  }

  final Store _store;
  final HostLog _log;
  final HostFaults _faults;
  late final Future<AdapterDetectionResult> _detected;

  RpcException _storeFailed(Object cause) => RpcException(
    ErrorCode.storeError,
    'runtime profile store failed: $cause',
  );

  T _read<T>(T Function() body) {
    try {
      return body();
    } on SqliteException catch (error) {
      throw _storeFailed(error);
    }
  }

  T _write<T>(T Function() body) => _read(() {
    if (_faults.profileWriteFails) {
      throw RpcException(
        ErrorCode.storeError,
        'injected profile write failure',
      );
    }
    _store.execute('BEGIN IMMEDIATE');
    try {
      final result = body();
      _store.execute('COMMIT');
      return result;
    } catch (_) {
      try {
        _store.execute('ROLLBACK');
      } on SqliteException {
        /* Already rolled back. */
      }
      rethrow;
    }
  });

  List<RuntimeProfile> _users() => [
    for (final row in _store.select(
      'SELECT id, name, runtime_kind, executable, args_json, env_json FROM runtime_profile ORDER BY created_at, rowid',
    ))
      RuntimeProfile(
        id: row['id'] as String,
        name: row['name'] as String,
        runtimeKind: row['runtime_kind'] as String,
        executable: row['executable'] as String,
        args: decodeProfileArgs(row['args_json'] as String),
        env: {
          for (final e
              in (jsonDecode(row['env_json'] as String) as Map).entries)
            e.key as String: e.value as String,
        },
      ),
  ];

  String? _defaultId() {
    final rows = _store.select('SELECT value FROM setting WHERE key = ?', [
      defaultRuntimeKey,
    ]);
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  void _setDefault(String id) => _store.execute(
    'INSERT INTO setting(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
    [defaultRuntimeKey, id],
  );

  /// Built-ins first, then users in creation order. A stored missing default
  /// remains selected but unavailable, with a reason; it is never replaced.
  /// When nothing has selected a default yet, choose the first available one.
  Future<RuntimeListResult> list() async {
    final detection = await _detected;
    final profiles = _read(
      () => [if (detection.profile != null) detection.profile!, ..._users()],
    );
    var id = _read(_defaultId);
    if (id == null && profiles.isNotEmpty) {
      id = _write(() {
        final existing = _defaultId();
        if (existing != null) return existing;
        _setDefault(profiles.first.id);
        return profiles.first.id;
      });
    }
    final available = id != null && profiles.any((p) => p.id == id);
    return RuntimeListResult(
      profiles: profiles,
      defaultId: id,
      defaultAvailable: available,
      defaultReason: available
          ? null
          : id == null
          ? detection.reason ?? adapterInstallReason
          : 'Runtime profile "$id" is unavailable. ${id.startsWith(builtinProfilePrefix) ? detection.reason ?? adapterInstallReason : 'Choose or add a runtime profile.'}',
    );
  }

  /// The exact stored/detected profile, or null. For default selection use
  /// [list] and require `defaultAvailable`; never substitute another profile.
  Future<RuntimeProfile?> find(String id) async {
    final detection = await _detected;
    if (detection.profile?.id == id) return detection.profile;
    return _read(() {
      for (final profile in _users()) {
        if (profile.id == id) return profile;
      }
      return null;
    });
  }

  /// Creates or edits a user profile after pure domain validation. The first
  /// save also selects a default atomically if none was ever selected.
  Future<EmptyResult> save(RuntimeSaveParams params) async {
    final profile = params.profile;
    if (profile.isBuiltin) throw _readOnly();
    final issues = RuntimeProfileDefinition(
      id: profile.id,
      name: profile.name,
      runtimeKind: profile.runtimeKind,
      executable: profile.executable,
      args: profile.args,
      env: profile.env,
    ).validate();
    if (issues.isNotEmpty) {
      throw RpcException(
        ErrorCode.invalidProfile,
        issues.map((i) => i.message).join(' '),
        {'field': issues.first.field},
      );
    }
    final detection = await _detected;
    _write(() {
      final exists = _store.select(
        'SELECT 1 FROM runtime_profile WHERE id = ?',
        [profile.id],
      ).isNotEmpty;
      if (!exists &&
          (_store
                      .select('SELECT COUNT(*) AS n FROM runtime_profile')
                      .single['n']
                  as int) >=
              maxUserProfiles) {
        throw RpcException(
          ErrorCode.invalidProfile,
          'At most $maxUserProfiles runtime profiles can be kept.',
          {'detail': 'profile-cap'},
        );
      }
      final now = DateTime.now().toUtc().toIso8601String();
      _store.execute(
        'INSERT INTO runtime_profile(id, name, runtime_kind, executable, args_json, env_json, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name, runtime_kind = excluded.runtime_kind, '
        'executable = excluded.executable, args_json = excluded.args_json, env_json = excluded.env_json, updated_at = excluded.updated_at',
        [
          profile.id,
          profile.name,
          profile.runtimeKind,
          profile.executable,
          encodeProfileArgs(profile.args),
          jsonEncode(profile.env),
          now,
          now,
        ],
      );
      if (_defaultId() == null) {
        _setDefault(detection.profile?.id ?? _users().first.id);
      }
    });
    _log.event('runtime-save', ids: {'profile': profile.id});
    return const EmptyResult();
  }

  /// Deletes only the user profile. Even its selected default and all native
  /// session records are intentionally left unchanged.
  Future<EmptyResult> remove(RuntimeRemoveParams params) async {
    if (isBuiltinProfileId(params.id)) throw _readOnly();
    await _detected;
    _write(() {
      if (!_exists(params.id)) throw _unknown(params.id);
      _store.execute('DELETE FROM runtime_profile WHERE id = ?', [params.id]);
    });
    _log.event('runtime-remove', ids: {'profile': params.id});
    return const EmptyResult();
  }

  Future<EmptyResult> setDefault(RuntimeSetDefaultParams params) async {
    final detection = await _detected;
    _write(() {
      if (detection.profile?.id != params.id && !_exists(params.id)) {
        throw _unknown(params.id);
      }
      _setDefault(params.id);
    });
    _log.event('runtime-default', ids: {'profile': params.id});
    return const EmptyResult();
  }

  bool _exists(String id) => _store.select(
    'SELECT 1 FROM runtime_profile WHERE id = ?',
    [id],
  ).isNotEmpty;
  RpcException _unknown(String id) => RpcException(
    ErrorCode.invalidProfile,
    'There is no runtime profile "$id".',
  );
  RpcException _readOnly() => RpcException(
    ErrorCode.readOnlyProfile,
    'Built-in runtime profiles are read-only; copy it with a new id to edit it.',
  );
}
