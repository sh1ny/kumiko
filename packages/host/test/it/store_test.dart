import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:test/test.dart';

import 'support/harness.dart';

Future<RpcException> helloError(Directory profile) async {
  final failure = await Desktop.newLauncher(profile)
      .start()
      .then<Object?>((s) async {
        await s.quit();
        return null;
      }, onError: (Object e) => e);
  final e = failure! as HostStartException;
  expect(e.kind, HostStartFailure.helloRejected);
  return RpcException(e.reason!, e.message, e.data);
}

String dbPath(Directory profile) => joinPath(profile.path, 'kumiko.db');

void main() {
  setUpAll(buildTestHost);

  late Directory profile;
  setUp(() => profile = tempDir('store_'));
  tearDown(() => deleteTree(profile));

  test('lock holder opens store and completes hello', () async {
    final desktop = await Desktop.start(profile);
    addTearDown(desktop.dispose);

    expect(File(dbPath(profile)).existsSync(), isTrue);
    final view = LedgerView(profile);
    final instance = view.instances().single;
    expect(instance['id'].toString(), desktop.session.hello.instanceId);
    expect(instance['host_pid'], desktop.session.pid);
    expect(instance['desktop_pid'], pid);
    final db = sql.sqlite3.open(dbPath(profile), mode: sql.OpenMode.readOnly);
    addTearDown(db.close);
    expect(db.select('PRAGMA user_version').single.values.first, 2);
  });

  test('hello reports store-migration-failed', () async {
    // A table the first migration step wants to create already exists, with
    // another shape: the step fails and must roll back.
    sql.sqlite3.open(dbPath(profile))
      ..execute('CREATE TABLE host_instance(x INTEGER)')
      ..execute('INSERT INTO host_instance(x) VALUES (7)')
      ..close();
    final before = File(dbPath(profile)).readAsBytesSync();

    final error = await helloError(profile);

    expect(error.reason, ErrorCode.storeMigrationFailed);
    expect(error.data['path'], dbPath(profile));
    expect(error.data['fromVersion'], 0);
    expect(error.data['toVersion'], 1);
    expect(error.message, contains(dbPath(profile)));
    final check = sql.sqlite3.open(
      dbPath(profile),
      mode: sql.OpenMode.readOnly,
    );
    addTearDown(check.close);
    expect(check.select('PRAGMA user_version').single.values.first, 0);
    expect(check.select('SELECT x FROM host_instance').single['x'], 7);
    expect(File(dbPath(profile)).readAsBytesSync().length, before.length);
  });

  test('newer store refused unchanged with both versions', () async {
    sql.sqlite3.open(dbPath(profile))
      ..execute('PRAGMA user_version = 99')
      ..close();
    final before = File(dbPath(profile)).readAsBytesSync();

    final error = await helloError(profile);

    expect(error.reason, ErrorCode.storeNewer);
    expect(error.data['storeVersion'], 99);
    expect(error.data['supportedVersion'], 2);
    expect(error.data['path'], dbPath(profile));
    expect(error.message, allOf(contains('99'), contains('2')));
    expect(File(dbPath(profile)).readAsBytesSync(), before);
  });

  test(
    'garbage store file left in place, store-unreadable with path',
    () async {
      final garbage = utf8.encode('this is not a database ' * 50);
      File(dbPath(profile)).writeAsBytesSync(garbage);

      final error = await helloError(profile);

      expect(error.reason, ErrorCode.storeUnreadable);
      expect(error.data['path'], dbPath(profile));
      expect(error.message, contains(dbPath(profile)));
      expect(File(dbPath(profile)).readAsBytesSync(), garbage);
    },
  );
}
