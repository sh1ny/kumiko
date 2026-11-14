import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:host/src/agent/acp/acp_client.dart';
import 'package:host/src/agent/codex/codex_client.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/acp_peer.dart';
import 'support/codex_peer.dart';

void main() {
  late CodexPeer p;
  setUp(() => p = CodexPeer());
  tearDown(() => p.dispose());
  Future<int> request([String method = 'test']) => p.client.request(
    method,
    {},
    decodeResult: (result) => (result as Json)['value']! as int,
  );

  test('initialize completes before initialized and omits jsonrpc', () async {
    p.onWrite = (message) {
      if (message['method'] == 'initialize') {
        p.result(message['id']!, {
          'userAgent': 'codex/0.166.0',
          'platformFamily': 'windows',
          'platformOs': 'windows',
          'codexHome': '/native/home',
          'futureField': true,
        });
      }
    };
    expect((await p.client.initialize()).userAgent, 'codex/0.166.0');
    expect(p.writes.map((w) => w['method']), ['initialize', 'initialized']);
    expect(p.writes.every((w) => !w.containsKey('jsonrpc')), isTrue);
  });

  test('malformed initialize fails the transport', () async {
    p.onWrite = (message) => p.result(message['id']!, {'userAgent': 9});
    await expectLater(
      p.client.initialize(),
      throwsA(isA<CodexProtocolException>()),
    );
    expect(p.client.isClosed, isTrue);
  });

  test(
    'malformed native JSON never includes source text in diagnostics',
    () async {
      const privateValue = 'fixture-private-native-configuration';
      final outcome = request().then<Object?>(
        (value) => value,
        onError: (Object error) => error,
      );
      p.input.add(utf8.encode('{"private":"$privateValue", broken}\n'));
      final error = await outcome;
      expect(error, isA<CodexProtocolException>());
      expect(error.toString().contains(privateValue), isFalse);
      expect(p.client.isClosed, isTrue);
    },
  );

  test(
    'requests are correlated before write can expose early native request',
    () async {
      final requests = <String>[];
      p.client.onRequest = (id, method, params) {
        requests.add(method);
        p.client.reply(id, {'decision': 'decline'}).ignore();
        return null;
      };
      p.onWrite = (message) {
        if (message['method'] == 'test') {
          p.send({'id': 'approval', 'method': 'approval', 'params': {}});
          p.result(message['id']!, {'value': 7});
        }
      };
      expect(await request(), 7);
      expect(requests, ['approval']);
      expect(p.writes.last['result'], {'decision': 'decline'});
    },
  );

  test('out of order and partial UTF8 responses use exact ids', () async {
    final a = request();
    final b = request();
    final result = utf8.encode(
      '${jsonEncode({
        'id': p.writes[1]['id'],
        'result': {'value': 2, 'extra': '猫'},
      })}\n',
    );
    for (final byte in result) {
      p.input.add([byte]);
    }
    p.result(p.writes[0]['id']!, {'value': 1});
    expect(await b, 2);
    expect(await a, 1);
  });

  test(
    'unknown optional events are ignored and optional shape failure is local',
    () async {
      final unavailable = <String>[];
      p.client.onUnsupported = (feature, reason) =>
          unavailable.add('$feature:$reason');
      p.client.normalizeNotification = (method, params) {
        if (method == 'optional') {
          throw CodexOptionalUnsupported('children', 'shape changed');
        }
        return null;
      };
      p.event('future/event', {'new': true});
      p.event('optional', {});
      await pumpCodex();
      expect(unavailable, ['children:shape changed']);
      expect(p.client.isClosed, isFalse);
      final call = request();
      p.result(p.writes.last['id']!, {'value': 1});
      expect(await call, 1);
    },
  );

  test('malformed known core event fails all pending requests', () async {
    p.client.normalizeNotification = (_, _) =>
        throw CodexProtocolException('missing core turn');
    final call = request();
    final checked = expectLater(call, throwsA(isA<CodexProtocolException>()));
    p.event('turn/completed', {});
    await checked;
    expect(p.client.isClosed, isTrue);
  });

  test('optional result settles before a failed unsupported notice closes transport', () async {
    var settled = false;
    p.client.onUnsupported = (_, _) =>
        throw StateError('notice delivery failed');
    final call = p.client.request<int>(
      'optional/history',
      {},
      decodeResult: (_) {
        throw CodexOptionalUnsupported('history', 'changed shape');
      },
    );
    final outcome = call.then<Object?>(
      (value) {
        settled = true;
        return value;
      },
      onError: (Object error) {
        settled = true;
        return error;
      },
    );
    p.result(p.writes.single['id']!, {});
    await p.client.done;
    await pumpCodex();
    expect(
      settled,
      isTrue,
      reason: 'removed optional request must not be orphaned',
    );
    expect(await outcome, isA<CodexOptionalUnsupported>());
    expect(p.client.failure.toString(), contains('notice delivery failed'));
  });

  for (final params in [
    <Object?>['new-shape'],
    17,
    null,
  ]) {
    test(
      'unknown and optional non-object params stay feature-local $params',
      () async {
        final unavailable = <String>[];
        p.client.onUnsupported = (feature, reason) => unavailable.add(feature);
        p.client.normalizeNotification = (method, params) {
          if (method == 'optional/children') {
            throw CodexOptionalUnsupported('children', 'metadata changed');
          }
          if (method == 'turn/completed') {
            throw CodexProtocolException('missing core turn');
          }
          return null;
        };
        p.send({'method': 'unknown/future', 'params': params});
        p.send({'method': 'optional/children', 'params': params});
        await pumpCodex();
        expect(unavailable, ['children']);
        expect(p.client.isClosed, isFalse);
        final call = request();
        p.result(p.writes.last['id']!, {'value': 9});
        expect(await call, 9);
        p.send({'method': 'turn/completed', 'params': params});
        await pumpCodex();
        expect(p.client.failure, isA<CodexProtocolException>());
      },
    );
  }

  test('unknown server requests are denied without granting', () async {
    p.send({'id': 'unknown', 'method': 'future/privileged', 'params': {}});
    await pumpCodex();
    expect((p.writes.single['error'] as Json)['code'], -32601);
  });

  for (final id in [null, 1.5, true, <String, Object?>{}, <Object?>[]]) {
    test('explicit invalid request id fails native envelope $id', () async {
      p.send({'id': id, 'method': 'unknown/request', 'params': {}});
      await pumpCodex();
      expect(p.client.failure, isA<CodexProtocolException>());
      expect(p.writes, isEmpty);
    });
  }

  for (final payload in [
    <Object?>['changed'],
    5,
  ]) {
    test(
      'optional result shape downgrade preserves core requests $payload',
      () async {
        final notices = <String>[];
        p.client.onUnsupported = (feature, reason) => notices.add(feature);
        final optional = p.client.request<int>(
          'optional/history',
          {},
          decodeResult: (Object? result) {
            throw CodexOptionalUnsupported(
              'history',
              'unsupported result shape',
            );
          },
        );
        final checked = expectLater(
          optional,
          throwsA(isA<CodexOptionalUnsupported>()),
        );
        p.send({'id': p.writes.last['id'], 'result': payload});
        await checked;
        expect(notices, ['history']);
        expect(p.client.isClosed, isFalse);
        final core = request();
        p.result(p.writes.last['id']!, {'value': 4});
        expect(await core, 4);
      },
    );
    test('malformed core result closes transport $payload', () async {
      final core = p.client.request<int>(
        'turn/start',
        {},
        decodeResult: (Object? result) {
          if (result is! Json) {
            throw CodexProtocolException('core result is not an object');
          }
          return result['value']! as int;
        },
      );
      final checked = expectLater(core, throwsA(isA<CodexProtocolException>()));
      p.send({'id': p.writes.last['id'], 'result': payload});
      await checked;
      expect(p.client.isClosed, isTrue);
    });
    test('unknown request non-object params are denied $payload', () async {
      p.send({'id': 'unknown', 'method': 'future/request', 'params': payload});
      await pumpCodex();
      expect(p.client.isClosed, isFalse);
      expect((p.writes.single['error'] as Json)['code'], -32601);
    });
    test(
      'optional request params downgrade but core approvals fail $payload',
      () async {
        p.client.onRequest = (id, method, params) {
          if (method == 'optional/question') {
            throw CodexOptionalUnsupported('questions', 'shape changed');
          }
          throw CodexProtocolException('core approval is malformed');
        };
        final notices = <String>[];
        p.client.onUnsupported = (feature, reason) => notices.add(feature);
        p.send({
          'id': 'question',
          'method': 'optional/question',
          'params': payload,
        });
        await pumpCodex();
        expect(p.client.isClosed, isFalse);
        expect(notices, ['questions']);
        expect((p.writes.single['error'] as Json)['code'], -32602);
        p.send({
          'id': 'approval',
          'method': 'item/commandExecution/requestApproval',
          'params': payload,
        });
        await pumpCodex();
        expect(p.client.failure, isA<CodexProtocolException>());
      },
    );
  }

  for (final partial in [false, true]) {
    test('EOF fails pending and closes transport partial=$partial', () async {
      final call = request();
      final checked = expectLater(call, throwsA(isA<CodexProtocolException>()));
      if (partial) p.input.add(utf8.encode('{"id":'));
      await p.input.close();
      await checked;
      expect(p.client.isClosed, isTrue);
    });
  }

  test('response cannot hide a later admitted write failure', () async {
    p.blockedWrite = Completer<void>();
    final call = request();
    p.result(p.writes.single['id']!, {'value': 1});
    expect(await call, 1);
    p.blockedWrite!.completeError(StateError('native write failed'));
    await p.client.done;
    expect(p.client.isClosed, isTrue);
    expect(p.client.failure.toString(), contains('native write failed'));
  });

  test('32 request bound refuses before observable write', () async {
    final calls = <Future<int>>[];
    for (var i = 0; i < 32; i++) {
      calls.add(request());
    }
    await expectLater(request(), throwsA(isA<RpcException>()));
    expect(p.writes.length, 32);
    for (var i = 0; i < 32; i++) {
      p.result(p.writes[i]['id']!, {'value': i});
    }
    expect(await Future.wait(calls), List.generate(32, (i) => i));
  });

  test(
    'interrupt batch refuses all replies and turns at the pending bound',
    () async {
      final calls = [for (var i = 0; i < 31; i++) request()];
      await expectLater(
        () => p.client.interruptBatch(
          {'root': 'r', 'child': 'c'},
          [
            {
              'id': 'approval',
              'result': {'decision': 'cancel'},
            },
          ],
          (_, _) => fail('refused batch must not install callbacks'),
        ),
        throwsA(isA<RpcException>()),
      );
      expect(p.writes, hasLength(31));
      for (var i = 0; i < 31; i++) {
        p.result(p.writes[i]['id']!, {'value': i});
      }
      expect(await Future.wait(calls), List.generate(31, (i) => i));
      final admitted = p.client.interruptBatch(
        {'root': 'r', 'child': 'c'},
        [],
        (_, _) => fail('unexpected rejection'),
      );
      expect(p.writes.skip(31).map((m) => m['id']), [32, 33]);
      for (final write in p.writes.skip(31)) {
        p.result(write['id']!, {});
      }
      await admitted;
    },
  );

  test(
    'interrupt batch refuses before any reply when native stdin is full',
    () async {
      p.blockedWrite = Completer<void>();
      final fill = p.client.notify('fill', {
        'text': 'x' * (unitPipeQueueLimit - 100),
      });
      await expectLater(
        () => p.client.interruptBatch(
          {'root': 'r', 'child': 'c'},
          [
            {
              'id': 'approval',
              'result': {'decision': 'cancel'},
            },
          ],
          (_, _) => fail('refused batch must not install callbacks'),
        ),
        throwsA(isA<RpcException>()),
      );
      expect(p.writes, hasLength(1));
      p.blockedWrite!.complete();
      await fill;
      p.blockedWrite = null;
      final call = request();
      expect(p.writes.last['id'], 1);
      p.result(p.writes.last['id']!, {'value': 7});
      expect(await call, 7);
    },
  );

  test(
    'interrupt batch registers every turn before early native acknowledgements',
    () async {
      p.blockedWrite = Completer<void>();
      p.onWrite = (write) {
        if (write['method'] == 'turn/interrupt') p.result(write['id']!, {});
      };
      await p.client.interruptBatch(
        {'root': 'r', 'child': 'c'},
        [
          {
            'id': 'approval',
            'result': {'decision': 'cancel'},
          },
        ],
        (_, _) => fail('early acknowledgements must correlate'),
      );
      expect(p.writes.map((m) => m['id']), ['approval', 1, 2]);
      expect(p.writes.skip(1).map((m) => m['params']), [
        {'threadId': 'root', 'turnId': 'r'},
        {'threadId': 'child', 'turnId': 'c'},
      ]);
      expect(p.client.isClosed, isFalse);
      p.blockedWrite!.complete();
      await pumpCodex();
    },
  );

  test(
    'acknowledged interrupt batch cannot hide a later native write failure',
    () async {
      p.blockedWrite = Completer<void>();
      p.onWrite = (write) => p.result(write['id']!, {});
      await p.client.interruptBatch(
        {'root': 'r', 'child': 'c'},
        [],
        (_, _) => fail('unexpected rejection'),
      );
      p.blockedWrite!.completeError(StateError('batch native write failed'));
      await p.client.done;
      expect(p.client.isClosed, isTrue);
      expect(
        p.client.failure.toString(),
        contains('batch native write failed'),
      );
    },
  );

  test(
    'interrupt batch reports an unsupported child without claiming completion',
    () async {
      final rejected = <String, Object>{};
      p.onWrite = (write) {
        if ((write['params']! as Json)['threadId'] == 'child') {
          p.send({
            'id': write['id'],
            'error': {'code': -32601, 'message': 'unsupported child interrupt'},
          });
        } else {
          p.result(write['id']!, {});
        }
      };
      await p.client.interruptBatch(
        {'root': 'r', 'child': 'c'},
        [],
        (thread, error) => rejected[thread] = error,
      );
      expect(rejected.keys, ['child']);
      expect(rejected['child'], isA<CodexRemoteException>());
      expect(p.client.isClosed, isFalse);
      p.onWrite = null;
      final call = request();
      p.result(p.writes.last['id']!, {'value': 3});
      expect(await call, 3);
    },
  );

  test(
    'bounded stdin refuses oversize without consuming request capacity',
    () async {
      await expectLater(
        p.client.request('large', {
          'text': 'x' * unitPipeQueueLimit,
        }, decodeResult: (_) => 0),
        throwsA(isA<RpcException>()),
      );
      expect(p.writes, isEmpty);
      final call = request();
      p.result(p.writes.single['id']!, {'value': 2});
      expect(await call, 2);
    },
  );

  test('aggregate blocked writes remain bounded', () async {
    p.blockedWrite = Completer<void>();
    await p.client
        .notify('first', {'text': 'x' * (unitPipeQueueLimit ~/ 2)})
        .timeout(const Duration(milliseconds: 1), onTimeout: () {});
    await expectLater(
      p.client.notify('second', {'text': 'x' * (unitPipeQueueLimit ~/ 2)}),
      throwsA(isA<RpcException>()),
    );
    expect(p.writes.length, 1);
  });

  test('16 MiB native line cap fails without decoding it', () async {
    final call = request();
    final checked = expectLater(call, throwsA(isA<CodexProtocolException>()));
    final chunk = Uint8List(65536)..fillRange(0, 65536, 32);
    for (var i = 0; i <= 256; i++) {
      p.input.add(chunk);
    }
    await checked;
    expect(p.client.isClosed, isTrue);
  });

  test('ACP and Codex share the host-wide large-line permit', () async {
    final permit = LargeLinePermit();
    final acp = AcpPeer(permit: permit);
    final native = CodexPeer(permit: permit);
    addTearDown(acp.dispose);
    addTearDown(native.dispose);
    final chunk = Uint8List(65536)..fillRange(0, 65536, 32);
    for (var i = 0; i < 17; i++) {
      acp.input.add(chunk);
    }
    await pumpCodex();
    expect(acp.client.largeLineOwned, isTrue);
    for (var i = 0; i < 17; i++) {
      native.input.add(chunk);
    }
    await pumpCodex();
    expect(native.client.largeLineWaiting, isTrue);
    await acp.client.close();
    await pumpCodex();
    expect(native.client.largeLineOwned, isTrue);
  });

  test(
    'bounded event consumption gates reads and releases large permit first',
    () async {
      final gate = Completer<void>();
      var events = 0;
      p.client.normalizeNotification = (_, params) =>
          (params as Json)['text'] is String ? 'small normalized' : null;
      p.client.consumeNotification = (_) {
        events++;
        return gate.future;
      };
      p.event('item/delta', {'text': 'x' * (1024 * 1024 + 10)});
      p.event('item/delta', {'text': 'second'});
      await pumpCodex();
      expect(events, 1);
      expect(p.client.largeLineOwned, isFalse);
      gate.complete();
      await pumpCodex();
      expect(events, 2);
    },
  );
  test(
    'optional response and async-normalizer notices use bounded consumption',
    () async {
      final notices = <Object>[];
      p.client.onUnsupported = (feature, reason) => '$feature: $reason';
      p.client.consumeNotification = notices.add;
      final response = p.client.request<void>(
        'optional',
        {},
        decodeResult: (_) => throw CodexOptionalUnsupported(
          'optional-response',
          'shape changed',
        ),
      );
      final error = expectLater(
        response,
        throwsA(isA<CodexOptionalUnsupported>()),
      );
      p.result(p.writes.last['id']!, {});
      await error;
      await pumpCodex();
      p.client.normalizeNotification = (_, _) => Future<Object?>.error(
        CodexOptionalUnsupported('optional-event', 'shape changed'),
      );
      p.event('optional/event', {});
      await pumpCodex();
      await pumpCodex();
      expect(notices, [
        'optional-response: shape changed',
        'optional-event: shape changed',
      ]);
      expect(p.client.isClosed, false);
    },
  );
}
