import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/agent_support.dart';
import 'support/harness.dart';
import 'support/tool_support.dart';

const _qualified = {
  'KUMIKO_TEST_QUALIFIED_ADAPTERS':
      '[["scripted-acp","test-only",["load","resume"]]]',
};
const _history = <String, Object?>{
  'loadSession': true,
  'sessionCapabilities': {'resume': <String, Object?>{}},
};

/// The `kumiko` entry of the fixture's latest `session/new` (when [method] is
/// null) or latest request of [method]; null when none or the list is empty.
Json? entryIn(File report, {String? method}) {
  for (final p in fixtureReports(report).reversed) {
    final matches = method == null
        ? p.containsKey('newCwd')
        : p['method'] == method;
    if (!matches) continue;
    final servers = p['mcpServers'];
    return servers is List && servers.isNotEmpty
        ? servers.single as Json
        : null;
  }
  return null;
}

String envValue(Json entry, String name) => [
  for (final e in entry['env'] as List)
    if ((e as Json)['name'] == name) e['value'] as String,
].single;

String? toolsStatus(Json state) =>
    (state['tools'] as Json?)?['status'] as String?;

String normalizePath(String p) {
  final real = File(p).resolveSymbolicLinksSync();
  return Platform.isWindows ? real.toLowerCase() : real;
}

