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
    expect(currentSchemaVersion, 1);
    expect(store.pragma('journal_mode'), 'wal');
    expect(store.pragma('synchronous'), 2); // FULL
    final tables = store
        .select("SELECT name FROM sqlite_master WHERE type='table'")
        .map((r) => r['name'] as String)
        .toSet();
    expect(tables, containsAll(<String>['host_instance', 'unit']));
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
    Store.open(profile, lock).close();
    final before = _snapshot(dbFile());

    final steps = <MigrationStep>[
      ...schemaMigrations,
      (db) {
        db.execute('CREATE TABLE half_done(x)');
        db.execute("INSERT INTO host_instance(id, host_pid, host_started_at,"
            " os, opened_at, closed_cleanly) VALUES (9, 1, 'a', 'x', 'a', 0)");
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

    final store = Store.open(profile, lock);
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
      throwsA(isA<StoreMigrationFailed>()
          .having((e) => e.fromVersion, 'from', 2)
          .having((e) => e.toVersion, 'to', 3)),
    );
    final db = sqlite3.open(dbFile().path);
    addTearDown(db.close);
    expect(db.select('PRAGMA user_version').single.values.first, 2);
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
            .having((e) => e.supportedVersion, 'supported', 1),
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
