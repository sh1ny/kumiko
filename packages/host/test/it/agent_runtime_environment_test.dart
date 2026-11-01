import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/agent_support.dart';
import 'support/harness.dart';

const _canary = 'KUMIKO_RUNTIME_INHERITED_CANARY';
String get _separator => Platform.isWindows ? ';' : ':';
String get _nodeName => Platform.isWindows ? 'node.exe' : 'node';

String _longPath() => List.generate(
  420,
  (i) => Platform.isWindows
      ? '${r'C:\a\b\c\d\e\f\g\h\i\j'}\\$i'
      : '/inherited/toolchains/vendor/$i/bin',
).join(_separator);

void main() {
  setUpAll(buildTestHost);
  late Directory profile;
  late Directory work;
  late Directory bin;
  setUp(() {
    profile = tempDir('runtime_env_profile_');
    work = tempDir('runtime_env_work_');
    bin = tempDir('runtime_env_bin_');
  });
  tearDown(() async {
    killReported(work);
    await deleteTree(bin);
    await deleteTree(work);
    await deleteTree(profile);
  });

  Future<Desktop> desktop(String inheritedPath) async {
    final d = await Desktop.start(
      profile,
      capabilities: {...testCapabilities, Capability.agent},
      environment: {
        'KUMIKO_TEST_RUNTIME_PATH': '',
        'KUMIKO_TEST_RUNTIME_DIRS': bin.path,
        'KUMIKO_TEST_SHELL_PATH': '',
        'KUMIKO_TEST_QUALIFIED_ADAPTERS':
            '[["scripted-acp","test-only",["load"]]]',
        'PATH': inheritedPath,
        _canary: 'inherited',
      },
    );
    addTearDown(d.dispose);
    await d.waitState();
    return d;
  }

  File install({String? executable}) {
    final node = File(joinPath(bin.path, _nodeName));
    if (executable == null) {
      node.writeAsStringSync('');
    } else {
      File(executable).copySync(node.path);
    }
    if (!Platform.isWindows) chmodPath(node.path, 0x1c0);
    final script = File(
      Platform.isWindows
          ? '${bin.path}/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js'
          : '${bin.path}/lib/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js',
    )..createSync(recursive: true);
    if (Platform.isWindows) {
      File('${bin.path}/claude-agent-acp.cmd').writeAsStringSync('');
    } else {
      Link('${bin.path}/claude-agent-acp').createSync(script.path);
    }
    return script;
  }

  Future<RuntimeListResult> list(Desktop d) async => RuntimeListResult.fromJson(
    await d.connection.request(Method.runtimeList, const EmptyParams()) as Json,
  );
  Future<void> save(Desktop d, RuntimeProfile p) async {
    await d.connection.request(Method.runtimeSave, RuntimeSaveParams(p));
  }

  RuntimeProfile copy(
    RuntimeProfile p, {
    String id = 'copy',
    Map<String, String>? env,
  }) => RuntimeProfile(
    id: id,
    name: 'Editable ${p.name}',
    runtimeKind: p.runtimeKind,
    executable: p.executable,
    args: p.args,
    env: env ?? p.env,
  );

  test('long inherited PATH round-trips detected and unrelated custom runtime profiles', () async {
    install();
    final inherited = _longPath();
    // Windows escaping alone crosses the bound even though raw PATH fits.
    expect(
      utf8.encode(jsonEncode(inherited)).length,
      greaterThan(maxProfileBytes),
    );
    if (Platform.isWindows) {
      expect(utf8.encode(inherited).length, lessThan(maxProfileBytes));
    }
    final d = await desktop(inherited);
    const custom = RuntimeProfile(
      id: 'custom',
      name: 'Unrelated valid runtime',
      runtimeKind: 'claude-code',
      executable: 'custom-adapter',
      env: {'CUSTOM': 'kept'},
    );
    await save(d, custom);
    // This is the real consumer boundary, not an unchecked host-side DTO.
    final result = await list(d);
    expect(result.profiles.map((p) => p.id), ['builtin:claude-code', 'custom']);
    expect(result.defaultAvailable, isTrue);
    expect(result.defaultReason, isNull);
    expect(result.profiles.last.toJson(), custom.toJson());
    expect(
      utf8.encode(jsonEncode(result.profiles.first.toJson())).length,
      lessThanOrEqualTo(maxProfileBytes),
    );
  });

  for (final long in [false, true]) {
    test(
      '${long ? 'long' : 'minimal'} inherited PATH survives native built-in copied start and Continue',
      () async {
        final script = install(executable: await buildNodeAgentFixture());
        final report = File('${work.path}/node.report.jsonl');
        script.writeAsStringSync(
          jsonEncode({
            'reportFile': report.path,
            'reportLaunch': true,
            'reportEnv': [_canary],
            'agentCapabilities': {'loadSession': true},
          }),
        );
        final inherited = long
            ? _longPath()
            : ['/inherited/first', '/inherited/last'].join(_separator);
        final d = await desktop(inherited);
        final w = await d.openWorkspace(work.path);
        final builtin = (await list(d)).profiles.single;
        final copied = copy(builtin);
        await save(d, copied);
        final expected = '${bin.path}$_separator$inherited';

        Future<void> expectNativePath(String path) async {
          final native = await waitFixture(
            report,
            (p) => p.containsKey('nativePath'),
          );
          expect(native['nativePath'], path);
          expect(
            await FileSystemEntity.identical(
              (native['nodeProbe'] as Map)['executable'] as String,
              joinPath(bin.path, _nodeName),
            ),
            isTrue,
          );
          expect(
            (await waitFixture(report, (p) => p.containsKey('env')))['env'],
            {_canary: 'inherited'},
          );
        }

        for (final runtime in [builtin.id, copied.id]) {
          report.writeAsStringSync('');
          final a = AgentPeer(d);
          await a.start(w.workspace.id, runtime: runtime);
          await a.attach();
          await expectNativePath(expected);
          await a.close();
          await a.call(Method.agentRelease);
          report.writeAsStringSync('');
          final continued = AgentContinueResult.fromJson(
            await a.call(Method.agentContinue, {'sessionId': a.id}),
          );
          a.started = AgentStartResult(
            sessionId: a.id,
            eventChannel: continued.eventChannel,
            adapter: continued.adapter,
            capabilities: continued.capabilities,
          );
          await a.attach();
          await a.wait(Method.agentState, where: (p) => p['state'] == 'idle');
          await expectNativePath(expected);
          expect(continued.mode, AgentContinueMode.load);
          await a.close();
        }
        if (!long) {
          // Copying must not freeze the original host's inherited PATH in the
          // store: the same saved profile uses the next host's environment.
          await d.session.quit();
          final changed = [
            '/next/host/first',
            '/next/host/last',
          ].join(_separator);
          final next = await desktop(changed);
          report.writeAsStringSync('');
          final a = AgentPeer(next);
          await a.start(w.workspace.id, runtime: copied.id);
          await a.attach();
          await expectNativePath('${bin.path}$_separator$changed');
          await a.close();
        }
      },
    );
  }

  test('edited Node profile defaults preserve discoverability explicit PATH wins and unrelated sessions stay inherited', () async {
    final script = install(executable: await buildNodeAgentFixture());
    final report = File('${work.path}/edited.report.jsonl');
    script.writeAsStringSync(
      jsonEncode({
        'reportFile': report.path,
        'reportLaunch': true,
        'reportEnv': [_canary, 'KUMIKO_RUNTIME_PROFILE_ONLY'],
      }),
    );
    final inherited = ['/inherited/first', '/inherited/last'].join(_separator);
    final d = await desktop(inherited);
    final w = await d.openWorkspace(work.path);
    final builtin = (await list(d)).profiles.single;
    // Clearing copied overrides keeps Node discoverable from its executable.
    await save(d, copy(builtin, env: const {}));
    final a = AgentPeer(d);
    await a.start(w.workspace.id, runtime: 'copy');
    await a.attach();
    expect(
      (await waitFixture(
        report,
        (p) => p.containsKey('nativePath'),
      ))['nativePath'],
      '${bin.path}$_separator$inherited',
    );
    await a.close();
    report.writeAsStringSync('');
    final explicit = [
      '/explicit/first',
      bin.path,
      '/explicit/last',
    ].join(_separator);
    await save(
      d,
      copy(
        builtin,
        env: {
          Platform.isWindows ? 'Path' : 'PATH': explicit,
          'KUMIKO_RUNTIME_PROFILE_ONLY': 'own',
        },
      ),
    );
    final b = AgentPeer(d);
    await b.start(w.workspace.id, runtime: 'copy');
    await b.attach();
    expect(
      (await waitFixture(
        report,
        (p) => p.containsKey('nativePath'),
      ))['nativePath'],
      explicit,
    );
    expect((await waitFixture(report, (p) => p.containsKey('env')))['env'], {
      _canary: 'inherited',
      'KUMIKO_RUNTIME_PROFILE_ONLY': 'own',
    });
    await b.close();
    final unrelated = await saveAgentFixture(
      d,
      work,
      id: 'unrelated',
      script: {
        'reportLaunch': true,
        'reportEnv': ['PATH', 'KUMIKO_RUNTIME_PROFILE_ONLY', _canary],
      },
    );
    final c = AgentPeer(d);
    await c.start(w.workspace.id, runtime: 'unrelated');
    await c.attach();
    expect((await waitFixture(unrelated, (p) => p.containsKey('env')))['env'], {
      'PATH': inherited,
      _canary: 'inherited',
    });
    await c.close();
    // A fresh built-in launch still sees the untouched host environment.
    report.writeAsStringSync('');
    final fresh = AgentPeer(d);
    await fresh.start(w.workspace.id, runtime: builtin.id);
    await fresh.attach();
    expect(
      (await waitFixture(
        report,
        (p) => p.containsKey('nativePath'),
      ))['nativePath'],
      '${bin.path}$_separator$inherited',
    );
    expect((await waitFixture(report, (p) => p.containsKey('env')))['env'], {
      _canary: 'inherited',
    });
    await fresh.close();
  });
}
