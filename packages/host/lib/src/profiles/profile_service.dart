import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:domain/domain.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../host_faults.dart';
import '../host_log.dart';
import '../host_options.dart';
import '../store/store.dart';
import 'shell_detector.dart';

/// The setting key that holds the default profile's id.
const String defaultProfileKey = 'default_profile';

/// Shell profiles (host-terminals design D6): detected built-ins held in
/// memory, user profiles and the default in the store (schema v3). The host
/// validates every save again with the `domain` rules.
class ProfileService {
  ProfileService({
    required this._store,
    required this._log,
    required this._faults,
    required HostOptions options,
  }) {
    _detected = _detect(options);
  }

  final Store _store;
  final HostLog _log;
  final HostFaults _faults;
  late final Future<List<ShellProfile>> _detected;

  /// Detects off the main isolate. Never fails: a detection that does not
  /// finish within its cap offers no built-in.
  Future<List<ShellProfile>> _detect(HostOptions options) async {
    final os = Platform.operatingSystem;
    final env = Platform.environment;
    final config = DetectionConfig(
      os: os,
      pathDirs: options.shellSearchPath ?? pathDirectories(env),
      wellKnownDirs: options.shellWellKnownDirs ?? wellKnownShellDirs(os, env),
    );
    final clock = Stopwatch()..start();
    try {
      final result = await detectShellsOffIsolate(config)
          .timeout(config.cap + const Duration(seconds: 1));
      if (result.skipped.isNotEmpty) {
        _log.event(
          'shell-detect-skipped',
          ids: {'shells': result.skipped.join(',')},
        );
      }
      _log.event(
        'shell-detect',
        duration: clock.elapsed,
        ids: {'found': result.found.length},
      );
      return [
        for (final s in result.found)
          ShellProfile(
            id: '$builtinProfilePrefix${s.name}',
            name: s.displayName,
            executable: s.path,
          ),
      ];
    } on Object catch (e) {
      _log.event(
        'shell-detect-failed',
        code: e is TimeoutException ? 'timeout' : 'error',
        duration: clock.elapsed,
      );
      return const [];
    }
  }

  RpcException _storeFailed(Object cause) =>
      RpcException(ErrorCode.storeError, 'profile store failed: $cause');

  T _guard<T>(T Function() body) {
    try {
      if (_faults.profileWriteFails) {
        throw RpcException(
          ErrorCode.storeError,
          'injected profile write failure',
        );
      }
      return body();
    } on SqliteException catch (e) {
      throw _storeFailed(e);
    }
  }

  RpcException _refused(
    String message,
    String detail, [
    Json data = const {},
  ]) => RpcException(ErrorCode.invalidParams, message, {
    'detail': detail,
    ...data,
  });

  String _now() => DateTime.now().toUtc().toIso8601String();

  List<ShellProfile> _userProfiles() => [
    for (final r in _store.select(
      'SELECT id, name, executable, args_json, cwd, env_json FROM '
      'shell_profile ORDER BY created_at, rowid',
    ))
      ShellProfile(
        id: r['id'] as String,
        name: r['name'] as String,
        executable: r['executable'] as String,
        args: decodeProfileArgs(r['args_json'] as String),
        cwd: r['cwd'] as String?,
        env: {
          for (final e in (jsonDecode(r['env_json'] as String) as Map).entries)
            e.key as String: e.value as String,
        },
      ),
  ];

