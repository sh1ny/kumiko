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
  const resumableHistory = <String, Object?>{
    'readThread': {
      'id': 'root-thread',
      'historyMode': 'legacy',
      'status': {'type': 'notLoaded'},
    },
    'afterReadThread': {
      'id': 'root-thread',
      'historyMode': 'legacy',
      'status': {'type': 'idle'},
    },
    'resumeThread': {
      'id': 'root-thread',
      'historyMode': 'legacy',
      'status': {'type': 'idle'},
      'turns': [
        {
          'id': 'turn-1',
          'status': 'completed',
          'itemsView': 'full',
          'items': [
            {
              'id': 'saved-user',
              'type': 'userMessage',
              'content': [
                {'type': 'text', 'text': 'saved question'},
              ],
            },
            {
              'id': 'message-turn-1',
              'type': 'agentMessage',
              'text': 'native reply',
            },
          ],
        },
      ],
    },
  };
  Future<AgentPeer> restore(
    NativeFixture f,
    String id, {
    String? runtime,
  }) async {
    final peer = AgentPeer(f.desktop);
    final result = AgentContinueResult.fromJson(
      await peer.call(Method.agentContinue, {
        'sessionId': id,
        'runtimeProfileId': ?runtime,
      }),
    );
    peer.started = AgentStartResult(
      sessionId: id,
      eventChannel: result.eventChannel,
      adapter: result.adapter,
      capabilities: result.capabilities,
    );
    expect(result.mode, AgentContinueMode.load);
    expect(f.requests.where((r) => r['method'] == 'thread/resume'), isEmpty);
    await peer.attach();
    await peer.wait(
      Method.agentState,
      where: (state) => state['state'] == 'idle',
    );
    await eventually(() => peer.events.any((event) => event['phase'] == 'end'));
    expect(
      peer.events
          .where((event) => event['kind'] == 'replay')
          .map((event) => event['phase']),
      ['start', 'end'],
    );
    expect(
      peer.events
          .where((event) => event['kind'] == 'user')
          .map((event) => event['text']),
      ['saved question'],
    );
    expect(
      peer.events
          .where((event) => event['kind'] == 'agentText')
          .map((event) => event['text']),
      ['native reply'],
    );
    expect(
      f.requests.where((r) => r['method'] == 'thread/resume'),
      hasLength(1),
    );
    expect(
      (f.requests.singleWhere((r) => r['method'] == 'thread/resume')['params']
          as Json)['threadId'],
      'root-thread',
    );
    expect(
      f.requests.where(
        (r) => r['method'] == 'thread/start' || r['method'] == 'turn/start',
      ),
      isEmpty,
    );
    return peer;
  }

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
  for (final selection in ['replacement', 'claude', 'missing']) {
    test('Codex: Continue selected profile $selection', () async {
      final f = NativeFixture(profile, work, script: resumableHistory);
      await f.open();
      final a = await f.start();
      await a.prompt('saved question');
      await a.wait(Method.agentTurnEnded);
      await a.close();
      await a.call(Method.agentRelease);
      final saved = agentRows(profile);
      final native = (await list(f.desktop)).profiles.single;
      await f.desktop.connection.request(
        Method.runtimeSave,
        RuntimeSaveParams(
          RuntimeProfile(
            id: 'replacement',
            name: 'Replacement',
            runtimeKind: 'codex',
            executable: native.executable,
            args: [...native.args, '--chosen-continue-profile'],
          ),
        ).toJson(),
      );
      await saveAgentFixture(f.desktop, work, id: 'claude');
      await f.desktop.connection.request(
        Method.runtimeSetDefault,
        const RuntimeSetDefaultParams('claude').toJson(),
      );
      if (selection == 'replacement') {
        await f.desktop.connection.request(
          Method.runtimeRemove,
          const RuntimeRemoveParams('native').toJson(),
        );
      }
      f.report.writeAsStringSync('');
      if (selection == 'replacement') {
        final continued = await restore(f, a.id, runtime: selection);
        expect(
          f.reports.singleWhere((r) => r['launch'] == 'root')['argv'],
          contains('--chosen-continue-profile'),
        );
        expect(agentRows(profile), saved);
        await continued.close();
        await continued.call(Method.agentRelease);
      } else {
        final error = await rpcFailure(
          f.desktop.connection.request(Method.agentContinue, {
            'sessionId': a.id,
            'runtimeProfileId': selection,
          }),
        );
        expect(error.reason, ErrorCode.noRuntimeProfile);
        expect(
          f.reports,
          isEmpty,
          reason: 'invalid explicit selections must fail before version probe',
        );
      }
      expect((await list(f.desktop)).defaultId, 'claude');
      expect(agentRows(profile), saved);
      expect(LedgerView(profile).units(), isEmpty);
    });
  }
  for (final originalAvailable in [true, false]) {
    test(
      'Codex: Continue legacy profile preference original=$originalAvailable',
      () async {
        final f = NativeFixture(profile, work, script: resumableHistory);
        await f.open();
        final a = await f.start();
        await a.prompt('saved question');
        await a.wait(Method.agentTurnEnded);
        await a.close();
        await a.call(Method.agentRelease);
        final saved = agentRows(profile);
        final native = (await list(f.desktop)).profiles.single;
        await f.desktop.connection.request(
          Method.runtimeSave,
          RuntimeSaveParams(
            RuntimeProfile(
              id: 'replacement',
              name: 'Replacement',
              runtimeKind: 'codex',
              executable: native.executable,
              args: [...native.args, '--compatible-default'],
            ),
          ).toJson(),
        );
        await f.desktop.connection.request(
          Method.runtimeSetDefault,
          const RuntimeSetDefaultParams('replacement').toJson(),
        );
        if (!originalAvailable) {
          await f.desktop.connection.request(
            Method.runtimeRemove,
            const RuntimeRemoveParams('native').toJson(),
          );
        }
        f.report.writeAsStringSync('');
        final continued = await restore(f, a.id);
        final root = f.reports.singleWhere((r) => r['launch'] == 'root');
        expect(
          (root['argv'] as List).contains('--compatible-default'),
          !originalAvailable,
        );
        expect((await list(f.desktop)).defaultId, 'replacement');
        expect(agentRows(profile), saved);
        await continued.close();
        await continued.call(Method.agentRelease);
        expect(agentRows(profile), saved);
        expect(LedgerView(profile).units(), isEmpty);
      },
    );
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
  test('Codex: the npm launcher script is recognised without running it', () {
    final script = File(
      joinPath(work.path, 'lib/node_modules/@openai/codex/bin/codex.js'),
    )..createSync(recursive: true);
    final native = File(
      joinPath(
        work.path,
        'lib/node_modules/@openai/codex-linux-x64/vendor/'
        'x86_64-unknown-linux-musl/codex/codex',
      ),
    )..createSync(recursive: true);
    expect(isNpmCodexLauncher(script.path), true);
    expect(isNpmCodexLauncher(native.path), false);
    expect(isNpmCodexLauncher(joinPath(work.path, 'missing')), false);
  });
  test('Codex: a POSIX npm launcher on PATH resolves to its native platform binary', () {
    final prefix = Directory(joinPath(work.path, 'prefix'))..createSync();
    final modules = joinPath(prefix.path, 'lib/node_modules');
    final main = Directory(joinPath(modules, '@openai/codex'))
      ..createSync(recursive: true);
    final launcher = File(joinPath(main.path, 'bin/codex.js'))
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/usr/bin/env node\n');
    chmodPath(launcher.path, 0x1c0);
    final bin = Directory(joinPath(prefix.path, 'bin'))..createSync();
    Link(joinPath(bin.path, 'codex')).createSync(launcher.path);
    final arch = Platform.version.contains('arm64') ? 'arm64' : 'x64';
    final os = Platform.isMacOS ? 'darwin' : 'linux';
    final key = '@openai/codex-$os-$arch';
    File(joinPath(main.path, 'package.json')).writeAsStringSync(
      '{"name":"@openai/codex","optionalDependencies":{"$key":"npm:@openai/codex@0.166.0-$os-$arch"}}',
    );
    final platform = Directory(joinPath(modules, key))..createSync();
    File(joinPath(platform.path, 'package.json')).writeAsStringSync(
      '{"name":"@openai/codex","version":"0.166.0-$os-$arch","os":["$os"],"cpu":["$arch"]}',
    );
    final machine = arch == 'arm64' ? 'aarch64' : 'x86_64';
    final target = Platform.isMacOS
        ? '$machine-apple-darwin'
        : '$machine-unknown-linux-musl';
    final binary = File(joinPath(platform.path, 'vendor/$target/codex/codex'))
      ..createSync(recursive: true);
    chmodPath(binary.path, 0x1c0);
    final found = detectCodex(
      AdapterDetectionConfig(
        os: Platform.operatingSystem,
        pathDirs: [bin.path],
        wellKnownDirs: const [],
        environment: const {},
      ),
    );
    expect(found, isNotNull);
    expect(
      File(found!.executable).resolveSymbolicLinksSync(),
      binary.resolveSymbolicLinksSync(),
    );
    expect(found.env['CODEX_MANAGED_BY_NPM'], '1');
  }, skip: Platform.isWindows);
  for (final nested in [false, true]) {
    test('Codex: an npm platform package ${nested ? 'nested under' : 'beside'} '
        '@openai/codex is found', () {
      final windows = Platform.isWindows;
      final prefix = Directory(joinPath(work.path, 'prefix'))..createSync();
      final bin = windows
          ? prefix
          : (Directory(joinPath(prefix.path, 'bin'))..createSync());
      final modules = joinPath(
        prefix.path,
        windows ? 'node_modules' : 'lib/node_modules',
      );
      final main = Directory(joinPath(modules, '@openai/codex'))
        ..createSync(recursive: true);
      final arch = Platform.version.contains('arm64') ? 'arm64' : 'x64';
      final os = windows
          ? 'win32'
          : Platform.isMacOS
          ? 'darwin'
          : 'linux';
      final key = '@openai/codex-$os-$arch';
      File(joinPath(main.path, 'package.json')).writeAsStringSync(
        '{"name":"@openai/codex","optionalDependencies":{"$key":"npm:@openai/codex@0.166.0-$os-$arch"}}',
      );
      // A global npm install places the dependency beneath the package.
      final platform = Directory(
        nested
            ? joinPath(main.path, 'node_modules/$key')
            : joinPath(modules, key),
      )..createSync(recursive: true);
      File(joinPath(platform.path, 'package.json')).writeAsStringSync(
        '{"name":"@openai/codex","version":"0.166.0-$os-$arch","os":["$os"],"cpu":["$arch"]}',
      );
      final machine = arch == 'arm64' ? 'aarch64' : 'x86_64';
      final target = windows
          ? '$machine-pc-windows-msvc'
          : Platform.isMacOS
          ? '$machine-apple-darwin'
          : '$machine-unknown-linux-musl';
      final binary = File(
        joinPath(
          platform.path,
          'vendor/$target/codex/${windows ? 'codex.exe' : 'codex'}',
        ),
      )..createSync(recursive: true);
      if (!windows) chmodPath(binary.path, 0x1c0);
      final found = detectCodex(
        AdapterDetectionConfig(
          os: Platform.operatingSystem,
          pathDirs: [bin.path],
          wellKnownDirs: const [],
          environment: const {},
        ),
      );
      expect(found, isNotNull);
      expect(
        File(found!.executable).resolveSymbolicLinksSync(),
        binary.resolveSymbolicLinksSync(),
      );
      expect(found.env['CODEX_MANAGED_BY_NPM'], '1');
    });
  }
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
