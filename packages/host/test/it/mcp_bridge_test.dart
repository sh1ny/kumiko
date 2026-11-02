import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/harness.dart';
import 'support/tool_support.dart';

/// A running `kumiko_host --mcp-bridge` with its output collected.
class Bridge {
  Bridge._(this.process) {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_lines.add);
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(errors.add);
    process.exitCode.then(_exit.complete);
  }

  final Process process;
  final _lines = <String>[];
  final errors = <String>[];
  final _exit = Completer<int>();

  static Future<Bridge> start({String? endpoint, String? secret}) async {
    final bridge = Bridge._(
      await Process.start(
        testHostExecutable(),
        ['--mcp-bridge'],
        environment: {
          'KUMIKO_TOOL_ENDPOINT': ?endpoint,
          'KUMIKO_TOOL_SECRET': ?secret,
          'KUMIKO_UNIT': 'marker-is-ignored',
        },
      ),
    );
    addTearDown(bridge.kill);
    return bridge;
  }

  void kill() => process.kill();

  /// Waits for the exit code; fails the test after [within].
  Future<int> exitCode({Duration within = const Duration(seconds: 15)}) =>
      _exit.future.timeout(
        within,
        onTimeout: () => throw TimeoutException('bridge still running'),
      );

  bool get exited => _exit.isCompleted;

  void send(Object message) =>
      process.stdin.writeln(message is String ? message : jsonEncode(message));

  Future<Map<String, Object?>> readJson() async {
    await eventually(() => _lines.isNotEmpty, reason: 'no stdout line');
    return jsonDecode(_lines.removeAt(0)) as Map<String, Object?>;
  }

  List<String> get unreadLines => List.of(_lines);
}

void main() {
  setUpAll(buildTestHost);

  group('without a usable host', () {
    Future<void> expectFails(Bridge b) async {
      // stdin stays open: the bridge must not wait for it.
      final code = await b.exitCode();
      expect(code, 2);
      await eventually(() => b.errors.isNotEmpty, reason: 'no stderr line');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(b.errors, hasLength(1));
      expect(b.unreadLines, isEmpty);
    }

    test(
      'missing endpoint or variables exit non-zero with one stderr line',
      () async {
        await expectFails(await Bridge.start());
        await expectFails(await Bridge.start(secret: 'A' * 43));
        await expectFails(await Bridge.start(endpoint: 'x'));

        final missing = Platform.isWindows
            ? r'\\.\pipe\kumiko-tools-does-not-exist'
            : joinPath(tempDir('nobridge_').path, 'tools.sock');
        await expectFails(
          await Bridge.start(endpoint: missing, secret: 'A' * 43),
        );
      },
    );
  });

  group('with a live host', () {
    late Directory profile;
    late Desktop desktop;
    late String endpoint;
    setUp(() async {
      profile = tempDir('bridge_');
      desktop = await Desktop.start(profile);
      await desktop.waitState();
      endpoint = await endpointOf(desktop);
    });
    tearDown(() async {
      await desktop.dispose();
      await deleteTree(profile);
    });

    test('authenticates and relays MCP both ways', () async {
      final g = await newGrant(desktop, target: r'C:\work\bridge');
      final b = await Bridge.start(endpoint: endpoint, secret: g.secret);

      b.send({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {'protocolVersion': '2025-06-18'},
      });
      final init = await b.readJson();
      expect(init['id'], 1);
      expect((init['result']! as Map)['protocolVersion'], '2025-06-18');

      b.send({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {
          'name': 'kumiko_session_info',
          'arguments': <String, Object?>{},
        },
      });
      final call = await b.readJson();
      final info = (call['result']! as Map)['structuredContent']! as Map;
      expect(info['sessionId'], 'rec-${g.id}');
      expect((info['target']! as Map)['path'], r'C:\work\bridge');
      expect(b.errors, isEmpty);
      expect(b.unreadLines, isEmpty, reason: 'the {"ok":true} stays internal');
    });

    test('exits on stdin EOF and the host drops the connection', () async {
      final g = await newGrant(desktop);
      final b = await Bridge.start(endpoint: endpoint, secret: g.secret);
      b.send({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'});
      await b.readJson();
      await b.process.stdin.close();
      expect(await b.exitCode(), 0);
      await eventually(
        () async => (await toolState(desktop))['authenticated'] == 0,
        reason: 'the host still counts the bridge connection',
      );
    });

    test('exits on endpoint EOF', () async {
      final g = await newGrant(desktop);
      final b = await Bridge.start(endpoint: endpoint, secret: g.secret);
      b.send({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'});
      await b.readJson();
      // Revoking closes the grant's connections from the host side.
      await grantCall(desktop, 'revoke', g.id);
      await b.exitCode();
      expect(b.errors.length, lessThanOrEqualTo(1));
    });

    test('exits non-zero on a refused secret', () async {
      await newGrant(desktop);
      final b = await Bridge.start(endpoint: endpoint, secret: 'C' * 43);
      // stdin stays open; the refusal alone ends the bridge.
      b.send({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'});
      expect(await b.exitCode(), 2);
      await eventually(() => b.errors.isNotEmpty, reason: 'no stderr line');
      expect(b.errors, hasLength(1));
      expect(b.unreadLines, isEmpty);
    });
  });
}
