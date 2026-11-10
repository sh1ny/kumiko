import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/codex_support.dart';
import 'support/tool_support.dart';

void main() {
  setUpAll(buildTestHost);
  late Directory profile;
  late Directory work;
  setUp(() {
    profile = tempDir('codex_tools_profile_');
    work = tempDir('codex_tools_work_');
  });
  tearDown(() async {
    killReported(work);
    killReported(profile);
    await deleteTree(work);
    await deleteTree(profile);
  });

  Future<(NativeFixture, AgentPeer)> start({
    Json script = const {},
    Map<String, String> environment = const {},
  }) async {
    final fixture = NativeFixture(profile, work, script: script);
    await fixture.open(env: environment);
    return (fixture, await fixture.start());
  }

  Future<bool> hasGrant(NativeFixture fixture, String id) async {
    final stats = await fixture.desktop.connection.request(
      'test/agent.stats',
      {},
    ) as Json;
    return ((stats['sessions'] as Json)[id] as Json)['hasGrant'] == true;
  }

  test('Codex: Codex receives its bridge configuration', () async {
    final (fixture, agent) = await start();
    expect(agent.started.tools?.status, AgentToolsStatus.notYetUsed);
    expect(await hasGrant(fixture, agent.id), isTrue);
    final methods = fixture.requests
        .map((request) => request['method'])
        .toList();
    expect(
      methods.indexOf('config/read'),
      greaterThan(methods.indexOf('initialize')),
    );
    expect(
      methods.indexOf('config/read'),
      lessThan(methods.indexOf('thread/start')),
    );
    final startRequest = fixture.requests.singleWhere(
      (request) => request['method'] == 'thread/start',
    );
    final config = (startRequest['params'] as Json)['config'] as Json;
    final servers = config['mcp_servers'] as Json;
    expect(servers.keys.toList(), ['kumiko']);
    final entry = servers['kumiko'] as Json;
    expect(entry['command'], testHostExecutable());
    expect(entry['args'], ['--mcp-bridge']);
    final env = entry['env'] as Json;
    expect(env['KUMIKO_TOOL_SECRET'] == '<redacted>', isTrue);
    expect(
      env.keys,
      containsAll([
        'KUMIKO_TOOL_ENDPOINT',
        'KUMIKO_TOOL_SECRET',
        'KUMIKO_UNIT',
      ]),
    );
    expect(
      fixture.reports
          .where((row) => row['launch'] != null)
          .every((row) => row['secret'] == false),
      isTrue,
    );
    await agent.close();
  });

  test(
    'Codex: native session_info names runtime and immutable root target',
    () async {
      final (fixture, agent) = await start(
        script: {
          'kumikoTool': {'when': 'prompt', 'call': 'kumiko_session_info'},
        },
      );
      expect(agent.started.tools?.status, AgentToolsStatus.notYetUsed);
      await agent.prompt();
      final result = await waitFixture(
        fixture.report,
        (row) => row.containsKey('kumikoToolResult'),
      );
      final info =
          ((result['kumikoToolResult'] as Json)['result']
                  as Json)['structuredContent']
              as Json;
      expect(info['sessionId'], agent.id);
      expect(info['runtime'], 'codex');
      expect(info['adapter'], {
        'name': 'codex-app-server',
        'version': '0.166.0',
      });
      expect(
        (info['target'] as Json)['path'],
        (agentRows(profile).single['target_path']),
      );
      await agent.wait(
        Method.agentState,
        where: (state) => (state['tools'] as Json?)?['status'] == 'connected',
      );
      await agent.close();
    },
  );

  test('Codex: Codex configuration cannot be applied', () async {
    final (fixture, agent) = await start(
      script: {
        'configReadError': {
          'code': -32601,
          'message': 'config/read unavailable',
        },
      },
    );
    expect(agent.started.tools?.status, AgentToolsStatus.unavailable);
    expect(agent.started.tools?.reason, contains('config/read'));
    expect(await hasGrant(fixture, agent.id), isFalse);
    final root = fixture.requests.singleWhere(
      (request) => request['method'] == 'thread/start',
    );
    expect((root['params'] as Json)['config'], isNull);
    await agent.prompt();
    await agent.wait(Method.agentTurnEnded);
    await agent.close();
  });

  test('Codex: User already defines kumiko MCP', () async {
    final (fixture, agent) = await start(
      script: {
        'configReadResult': {
          'config': <String, Object?>{},
          'origins': <String, Object?>{},
          'layers': [
            {
              'name': {'type': 'user', 'file': '/fixture/user.toml'},
              'version': 'fixture',
              'config': {
                'mcp_servers': {
                  'kumiko': {'command': 'user-owned'},
                },
              },
            },
          ],
        },
      },
    );
    expect(agent.started.tools?.status, AgentToolsStatus.unavailable);
    expect(
      agent.started.tools?.reason?.toLowerCase(),
      contains('already defines kumiko'),
    );
    expect(await hasGrant(fixture, agent.id), isFalse);
    final root = fixture.requests.singleWhere(
      (request) => request['method'] == 'thread/start',
    );
    expect((root['params'] as Json)['config'], isNull);
    await agent.close();
  });

  test('Codex: unavailable endpoint retains its actual reason', () async {
    final (fixture, agent) = await start(
      environment: {
        'KUMIKO_TEST_TOOL_ENDPOINT_FAULT': 'fixture endpoint unavailable',
      },
    );
    expect(agent.started.tools?.status, AgentToolsStatus.unavailable);
    expect(
      agent.started.tools?.reason,
      'endpoint-unavailable: fixture endpoint unavailable',
    );
    expect(await hasGrant(fixture, agent.id), isFalse);
    expect(
      fixture.requests.any((request) => request['method'] == 'config/read'),
      isFalse,
    );
    await agent.close();
  });

  test('Codex: Unrelated commands cannot read bridge secret', () async {
    final (fixture, agent) = await start(
      script: {
        'kumikoTool': {'when': 'prompt', 'call': 'kumiko_session_info'},
        'toolsAudit': {
          'scanRoots': [work.path, profile.path],
          'otherEnv': {'UNRELATED_MCP_MARKER': 'own-entry'},
        },
      },
    );
    await agent.prompt();
    await waitFixture(
      fixture.report,
      (row) => row.containsKey('kumikoToolResult'),
    );
    final audit = await waitFixture(
      fixture.report,
      (row) => row['toolsAudit'] == true,
    );
    for (final key in [
      'bridgeEntryHasSecret',
      'parentEnvironmentIsolated',
      'commandEnvironmentIsolated',
      'otherMcpEnvironmentIsolated',
      'scanComplete',
    ]) {
      expect(
        audit[key],
        true,
        reason: key == 'scanComplete' ? '$key ${audit['scanErrors']}' : key,
      );
    }
    expect(audit['secretFound'], false);
    expect(audit['errorCount'], 0);
    expect(audit['scannedFiles'] as int, greaterThan(0));
    await agent.close();
  });

  for (final leak in [false, true]) {
    test('Codex: post-run file canary detects leak=$leak', () async {
      final (fixture, agent) = await start(
        script: {
          'persistSecretForScanTest': leak,
          'toolsAudit': {
            'scanRoots': [work.path, profile.path],
          },
        },
      );
      await agent.prompt();
      await agent.wait(Method.agentTurnEnded);
      await agent.close();
      final stats = await fixture.desktop.connection.request(
        'test/agent.stats',
        {
          'secretScanSessionId': agent.id,
          'secretScanRoots': [work.path, profile.path],
        },
      ) as Json;
      final scan = stats['secretAudit'] as Json?;
      expect(
        scan,
        isNotNull,
        reason: 'post-settlement scan must not be omitted',
      );
      expect(scan!['complete'], true);
      expect(scan['errorCount'], 0);
      expect(scan['scannedFiles'] as int, greaterThan(0));
      expect((scan['matchedFiles'] as int) > 0, leak);
      expect((await toolState(fixture.desktop))['authenticated'], 0);
    });
  }

  test('Codex: Child bridge connection cap', () async {
    final (fixture, agent) = await start(
      script: {
        'kumikoPeers': [
          for (var i = 0; i < 5; i++) {'when': 'session/new', 'list': true},
        ],
      },
    );
    await waitFixture(
      fixture.report,
      (row) => row['peerIndex'] == 4 && row.containsKey('kumikoBridgeExit'),
    );
    expect((await toolState(fixture.desktop))['authenticated'], 4);
    await eventually(
      () => agent.events.toString().contains('child tools unavailable'),
      within: const Duration(seconds: 3),
      reason: 'refused child bridge must remain visible at the root',
    );
    expect(agent.of(Method.agentState).last['tools'], {'status': 'notYetUsed'});
    fixture.scriptFile.writeAsStringSync(
      jsonEncode({'reportFile': fixture.report.path}),
    );
    final other = AgentPeer(fixture.desktop);
    await other.start(fixture.workspace, runtime: 'native');
    await other.attach();
    expect(other.started.tools?.status, AgentToolsStatus.notYetUsed);
    expect(other.events.toString().contains('child tools unavailable'), false);
    await other.close();
    expect((await toolState(fixture.desktop))['authenticated'], 4);
    await agent.close();
    expect((await toolState(fixture.desktop))['authenticated'], 0);
  });

  test('Codex: Child uses inherited Kumiko tools', () async {
    final other = tempDir('codex_child_other_');
    addTearDown(() => deleteTree(other));
    final (fixture, agent) = await start(
      script: {
        'kumikoPeers': [
          {'when': 'prompt', 'call': 'kumiko_session_info'},
        ],
      },
    );
    await fixture.desktop.openWorkspace(other.path);
    await agent.prompt();
    final result = await waitFixture(
      fixture.report,
      (row) => row['peerIndex'] == 0 && row.containsKey('kumikoToolResult'),
    );
    final info =
        ((result['kumikoToolResult'] as Json)['result']
                as Json)['structuredContent']
            as Json;
    expect(info['sessionId'], agent.id);
    expect(info['role'], 'coding');
    expect(info['runtime'], 'codex');
    expect(
      (info['target'] as Json)['path'],
      agentRows(profile).single['target_path'],
    );
    expect((info['target'] as Json)['path'] == other.path, false);
    await agent.close();
  });

  test('Codex: post-run scan refuses unreadable nonempty data', () async {
    if (!Platform.isWindows) {
      markTestSkipped('Windows mandatory file range lock');
      return;
    }
    final (fixture, agent) = await start();
    await agent.close();
    final file = File(p.join(work.path, 'locked-scan-control.bin'));
    file.writeAsStringSync('nonempty scanner control');
    final lock = file.openSync(mode: FileMode.append);
    lock.lockSync(FileLock.exclusive);
    try {
      final stats =
          await fixture.desktop.connection
                  .request('test/agent.stats', {
                    'secretScanSessionId': agent.id,
                    'secretScanRoots': [work.path, profile.path],
                  })
                  .timeout(const Duration(seconds: 5))
              as Json;
      final scan = stats['secretAudit'] as Json;
      expect(scan['complete'], false);
      expect(scan['errorCount'] as int, greaterThan(0));
    } finally {
      lock.unlockSync();
      lock.closeSync();
    }
  });

  for (final fails in [false, true]) {
    test(
      'Codex: Continue binds a fresh bridge after native history failure=$fails',
      () async {
        final (fixture, original) = await start();
        final savedId = original.id;
        final record = agentRows(profile).single;
        await original.close();
        await original.call(Method.agentRelease);
        expect((await toolState(fixture.desktop))['authenticated'], 0);
        final release = File(p.join(work.path, 'release-native-resume'));
        fixture.scriptFile.writeAsStringSync(
          jsonEncode({
            'reportFile': fixture.report.path,
            'version': 'codex-cli 0.167.0',
            if (fails)
              'startError': {
                'code': -32000,
                'message': 'fixture refused resume',
              },
            'kumikoTool': {
              'when': 'session/new',
              'call': 'kumiko_session_info',
            },
            'resumeActions': [
              {'waitFile': release.path},
            ],
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
                  'id': 'old-turn',
                  'status': 'completed',
                  'items': [
                    {
                      'id': 'old-message',
                      'type': 'agentMessage',
                      'text': 'saved answer',
                    },
                  ],
                },
              ],
            },
          }),
        );
        fixture.report.writeAsStringSync('');
        final agent = AgentPeer(fixture.desktop);
        final result = AgentContinueResult.fromJson(
          await agent.call(Method.agentContinue, {'sessionId': savedId}),
        );
        agent.started = AgentStartResult(
          sessionId: savedId,
          eventChannel: result.eventChannel,
          adapter: result.adapter,
          capabilities: result.capabilities,
          tools: result.tools,
        );
        await agent.attach();
        await waitFixture(
          fixture.report,
          (row) => row.containsKey('kumikoToolListed'),
        );
        await eventually(
          () async =>
              (await toolState(fixture.desktop))['pendingBindings'] == 1,
        );
        expect(
          fixture.reports.any((row) => row.containsKey('kumikoToolResult')),
          false,
        );
        release.writeAsStringSync('continue');
        if (fails) {
          final exit = await agent.wait(Method.agentExited);
          expect(exit['error'], ErrorCode.resumeUnavailable);
          expect(agentRows(profile).single, record);
          expect((await toolState(fixture.desktop))['authenticated'], 0);
          expect((await toolState(fixture.desktop))['pendingBindings'], 0);
          expect(
            fixture.requests.where(
              (request) => request['method'] == 'thread/resume',
            ),
            hasLength(1),
          );
          expect(
            fixture.requests.where(
              (request) =>
                  request['method'] == 'thread/start' ||
                  request['method'] == 'turn/start',
            ),
            isEmpty,
          );
          expect(
            fixture.reports
                .where((row) => row.containsKey('kumikoToolResult'))
                .every(
                  (row) => (row['kumikoToolResult'] as Json)['result'] == null,
                ),
            true,
          );
          return;
        }
        final response = await waitFixture(
          fixture.report,
          (row) => row.containsKey('kumikoToolResult'),
        );
        final info =
            ((response['kumikoToolResult'] as Json)['result']
                    as Json)['structuredContent']
                as Json;
        expect(info['sessionId'], savedId);
        expect(info['runtime'], 'codex');
        expect(info['adapter'], {
          'name': 'codex-app-server',
          'version': '0.167.0',
        });
        expect((info['target'] as Json)['path'], record['target_path']);
        expect(agentRows(profile).single, record);
        final resumed = fixture.requests.singleWhere(
          (request) => request['method'] == 'thread/resume',
        );
        expect(
          ((resumed['params'] as Json)['config'] as Json).containsKey(
            'mcp_servers',
          ),
          true,
        );
        expect(
          fixture.requests.where(
            (request) => request['method'] == 'turn/start',
          ),
          isEmpty,
        );
        await agent.close();
        expect((await toolState(fixture.desktop))['authenticated'], 0);
      },
    );
  }

  for (final fails in [false, true]) {
    test('Codex: pending native binding settles failure=$fails', () async {
      final release = File(p.join(work.path, 'release-native-start'));
      final fixture = NativeFixture(
        profile,
        work,
        script: {
          'kumikoTool': {'when': 'session/new', 'call': 'kumiko_session_info'},
          'newActions': [
            {'waitFile': release.path},
          ],
          if (fails)
            'startError': {'code': -32000, 'message': 'fixture refused thread'},
        },
      );
      await fixture.open();
      final agent = AgentPeer(fixture.desktop);
      final starting = agent.start(fixture.workspace, runtime: 'native');
      final observedStart = starting.then<Object?>(
        (value) => value,
        onError: (Object error) => error,
      );
      await waitFixture(
        fixture.report,
        (row) => row.containsKey('kumikoToolListed'),
      );
      final state = await toolState(fixture.desktop);
      expect(state.containsKey('pendingBindings'), true);
      await eventually(
        () async => (await toolState(fixture.desktop))['pendingBindings'] == 1,
      );
      expect(
        fixture.reports.any((row) => row.containsKey('kumikoToolResult')),
        false,
      );
      release.writeAsStringSync('continue');
      final outcome = await observedStart;
      if (fails) {
        expect(outcome, isA<RpcException>());
        expect((await toolState(fixture.desktop))['authenticated'], 0);
        expect((await toolState(fixture.desktop))['pendingBindings'], 0);
        expect(agentRows(profile), isEmpty);
        expect(
          fixture.requests.where(
            (request) => request['method'] == 'thread/start',
          ),
          hasLength(1),
        );
      } else {
        expect(outcome, isA<AgentStartResult>());
        final result = await waitFixture(
          fixture.report,
          (row) => row.containsKey('kumikoToolResult'),
        );
        final info =
            ((result['kumikoToolResult'] as Json)['result']
                    as Json)['structuredContent']
                as Json;
        expect(info['sessionId'], agent.id);
        await agent.attach();
        await agent.close();
      }
    });
  }
}
