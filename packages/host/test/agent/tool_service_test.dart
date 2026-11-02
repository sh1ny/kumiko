import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:host/src/agent/tools/tool_catalog.dart';
import 'package:host/src/agent/tools/tool_service.dart';
import 'package:test/test.dart';

/// In-memory transport for the tool service.
class FakeConnection implements ToolConnection {
  final _input = StreamController<List<int>>();
  final _closed = Completer<void>();
  final _waiters = <Completer<Map<String, Object?>>>[];
  final _pending = <Map<String, Object?>>[];
  final _partial = BytesBuilder();
  final raw = <int>[];
  bool closeCalled = false;

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  void add(List<int> bytes) {
    if (_closed.isCompleted) throw StateError('closed');
    raw.addAll(bytes);
    for (final b in bytes) {
      if (b == 10) {
        final line = utf8.decode(_partial.takeBytes());
        final msg = jsonDecode(line) as Map<String, Object?>;
        if (_waiters.isNotEmpty) {
          _waiters.removeAt(0).complete(msg);
        } else {
          _pending.add(msg);
        }
      } else {
        _partial.addByte(b);
      }
    }
  }

  @override
  Future<void> close() {
    closeCalled = true;
    if (!_closed.isCompleted) _closed.complete();
    return _closed.future;
  }

  bool get isClosed => _closed.isCompleted;
  Future<void> get closed => _closed.future;

  void send(Object? message) => sendRaw('${jsonEncode(message)}\n');
  void sendRaw(String text) => _input.add(utf8.encode(text));
  void sendBytes(List<int> bytes) => _input.add(bytes);
  Future<void> eof() => _input.close();

  Future<Map<String, Object?>> next() {
    if (_pending.isNotEmpty) return Future.value(_pending.removeAt(0));
    final c = Completer<Map<String, Object?>>();
    _waiters.add(c);
    return c.future.timeout(const Duration(seconds: 5));
  }

  /// Lets the service process everything queued so far.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  List<Map<String, Object?>> get unread => List.of(_pending);
}

ToolGrant newGrant(
  ToolService s, {
  void Function()? onAuthenticated,
  void Function()? onCallSucceeded,
}) => s.register(
  target: r'C:\work\proj',
  role: ToolRole.coding,
  runtime: 'claude-code',
  profile: 'default',
  onAuthenticated: onAuthenticated,
  onCallSucceeded: onCallSucceeded,
);

Future<FakeConnection> connect(ToolService s, ToolGrant g) async {
  final c = FakeConnection();
  s.accept(c);
  c.send({'kumikoBridge': 1, 'secret': g.secret});
  final answer = await c.next();
  expect(answer, {'ok': true});
  return c;
}

Map<String, Object?> req(int id, String method, [Object? params]) => {
  'jsonrpc': '2.0',
  'id': id,
  'method': method,
  'params': ?params,
};

Map<String, Object?> callReq(int id, String name, [Object? args]) =>
    req(id, 'tools/call', {'name': name, 'arguments': ?args});

