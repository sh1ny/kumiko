import 'dart:io';

import 'package:host/src/agent/adapter_detector.dart';

import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/codex_support.dart';
import 'support/terminal_support.dart' show rpcFailure;

void main() {
  setUpAll(buildTestHost);
  late Directory profile, work;
  setUp(() {
    profile = tempDir('codex_profiles_');
    work = tempDir('codex_profiles_work_');
  });
  tearDown(() async {
    killReported(work);
    killReported(profile);
    await deleteTree(work);
    await deleteTree(profile);
  });
  Future<RuntimeListResult> list(Desktop d) async => RuntimeListResult.fromJson(
    await d.connection.request(Method.runtimeList, {}) as Json,
  );
  for (final version in [
    'codex-cli 0.166.0',
    'codex-cli 0.167.0',
    'codex-cli 1.0.0-alpha.1+build',
  ]) {
    test(
      'Codex: Codex follows minimum-version compatibility $version',
      () async {
        final f = NativeFixture(profile, work, script: {'version': version});
        await f.open();
        final a = await f.start();
        expect(a.started.adapter.version, version.substring(10));
        await a.close();
      },
    );
  }
  for (final version in [
    'codex-cli 0.165.99',
    'codex-cli 0.166.0-alpha.1',
    'codex-cli 0.166.0-01',
    'codex-cli 00.167.0',
    'wrapper 9.0.0',
    'codex-cli 0.167.0\ncodex-cli 0.168.0',
  ]) {
    test('Codex: Missing or invalid version $version', () async {
      final f = NativeFixture(profile, work, script: {'version': version});
      await f.open();
      final e = await rpcFailure(
        f.desktop.connection.request(Method.agentStart, {
          'workspaceId': f.workspace,
          'runtimeProfileId': 'native',
        }),
      );
      expect(e.reason, ErrorCode.adapterProtocol);
      expect(e.message, anyOf(contains('version'), contains('minimum')));
      expect(f.reports.where((r) => r['launch'] == 'probe'), hasLength(1));
      expect(f.reports.where((r) => r['launch'] == 'root'), isEmpty);
      expect(LedgerView(profile).units(), isEmpty);
    });
  }
  test('Codex: Initialization version mismatch', () async {
    final f = NativeFixture(
      profile,
      work,
      script: {
        'initialize': {
          'userAgent': 'kumiko/0.167.0 (Windows 10.0; x86_64) terminal (kumiko; 0.166.0)',
          'platformFamily': 'windows',
          'platformOs': 'windows',
          'codexHome': '/fixture',
        },
      },
    );
    await f.open();
    final e = await rpcFailure(
      f.desktop.connection.request(Method.agentStart, {
        'workspaceId': f.workspace,
        'runtimeProfileId': 'native',
      }),
    );
    expect(e.reason, ErrorCode.adapterProtocol);
    expect(e.message, contains('mismatch'));
    expect(f.requests.where((r) => r['method'] == 'thread/start'), isEmpty);
  });
  for (final ua in [
    'kumiko/0.166.0 (Windows 99.0.0; x86_64) terminal (kumiko; 12.0.0)',
    'future-agent-format 99.0.0',
  ]) {
    test(
      'Codex: first UA product ignores suffix and additive version $ua',
      () async {
        final f = NativeFixture(
          profile,
          work,
          script: {
            'initialize': {
              'userAgent': ua,
              'platformFamily': 'windows',
              'platformOs': 'windows',
              'codexHome': '/fixture',
              'version': '999.0.0',
            },
          },
        );
        await f.open();
        final a = await f.start();
        expect(a.started.adapter.version, '0.166.0');
        await a.close();
      },
    );
  }
  test('Codex: Unsupported runtime kind', () async {
    final f = NativeFixture(profile, work);
    await f.open();
    await f.desktop.connection.request(
      Method.runtimeSave,
      RuntimeSaveParams(
        RuntimeProfile(
          id: 'other',
          name: 'Other',
          runtimeKind: 'unsupported-native',
          executable: testHostExecutable(),
          args: const ['--test-fixture', 'sleeper'],
        ),
      ),
    );
    final e = await rpcFailure(
      f.desktop.connection.request(Method.agentStart, {
        'workspaceId': f.workspace,
        'runtimeProfileId': 'other',
      }),
    );
    expect(e.message, contains('unsupported-native'));
    expect(LedgerView(profile).units(), isEmpty);
  });
  for (final kind in ['codex', 'claude-code']) {
    test('Codex: host-side explicit profile kind filtering $kind', () async {
      final f = NativeFixture(profile, work);
      await f.open();
      final report = await saveAgentFixture(f.desktop, work, id: 'claude');
      final selected = kind == 'codex' ? 'claude' : 'native';
      final e = await rpcFailure(
        f.desktop.connection.request(Method.agentStart, {
          'workspaceId': f.workspace,
          'runtimeKind': kind,
          'runtimeProfileId': selected,
        }),
      );
      expect(e.reason, ErrorCode.noRuntimeProfile);
      expect(e.message, contains(kind));
      expect(report.existsSync(), false);
      expect(f.reports, isEmpty);
    });
  }
  for (final native in [true, false]) {
    test(
      native
          ? 'Codex: Codex is installed on PATH'
          : 'Codex: Only a Windows batch shim exists',
      () async {
        final bin = Directory(joinPath(work.path, 'bin'))..createSync();
        if (native) {
          final file = File(
            joinPath(bin.path, Platform.isWindows ? 'codex.exe' : 'codex'),
          )..writeAsStringSync('');
          if (!Platform.isWindows) chmodPath(file.path, 0x1c0);
        } else {
          File(joinPath(bin.path, 'codex.cmd'))
              .writeAsStringSync('@echo forbidden');
        }
        final d = await Desktop.start(
          profile,
          capabilities: {...testCapabilities, ...codexCaps},
          environment: {
            'KUMIKO_TEST_RUNTIME_PATH': bin.path,
            'KUMIKO_TEST_RUNTIME_DIRS': '',
            'KUMIKO_TEST_SHELL_PATH': '',
          },
        );
        addTearDown(d.dispose);
        await d.waitState();
        final result = await list(d);
        expect(
          result.profiles.where((p) => p.runtimeKind == 'codex'),
          native ? hasLength(1) : isEmpty,
        );
        if (native) {
          expect(result.defaultId, 'builtin:codex');
          expect(result.profiles.single.args, ['app-server']);
        }
        expect(LedgerView(profile).units(), isEmpty);
      },
    );
  }
  test(
    'Codex: native npm platform package discovery executes no shim',
    () async {
      final bin = Directory(joinPath(work.path, 'npm'))..createSync();
      final main = Directory(joinPath(bin.path, 'node_modules/@openai/codex'))
        ..createSync(recursive: true);
      final platform = Directory(
        joinPath(bin.path, 'node_modules/@openai/codex-win32-x64'),
      )..createSync(recursive: true);
      File(joinPath(bin.path, 'codex.cmd'))
          .writeAsStringSync('@echo forbidden');
      File(joinPath(main.path, 'package.json')).writeAsStringSync(
        '{"name":"@openai/codex","optionalDependencies":{"@openai/codex-win32-x64":"npm:@openai/codex@0.166.0-win32-x64"}}',
      );
      File(joinPath(platform.path, 'package.json')).writeAsStringSync(
        '{"name":"@openai/codex","version":"0.166.0-win32-x64","os":["win32"],"cpu":["x64"]}',
      );
      final binary = File(
        joinPath(
          platform.path,
          'vendor/x86_64-pc-windows-msvc/codex/codex.exe',
        ),
      )..createSync(recursive: true);
      final d = await Desktop.start(
        profile,
        capabilities: {...testCapabilities, ...codexCaps},
        environment: {
          'KUMIKO_TEST_RUNTIME_PATH': bin.path,
          'KUMIKO_TEST_RUNTIME_DIRS': '',
          'KUMIKO_TEST_SHELL_PATH': '',
        },
      );
      addTearDown(d.dispose);
      await d.waitState();
      final result = await list(d);
      expect(
        File(result.profiles.single.executable).resolveSymbolicLinksSync(),
        binary.resolveSymbolicLinksSync(),
      );
      expect(result.profiles.single.env['CODEX_MANAGED_BY_NPM'], '1');
      expect(LedgerView(profile).units(), isEmpty);
    },
    skip: !Platform.isWindows,
  );
  test('Codex: Codex added beside existing Claude default', () async {
    final f = NativeFixture(profile, work);
    await f.open();
    await saveAgentFixture(f.desktop, work, id: 'claude');
    await f.desktop.connection.request(
      Method.runtimeSetDefault,
      const RuntimeSetDefaultParams('claude'),
    );
    await f.desktop.dispose();
    final bin = Directory(joinPath(work.path, 'native-bin'))..createSync();
    final binary = File(
      joinPath(bin.path, Platform.isWindows ? 'codex.exe' : 'codex'),
    )..writeAsStringSync('');
    if (!Platform.isWindows) chmodPath(binary.path, 0x1c0);
    final d = await Desktop.start(
      profile,
      capabilities: {...testCapabilities, ...codexCaps},
      environment: {
        'KUMIKO_TEST_RUNTIME_PATH': bin.path,
        'KUMIKO_TEST_RUNTIME_DIRS': '',
        'KUMIKO_TEST_SHELL_PATH': '',
      },
    );
    addTearDown(d.dispose);
    await d.waitState();
    final result = await list(d);
    expect(result.defaultId, 'claude');
    expect(result.profiles.any((p) => p.runtimeKind == 'codex'), true);
  });

  test(
    'Codex: Remove a profile in use and Continue never switches runtime kind',
    () async {
      final f = NativeFixture(profile, work);
      await f.open();
      final a = await f.start();
      await f.desktop.connection.request(
        Method.runtimeRemove,
        const RuntimeRemoveParams('native'),
      );
      await a.prompt();
      await a.wait(Method.agentTurnEnded);
      await a.close();
      await saveAgentFixture(f.desktop, work, id: 'claude');
      await f.desktop.connection.request(
        Method.runtimeSetDefault,
        const RuntimeSetDefaultParams('claude'),
      );
      final before = f.reports.length;
      final e = await rpcFailure(
        f.desktop.connection.request(Method.agentContinue, {'sessionId': a.id}),
      );
      expect(e.reason, ErrorCode.noRuntimeProfile);
      expect(e.message, contains('codex'));
      expect(f.reports.length, before);
      expect(LedgerView(profile).units(), isEmpty);
    },
  );
  for (final kind in ['codex', 'claude-code']) {
    test(
      'Codex: incompatible default filters launcher and fresh recovery $kind',
      () async {
        final f = NativeFixture(profile, work);
        await f.open();
        await saveAgentFixture(f.desktop, work, id: 'claude');
        await f.desktop.connection.request(
          Method.runtimeSetDefault,
          RuntimeSetDefaultParams(kind == 'codex' ? 'claude' : 'native'),
        );
        final e = await rpcFailure(
          f.desktop.connection.request(Method.agentStart, {
            'workspaceId': f.workspace,
            'runtimeKind': kind,
          }),
        );
        expect(e.reason, ErrorCode.noRuntimeProfile);
        expect(e.message, contains(kind));
        expect(LedgerView(profile).units(), isEmpty);
        expect(f.reports, isEmpty);
      },
    );
  }

  test(
    'Codex: native npm environment retains resources and one manager marker',
    () async {
      final bin = Directory(joinPath(work.path, 'vendor/target/codex'))
        ..createSync(recursive: true);
      final resources = Directory(joinPath(work.path, 'vendor/target/path'))
        ..createSync(recursive: true);
      final executable = File(
        joinPath(bin.path, Platform.isWindows ? 'codex.exe' : 'codex'),
      )..writeAsStringSync('');
      final p = RuntimeProfile(
        id: 'builtin:codex',
        name: 'Codex',
        runtimeKind: 'codex',
        executable: executable.path,
        args: const ['app-server'],
        env: const {
          'CODEX_MANAGED_PACKAGE_ROOT': 'validated-package',
          'CODEX_MANAGED_BY_NPM': '1',
          'CODEX_MANAGED_BY_BUN': '',
        },
      );
      final env = nativeCodexLaunchEnvironment(
        p,
        executable.path,
        inherited: const {
          'PATH': 'ambient-path',
          'CODEX_MANAGED_PACKAGE_ROOT': 'stale-package',
          'CODEX_MANAGED_BY_BUN': '1',
        },
      );
      expect(env.containsKey('CODEX_MANAGED_BY_BUN'), false);
      expect(env['CODEX_MANAGED_BY_NPM'] == '1', true);
      expect(env['CODEX_MANAGED_PACKAGE_ROOT'] == 'validated-package', true);
      expect(
        Directory(env['PATH']!.split(Platform.isWindows ? ';' : ':').first)
                .resolveSymbolicLinksSync() ==
            resources.resolveSymbolicLinksSync(),
        true,
      );
    },
  );

  test('Codex: Only Tern has installed Codex', () async {
    final private = File(
      joinPath(work.path, 'Tern/private/node_modules/codex/codex.exe'),
    )..createSync(recursive: true);
    final result = await AdapterDetector(
      AdapterDetectionConfig(
        pathDirs: const [],
        wellKnownDirs: const [],
        environment: {'APPDATA': work.path, 'HOME': work.path},
      ),
    ).detect();
    expect(result.codex, isNull);
    expect(private.existsSync(), true);
  });
  test('Codex: Codex argv profile', () async {
    final f = NativeFixture(profile, work);
    await f.open();
    final profiles = await list(f.desktop);
    final native = profiles.profiles.single;
    final args = [...native.args, '--setting="a b"', 'quote"literal', ''];
    await f.desktop.connection.request(
      Method.runtimeSave,
      RuntimeSaveParams(
        RuntimeProfile(
          id: native.id,
          name: native.name,
          runtimeKind: 'codex',
          executable: native.executable,
          args: args,
          env: native.env,
        ),
      ),
    );
    final a = await f.start();
    final root = f.reports.firstWhere((r) => r['launch'] == 'root');
    expect(root['argv'], args.skip(2).toList());
    await a.close();
  });

  test(
    'Codex: bounded probe stderr is diagnostic and never native identity',
    () async {
      final f = NativeFixture(
        profile,
        work,
        script: {'probeStderr': 'fixture warning: wrapper 99.0.0'},
      );
      await f.open();
      final a = await f.start();
      expect(a.started.adapter.version, '0.166.0');
      await a.close();
    },
  );
}
