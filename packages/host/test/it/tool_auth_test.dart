import 'dart:io';

import 'package:test/test.dart';

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
      final closed = await newGrant(desktop);
      final exited = await newGrant(desktop);
      // AgentService revokes on close and on adapter exit (task 5.2); here
      // the grants are revoked directly.
      await grantCall(desktop, 'revoke', closed.id);
      await grantCall(desktop, 'revoke', exited.id);
      for (final secret in [closed.secret, exited.secret]) {
        final c = await client();
        c.authenticate(secret);
        expect(await c.readJson(), {'ok': false, 'error': 'unauthenticated'});
        expect(await c.closedByHost(), isTrue);
      }
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
    () {},
    skip: 'enabled by task 5.2',
  );
}
