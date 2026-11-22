import 'dart:async';
import 'dart:typed_data';

import 'package:host/src/agent/omp/omp_client.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/omp_peer.dart';

void main() {
  late OmpPeer peer;
  setUp(() {
    peer = OmpPeer();
    addTearDown(peer.dispose);
  });

  test(
    'correlates out-of-order responses and delivers events separately',
    () async {
      final events = <Json>[];
      peer.client.consumeNotification = (value) => events.add(value as Json);
      final first = peer.client.request('get_state');
      final second = peer.client.request('abort');
      expect(peer.writes, [
        {'type': 'get_state', 'id': 'k1'},
        {'type': 'abort', 'id': 'k2'},
      ]);
      peer.result('k2', 'second');
      peer.send({'type': 'notice', 'message': 'visible'});
      peer.result('k1', 'first');
      expect(await first, 'first');
      expect(await second, 'second');
      expect(events, [
        {'type': 'notice', 'message': 'visible'},
      ]);
    },
  );

  test(
    'refuses the 33rd waiting command before writing or issuing an id',
    () async {
      final requests = List.generate(
        32,
        (_) => peer.client.request('get_state'),
      );
      await expectLater(
        peer.client.request('get_state'),
        throwsA(isA<RpcException>().having((e) => e.reason, 'reason', 'busy')),
      );
      expect(peer.writes, hasLength(32));
      for (var n = 1; n <= 32; n++) {
        peer.result('k$n', n);
      }
      expect(await Future.wait(requests), List.generate(32, (n) => n + 1));
      final next = peer.client.request('get_state');
      expect(peer.writes.last['id'], 'k33');
      peer.result('k33', 33);
      expect(await next, 33);
    },
  );

  test('OMP: Abort acknowledged after its deadline', () async {
    await expectLater(
      peer.client.command('abort', timeout: Duration.zero),
      throwsA(isA<TimeoutException>()),
    );
    for (var n = 2; n <= 35; n++) {
      final request = peer.client.request('get_state');
      peer.result('k$n', n);
      expect(await request, n);
    }
    peer.result('k1');
    peer.result('k2');
    final next = peer.client.request('get_state');
    peer.result('k36', 'still connected');
    expect(await next, 'still connected');
  });

  test('remote failures preserve error and code without closing', () async {
    final rejected = peer.client.request('abort');
    peer.send({
      'type': 'response',
      'id': 'k1',
      'success': false,
      'error': 'no turn',
      'code': 'invalid_state',
    });
    await expectLater(
      rejected,
      throwsA(
        isA<OmpRemoteException>()
            .having((e) => e.message, 'message', 'no turn')
            .having((e) => e.code, 'code', 'invalid_state'),
      ),
    );
    final next = peer.client.request('get_state');
    peer.result('k2', 'idle');
    expect(await next, 'idle');
  });

  for (final line in [
    '[]',
    'not JSON',
    '{"type":"response","id":"k2","success":true}',
  ]) {
    test('OMP: Malformed frame after start: $line', () async {
      final waiting = peer.client.request('get_state');
      final refused = expectLater(
        waiting,
        throwsA(isA<OmpProtocolException>()),
      );
      peer.input.add('$line\n'.codeUnits);
      await refused;
      await peer.client.done;
      expect(peer.client.failure, isA<OmpProtocolException>());
    });
  }

  test('stdout enforces the shared 16 MiB line limit', () async {
    final chunk = Uint8List(65536)..fillRange(0, 65536, 32);
    for (var n = 0; n < 256; n++) {
      peer.input.add(chunk);
    }
    peer.input.add([32]);
    await peer.client.done;
    expect(peer.client.failure.toString(), contains('16 MiB'));
  });

  test('stdin admission shares the 1 MiB budget across writes', () async {
    peer.blockedWrite = Completer<void>();
    final payload = 'a' * (600 * 1024);
    final first = peer.client.request('prompt', {'message': payload});
    await expectLater(
      peer.client.request('prompt', {'message': payload}),
      throwsA(isA<RpcException>().having((e) => e.reason, 'reason', 'busy')),
    );
    expect(peer.writes, hasLength(1));
    peer.result('k1');
    await first;
    peer.blockedWrite!.complete();
    peer.blockedWrite = null;
    await Future<void>(() {});
    final next = peer.client.request('prompt', {'message': payload});
    expect(peer.writes.last['id'], 'k2');
    peer.result('k2', true);
    expect(await next, isTrue);
  });
}
