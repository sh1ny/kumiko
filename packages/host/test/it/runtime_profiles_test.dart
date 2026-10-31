import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

RuntimeProfile user(
  String id, {
  String executable = 'node',
  List<String> args = const [],
  Map<String, String> env = const {},
  String kind = 'claude-code',
}) => RuntimeProfile(
  id: id,
  name: 'User $id',
  runtimeKind: kind,
  executable: executable,
  args: args,
  env: env,
);

void main() {
  setUpAll(buildTestHost);
  late Directory profile;
  late Directory bin;
  setUp(() {
    profile = tempDir('runtime_profile_');
    bin = tempDir('runtime_bin_');
  });
  tearDown(() async {
    await deleteTree(bin);
    await deleteTree(profile);
  });
  Future<Desktop> start({bool agent = true}) async {
    final d = await Desktop.start(
      profile,
      capabilities: {...testCapabilities, if (agent) Capability.agent},
      environment: {
        'KUMIKO_TEST_RUNTIME_PATH': bin.path,
        'KUMIKO_TEST_SHELL_PATH': '',
      },
    );
    addTearDown(d.dispose);
    await d.waitState();
    return d;
  }

  Future<void> restart(Desktop d) async {
    await d.session.quit();
    await d.restart();
    await d.waitState();
  }

  Future<RuntimeListResult> list(Desktop d) async => RuntimeListResult.fromJson(
    (await d.connection.request(Method.runtimeList, const EmptyParams()))
        as Json,
  );
  Future<void> save(Desktop d, RuntimeProfile p) async {
    await d.connection.request(Method.runtimeSave, RuntimeSaveParams(p));
  }

  Future<void> remove(Desktop d, String id) async {
    await d.connection.request(Method.runtimeRemove, RuntimeRemoveParams(id));
  }

  Future<void> setDefault(Desktop d, String id) async {
    await d.connection.request(
      Method.runtimeSetDefault,
      RuntimeSetDefaultParams(id),
    );
  }

  List<Map<String, Object?>> rows(String table) {
    final db = sqlite3.open(
      joinPath(profile.path, 'kumiko.db'),
      mode: OpenMode.readOnly,
    );
    try {
      return [
        for (final row in db.select('SELECT * FROM $table ORDER BY rowid'))
          Map.of(row),
      ];
    } finally {
      db.close();
    }
  }

  Matcher code(String reason) =>
      throwsA(isA<RpcException>().having((e) => e.reason, 'reason', reason));
  void install() {
    final node = File(
      joinPath(bin.path, Platform.isWindows ? 'node.exe' : 'node'),
    )..writeAsStringSync('');
    final script = File(
      '${bin.path}/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js',
    )..createSync(recursive: true);
    if (Platform.isWindows) {
      File(joinPath(bin.path, 'claude-agent-acp.cmd')).writeAsStringSync('');
    } else {
      chmodPath(node.path, 0x1c0);
      Link(joinPath(bin.path, 'claude-agent-acp')).createSync(script.path);
    }
  }

  test(
    'runtime/list with no adapter returns no built-in and the reason',
    () async {
      final d = await start();
      final result = await list(d);
      expect(result.profiles, isEmpty);
      expect(result.defaultAvailable, isFalse);
      expect(result.defaultId, isNull);
      expect(
        result.defaultReason,
        allOf(
          contains('@agentclientprotocol/claude-agent-acp'),
          contains('22'),
        ),
      );
    },
  );
  test('saved profile survives a host restart unchanged', () async {
    final d = await start();
    final p = user(
      'u',
      args: ['', '--setting="a b"'],
      env: {'ANTHROPIC_LOG': 'debug'},
    );
    await save(d, p);
    expect((await list(d)).defaultId, 'u');
    await restart(d);
    expect((await list(d)).profiles.single.toJson(), p.toJson());
    expect(
      rows('runtime_profile').single['args_json'],
      '["","--setting=\\"a b\\""]',
    );
    final created = rows('runtime_profile').single['created_at'];
    await save(d, user('u', executable: '/absolute/node', args: ['edited']));
    expect(rows('runtime_profile').single['created_at'], created);
    await restart(d);
    expect((await list(d)).profiles.single.args, ['edited']);
    await remove(d, 'u');
    expect((await list(d)).profiles, isEmpty);
  });
  test('save refused invalid-profile leaves the store unchanged', () async {
    final d = await start();
    await save(d, user('kept'));
    final before = rows('runtime_profile');
    for (final p in [
      user('bad', executable: ''),
      user('bad', env: {'A=B': 'x'}),
      user('bad', env: {'': 'x'}),
      user('bad', kind: ''),
    ]) {
      await expectLater(save(d, p), code(ErrorCode.invalidProfile));
      expect(rows('runtime_profile'), before);
    }
  });
  test('with no stored default the detected built-in is the default', () async {
    install();
    final d = await start();
    await save(d, user('u'));
    final result = await list(d);
    expect(result.profiles.first.isBuiltin, isTrue);
    expect(result.profiles.last.id, 'u');
    expect(result.defaultId, result.profiles.first.id);
    expect(result.defaultAvailable, isTrue);
    expect(result.defaultReason, isNull);
    expect(rows('runtime_profile').map((r) => r['id']), ['u']);
    expect(
      rows('setting')
          .where((r) => r['key'] == 'default_runtime')
          .single['value'],
      result.defaultId,
    );
  });
  test('save or remove of a built-in is refused read-only-profile and nothing changes', () async {
    install();
    final d = await start();
    final p = (await list(d)).profiles.single;
    await expectLater(save(d, p), code(ErrorCode.readOnlyProfile));
    await expectLater(remove(d, p.id), code(ErrorCode.readOnlyProfile));
    expect((await list(d)).profiles.single.toJson(), p.toJson());
    await save(
      d,
      RuntimeProfile(
        id: 'copy',
        name: p.name,
        runtimeKind: p.runtimeKind,
        executable: p.executable,
        args: p.args,
        env: p.env,
      ),
    );
    await setDefault(d, 'copy');
    await restart(d);
    expect((await list(d)).defaultId, 'copy');
    expect(rows('runtime_profile').map((r) => r['id']), ['copy']);
  });
  test('stored built-in default not detected reports defaultAvailable false with the reason', () async {
    install();
    final d = await start();
    final id = (await list(d)).defaultId;
    await save(d, user('fallback'));
    await d.session.quit();
    File(
      joinPath(
        bin.path,
        Platform.isWindows ? 'claude-agent-acp.cmd' : 'claude-agent-acp',
      ),
    ).deleteSync();
    await d.restart();
    await d.waitState();
    final result = await list(d);
    expect(result.defaultId, id);
    expect(result.defaultAvailable, isFalse);
    expect(result.defaultReason, isNotEmpty);
    expect(result.profiles.single.id, 'fallback');
  });
  test(
    'explicit default persists and removed default is not silently substituted',
    () async {
      final d = await start();
      await save(d, user('a'));
      await save(d, user('b'));
      await setDefault(d, 'b');
      await restart(d);
      expect((await list(d)).defaultId, 'b');
      await remove(d, 'b');
      final result = await list(d);
      expect(result.defaultId, 'b');
      expect(result.defaultAvailable, isFalse);
      expect(result.defaultReason, contains('b'));
      await expectLater(
        setDefault(d, 'unknown'),
        code(ErrorCode.invalidProfile),
      );
      await expectLater(remove(d, 'unknown'), code(ErrorCode.invalidProfile));
    },
  );
  test('64 user profiles allowed, 65th refused and existing profile still editable', () async {
    final d = await start();
    for (var i = 0; i < 64; i++) {
      await save(d, user('u$i'));
    }
    await expectLater(
      save(d, user('overflow')),
      code(ErrorCode.invalidProfile),
    );
    await save(d, user('u0', args: ['edited']));
    expect(rows('runtime_profile'), hasLength(64));
    expect((await list(d)).profiles.first.args, ['edited']);
  });
  test(
    'removing a profile leaves every saved native record unchanged',
    () async {
      final d = await start();
      await save(d, user('u'));
      await d.session.quit();
      final db = sqlite3.open(joinPath(profile.path, 'kumiko.db'));
      db.execute(
        "INSERT INTO agent_session VALUES ('s', 'claude-code', 'u', 'adapter', '0.99.1', 'native', 'coding', 'local', '/target', 'identity', NULL, 'a', 'a')",
      );
      db.close();
      final before = rows('agent_session');
      await d.restart();
      await d.waitState();
      await remove(d, 'u');
      expect(rows('agent_session'), before);
    },
  );
  test('runtime mutations report store-error atomically without changing profiles or default', () async {
    final d = await start();
    await save(d, user('u'));
    final before = rows('runtime_profile');
    final settings = rows('setting');
    await d.setFault(TestFault.profileWriteFails);
    await expectLater(save(d, user('new')), code(ErrorCode.storeError));
    await expectLater(remove(d, 'u'), code(ErrorCode.storeError));
    await expectLater(setDefault(d, 'u'), code(ErrorCode.storeError));
    expect(rows('runtime_profile'), before);
    expect(rows('setting'), settings);
  });
  test('runtime methods require negotiated agent capability while shell profiles still work', () async {
    final d = await start(agent: false);
    await expectLater(list(d), code(ErrorCode.methodNotAvailable));
    expect((await d.listProfiles()).profiles, isA<List<ShellProfile>>());
    await expectLater(save(d, user('u')), code(ErrorCode.methodNotAvailable));
    await expectLater(remove(d, 'u'), code(ErrorCode.methodNotAvailable));
    await expectLater(setDefault(d, 'u'), code(ErrorCode.methodNotAvailable));
  });
}