void main() {
  setUpAll(buildTestHost);
  late Directory profile;
  late Directory work;
  setUp(() {
    profile = tempDir('tools_profile_');
    work = tempDir('tools_work_');
  });
  tearDown(() async {
    killReported(work);
    await deleteTree(work);
    await deleteTree(profile);
  });

  Future<Desktop> desktop({Map<String, String> env = const {}}) async {
    final d = await Desktop.start(
      profile,
      capabilities: {...testCapabilities, Capability.agent},
      environment: {
        'KUMIKO_TEST_RUNTIME_PATH': '',
        'KUMIKO_TEST_SHELL_PATH': '',
        ..._qualified,
        ...env,
      },
    );
    addTearDown(d.dispose);
    await d.waitState();
    return d;
  }

  Future<(Desktop, AgentPeer, File)> session({
    Json script = const {},
    Map<String, String> env = const {},
    bool attach = true,
  }) async {
    final d = await desktop(env: env);
    final w = await d.openWorkspace(work.path);
    final report = await saveAgentFixture(
      d,
      work,
      script: {'agentCapabilities': _history, ...script},
    );
    final a = AgentPeer(d);
    await a.start(w.workspace.id);
    if (attach) await a.attach();
    return (d, a, report);
  }

  Future<void> turnEnds(AgentPeer a, int count) => eventually(
    () => a.of(Method.agentTurnEnded).length >= count,
    reason: 'turn $count did not end',
  );

  test('session/new carries one kumiko entry with the bridge command and no '
      'workspace file changes', () async {
    final d = await desktop();
    final w = await d.openWorkspace(work.path);
    final report = await saveAgentFixture(
      d,
      work,
      script: {'reportLaunch': true},
    );
    List<String> listing() => [
      for (final e in work.listSync(recursive: true))
        if (!e.path.endsWith('.report.jsonl') &&
            !e.path.contains('kumiko-fixture-'))
          e.path,
    ]..sort();
    final before = listing();
    final a = AgentPeer(d);
    await a.start(w.workspace.id);
    await a.attach();

    final reports = fixtureReports(report)
        .where((p) => p.containsKey('newCwd'))
        .toList();
    final servers = reports.single['mcpServers'] as List;
    expect(servers, hasLength(1));
    final entry = servers.single as Json;
    expect(entry['name'], 'kumiko');
    expect(
      normalizePath(entry['command'] as String),
      normalizePath(testHostExecutable()),
    );
    expect(entry['args'], ['--mcp-bridge']);
    final names = [for (final e in entry['env'] as List) (e as Json)['name']];
    expect(
      names,
      containsAll([
        'KUMIKO_TOOL_ENDPOINT',
        'KUMIKO_TOOL_SECRET',
        'KUMIKO_UNIT',
      ]),
    );
    expect(envValue(entry, 'KUMIKO_TOOL_ENDPOINT'), await endpointOf(d));
    expect(
      base64Url.decode(
        base64Url.normalize(envValue(entry, 'KUMIKO_TOOL_SECRET')),
      ),
      hasLength(32),
    );
    expect(
      LedgerView(profile).units().map((u) => u['containment_id']),
      contains(envValue(entry, 'KUMIKO_UNIT')),
    );
    expect(listing(), before);
  });

  test('load and resume carry a kumiko entry with a fresh secret', () async {
    final d = await desktop();
    final w = await d.openWorkspace(work.path);
    final report = await saveAgentFixture(
      d,
      work,
      script: {'agentCapabilities': _history, 'reportLaunch': true},
    );
    final a = AgentPeer(d);
    await a.start(w.workspace.id);
    await a.attach();
    final seen = {envValue(entryIn(report)!, 'KUMIKO_TOOL_SECRET')};
    for (final (method, mode, capabilities) in [
      ('session/load', AgentContinueMode.load, _history),
      (
        'session/resume',
        AgentContinueMode.resume,
        {
          'sessionCapabilities': {'resume': <String, Object?>{}},
        },
      ),
    ]) {
      final id = a.id;
      await a.close();
      await a.call(Method.agentRelease);
      a.notifications.clear();
      await saveAgentFixture(
        d,
        work,
        script: {'agentCapabilities': capabilities, 'reportLaunch': true},
      );
      final result = AgentContinueResult.fromJson(
        await a.call(Method.agentContinue, {'sessionId': id}),
      );
      expect(result.mode, mode);
      expect(result.tools?.status, AgentToolsStatus.notYetUsed);
      a.started = AgentStartResult(
        sessionId: id,
        eventChannel: result.eventChannel,
        adapter: result.adapter,
        capabilities: result.capabilities,
      );
      await a.attach();
      await a.wait(Method.agentState, where: (p) => p['state'] == 'idle');
      await waitFixture(report, (p) => p['method'] == method);
      final entry = entryIn(report, method: method)!;
      expect(entry['name'], 'kumiko');
      expect(entry['args'], ['--mcp-bridge']);
      expect(seen.add(envValue(entry, 'KUMIKO_TOOL_SECRET')), isTrue);
    }
    await a.close();
  });

  test('endpoint down sends empty mcpServers and status unavailable', () async {
    final (_, a, report) = await session(
      script: {'reportLaunch': true},
      env: {'KUMIKO_TEST_TOOL_ENDPOINT_FAULT': 'no endpoint here'},
    );
    final reports = fixtureReports(report).where((p) => p['newCwd'] != null);
    expect(reports.single['mcpServers'], isEmpty);
    expect(a.started.tools?.status, AgentToolsStatus.unavailable);
    expect(a.started.tools?.reason, 'endpoint-unavailable: no endpoint here');
    final state = await a.wait(
      Method.agentState,
      where: (p) => toolsStatus(p) != null,
    );
    expect(toolsStatus(state), 'unavailable');
  });

  test('rejected session/new revokes the secret, stores nothing and is not '
      'retried', () async {
    final d = await desktop();
    final w = await d.openWorkspace(work.path);
    final report = await saveAgentFixture(
      d,
      work,
      script: {
        'newErrorAfterActions': {'code': -32000, 'message': 'rejected'},
      },
    );
    final a = AgentPeer(d);
    await expectLater(a.start(w.workspace.id), throwsA(isA<RpcException>()));
    final news = fixtureReports(report).where((p) => p['newCwd'] != null);
    expect(news, hasLength(1), reason: 'session/new is not retried');
    expect(agentRows(profile), isEmpty);
    final secret = envValue(
      news.single['mcpServers'].toString().isEmpty
          ? <String, Object?>{}
          : (news.single['mcpServers'] as List).single as Json,
      'KUMIKO_TOOL_SECRET',
    );
    final c = await ToolClient.connect(await endpointOf(d));
    addTearDown(c.close);
    c.authenticate(secret);
    expect(await c.readJson(), {'ok': false, 'error': 'unauthenticated'});
  });

  test(
    'kumiko_session_info returns id, role, runtime, adapter and target',
    () async {
      final (_, a, report) = await session(
        script: {
          'kumikoTool': {'call': 'kumiko_session_info', 'when': 'prompt'},
        },
      );
      await a.prompt();
      final result = await waitFixture(
        report,
        (p) => p.containsKey('kumikoToolResult'),
      );
      final info =
          ((result['kumikoToolResult'] as Json)['result']
                  as Json)['structuredContent']
              as Json;
      final target = directoryIdentity(work.path) as ResolvedDirectory;
      expect(info, {
        'sessionId': a.id,
        'role': 'coding',
        'runtime': 'claude-code',
        'adapter': {'name': 'scripted-acp', 'version': 'test-only'},
        'target': {'path': target.realPath},
      });
      expect(
        (agentRows(profile).single['target_path'] as String),
        target.realPath,
      );
    },
  );

  test('call before session/new returns waits for the record, or fails '
      'session unavailable when start fails', () async {
    final release = File(joinPath(work.path, 'release-new'));
    final tool = {'call': 'kumiko_session_info', 'when': 'session/new'};
    // Waits for the record.
    final d = await desktop();
    final w = await d.openWorkspace(work.path);
    final report = await saveAgentFixture(
      d,
      work,
      script: {
        'kumikoTool': tool,
        'new': [
          {'waitFile': release.path},
        ],
      },
    );
    final a = AgentPeer(d);
    final starting = a.start(w.workspace.id);
    await waitFixture(report, (p) => p.containsKey('kumikoToolListed'));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      fixtureReports(report).where((p) => p.containsKey('kumikoToolResult')),
      isEmpty,
      reason: 'the call must wait for the session record',
    );
    release.writeAsStringSync('go');
    await starting;
    final result = await waitFixture(
      report,
      (p) => p.containsKey('kumikoToolResult'),
    );
    expect(
      (((result['kumikoToolResult'] as Json)['result']
              as Json)['structuredContent']
          as Json)['sessionId'],
      a.id,
    );
    await a.attach();
    await a.close();

    // Fails session unavailable when the start fails: a call from a bridge
    // that authenticated early is answered, not left hanging.
    final release2 = File(joinPath(work.path, 'release-new-2'));
    final report2 = await saveAgentFixture(
      d,
      work,
      id: 'failing',
      script: {
        'reportLaunch': true,
        'new': [
          {'waitFile': release2.path},
        ],
        'newErrorAfterActions': {'code': -32000, 'message': 'rejected'},
      },
    );
    final b = AgentPeer(d);
    final failing = b.start(w.workspace.id, runtime: 'failing');
    final failed = expectLater(failing, throwsA(isA<RpcException>()));
    final launched = await waitFixture(report2, (p) => p.containsKey('newCwd'));
    final secret = envValue(
      (launched['mcpServers'] as List).single as Json,
      'KUMIKO_TOOL_SECRET',
    );
    final c = await ToolClient.connect(await endpointOf(d));
    addTearDown(c.close);
    c.authenticate(secret);
    expect(await c.readJson(), {'ok': true});
    c.send({
      'jsonrpc': '2.0',
      'id': 7,
      'method': 'tools/call',
      'params': {
        'name': 'kumiko_session_info',
        'arguments': <String, Object?>{},
      },
    });
    release2.writeAsStringSync('go');
    await failed;
    final response = (await c.readJson())!;
    expect(response.containsKey('result'), isFalse);
    expect((response['error'] as Json)['message'], 'session unavailable');
  });

  test(
    'result names the original target after another workspace is focused',
    () async {
      final other = tempDir('tools_other_');
      addTearDown(() => deleteTree(other));
      final (d, a, report) = await session(
        script: {
          'kumikoTool': {'call': 'kumiko_session_info', 'when': 'prompt'},
        },
      );
      await d.openWorkspace(other.path);
      await a.prompt();
      final result = await waitFixture(
        report,
        (p) => p.containsKey('kumikoToolResult'),
      );
      final info =
          ((result['kumikoToolResult'] as Json)['result']
                  as Json)['structuredContent']
              as Json;
      final original = directoryIdentity(work.path) as ResolvedDirectory;
      expect((info['target'] as Json)['path'], original.realPath);
    },
  );

  test(
    'status not yet used until the first successful call, then connected',
    () async {
      final (_, a, _) = await session(
        script: {
          'kumikoTool': {'call': 'kumiko_session_info', 'when': 'prompt'},
        },
      );
      expect(a.started.tools?.status, AgentToolsStatus.notYetUsed);
      final idle = await a.wait(
        Method.agentState,
        where: (p) => p['state'] == 'idle',
      );
      expect(toolsStatus(idle), 'notYetUsed');
      await a.prompt();
      final connected = await a.wait(
        Method.agentState,
        where: (p) => toolsStatus(p) == 'connected',
      );
      expect(toolsStatus(connected), 'connected');
      await turnEnds(a, 1);
      expect(
        a.of(Method.agentState).last['tools'],
        containsPair('status', 'connected'),
      );
    },
  );

  test(
    'first successful call publishes state seq+1 with tools connected',
    () async {
      final (_, a, _) = await session(
        script: {
          'kumikoTool': {'call': 'kumiko_session_info', 'when': 'prompt'},
        },
      );
      await a.prompt();
      await turnEnds(a, 1);
      final states = a.of(Method.agentState);
      final i = states.indexWhere((p) => toolsStatus(p) == 'connected');
      expect(i, greaterThan(0));
      final before = states[i - 1];
      final at = states[i];
      expect(at['seq'], (before['seq'] as int) + 1);
      expect(at['state'], before['state'], reason: 'only the tools changed');
      expect(toolsStatus(before), 'notYetUsed');
      for (var k = 1; k < states.length; k++) {
        expect(
          states[k]['seq'] as int,
          greaterThan(states[k - 1]['seq'] as int),
        );
      }
    },
  );

  test('tools/list alone never yields connected', () async {
    final (_, a, report) = await session(
      script: {
        'kumikoTool': {'when': 'prompt', 'list': true},
      },
    );
    await a.prompt();
    final listed = await waitFixture(
      report,
      (p) => p.containsKey('kumikoToolListed'),
    );
    expect(listed['kumikoToolListed'], ['kumiko_session_info']);
    await turnEnds(a, 1);
    for (final s in a.of(Method.agentState)) {
      expect(toolsStatus(s), isNot('connected'));
    }
    expect(a.of(Method.agentState).last['tools'], {'status': 'notYetUsed'});
  });

  test('first turn end without authentication gives not started, later auth '
      'not yet used, later call connected', () async {
    final (d, a, report) = await session(script: {'reportLaunch': true});
    await a.prompt();
    await turnEnds(a, 1);
    final notStarted = await a.wait(
      Method.agentState,
      where: (p) => toolsStatus(p) == 'notStarted',
    );
    expect(toolsStatus(notStarted), 'notStarted');

    final secret = envValue(entryIn(report)!, 'KUMIKO_TOOL_SECRET');
    final c = await ToolClient.connect(await endpointOf(d));
    addTearDown(c.close);
    c.authenticate(secret);
    expect(await c.readJson(), {'ok': true});
    await a.wait(
      Method.agentState,
      where: (p) =>
          toolsStatus(p) == 'notYetUsed' &&
          p['seq'] as int > (notStarted['seq'] as int),
    );

    c.send({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {
        'name': 'kumiko_session_info',
        'arguments': <String, Object?>{},
      },
    });
    expect((await c.readJson())!['result'], isA<Map<String, Object?>>());
    await a.wait(
      Method.agentState,
      where: (p) => toolsStatus(p) == 'connected',
    );
  });

  test('early authentication never reports not started', () async {
    final (_, a, report) = await session(
      script: {
        'kumikoTool': {'when': 'session/new', 'list': true},
      },
    );
    await waitFixture(report, (p) => p.containsKey('kumikoToolListed'));
    await a.prompt();
    await turnEnds(a, 1);
    for (final s in a.of(Method.agentState)) {
      expect(toolsStatus(s), isNot('notStarted'));
    }
    expect(a.of(Method.agentState).last['tools'], {'status': 'notYetUsed'});
  });

  test('listed version failure shows unavailable with recorded text', () async {
    final (_, a, _) = await session(
      env: {
        'KUMIKO_TEST_TOOL_DELIVERY_FAILURES':
            '[["scripted-acp","test-only","bridge never started"]]',
      },
      script: {
        'kumikoTool': {'call': 'kumiko_session_info', 'when': 'prompt'},
      },
    );
    expect(a.started.tools?.status, AgentToolsStatus.unavailable);
    expect(
      a.started.tools?.reason,
      'for scripted-acp test-only: bridge never started',
    );
    // Observation beats the record.
    await a.prompt();
    await a.wait(
      Method.agentState,
      where: (p) => toolsStatus(p) == 'connected',
    );
  });

  test('listed failure affects only that exact version', () async {
    final (_, a, _) = await session(
      env: {
        'KUMIKO_TEST_TOOL_DELIVERY_FAILURES':
            '[["scripted-acp","1.0.0","old failure"]]',
      },
    );
    expect(a.started.tools?.status, AgentToolsStatus.notYetUsed);
    expect(a.started.tools?.reason, isNull);
  });

  test('continued run starts at not yet used', () async {
    final (d, a, report) = await session(
      script: {
        'kumikoTool': {'call': 'kumiko_session_info', 'when': 'prompt'},
      },
    );
    await a.prompt();
    await a.wait(
      Method.agentState,
      where: (p) => toolsStatus(p) == 'connected',
    );
    final id = a.id;
    await a.close();
    await a.call(Method.agentRelease);
    a.notifications.clear();
    report.writeAsStringSync('');

    final result = AgentContinueResult.fromJson(
      await a.call(Method.agentContinue, {'sessionId': id}),
    );
    expect(result.tools?.status, AgentToolsStatus.notYetUsed);
    a.started = AgentStartResult(
      sessionId: id,
      eventChannel: result.eventChannel,
      adapter: result.adapter,
      capabilities: result.capabilities,
    );
    await a.attach();
    final idle = await a.wait(
      Method.agentState,
      where: (p) => p['state'] == 'idle',
    );
    expect(toolsStatus(idle), 'notYetUsed');
    await d.session.quit();
  });

  test('bridge process gone when close settles', () async {
    final (_, a, report) = await session(
      script: {
        'kumikoTool': {'call': 'kumiko_session_info', 'when': 'prompt'},
      },
    );
    await a.prompt();
    final spawned = await waitFixture(
      report,
      (p) => p.containsKey('kumikoBridgePid'),
    );
    final pid = spawned['kumikoBridgePid'] as int;
    final started = processStartTime(pid)!;
    await waitFixture(report, (p) => p.containsKey('kumikoToolResult'));
    expect(isProcessAlive(pid, started), isTrue);
    await a.close();
    expect(isProcessAlive(pid, started), isFalse);
    expect(LedgerView(profile).units(), isEmpty);
  });

  test('bridge exits on endpoint EOF and reconciliation leaves none', () async {
    final (d, a, report) = await session(
      script: {
        'kumikoTool': {'call': 'kumiko_session_info', 'when': 'prompt'},
        'holdPrompt': true,
      },
    );
    await a.prompt();
    final spawned = await waitFixture(
      report,
      (p) => p.containsKey('kumikoBridgePid'),
    );
    final pid = spawned['kumikoBridgePid'] as int;
    final started = processStartTime(pid)!;
    await waitFixture(report, (p) => p.containsKey('kumikoToolResult'));
    Process.killPid(d.session.pid, ProcessSignal.sigkill);
    await d.session.lost;
    // The bridge sees the endpoint close and leaves on its own.
    await eventually(
      () => !isProcessAlive(pid, started),
      within: const Duration(seconds: 40),
      reason: 'the bridge outlived its host',
    );
    await d.restart();
    await d.waitState();
    expect(isProcessAlive(pid, started), isFalse);
  });
}