void main() {
  late ToolService service;
  setUp(() {
    service = ToolService(preambleDeadline: const Duration(milliseconds: 150));
  });
  tearDown(() => service.close());

  group('grants', () {
    test('register mints distinct 32-byte base64url secrets', () {
      final a = newGrant(service);
      final b = newGrant(service);
      expect(a.secret, isNot(b.secret));
      expect(a.secret, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(base64Url.decode(base64Url.normalize(a.secret)), hasLength(32));
      expect(a.everAuthenticated, isFalse);
      expect(a.everCalled, isFalse);
      expect(a.isLive, isTrue);
    });

    test('constantTimeEquals compares bytes and lengths', () {
      expect(constantTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
      expect(constantTimeEquals([1, 2, 3], [1, 2, 4]), isFalse);
      expect(constantTimeEquals([1, 2, 3], [1, 2]), isFalse);
      expect(constantTimeEquals(const [], const []), isTrue);
    });

    test(
      'revoke marks the grant dead and its secret stops authenticating',
      () async {
        final g = newGrant(service);
        g.revoke();
        expect(g.isLive, isFalse);
        final c = FakeConnection();
        service.accept(c);
        c.send({'kumikoBridge': 1, 'secret': g.secret});
        expect(await c.next(), {'ok': false, 'error': 'unauthenticated'});
        await c.closed;
      },
    );
  });

  group('handshake', () {
    test('a matching secret is answered ok and flags the grant', () async {
      var authenticated = 0;
      final g = newGrant(service, onAuthenticated: () => authenticated++);
      final c = await connect(service, g);
      expect(g.everAuthenticated, isTrue);
      expect(authenticated, 1);
      expect(c.isClosed, isFalse);
    });

    test('a wrong secret is refused and the connection closed', () async {
      newGrant(service);
      final c = FakeConnection();
      service.accept(c);
      final wrong = base64Url.encode(List.filled(32, 7)).replaceAll('=', '');
      c.send({'kumikoBridge': 1, 'secret': wrong});
      expect(await c.next(), {'ok': false, 'error': 'unauthenticated'});
      await c.closed;
    });

    test('a non-JSON first line closes without an answer', () async {
      final c = FakeConnection();
      service.accept(c);
      c.sendRaw('hello\n');
      await c.closed;
      expect(c.raw, isEmpty);
    });

    test('an MCP message as first line closes and is not processed', () async {
      final g = newGrant(service);
      final c = FakeConnection();
      service.accept(c);
      c.send(req(1, 'ping'));
      await c.closed;
      expect(c.raw, isEmpty);
      expect(g.everAuthenticated, isFalse);
    });

    test('a preamble over 512 bytes closes the connection', () async {
      final c = FakeConnection();
      service.accept(c);
      c.sendBytes(List.filled(600, 0x61));
      await c.closed;
      expect(c.raw, isEmpty);
    });

    test(
      'a silent connection is closed at the deadline and its slot freed',
      () async {
        final c = FakeConnection();
        service.accept(c);
        expect(service.unauthenticatedCount, 1);
        await c.closed.timeout(const Duration(seconds: 2));
        await c.settle();
        expect(service.unauthenticatedCount, 0);
      },
    );

    test('17th unauthenticated connection is closed at once', () async {
      final held = [for (var i = 0; i < 16; i++) FakeConnection()];
      held.forEach(service.accept);
      expect(service.unauthenticatedCount, 16);
      final extra = FakeConnection();
      service.accept(extra);
      await extra.closed;
      expect(held.any((c) => c.isClosed), isFalse);
    });

    test('a fifth connection for one grant is answered busy', () async {
      final g = newGrant(service);
      final open = [for (var i = 0; i < 4; i++) await connect(service, g)];
      final c = FakeConnection();
      service.accept(c);
      c.send({'kumikoBridge': 1, 'secret': g.secret});
      expect(await c.next(), {'ok': false, 'error': 'busy'});
      await c.closed;
      expect(open.any((o) => o.isClosed), isFalse);
      // A freed slot is usable again.
      await open.first.eof();
      await open.first.closed;
      await open.first.settle();
      await connect(service, g);
    });
  });

  group('MCP subset', () {
    late ToolGrant grant;
    late FakeConnection c;
    setUp(() async {
      grant = newGrant(service);
      c = await connect(service, grant);
    });

    test('initialize echoes a supported protocol version', () async {
      c.send(
        req(1, 'initialize', {
          'protocolVersion': '2025-03-26',
          'capabilities': <String, Object?>{},
          'clientInfo': {'name': 'x', 'version': '1'},
        }),
      );
      final r = await c.next();
      expect(r['id'], 1);
      final result = r['result'] as Map<String, Object?>;
      expect(result['protocolVersion'], '2025-03-26');
      expect(
        result['capabilities'],
        containsPair('tools', isA<Map<String, Object?>>()),
      );
      expect(result['serverInfo'], isA<Map<String, Object?>>());
    });

    test('initialize answers the newest version for an unknown one', () async {
      c.send(req(1, 'initialize', {'protocolVersion': '1999-01-01'}));
      final result = (await c.next())['result'] as Map<String, Object?>;
      expect(result['protocolVersion'], '2025-06-18');
    });

    test('ping answers an empty result', () async {
      c.send(req(7, 'ping'));
      expect(await c.next(), {
        'jsonrpc': '2.0',
        'id': 7,
        'result': <String, Object?>{},
      });
    });

    test('unknown requests get -32601', () async {
      c.send(req(3, 'resources/list'));
      final r = await c.next();
      expect(r['id'], 3);
      expect((r['error'] as Map)['code'], -32601);
    });

    test('notifications are never answered', () async {
      c.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
      c.send({'jsonrpc': '2.0', 'method': 'notifications/whatever'});
      c.send(req(9, 'ping'));
      expect((await c.next())['id'], 9);
      await c.settle();
      expect(c.unread, isEmpty);
    });

    test(
      'a malformed line gets -32700 and the connection stays open',
      () async {
        c.sendRaw('{not json\n');
        final r = await c.next();
        expect(r['id'], isNull);
        expect((r['error'] as Map)['code'], -32700);
        c.send(req(1, 'ping'));
        expect((await c.next())['id'], 1);
        expect(c.isClosed, isFalse);
      },
    );

    test('notifications/cancelled drops an in-flight call result', () async {
      c.send(callReq(5, 'kumiko_session_info', <String, Object?>{}));
      await c.settle();
      c.send({
        'jsonrpc': '2.0',
        'method': 'notifications/cancelled',
        'params': {'requestId': 5, 'reason': 'user'},
      });
      await c.settle();
      grant
        ..setAdapter('claude-agent-acp', '0.99.1')
        ..bind('sess-1');
      await c.settle();
      c.send(req(6, 'ping'));
      expect((await c.next())['id'], 6);
      expect(c.unread, isEmpty);
    });

    test('a line over 1 MiB closes the connection', () async {
      c.sendBytes(List.filled(1024 * 1024 + 10, 0x20));
      await c.closed;
    });

    test(
      'a 9th concurrent call gets -32000 too many concurrent calls',
      () async {
        for (var i = 1; i <= 8; i++) {
          c.send(callReq(i, 'kumiko_session_info', <String, Object?>{}));
        }
        c.send(callReq(9, 'kumiko_session_info', <String, Object?>{}));
        final r = await c.next();
        expect(r['id'], 9);
        expect((r['error'] as Map)['code'], -32000);
        expect((r['error'] as Map)['message'], 'too many concurrent calls');
        // The first eight are still waiting on the binding and then answer.
        grant
          ..setAdapter('a', '1')
          ..bind('s');
        final ids = {for (var i = 0; i < 8; i++) (await c.next())['id']};
        expect(ids, {1, 2, 3, 4, 5, 6, 7, 8});
      },
    );

    test('a closed connection releases its calls waiting on the binding', () async {
      // Authenticate, fill the in-flight cap and disconnect, repeatedly,
      // while session/new is still pending: nothing stays allocated.
      for (var round = 0; round < 4; round++) {
        final peer = round == 0 ? c : await connect(service, grant);
        for (var i = 1; i <= 8; i++) {
          peer.send(callReq(i, 'kumiko_session_info', <String, Object?>{}));
          await peer.settle();
          if (i == 4) {
            peer.send({
              'jsonrpc': '2.0',
              'method': 'notifications/cancelled',
              'params': {'requestId': 4},
            });
          }
        }
        await peer.settle();
        expect(grant.pendingBindingWaiters, 8);
        await peer.eof();
        await peer.closed;
        await peer.settle();
        expect(grant.pendingBindingWaiters, 0, reason: 'round $round');
      }
      // A live connection's waiter is still answered after binding.
      final live = await connect(service, grant);
      live.send(callReq(1, 'kumiko_session_info', <String, Object?>{}));
      await live.settle();
      grant
        ..setAdapter('a', '1')
        ..bind('s');
      expect((await live.next())['id'], 1);
      expect(grant.pendingBindingWaiters, 0);
    });

    test('a request ID already in flight is rejected, not replaced', () async {
      c.send(callReq(1, 'kumiko_session_info', <String, Object?>{}));
      for (var i = 0; i < 10; i++) {
        c.send(callReq(1, 'kumiko_session_info', <String, Object?>{}));
        final r = await c.next();
        expect(r['id'], 1);
        expect((r['error'] as Map)['code'], -32600);
      }
      // The first call still holds its slot: seven more fit, the ninth not.
      for (var i = 2; i <= 8; i++) {
        c.send(callReq(i, 'kumiko_session_info', <String, Object?>{}));
      }
      c.send(callReq(9, 'kumiko_session_info', <String, Object?>{}));
      final r = await c.next();
      expect(r['id'], 9);
      expect((r['error'] as Map)['message'], 'too many concurrent calls');
      grant
        ..setAdapter('a', '1')
        ..bind('s');
      final ids = [for (var i = 0; i < 8; i++) (await c.next())['id']];
      expect(ids.toSet(), {1, 2, 3, 4, 5, 6, 7, 8});
      await c.settle();
      expect(c.unread, isEmpty);
    });

    test(
      'cancelled calls waiting on the binding still count until they settle',
      () async {
        for (var i = 1; i <= 8; i++) {
          c.send(callReq(i, 'kumiko_session_info', <String, Object?>{}));
          await c.settle();
          c.send({
            'jsonrpc': '2.0',
            'method': 'notifications/cancelled',
            'params': {'requestId': i},
          });
        }
        await c.settle();
        expect(c.unread, isEmpty);
        // Eight cancelled calls still await the binding: no capacity freed.
        c.send(callReq(9, 'kumiko_session_info', <String, Object?>{}));
        final r = await c.next();
        expect(r['id'], 9);
        expect((r['error'] as Map)['message'], 'too many concurrent calls');
        // Once the binding settles them, capacity returns; no cancelled
        // result is ever sent.
        grant
          ..setAdapter('a', '1')
          ..bind('s');
        await c.settle();
        c.send(callReq(10, 'kumiko_session_info', <String, Object?>{}));
        expect((await c.next())['id'], 10);
        await c.settle();
        expect(c.unread, isEmpty);
      },
    );
  });

  group('tool catalog', () {
    test('coding role holds exactly kumiko_session_info', () {
      final tools = ToolCatalog.toolsFor(ToolRole.coding);
      expect(tools.map((t) => t.name), ['kumiko_session_info']);
      final json = tools.single.toJson();
      expect(json['inputSchema'], {
        'type': 'object',
        'properties': <String, Object?>{},
        'additionalProperties': false,
      });
      expect(json['annotations'], {'readOnlyHint': true});
      expect(json['description'], isA<String>());
      expect(ToolCatalog.find(ToolRole.coding, 'nope'), isNull);
    });
  });

  group('kumiko_session_info', () {
    late ToolGrant grant;
    late FakeConnection c;
    setUp(() async {
      grant = newGrant(service);
      c = await connect(service, grant);
    });

    test('Permitted tool for the coding role', () async {
      c.send(req(1, 'tools/list'));
      final list = (await c.next())['result'] as Map<String, Object?>;
      final tools = list['tools'] as List;
      expect(tools.map((t) => (t as Map)['name']), ['kumiko_session_info']);

      grant
        ..setAdapter('claude-agent-acp', '0.99.1')
        ..bind('rec-42');
      c.send(callReq(2, 'kumiko_session_info', <String, Object?>{}));
      final r = await c.next();
      final result = r['result'] as Map<String, Object?>;
      expect(result['structuredContent'], {
        'sessionId': 'rec-42',
        'role': 'coding',
        'runtime': 'claude-code',
        'adapter': {'name': 'claude-agent-acp', 'version': '0.99.1'},
        'target': {'path': r'C:\work\proj'},
      });
      final content = result['content'] as List;
      expect((content.single as Map)['type'], 'text');
      expect(
        jsonDecode((content.single as Map)['text'] as String),
        result['structuredContent'],
      );
      expect(grant.everCalled, isTrue);
    });

    test('a call without arguments is also valid', () async {
      grant
        ..setAdapter('a', '1')
        ..bind('s');
      c.send(callReq(1, 'kumiko_session_info'));
      expect((await c.next())['result'], isA<Map<String, Object?>>());
    });

    test('callSucceeded is reported to the listener', () async {
      var calls = 0;
      final g = newGrant(service, onCallSucceeded: () => calls++);
      final conn = await connect(service, g);
      g
        ..setAdapter('a', '1')
        ..bind('s');
      conn.send(callReq(1, 'kumiko_session_info', <String, Object?>{}));
      await conn.next();
      expect(calls, 1);
    });

    test('Tool not permitted for the role', () async {
      c.send(callReq(1, 'rm_rf_everything', <String, Object?>{}));
      final r = await c.next();
      final error = r['error'] as Map;
      expect(error['code'], -32602);
      expect(error['message'], 'tool rm_rf_everything is not available');
      expect(grant.everCalled, isFalse);
    });

    test('Arguments name another session', () async {
      grant
        ..setAdapter('a', '1')
        ..bind('mine');
      c.send(callReq(1, 'kumiko_session_info', {'sessionId': 'theirs'}));
      final r = await c.next();
      expect((r['error'] as Map)['code'], -32602);
      expect(r.containsKey('result'), isFalse);
      expect(grant.everCalled, isFalse);
    });

    test('non-object arguments are invalid', () async {
      c.send(callReq(1, 'kumiko_session_info', [1]));
      expect(((await c.next())['error'] as Map)['code'], -32602);
    });

    test('waits for the binding, then answers', () async {
      c.send(callReq(1, 'kumiko_session_info', <String, Object?>{}));
      await c.settle();
      expect(c.unread, isEmpty);
      grant
        ..setAdapter('a', '1')
        ..bind('late');
      final r = await c.next();
      expect(
        ((r['result'] as Map)['structuredContent'] as Map)['sessionId'],
        'late',
      );
    });

    test('fail answers waiting calls with session unavailable', () async {
      c.send(callReq(1, 'kumiko_session_info', <String, Object?>{}));
      await c.settle();
      grant.fail('adapter rejected session/new');
      final r = await c.next();
      expect((r['error'] as Map)['code'], -32000);
      expect((r['error'] as Map)['message'], 'session unavailable');
    });

    test(
      'revoke answers in-flight calls and closes open connections',
      () async {
        final other = await connect(service, grant);
        c.send(callReq(1, 'kumiko_session_info', <String, Object?>{}));
        await c.settle();
        grant.revoke();
        final r = await c.next();
        expect((r['error'] as Map)['code'], -32000);
        await c.closed;
        await other.closed;
      },
    );

    test('a call after revoke is refused', () async {
      grant.revoke();
      await c.closed;
      expect(grant.isLive, isFalse);
    });
  });
}
