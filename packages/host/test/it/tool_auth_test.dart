import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/agent_support.dart';
import 'support/harness.dart';
import 'support/tool_support.dart';

void main() {
  setUpAll(buildTestHost);

  late Directory profile;
  late Desktop desktop;
  late String endpoint;
  setUp(() async {
    profile = tempDir('toolauth_');
    desktop = await Desktop.start(profile);
    await desktop.waitState();
    endpoint = await endpointOf(desktop);
  });
  tearDown(() async {
    await desktop.dispose();
    await deleteTree(profile);
  });

  Future<ToolClient> client() async {
    final c = await ToolClient.connect(endpoint);
    addTearDown(c.close);
    return c;
  }

  Future<Map<String, Object?>> rpc(
    ToolClient c,
    int id,
    String method, [
    Object? params,
  ]) async {
    c.send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': ?params});
    final r = await c.readJson();
    expect(r, isNotNull, reason: 'connection ended before the answer');
    expect(r!['id'], id);
    return r;
  }

  Map<String, Object?> grantState(Map<String, Object?> state, String id) =>
      (state['grants']! as Map<String, Object?>)[id]! as Map<String, Object?>;

  /// A second host with the agent capability and a scripted ACP fixture: the
  /// grants below are minted, bound and revoked by real sessions.
  Future<(Desktop, AgentPeer, File)> realSession({
    Json script = const {},
    bool attach = true,
  }) async {
    final prof = tempDir('toolauth_agent_profile_');
    final work = tempDir('toolauth_agent_work_');
    addTearDown(() async {
      killReported(work);
      await deleteTree(work);
      await deleteTree(prof);
    });
    final d = await Desktop.start(
      prof,
      capabilities: {...testCapabilities, Capability.agent},
      environment: const {
        'KUMIKO_TEST_RUNTIME_PATH': '',
        'KUMIKO_TEST_SHELL_PATH': '',
      },
    );
    addTearDown(d.dispose);
    await d.waitState();
    final w = await d.openWorkspace(work.path);
    final report = await saveAgentFixture(
      d,
      work,
      script: {'reportLaunch': true, ...script},
    );
    final a = AgentPeer(d);
    await a.start(w.workspace.id);
    if (attach) await a.attach();
    return (d, a, report);
  }

  /// The file as text, or null when the running host holds it locked.
  String? readable(File f) {
    try {
      return latin1.decode(f.readAsBytesSync());
    } on FileSystemException {
      return null;
    }
  }

  String secretIn(File report) {
    final launch = fixtureReports(report).lastWhere(
      (p) => p.containsKey('newCwd'),
    );
    final entry = (launch['mcpServers'] as List).single as Json;
    return [
      for (final e in entry['env'] as List)
        if ((e as Json)['name'] == 'KUMIKO_TOOL_SECRET') e['value'] as String,
    ].single;
  }

  test('correct secret is accepted and served for its session only', () async {
    final a = await newGrant(desktop, target: r'C:\work\a');
    final b = await newGrant(desktop, target: r'C:\work\b');
    final ca = await client();
    ca.authenticate(a.secret);
    expect(await ca.readJson(), {'ok': true});

    final list = await rpc(ca, 1, 'tools/list');
    final tools = (list['result']! as Map)['tools']! as List;
    expect(tools.map((t) => (t as Map)['name']), ['kumiko_session_info']);

    final call = await rpc(ca, 2, 'tools/call', {
      'name': 'kumiko_session_info',
      'arguments': <String, Object?>{},
    });
    final info = (call['result']! as Map)['structuredContent']! as Map;
    expect(info['sessionId'], 'rec-${a.id}');
    expect((info['target']! as Map)['path'], r'C:\work\a');
    expect(info['role'], 'coding');

    final cb = await client();
    cb.authenticate(b.secret);
    expect(await cb.readJson(), {'ok': true});
    final other = await rpc(cb, 1, 'tools/call', {
      'name': 'kumiko_session_info',
      'arguments': <String, Object?>{},
    });
    expect(
      ((other['result']! as Map)['structuredContent']! as Map)['sessionId'],
      'rec-${b.id}',
    );
    final state = await toolState(desktop);
    expect(grantState(state, a.id)['everCalled'], isTrue);
  });

  test('wrong secret is refused before any MCP message', () async {
    final g = await newGrant(desktop);
    final c = await client();
    // Right shape, wrong bytes.
    c.authenticate('B' * 43);
    expect(await c.readJson(), {'ok': false, 'error': 'unauthenticated'});
    expect(await c.closedByHost(), isTrue);

    final state = await toolState(desktop);
    expect((state['authFailures']! as int) >= 1, isTrue);
    expect(grantState(state, g.id)['everAuthenticated'], isFalse);
    expect(grantState(state, g.id)['everCalled'], isFalse);
  });

  test(
    'MCP without preamble or silence past the deadline closes the connection',
    () async {
      final g = await newGrant(desktop);
      final mcp = await client();
      mcp.send({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'});
      expect(await mcp.closedByHost(), isTrue);
      expect(await mcp.readLine(), isNull, reason: 'no answer to MCP');

      final junk = await client();
      junk.send('not json');
      expect(await junk.closedByHost(), isTrue);

      final silent = await client();
      final watch = Stopwatch()..start();
      expect(
        await silent.closedByHost(within: const Duration(seconds: 9)),
        isTrue,
      );
      // The 5 s deadline, on every OS.
      expect(watch.elapsed, greaterThan(const Duration(seconds: 4)));
      expect(watch.elapsed, lessThan(const Duration(seconds: 8)));

      expect(
        grantState(await toolState(desktop), g.id)['everAuthenticated'],
        isFalse,
      );
    },
  );

  test('silent client is disconnected by the host within the deadline and '
      'its slot freed', () async {
    final silent = await client();
    await eventually(
      () async => (await toolState(desktop))['unauthenticated'] == 1,
      reason: 'the silent connection is not counted',
    );
    expect(
      await silent.closedByHost(within: const Duration(seconds: 9)),
      isTrue,
    );
    await eventually(
      () async => (await toolState(desktop))['unauthenticated'] == 0,
      within: const Duration(seconds: 5),
      reason: 'the slot is not free again',
    );
  });

  test(
    'revoked secret is refused after close and after adapter exit',
    () async {
      final (closedHost, closing, closedReport) = await realSession();
      final closedSecret = secretIn(closedReport);
      final live = await ToolClient.connect(await endpointOf(closedHost));
      addTearDown(live.close);
      live.authenticate(closedSecret);
      expect(await live.readJson(), {'ok': true});
      await closing.close();
      expect(await live.closedByHost(), isTrue);
      final afterClose = await ToolClient.connect(await endpointOf(closedHost));
      addTearDown(afterClose.close);
      afterClose.authenticate(closedSecret);
      expect(await afterClose.readJson(), {
        'ok': false,
        'error': 'unauthenticated',
      });
      expect(await afterClose.closedByHost(), isTrue);

      final (exitedHost, exiting, exitedReport) = await realSession(
        script: {
          'prompt': [
            {'exit': 3},
          ],
        },
      );
      final exitedSecret = secretIn(exitedReport);
      await exiting.prompt();
      await exiting.wait(
        Method.agentExited,
        where: (p) => p['reason'] == 'failed',
      );
      final afterExit = await ToolClient.connect(await endpointOf(exitedHost));
      addTearDown(afterExit.close);
      afterExit.authenticate(exitedSecret);
      expect(await afterExit.readJson(), {
        'ok': false,
        'error': 'unauthenticated',
      });
      expect(await afterExit.closedByHost(), isTrue);
    },
  );

  test('call after close is rejected and the connection closed', () async {
    final g = await newGrant(desktop);
    final c = await client();
    c.authenticate(g.secret);
    expect(await c.readJson(), {'ok': true});
    await grantCall(desktop, 'revoke', g.id);
    expect(await c.closedByHost(), isTrue);
    try {
      c.send({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/call',
        'params': {
          'name': 'kumiko_session_info',
          'arguments': <String, Object?>{},
        },
      });
    } on Object {
      // Writing to a closed connection fails: also a rejection.
    }
    final line = await c.readLine();
    expect(line, anyOf(isNull, contains('"error"')));
    expect(grantState(await toolState(desktop), g.id)['live'], isFalse);
  });

  test('16 unauthenticated connections are the cap', () async {
    final held = <ToolClient>[];
    for (var i = 0; i < 16; i++) {
      held.add(await client());
    }
    await eventually(
      () async => (await toolState(desktop))['unauthenticated'] == 16,
      reason: 'not all 16 connections are counted',
    );
    final extra = await client();
    expect(
      await extra.closedByHost(within: const Duration(seconds: 3)),
      isTrue,
    );
    expect(held.where((c) => c.ended), isEmpty);
  });

  test('4 authenticated connections per grant, the fifth is busy', () async {
    final g = await newGrant(desktop);
    final open = <ToolClient>[];
    for (var i = 0; i < 4; i++) {
      final c = await client();
      c.authenticate(g.secret);
      expect(await c.readJson(), {'ok': true});
      open.add(c);
    }
    final fifth = await client();
    fifth.authenticate(g.secret);
    expect(await fifth.readJson(), {'ok': false, 'error': 'busy'});
    expect(await fifth.closedByHost(), isTrue);
    expect(open.where((c) => c.ended), isEmpty);
  });

  test(
    'secret absent from records, control messages and redacted stderr tails',
    () async {
      // A successful session: the secret exists only in the adapter's launch
      // data, never in the store, the log or any control message.
      final prof = tempDir('toolauth_secret_profile_');
      final work = tempDir('toolauth_secret_work_');
      addTearDown(() async {
        killReported(work);
        await deleteTree(work);
        await deleteTree(prof);
      });
      final d = await Desktop.start(
        prof,
        capabilities: {...testCapabilities, Capability.agent},
        environment: const {
          'KUMIKO_TEST_RUNTIME_PATH': '',
          'KUMIKO_TEST_SHELL_PATH': '',
        },
      );
      addTearDown(d.dispose);
      await d.waitState();
      final w = await d.openWorkspace(work.path);
      final report = await saveAgentFixture(
        d,
        work,
        script: {'reportLaunch': true},
      );
      final a = AgentPeer(d);
      await a.start(w.workspace.id);
      await a.attach();
      final secret = secretIn(report);
      await a.prompt();
      await a.wait(Method.agentTurnEnded);
      await a.close();

      final surfaces = <String, String>{
        'start result': jsonEncode(a.started.toJson()),
        'notifications': jsonEncode([
          for (final n in a.notifications) {'method': n.method, 'params': n.params},
        ]),
        for (final f in prof.listSync(recursive: true).whereType<File>())
          if (readable(f) case final String text) f.path: text,
      };
      for (final entry in surfaces.entries) {
        expect(entry.value, isNot(contains(secret)), reason: entry.key);
      }

      // A failed start: the adapter echoes the secret on stderr, the host
      // reports the tail with the secret redacted.
      final failWork = tempDir('toolauth_secret_fail_');
      addTearDown(() async {
        killReported(failWork);
        await deleteTree(failWork);
      });
      final w2 = await d.openWorkspace(failWork.path);
      final failReport = await saveAgentFixture(
        d,
        failWork,
        script: {
          'reportLaunch': true,
          'new': [
            {'stderrSecret': true},
          ],
          'newErrorAfterActions': {'code': -32000, 'message': 'rejected'},
        },
      );
      final b = AgentPeer(d);
      RpcException? failure;
      try {
        await b.start(w2.workspace.id);
      } on RpcException catch (e) {
        failure = e;
      }
      expect(failure, isNotNull);
      final failedSecret = secretIn(failReport);
      final text = jsonEncode({
        'message': failure!.message,
        'data': failure.data,
      });
      expect(text, isNot(contains(failedSecret)));
      expect(text, contains('<redacted>'));
    },
  );
}