  String? _storedDefault() {
    final rows = _store.select('SELECT value FROM setting WHERE key = ?', [
      defaultProfileKey,
    ]);
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  /// `profile/list`: built-ins in probe order, then the user's profiles. The
  /// first time a shell is detected and no default is stored, the first one
  /// becomes the stored default; a stored default naming a missing profile is
  /// reported unavailable and never replaced.
  Future<ProfileListResult> list() async {
    final builtins = await _detected;
    final List<ShellProfile> users;
    String? defaultId;
    try {
      users = _userProfiles();
      defaultId = _storedDefault();
      if (defaultId == null && builtins.isNotEmpty) {
        defaultId = builtins.first.id;
        try {
          _store.execute(
            'INSERT OR IGNORE INTO setting(key, value) VALUES (?, ?)',
            [defaultProfileKey, defaultId],
          );
        } on SqliteException {
          // Not stored; the same choice is made again on the next list.
        }
      }
    } on SqliteException catch (e) {
      throw _storeFailed(e);
    }
    final profiles = [...builtins, ...users];
    return ProfileListResult(
      profiles: profiles,
      defaultId: defaultId,
      defaultAvailable:
          defaultId != null && profiles.any((p) => p.id == defaultId),
    );
  }

  /// The profile with [id], built-in or user; null when there is none.
  Future<ShellProfile?> find(String id) async {
    final builtins = await _detected;
    for (final p in builtins) {
      if (p.id == id) return p;
    }
    try {
      for (final p in _userProfiles()) {
        if (p.id == id) return p;
      }
    } on SqliteException catch (e) {
      throw _storeFailed(e);
    }
    return null;
  }

  /// `profile/save`: creates or edits a user profile. Built-ins are refused.
  Future<ProfileSaveResult> save(ProfileSaveParams params) async {
    await _detected;
    final profile = params.profile;
    if (profile.isBuiltin) {
      throw _refused(
        'Built-in profiles cannot be edited; copy it as a new profile.',
        'builtin-profile',
      );
    }
    final definition = ProfileDefinition(
      id: profile.id,
      name: profile.name,
      executable: profile.executable,
      args: profile.args,
      cwd: profile.cwd,
      env: profile.env,
    );
    final issues = definition.validate();
    if (issues.isNotEmpty) {
      throw _refused(
        issues.map((i) => i.message).join(' '),
        'profile-invalid',
        {'field': issues.first.field},
      );
    }
    _guard(() {
      final count =
          _store.select('SELECT COUNT(*) AS n FROM shell_profile').single['n']
              as int;
      final exists = _store.select('SELECT 1 FROM shell_profile WHERE id = ?', [
        profile.id,
      ]).isNotEmpty;
      if (!exists && count >= maxUserProfiles) {
        throw _refused(
          'At most $maxUserProfiles profiles can be kept.',
          'profile-cap',
        );
      }
      final now = _now();
      _store.execute(
        'INSERT INTO shell_profile(id, name, executable, args_json, cwd, '
        'env_json, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(id) DO UPDATE SET name = excluded.name, '
        'executable = excluded.executable, args_json = excluded.args_json, '
        'cwd = excluded.cwd, env_json = excluded.env_json, '
        'updated_at = excluded.updated_at',
        [
          profile.id,
          profile.name,
          profile.executable,
          encodeProfileArgs(profile.args),
          profile.cwd,
          jsonEncode(profile.env),
          now,
          now,
        ],
      );
    });
    _log.event('profile-save', ids: {'profile': profile.id});
    return ProfileSaveResult(profile);
  }

  /// `profile/remove`: removes a user profile. The stored default is left as
  /// it is, so a removed default is reported unavailable.
  Future<void> remove(ProfileRemoveParams params) async {
    await _detected;
    if (isBuiltinProfileId(params.id)) {
      throw _refused('Built-in profiles cannot be removed.', 'builtin-profile');
    }
    _guard(() {
      final exists = _store.select('SELECT 1 FROM shell_profile WHERE id = ?', [
        params.id,
      ]).isNotEmpty;
      if (!exists) throw _unknown(params.id);
      _store.execute('DELETE FROM shell_profile WHERE id = ?', [params.id]);
    });
    _log.event('profile-remove', ids: {'profile': params.id});
  }

  RpcException _unknown(String id) =>
      _refused('There is no profile "$id".', 'unknown-profile');

  /// `profile/setDefault`: writes the `default_profile` setting, nothing else.
  Future<void> setDefault(ProfileSetDefaultParams params) async {
    final builtins = await _detected;
    _guard(() {
      final known =
          builtins.any((p) => p.id == params.id) ||
          _store.select('SELECT 1 FROM shell_profile WHERE id = ?', [
            params.id,
          ]).isNotEmpty;
      if (!known) throw _unknown(params.id);
      _store.execute(
        'INSERT INTO setting(key, value) VALUES (?, ?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        [defaultProfileKey, params.id],
      );
    });
    _log.event('profile-default', ids: {'profile': params.id});
  }
}
