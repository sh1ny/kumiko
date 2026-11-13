import 'dart:async';
import 'dart:convert';

import 'package:host/src/agent/agent_session.dart';
import 'package:host/src/agent/codex/codex_client.dart';

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
    driver.normalizeUpdate = (u) => encodeAgentEvent(
      u.event ??
          (u.kind == AgentEventKind.notice
              ? AgentEvent.notice(u.text)
              : AgentEvent.text(u.kind, u.text)),
    );
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
  for (final other in [false, true]) {
    test('a parentless thread/started before the thread/start response is '
        'classified once the root is known other=$other', () async {
      peer.onWrite = (m) {
        if (m['method'] == 'thread/start') {
          peer.event('thread/started', {
            'thread': {
              'id': other ? 'stranger' : 'root',
              'status': {'type': 'idle'},
            },
          });
          peer.result(m['id']!, {
            'thread': {'id': 'root'},
            'model': 'fixture',
            'modelProvider': 'fixture',
            'cwd': '/fixture',
            'approvalPolicy': 'untrusted',
            'approvalsReviewer': 'user',
            'sandbox': <String, Object?>{},
          });
        }
      };
      expect(await driver.newSession('/fixture'), 'root');
      for (var i = 0; i < 5; i++) {
        await pumpCodex();
      }
      expect(driver.delegated.incomplete, other);
    });
  }
  test('history relationship transfers pending attribution reservation exactly once', () async {
    await driver.newSession('/fixture');
    var reserved = 0, reads = 0;
    driver.reserveEarly = (bytes) {
      reserved += bytes;
      return true;
    };
    driver.releaseEarly = (bytes) => reserved -= bytes;
    driver.normalizeUpdate = (u) =>
        encodeAgentEvent(u.event ?? AgentEvent.notice(u.text));
    final entered = Completer<RuntimeDelivery>(), release = Completer<void>();
    driver.consumeNotification = (value) async {
      if (value is RuntimeDelivery) {
        entered.complete(value);
        await release.future;
        value.release();
      }
    };
    peer.onWrite = (request) {
      if (request['method'] == 'thread/read') {
        peer.result(request['id']!, {
          'thread': {
            'id': 'root',
            'historyMode': 'legacy',
            'status': {'type': reads++ == 0 ? 'notLoaded' : 'idle'},
          },
        });
      } else if (request['method'] == 'thread/resume') {
        peer.event('item/agentMessage/delta', {
          'threadId': 'child',
          'turnId': 'ct',
          'itemId': 'ci',
          'delta': 'held historical child',
        });
        peer.result(request['id']!, {
          'thread': {
            'id': 'root',
            'historyMode': 'legacy',
            'status': {'type': 'idle'},
            'turns': [
              {
                'id': 'old',
                'status': 'completed',
                'items': [
                  {
                    'id': 'spawn',
                    'type': 'collabAgentToolCall',
                    'tool': 'spawnAgent',
                    'senderThreadId': 'root',
                    'receiverThreadIds': ['child'],
                    'agentsStates': {
                      'child': {'status': 'completed', 'message': null},
                    },
                  },
                ],
              },
            ],
          },
        });
      }
    };
    final loading = driver.loadSession('root', '/fixture');
    final delivery = await entered.future;
    try {
      expect(
        reserved,
        delivery.bytes,
        reason: 'existing held attribution charge transfers into this delivery',
      );
    } finally {
      release.complete();
      await loading;
    }
    expect(
      reserved,
      0,
      reason:
          'replay must release without waiting for another native notification',
    );
  });
  test(
    'a buffered terminal reports its turn end to Stop aggregation',
    () async {
      await driver.newSession('/fixture');
      driver.reserveEarly = (_) => true;
      driver.releaseEarly = (_) {};
      final ended = <(String, String, RuntimeTurnResult)>[];
      driver.onNativeTurnEnded = (thread, turn, result) =>
          ended.add((thread, turn, result));
      final entered = Completer<RuntimeDelivery>(), release = Completer<void>();
      driver.consumeNotification = (value) async {
        if (value is RuntimeDelivery) {
          entered.complete(value);
          await release.future;
          value.release();
          value.after?.call();
        }
      };
      peer.onWrite = (m) {
        if (m['method'] == 'turn/start') {
          peer.event('turn/completed', {
            'threadId': 'root',
            'turn': {
              'id': 'turn',
              'status': 'completed',
              'items': <Object?>[],
              'error': null,
            },
          });
          peer.result(m['id']!, {
            'turn': {
              'id': 'turn',
              'status': 'inProgress',
              'items': <Object?>[],
            },
          });
        }
      };
      final turn = driver.prompt('root', 'hello');
      await entered.future;
      // Stop may be admitted here, after the turn identity is published and
      // before buffered delivery drains.
      expect(ended, isEmpty);
      release.complete();
      final result = await turn;
      expect(ended, hasLength(1));
      expect(ended.single.$1, 'root');
      expect(ended.single.$2, 'turn');
      expect(identical(ended.single.$3, result), isTrue);
    },
  );
  test(
    'a staged early request retired before the response is never published',
    () async {
      await driver.newSession('/fixture');
      var reserved = 0;
      driver.reserveEarly = (bytes) {
        reserved += bytes;
        return true;
      };
      driver.releaseEarly = (bytes) => reserved -= bytes;
      final published = <RuntimePermission>[];
      driver.onPermission = (p) {
        published.add(p);
        return null;
      };
      final writes = <Json>[];
      peer.onWrite = (m) {
        writes.add(m);
        if (m['method'] == 'turn/start') {
          peer.send({
            'id': 'early-approval',
            'method': 'item/commandExecution/requestApproval',
            'params': {
              'threadId': 'root',
              'turnId': 'turn',
              'itemId': 'cmd',
              'startedAtMs': 1,
              'command': 'echo early',
              'availableDecisions': ['accept', 'cancel'],
            },
          });
          peer.event('serverRequest/resolved', {
            'threadId': 'root',
            'requestId': 'early-approval',
          });
          peer.event('turn/completed', {
            'threadId': 'root',
            'turn': {
              'id': 'turn',
              'status': 'completed',
              'items': <Object?>[],
              'error': null,
            },
          });
          peer.result(m['id']!, {
            'turn': {
              'id': 'turn',
              'status': 'inProgress',
              'items': <Object?>[],
            },
          });
        }
      };
      await driver.prompt('root', 'hello');
      expect(published, isEmpty);
      expect(writes.where((m) => m['id'] == 'early-approval'), isEmpty);
      expect(reserved, 0);
    },
  );
  test(
    'child-only dedup eviction emits a visible root omission notice',
    () async {
      await driver.newSession('/fixture');
      final events = <Json>[];
      driver.normalizeUpdate = (u) => [
        if (u.optionalNotice != null)
          ...encodeAgentEvent(AgentEvent.notice(u.optionalNotice!)),
        ...encodeAgentEvent(u.event ?? AgentEvent.notice(u.text)),
      ];
      driver.consumeNotification = (value) {
        if (value is Iterable<Uint8List>) {
          for (final line in value) {
            events.add(jsonDecode(utf8.decode(line)) as Json);
          }
        }
      };
      peer.event('thread/started', {
        'thread': {'id': 'child', 'parentThreadId': 'root'},
      });
      for (var i = 0; i < 4097; i++) {
        peer.event('item/completed', {
          'threadId': 'child',
          'turnId': 'ct',
          'item': {
            'id': 'i-$i',
            'type': 'agentMessage',
            'text': 'bounded child item',
          },
        });
      }
      // A correlated response is a stream-order barrier after all child items.
      final barrier = peer.client.request<void>(
        'barrier',
        {},
        decodeResult: (_) {},
      );
      peer.result(peer.writes.last['id']!, {});
      await barrier;
      expect(
        events.any(
          (e) => e['kind'] == 'notice' && '${e['text']}'.contains('4096'),
        ),
        true,
      );
    },
  );
  for (final closeWhileBlocked in [false, true]) {
    test(
      'unknown attribution retains shared reservation until delivery or close $closeWhileBlocked',
      () async {
        await driver.newSession('/fixture');
        var reserved = 0;
        driver.reserveEarly = (bytes) {
          reserved += bytes;
          return reserved <= 256 * 1024;
        };
        driver.releaseEarly = (bytes) => reserved -= bytes;
        driver.normalizeUpdate = (u) =>
            encodeAgentEvent(u.event ?? AgentEvent.notice(u.text));
        final blocked = Completer<void>();
        RuntimeDelivery? owned;
        driver.consumeNotification = (value) async {
          if (value is RuntimeDelivery) {
            owned = value;
            await blocked.future;
            value.release();
            value.after?.call();
          }
        };
        peer.event('item/agentMessage/delta', {
          'threadId': 'child',
          'turnId': 'ct',
          'itemId': 'i',
          'delta': 'held child output',
        });
        await pumpCodex();
        expect(reserved, greaterThan(0));
        peer.event('thread/started', {
          'thread': {'id': 'child', 'parentThreadId': 'root'},
        });
        await pumpCodex();
        expect(owned, isNotNull);
        expect(
          reserved,
          greaterThan(0),
          reason: 'reader-to-relay transfer still owns the pending bytes',
        );
        if (closeWhileBlocked) await driver.close();
        blocked.complete();
        await pumpCodex();
        expect(reserved, 0);
      },
    );
  }
  test(
    'opaque native separators cannot merge child tools or dedup identities',
    () async {
      await driver.newSession('/fixture');
      final events = <Json>[];
      driver.normalizeUpdate = (u) =>
          encodeAgentEvent(u.event ?? AgentEvent.notice(u.text));
      driver.consumeNotification = (value) {
        if (value is Iterable<Uint8List>) {
          for (final line in value) {
            events.add(jsonDecode(utf8.decode(line)) as Json);
          }
        }
      };
      for (final pair in [('a:', 'x'), ('a', ':x')]) {
        peer.event('thread/started', {
          'thread': {'id': pair.$1, 'parentThreadId': 'root'},
        });
        peer.event('item/completed', {
          'threadId': pair.$1,
          'turnId': 't',
          'item': {
            'id': pair.$2,
            'type': 'commandExecution',
            'command': 'echo fixture',
            'cwd': '/fixture',
            'status': 'completed',
            'commandActions': <Object?>[],
          },
        });
      }
      for (final pair in [('t:', 'x'), ('t', ':x')]) {
        peer.event('item/completed', {
          'threadId': 'a',
          'turnId': pair.$1,
          'item': {
            'id': pair.$2,
            'type': 'agentMessage',
            'text': 'distinct message',
          },
        });
      }
      await pumpCodex();
      await pumpCodex();
      expect(
        events
            .where((e) => e['kind'] == 'toolUpdate')
            .map((e) => e['toolCallId'])
            .toSet(),
        hasLength(2),
      );
      expect(events.where((e) => e['kind'] == 'agentText'), hasLength(2));
    },
  );
  test(
    'healthy optional config read timeout keeps native chat usable',
    () async {
      await driver.close();
      await peer.dispose();
      peer = CodexPeer(configReadTimeout: const Duration(milliseconds: 1));
      driver = CodexRuntimeDriver(peer.client, '0.166.0');
      peer.onWrite = (request) {
        if (request['method'] == 'thread/start') {
          expect((request['params'] as Json)['config'], isNull);
          peer.result(request['id']!, {
            'thread': {'id': 'root'},
            'model': 'fixture',
            'modelProvider': 'fixture',
            'cwd': '/fixture',
            'approvalPolicy': 'untrusted',
            'approvalsReviewer': 'user',
            'sandbox': <String, Object?>{},
          });
        }
      };
      final reason = await driver.prepareTools(
        '/fixture',
        mcpServers: [
          {
            'name': 'kumiko',
            'command': '/bridge',
            'args': <Object?>[],
            'env': [
              {'name': 'KUMIKO_TOOL_ENDPOINT', 'value': 'endpoint'},
              {'name': 'KUMIKO_TOOL_SECRET', 'value': 'private'},
              {'name': 'KUMIKO_UNIT', 'value': 'unit'},
            ],
          },
        ],
      );
      expect(reason, contains('timed out'));
      expect(peer.client.isClosed, false);
      expect(await driver.newSession('/fixture'), 'root');
    },
  );
  test(
    'optional config preparation does not hide a closed native transport',
    () async {
      peer.onWrite = (request) {
        if (request['method'] == 'config/read') unawaited(driver.close());
      };
      await expectLater(
        driver.prepareTools(
          '/fixture',
          mcpServers: [
            {'name': 'kumiko'},
          ],
        ),
        throwsA(isA<CodexProtocolException>()),
      );
      expect(peer.client.isClosed, true);
    },
  );
  test(
    'history page bytes reserve shared relay capacity before delivery',
    () async {
      var reads = 0;
      var reserved = 0;
      final observed = <int>[];
      driver.reserveEarly = (bytes) {
        reserved += bytes;
        return true;
      };
      driver.releaseEarly = (bytes) => reserved -= bytes;
      driver.consumeNotification = (value) async {
        observed.add(reserved);
        if (value is RuntimeDelivery) value.release();
      };
      peer.onWrite = (request) {
        if (request['method'] == 'thread/read') {
          peer.result(request['id']!, {
            'thread': {
              'id': 'root',
              'historyMode': 'legacy',
              'status': {'type': reads++ == 0 ? 'notLoaded' : 'idle'},
            },
          });
        } else if (request['method'] == 'thread/resume') {
          peer.result(request['id']!, {
            'thread': {
              'id': 'root',
              'historyMode': 'legacy',
              'status': {'type': 'idle'},
              'turns': [
                {
                  'id': 'old',
                  'status': 'completed',
                  'items': [
                    {
                      'id': 'message',
                      'type': 'agentMessage',
                      'text': 'history',
                    },
                  ],
                },
              ],
            },
          });
        }
      };
      await driver.loadSession('root', '/fixture');
      expect(observed, isNotEmpty);
      expect(observed.first, greaterThan(0));
      expect(reserved, 0);
    },
  );
  test('unknown profile MCP overlays cannot bypass absence proof', () async {
    peer.onWrite = (request) {
      if (request['method'] == 'config/read') {
        peer.result(request['id']!, {
          'config': <String, Object?>{},
          'layers': [
            {
              'config': {
                'profiles': {
                  'selected': {
                    'mcp_servers': {
                      'kumiko': {'command': 'user-owned'},
                    },
                  },
                },
              },
            },
          ],
        });
      }
    };
    final reason = await driver.prepareTools(
      '/fixture',
      mcpServers: [
        {
          'name': 'kumiko',
          'command': '/bridge',
          'args': <Object?>[],
          'env': [
            {'name': 'KUMIKO_TOOL_ENDPOINT', 'value': 'endpoint'},
            {'name': 'KUMIKO_TOOL_SECRET', 'value': 'private'},
            {'name': 'KUMIKO_UNIT', 'value': 'unit'},
          ],
        },
      ],
    );
    expect(reason, contains('profile'));
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
