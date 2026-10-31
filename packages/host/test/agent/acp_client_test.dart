import 'dart:async';
import 'dart:convert';

import 'package:host/src/agent/acp/acp_client.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/acp_peer.dart';

/// Virtual timer scheduling only. Zero-duration event-loop barriers still use
/// the parent zone, so ACP framing/consumption is not replaced by a mock.
class _DeadlineTimer implements Timer {
  _DeadlineTimer(this.duration, this.callback);
  final Duration duration;
  final void Function() callback;
  bool _active = true;
  @override
  bool get isActive => _active;
  @override
  int get tick => _active ? 0 : 1;
  @override
  void cancel() => _active = false;
  void fire() {
    if (!_active) return;
    _active = false;
    callback();
  }
}

void main() {
  late AcpPeer p;
  setUp(() => p = AcpPeer());
  tearDown(() => p.dispose());
  test('partial UTF8 lines and response ids match out of order', () async {
    final a = p.client.request('a', {});
    final b = p.client.request('b', {});
    final ai = p.writes[0]['id']!;
    final bi = p.writes[1]['id']!;
    final bytes = utf8.encode(
      '${jsonEncode({
        'jsonrpc': '2.0',
        'id': bi,
        'result': {'text': '猫'},
      })}\n',
    );
    for (final byte in bytes) {
      p.input.add([byte]);
    }
    p.result(ai, {'a': true});
    expect(await b, {'text': '猫'});
    expect(await a, {'a': true});
  });
  for (final mode in ['load', 'resume']) {
    test(
      'session/$mode deadline is 60 active seconds and excludes bounded event consumption pauses',
      () async {
        final timers = <_DeadlineTimer>[];
        await runZoned(
          () async {
            final peer = AcpPeer();
            final consuming = Completer<void>();
            final credit = Completer<void>();
            peer.client.normalizeNotification = (_, params) => params;
            peer.client.consumeNotification = (_) {
              consuming.complete();
              return credit.future;
            };
            var completed = false;
            final request = mode == 'load'
                ? peer.client.loadSession('native', '/target')
                : peer.client.resumeSession('native', '/target');
            final outcome = request.then<Object?>(
              (_) {
                completed = true;
                return null;
              },
              onError: (Object error) {
                completed = true;
                return error;
              },
            );
            try {
              expect(
                timers.where((t) => t.isActive).single.duration,
                const Duration(seconds: 60),
              );
              peer.update({'sessionUpdate': 'agent_message_chunk'});
              await consuming.future;
              expect(
                timers.where((t) => t.isActive),
                isEmpty,
                reason: 'credit-blocked event consumption must suspend the deadline',
              );
              // Arbitrarily many virtual minutes can pass while no timer is armed.
              for (final timer in timers.toList()) {
                timer.fire();
              }
              await pumpAcp();
              expect(completed, isFalse);
              credit.complete();
              await pumpAcp();
              final active = timers.where((t) => t.isActive).single;
              expect(
                active.duration,
                lessThanOrEqualTo(const Duration(seconds: 60)),
              );
              active.fire();
              expect(await outcome, isA<TimeoutException>());
            } finally {
              if (!credit.isCompleted) credit.complete();
              await peer.dispose();
              await outcome;
            }
          },
          zoneSpecification: ZoneSpecification(
            createTimer: (self, parent, zone, duration, callback) {
              if (duration == Duration.zero) {
                return parent.createTimer(zone, duration, callback);
              }
              final timer = _DeadlineTimer(duration, callback);
              timers.add(timer);
              return timer;
            },
          ),
        );
      },
    );
  }

  test('initialize advertises only reviewed v1 client capabilities', () async {
    final response = p.client.initialize();
    expect(p.writes.single['params'], {
      'protocolVersion': 1,
      'clientCapabilities': {
        'fs': {'readTextFile': false, 'writeTextFile': false},
        'terminal': false,
      },
      'clientInfo': {'name': 'kumiko'},
    });
    p.result(p.writes.single['id']!, {
      'protocolVersion': 1,
      'agentInfo': {'name': 'fixture'},
      'agentCapabilities': {},
    });
    expect((await response).protocolVersion, 1);
  });
  test('permission preserves opaque request id and unsupported requests get -32601', () async {
    p.client.onPermissionRequest = (id, params) {
      p.client.reply(id, {
        'outcome': {'outcome': 'selected', 'optionId': 'opaque'},
      }).ignore();
      return null;
    };
    p.permission('request/opaque');
    p.send({
      'jsonrpc': '2.0',
      'id': 9,
      'method': 'fs/read_text_file',
      'params': {},
    });
    p.send({'jsonrpc': '2.0', 'method': 'future/notification', 'params': {}});
    await pumpAcp();
    expect(p.writes[0]['id'], 'request/opaque');
    expect((p.writes[0]['result'] as Json)['outcome'], {
      'outcome': 'selected',
      'optionId': 'opaque',
    });
    expect((p.writes[1]['error'] as Json)['code'], -32601);
    expect(p.writes, hasLength(2));
  });
  for (final bytes in [
    utf8.encode('bad\n'),
    [255, 10],
    utf8.encode('{"jsonrpc":"1.0","result":{}}\n'),
  ]) {
    test(
      'malformed JSON UTF8 or envelope settles pending calls $bytes',
      () async {
        final request = p.client.request('pending', {});
        final failure = expectLater(
          request,
          throwsA(isA<AcpProtocolException>()),
        );
        p.input.add(bytes);
        await failure;
        await p.client.done;
      },
    );
  }
  test('16 MiB line bound fails visibly', () async {
    final request = p.client.request('pending', {});
    final failure = expectLater(request, throwsA(isA<AcpProtocolException>()));
    addChunks(p, largeUpdate(16 * 1024 * 1024));
    await failure;
    expect(p.client.failure.toString(), contains('too large'));
  });
  test(
    'shared large permit lasts through normalization not delivery',
    () async {
      final permit = LargeLinePermit();
      final first = AcpPeer(permit: permit);
      final second = AcpPeer(permit: permit);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final normalize = Completer<void>();
      final delivery = Completer<void>();
      var secondNormalized = false;
      first.client.normalizeNotification = (_, params) async {
        await normalize.future;
        return params;
      };
      first.client.consumeNotification = (_) => delivery.future;
      second.client.normalizeNotification = (_, params) {
        secondNormalized = true;
        return params;
      };
      addChunks(first, largeUpdate(1100000));
      await pumpAcp();
      addChunks(second, largeUpdate(1100000));
      await pumpAcp();
      expect(secondNormalized, isFalse);
      normalize.complete();
      await pumpAcp();
      expect(secondNormalized, isTrue);
      delivery.complete();
    },
  );
  for (final release in [
    'close',
    'eof',
    'parse failure',
    'normalization failure',
  ]) {
    test('large permit released on $release', () async {
      final permit = LargeLinePermit();
      final owner = AcpPeer(permit: permit);
      final waiter = AcpPeer(permit: permit);
      addTearDown(owner.dispose);
      addTearDown(waiter.dispose);
      final normalized = Completer<void>();
      waiter.client.normalizeNotification = (_, params) {
        normalized.complete();
        return params;
      };
      if (release == 'normalization failure') {
        owner.client.normalizeNotification = (_, _) =>
            throw StateError('normalize failed');
      }
      addChunks(
        owner,
        largeUpdate(1100000),
        newline: release == 'normalization failure',
      );
      await pumpAcp();
      addChunks(waiter, largeUpdate(1100000));
      if (release == 'close') await owner.client.close();
      if (release == 'eof') await owner.input.close();
      if (release == 'parse failure') owner.input.add(utf8.encode('!\n'));
      await normalized.future;
    });
  }
  test('cancelled permit waiter cannot steal next permit', () async {
    final permit = LargeLinePermit();
    final owner = AcpPeer(permit: permit);
    final waiter = AcpPeer(permit: permit);
    final next = AcpPeer(permit: permit);
    addTearDown(owner.dispose);
    addTearDown(waiter.dispose);
    addTearDown(next.dispose);
    addChunks(owner, largeUpdate(1100000), newline: false);
    await pumpAcp();
    addChunks(waiter, largeUpdate(1100000));
    await pumpAcp();
    await waiter.client.close();
    final seen = Completer<void>();
    next.client.normalizeNotification = (_, p) {
      seen.complete();
      return p;
    };
    addChunks(next, largeUpdate(1100000));
    await owner.client.close();
    await seen.future;
  });
  test(
    'delivery backpressure gates subsequent lines in the same chunk',
    () async {
      final delivery = Completer<void>();
      var count = 0;
      p.client.normalizeNotification = (_, params) {
        count++;
        return params;
      };
      p.client.consumeNotification = (_) => delivery.future;
      final line = largeUpdate(1);
      p.input.add([...line, ...line]);
      await pumpAcp();
      expect(count, 1);
      delivery.complete();
      await pumpAcp();
      expect(count, 2);
    },
  );
  test('blocked stdin refuses excess queued requests as busy without retaining them', () async {
    p.blockedWrite = Completer<void>();
    final first = p.client.request('first', {'text': 'x' * 700000});
    final closed = expectLater(first, throwsA(isA<AcpClosedException>()));
    await expectLater(
      p.client.request('second', {'text': 'x' * 700000}),
      throwsA(isA<RpcException>().having((e) => e.reason, 'reason', 'busy')),
    );
    expect(p.writes, hasLength(1));
    await p.client.close();
    await closed;
  });
  test(
    'close settles request even while native stdin write is blocked',
    () async {
      p.blockedWrite = Completer<void>();
      final request = p.client.request('pending', {});
      final failure = expectLater(request, throwsA(isA<AcpClosedException>()));
      await p.client.close();
      await failure;
    },
  );
}
