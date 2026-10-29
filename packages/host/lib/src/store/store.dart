import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../profile_lock.dart';
import 'store_error.dart';

/// One forward migration step. It runs inside its own transaction, together
/// with the `user_version` bump.
typedef MigrationStep = void Function(Database db);

/// Schema v1 (design D4), v2 (design D3) and v3 (host-terminals design D6).
final List<MigrationStep> schemaMigrations = <MigrationStep>[
  (db) {
    db.execute('''
CREATE TABLE host_instance(
  id INTEGER PRIMARY KEY,
  host_pid INTEGER NOT NULL,
  host_started_at TEXT NOT NULL,
  desktop_pid INTEGER,
  desktop_started_at TEXT,
  os TEXT NOT NULL,
  opened_at TEXT NOT NULL,
  closed_cleanly INTEGER NOT NULL DEFAULT 0
)''');
    db.execute('''
CREATE TABLE unit(
  containment_id TEXT PRIMARY KEY,
  host_instance_id INTEGER NOT NULL REFERENCES host_instance(id),
  kind TEXT NOT NULL,
  target_path TEXT NOT NULL,
  target_identity TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('pending','running','unresolved')),
  pid INTEGER,
  process_started_at TEXT,
  unresolved_reason TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
)''');
  },
  // v2 (design D3): workspaces and the personal working set. The v1 ledger
  // tables are untouched.
  (db) {
    db.execute('''
CREATE TABLE workspace(
  id TEXT PRIMARY KEY,
  path TEXT NOT NULL UNIQUE,
  identity TEXT NOT NULL,
  label TEXT NOT NULL,
  added_at TEXT NOT NULL
)''');
    db.execute('''
CREATE TABLE working_set(
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('personal','project')),
  layout TEXT,
  layout_format INTEGER,
  revision INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
)''');
    db.execute(
      "INSERT INTO working_set(id, kind, layout, layout_format, revision,"
      " updated_at) VALUES ('personal', 'personal', NULL, NULL, 0,"
      " strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))",
    );
  },
  // v3 (host-terminals D6): user shell profiles and the settings table that
  // holds `default_profile`. Detected built-ins are never stored. The ledger
  // and layout tables are untouched.
  (db) {
    db.execute('''
CREATE TABLE shell_profile(
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  executable TEXT NOT NULL,
  args_json TEXT NOT NULL,
  cwd TEXT,
  env_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
)''');
    db.execute('''
CREATE TABLE setting(
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
)''');
  },
];

int get currentSchemaVersion => schemaMigrations.length;

/// The host's local SQLite store (ADR 0003, ADR 0008).
class Store {
  Store._(this._db);

  final Database _db;

  /// Opens `<profile>/kumiko.db`, migrating it forward. Requires a held
  /// [lock]; an existing store is never reset, truncated or downgraded.
  static Store open(
    Directory profile,
    ProfileLock lock, {
    List<MigrationStep>? migrations,
  }) {
    if (!lock.isHeld || lock.profile.path != profile.path) {
      throw ArgumentError('the profile lock must be held for this profile');
    }
    final steps = migrations ?? schemaMigrations;
    final path = '${profile.path}${Platform.pathSeparator}kumiko.db';

    // Check an existing file read-only first: nothing here writes to it.
    if (File(path).existsSync()) {
      final version = _readVersion(path);
      if (version > steps.length) {
        throw StoreNewer(storeVersion: version, supportedVersion: steps.length);
      }
    }

    final Database db;
    try {
      db = sqlite3.open(path);
    } on SqliteException catch (e) {
      throw StoreUnreadable(path: path, cause: e);
    }
    try {
      db.execute('PRAGMA journal_mode = WAL');
      db.execute('PRAGMA synchronous = FULL');
      _migrate(db, steps);
    } on StoreError {
      db.close();
      rethrow;
    } on SqliteException catch (e) {
      db.close();
      throw StoreUnreadable(path: path, cause: e);
    } catch (_) {
      db.close();
      rethrow;
    }
    return Store._(db);
  }

  static int _readVersion(String path) {
    Database? db;
    try {
      db = sqlite3.open(path, mode: OpenMode.readOnly);
      return db.select('PRAGMA user_version').single.values.first! as int;
    } on SqliteException catch (e) {
      throw StoreUnreadable(path: path, cause: e);
    } finally {
      db?.close();
    }
  }

  static void _migrate(Database db, List<MigrationStep> steps) {
    var version = db.select('PRAGMA user_version').single.values.first! as int;
    while (version < steps.length) {
      final to = version + 1;
      db.execute('BEGIN IMMEDIATE');
      try {
        steps[version](db);
        db.execute('PRAGMA user_version = $to');
        db.execute('COMMIT');
      } catch (e) {
        try {
          db.execute('ROLLBACK');
        } on SqliteException {
          // Transaction already gone; nothing to roll back.
        }
        throw StoreMigrationFailed(
          fromVersion: version,
          toVersion: to,
          cause: e,
        );
      }
      version = to;
    }
  }

  int get userVersion =>
      _db.select('PRAGMA user_version').single.values.first! as int;

  /// Value of a PRAGMA, for diagnostics and tests.
  Object? pragma(String name) => _db.select('PRAGMA $name').single.values.first;

  ResultSet select(String sql, [List<Object?> parameters = const []]) =>
      _db.select(sql, parameters);

  void execute(String sql, [List<Object?> parameters = const []]) =>
      _db.execute(sql, parameters);

  void close() => _db.close();
}
