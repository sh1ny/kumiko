import 'dart:async';
import 'dart:convert';

import 'package:host/src/agent/agent_session.dart';

import 'dart:typed_data';

import 'package:host/src/agent/runtime_driver.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/codex_peer.dart';

void main() {
  late CodexPeer peer;
  late CodexRuntimeDriver driver;
  setUp(() {
    peer = CodexPeer();
    driver = CodexRuntimeDriver(peer.client, '0.166.0');
    peer.onWrite = (m) {
      if (m['method'] == 'thread/start') {
        peer.result(m['id']!, {
          'thread': {'id': 'root'},
          'model': 'fixture',
          'modelProvider': 'fixture',
          'cwd': '/fixture',
          'approvalPolicy': 'untrusted',
          'approvalsReviewer': 'user',
          'sandbox': {},
        });
      }
      if (m['method'] == 'turn/start') {
        peer.result(m['id']!, {
          'turn': {'id': 'turn', 'status': 'inProgress', 'items': <Object?>[]},
        });
      }
    };
    driver.normalizeUpdate = (u) =>
        encodeAgentEvent(AgentEvent.text(u.kind, u.text));
    driver.consumeNotification = (value) async {
      if (value is RuntimeDelivery) {
        value.release();
        value.after?.call();
      } else if (value is Iterable<Uint8List>) {
        value.toList();
      }
    };
  });
  tearDown(() async {
    await driver.close();
    await peer.dispose();
  });
  for (final loss in ['eof', 'failure', 'close']) {
    test('accepted native turn settles exactly once on $loss', () async {
      await driver.newSession('/fixture');
      var settlements = 0;
      final result = driver.prompt('root', 'fixture');
      final settled = result.then<Object?>(
        (_) {
          settlements++;
          return null;
        },
        onError: (Object error) {
          settlements++;
          return error;
        },
      );
      await pumpCodex();
      expect(driver.turnId, 'turn');
      if (loss == 'eof') {
        await peer.input.close();
      } else if (loss == 'failure') {
        peer.send({'id': true, 'result': {}});
      } else {
        await driver.close();
      }
      expect(await settled.timeout(const Duration(seconds: 1)), isNotNull);
      expect(driver.turnId, isNull);
      await driver.close();
      expect(settlements, 1);
    });
  }
  test(
    'early correlation shares relay capacity and releases on failure',
    () async {
      await driver.newSession('/fixture');
      var reserved = 0;
      driver.reserveEarly = (bytes) {
        if (reserved + bytes > 4096) return false;
        reserved += bytes;
        return true;
      };
      driver.releaseEarly = (bytes) => reserved -= bytes;
      peer.onWrite = (m) {};
      final turn = driver.prompt('root', 'fixture');
      final observed = turn.then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      peer.event('item/agentMessage/delta', {
        'threadId': 'root',
        'turnId': 'future',
        'itemId': 'item',
        'delta': 'held',
      });
      await pumpCodex();
      expect(reserved, greaterThan(0));
      peer.event('item/agentMessage/delta', {
        'threadId': 'root',
        'turnId': 'future',
        'itemId': 'item',
        'delta': List.filled(5000, 'x').join(),
      });
      expect(await observed.timeout(const Duration(seconds: 1)), isNotNull);
      expect(reserved, 0);
    },
  );
  test(
    'native Stop saturation admits no partial replies or state mutation',
    () async {
      await driver.newSession('/fixture');
      final session = AgentSession(
        sessionId: 'session',
        driver: driver,
        runId: 'run',
        nativeSessionId: 'root',
        onState: (_) {},
        onPermissionRequested: (_) {},
        onPermissionResolved: (_) {},
        onStopResult: (_) {},
        onTurnEnded: (_) {},
        enqueueEvents: (_) {},
      );
      session.ready(nativeSessionId: 'root');
      session.acceptPrompt('fixture');
      await pumpCodex();
      for (var i = 0; i < 2; i++) {
        peer.send({
          'id': 'permission-$i',
          'method': 'item/commandExecution/requestApproval',
          'params': {
            'threadId': 'root',
            'turnId': 'turn',
            'itemId': 'item-$i',
            'startedAtMs': 1,
            'availableDecisions': ['accept', 'decline'],
          },
        });
      }
      await pumpCodex();
      expect(session.pendingPermissionCount, 2);
      peer.blockedWrite = Completer<void>();
      final overhead = utf8
          .encode(
            '${jsonEncode({
              'id': 'fill',
              'result': {'padding': ''},
            })}\n',
          )
          .length;
      final fill = peer.client.replyAdmitted('fill', {
        'padding': List.filled(1024 * 1024 - overhead - 100, 'x').join(),
      });
      final before = peer.writes.length;
      expect(
        session.stop,
        throwsA(
          isA<RpcException>().having((e) => e.reason, 'reason', ErrorCode.busy),
        ),
      );
      expect(peer.writes.length, before);
      expect(session.pendingPermissionCount, 2);
      expect(session.state, AgentState.waitingApproval);
      peer.blockedWrite!.complete();
      await fill;
      session.dispose();
    },
  );
  test(
    'explicit close remains available when native interrupt cannot fit',
    () async {
      await driver.newSession('/fixture');
      final session = AgentSession(
        sessionId: 'session',
        driver: driver,
        runId: 'run',
        nativeSessionId: 'root',
        onState: (_) {},
        onPermissionRequested: (_) {},
        onPermissionResolved: (_) {},
        onStopResult: (_) {},
        onTurnEnded: (_) {},
        enqueueEvents: (_) {},
      );
      addTearDown(session.dispose);
      session.ready(nativeSessionId: 'root');
      session.acceptPrompt('fixture');
      await pumpCodex();
      peer.blockedWrite = Completer<void>();
      final overhead = utf8
          .encode(
            '${jsonEncode({
              'id': 'fill',
              'result': {'padding': ''},
            })}\n',
          )
          .length;
      peer.client.replyAdmitted('fill', {
        'padding': List.filled(1024 * 1024 - overhead - 10, 'x').join(),
      }).ignore();
      expect(session.beginClosing, returnsNormally);
      expect(session.state, AgentState.closing);
    },
  );
  test('bounded item identity eviction is visibly marked once', () async {
    await driver.newSession('/fixture');
    driver.prompt('root', 'fixture').ignore();
    await pumpCodex();
    final marked = Completer<void>();
    var notices = 0;
    driver.normalizeUpdate = (update) {
      if (update.optionalNotice?.contains('identity') ?? false) {
        notices++;
        if (!marked.isCompleted) marked.complete();
      }
      return const <Uint8List>[];
    };
    for (var i = 0; i < 4098; i++) {
      peer.event('item/completed', {
        'threadId': 'root',
        'turnId': 'turn',
        'item': {'id': 'item-$i', 'type': 'agentMessage', 'text': ''},
      });
    }
    await marked.future.timeout(const Duration(seconds: 5));
    await pumpCodex();
    expect(notices, 1);
  });
}
