import 'dart:io';

import 'package:host/src/profile_lock.dart';
import 'package:host/src/store/store.dart';
import 'package:host/src/store/store_error.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory profile;
  late ProfileLock lock;

  setUp(() async {
    profile = Directory.systemTemp.createTempSync('kumiko_store_');
    final acquired = await ProfileLock.tryAcquire(profile);
    lock = acquired!;
  });

  tearDown(() async {
    await lock.release();
    profile.deleteSync(recursive: true);
  });

  File dbFile() => File('${profile.path}${Platform.pathSeparator}kumiko.db');

  Set<String> names() => profile
      .listSync()
      .map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last)
      .toSet();

  test('fresh store created at current version', () {
    final store = Store.open(profile, lock);
    addTearDown(store.close);

    expect(store.userVersion, currentSchemaVersion);
    expect(currentSchemaVersion, 2);
    expect(store.pragma('journal_mode'), 'wal');
    expect(store.pragma('synchronous'), 2); // FULL
    final tables = store
        .select("SELECT name FROM sqlite_master WHERE type='table'")
        .map((r) => r['name'] as String)
        .toSet();
    expect(
      tables,
      containsAll(<String>['host_instance', 'unit', 'workspace', 'working_set']),
    );
    expect(dbFile().existsSync(), isTrue);
  });

  test('unit state CHECK rejects unknown states', () {
    final store = Store.open(profile, lock);
    addTearDown(store.close);
    store.execute(
      "INSERT INTO host_instance(id, host_pid, host_started_at, os, opened_at,"
      " closed_cleanly) VALUES (1, 1, 'a', 'x', 'a', 0)",
    );
    expect(
      () => store.execute(
        'INSERT INTO unit(containment_id, host_instance_id, kind, target_path,'
        " target_identity, state, created_at, updated_at)"
        " VALUES ('c', 1, 'k', 'p', 'i', 'bogus', 'a', 'a')",
      ),
      throwsA(isA<SqliteException>()),
    );
  });

  test('reopening an up-to-date store keeps its contents', () {
    var store = Store.open(profile, lock);
    store.execute(
      "INSERT INTO host_instance(id, host_pid, host_started_at, os, opened_at,"
      " closed_cleanly) VALUES (7, 1, 'a', 'x', 'a', 0)",
    );
    store.close();
    store = Store.open(profile, lock);
    addTearDown(store.close);
    expect(store.select('SELECT id FROM host_instance').single['id'], 7);
  });

  test('failing step rolls back version and contents', () {
    final v1 = <MigrationStep>[schemaMigrations.first];
    Store.open(profile, lock, migrations: v1).close();
    final before = _snapshot(dbFile());

    final steps = <MigrationStep>[
      ...v1,
      (db) {
        db.execute('CREATE TABLE half_done(x)');
        db.execute(
          "INSERT INTO host_instance(id, host_pid, host_started_at,"
          " os, opened_at, closed_cleanly) VALUES (9, 1, 'a', 'x', 'a', 0)",
        );
        throw StateError('boom');
      },
    ];

    expect(
      () => Store.open(profile, lock, migrations: steps),
      throwsA(
        isA<StoreMigrationFailed>()
            .having((e) => e.code, 'code', 'store-migration-failed')
            .having((e) => e.fromVersion, 'from', 1)
            .having((e) => e.toVersion, 'to', 2)
            .having((e) => e.cause, 'cause', isA<StateError>()),
      ),
    );

    final store = Store.open(profile, lock, migrations: v1);
    addTearDown(store.close);
    expect(store.userVersion, 1);
    expect(_snapshot(dbFile()), before);
    expect(
      store.select("SELECT name FROM sqlite_master WHERE name='half_done'"),
      isEmpty,
    );
  });

  test('failure in a later step keeps earlier completed steps', () {
    final steps = <MigrationStep>[
      ...schemaMigrations,
      (db) => db.execute('CREATE TABLE extra(x)'),
      (db) => throw StateError('boom'),
    ];
    expect(
      () => Store.open(profile, lock, migrations: steps),
      throwsA(
        isA<StoreMigrationFailed>()
            .having((e) => e.fromVersion, 'from', 3)
            .having((e) => e.toVersion, 'to', 4),
      ),
    );
    final db = sqlite3.open(dbFile().path);
    addTearDown(db.close);
    expect(db.select('PRAGMA user_version').single.values.first, 3);
  });

  test('newer user_version is refused unchanged', () {
    final db = sqlite3.open(dbFile().path);
    db.execute('CREATE TABLE t(x)');
    db.execute('PRAGMA user_version = 5');
    db.close();
    final before = dbFile().readAsBytesSync();
    final namesBefore = names();

    expect(
      () => Store.open(profile, lock),
      throwsA(
        isA<StoreNewer>()
            .having((e) => e.code, 'code', 'store-newer')
            .having((e) => e.storeVersion, 'store', 5)
            .having((e) => e.supportedVersion, 'supported', 2),
      ),
    );

    expect(dbFile().readAsBytesSync(), before);
    expect(names(), namesBefore);
  });

  test('garbage file is left in place and reported with its path', () {
    final garbage = List<int>.generate(4096, (i) => (i * 31 + 7) & 0xff);
    dbFile().writeAsBytesSync(garbage);
    final namesBefore = names();

    expect(
      () => Store.open(profile, lock),
      throwsA(
        isA<StoreUnreadable>()
            .having((e) => e.code, 'code', 'store-unreadable')
            .having((e) => e.path, 'path', dbFile().path),
      ),
    );

    expect(dbFile().readAsBytesSync(), garbage);
    expect(names(), namesBefore);
  });

  test('v1 store with ledger rows migrates to v2 keeping every row', () {
    Store.open(
        profile,
        lock,
        migrations: <MigrationStep>[schemaMigrations.first],
      )
      ..execute(
        "INSERT INTO host_instance(id, host_pid, host_started_at, os,"
        " opened_at, closed_cleanly) VALUES (3, 1, 'a', 'x', 'a', 0)",
      )
      ..execute(
        'INSERT INTO unit(containment_id, host_instance_id, kind, target_path,'
        ' target_identity, state, created_at, updated_at)'
        " VALUES ('c1', 3, 'k', 'p', 'i', 'unresolved', 'a', 'a'),"
        " ('c2', 3, 'k', 'p', 'i', 'running', 'a', 'a')",
      )
      ..close();

    final store = Store.open(profile, lock);
    addTearDown(store.close);
    expect(store.userVersion, 2);
    expect(
      store
          .select('SELECT containment_id FROM unit ORDER BY 1')
          .map((r) => r['containment_id']),
      ['c1', 'c2'],
    );
    expect(store.select('SELECT id FROM host_instance').single['id'], 3);

    final ws = store.select('SELECT * FROM working_set').single;
    expect(ws['id'], 'personal');
    expect(ws['kind'], 'personal');
    expect(ws['layout'], isNull);
    expect(ws['layout_format'], isNull);
    expect(ws['revision'], 0);
    expect(store.select('SELECT * FROM workspace'), isEmpty);
    expect(
      store.select('PRAGMA table_info(workspace)').map((r) => r['name']),
      ['id', 'path', 'identity', 'label', 'added_at'],
    );
  });

  test('workspace path is unique and working_set kind is checked', () {
    final store = Store.open(profile, lock);
    addTearDown(store.close);
    store.execute("INSERT INTO workspace VALUES ('w1', '/p', 'i', 'l', 'a')");
    expect(
      () => store.execute(
        "INSERT INTO workspace VALUES ('w2', '/p', 'i2', 'l', 'a')",
      ),
      throwsA(isA<SqliteException>()),
    );
    expect(
      () => store.execute(
        'INSERT INTO working_set(id, kind, updated_at)'
        " VALUES ('x', 'bogus', 'a')",
      ),
      throwsA(isA<SqliteException>()),
    );
  });
}

List<int> _snapshot(File f) {
  // Contents-level snapshot: checkpoint-independent via logical dump.
  final db = sqlite3.open(f.path, mode: OpenMode.readOnly);
  try {
    final rows = db.select(
      "SELECT type, name, sql FROM sqlite_master ORDER BY name",
    );
    final v = db.select('PRAGMA user_version').single.values.first;
    return '$v|${rows.map((r) => r.values.join(",")).join(";")}'.codeUnits;
  } finally {
    db.close();
  }
}
