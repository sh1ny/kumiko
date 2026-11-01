import 'dart:async';
import 'dart:convert';

import 'package:host/src/agent/acp/acp_client.dart';
import 'package:host/src/agent/agent_session.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/acp_peer.dart';

class ManualDeadline implements AgentDeadline {
  void Function()? action;
  @override
  void cancel() {
    action = null;
  }

  void fire() {
    final a = action;
    action = null;
    a?.call();
  }
}

void main() {
  late AcpPeer p;
  late AgentSession s;
  late ManualDeadline clock;
  late List<AgentStateParams> states;
  late List<AgentPermissionRequestedParams> requests;
  late List<AgentPermissionResolvedParams> resolved;
  late List<AgentStopResultParams> stops;
  late List<AgentTurnEndedParams> ends;
  late List<AgentEvent> events;
  setUp(() {
    p = AcpPeer();
    clock = ManualDeadline();
    states = [];
    requests = [];
    resolved = [];
    stops = [];
    ends = [];
    events = [];
    s = AgentSession(
      sessionId: 'host',
      client: p.client,
      onState: states.add,
      onPermissionRequested: requests.add,
      onPermissionResolved: resolved.add,
      onStopResult: stops.add,
      onTurnEnded: ends.add,
      enqueueEvents: (lines) {
        final decoder = AgentEventDecoder();
        for (final line in lines) {
          events.addAll(decoder.add(line));
        }
        decoder.close();
      },
      deadlineFactory: (duration, callback) {
        expect(duration, const Duration(seconds: 10));
        clock.action = callback;
        return clock;
      },
    );
    s.ready(nativeSessionId: 'native');
  });
  tearDown(() async {
    s.dispose();
    await p.dispose();
  });
  Object getPromptId() =>
      p.writes.lastWhere((w) => w['method'] == 'session/prompt')['id']!;
  Future<void> finish(String reason) async {
    p.result(getPromptId(), {'stopReason': reason});
    await pumpAcp();
  }

  test(
    'prompt acceptance does not await result; running then idle after enqueue',
    () async {
      s.acceptPrompt('hello');
      expect(s.state, AgentState.running);
      expect(p.writes.single['method'], 'session/prompt');
      p.update({
        'sessionUpdate': 'agent_message_chunk',
        'content': {'type': 'text', 'text': 'reply'},
      });
      await finish('end_turn');
      expect(s.state, AgentState.idle);
      expect(events.map((e) => e.kind), [
        AgentEventKind.user,
        AgentEventKind.agentText,
        AgentEventKind.turn,
      ]);
      expect(ends.single.stopReason, 'end_turn');
      expect(
        states.map((e) => e.seq).toList(),
        orderedEquals(List.generate(states.length, (i) => i + 1)),
      );
    },
  );
  test('agent/prompt while running refused turn-running', () {
    s.acceptPrompt('one');
    expect(
      () => s.acceptPrompt('two'),
      throwsA(
        isA<RpcException>().having((e) => e.reason, 'reason', 'turn-running'),
      ),
    );
    expect(p.writes, hasLength(1));
  });
  test('permission request waitingApproval explicit opaque reply and remaining requests', () async {
    s.acceptPrompt('hello');
    p.permission('p1');
    p.permission(2);
    await pumpAcp();
    expect(s.state, AgentState.waitingApproval);
    expect(
      () => s.permissionReply(requests.first.requestId, 'not-offered'),
      throwsA(isA<RpcException>()),
    );
    s.permissionReply(requests.first.requestId, 'opaque/allow');
    expect(s.state, AgentState.waitingApproval);
    s.permissionReply(requests.last.requestId, 'opaque/allow');
    expect(s.state, AgentState.running);
    expect((p.writes.last['result'] as Json)['outcome'], {
      'outcome': 'selected',
      'optionId': 'opaque/allow',
    });
    expect(p.writes.last['id'], 2);
    expect(resolved, hasLength(2));
  });

  test('permission reply queue refusal stays pending and retries after stdin drains', () async {
    s.acceptPrompt('bounded permission replies');
    await pumpAcp();
    final option = 'o' * 65000;
    final nativeIds = [for (var i = 0; i < 16; i++) '${'r' * 4090}-$i'];
    for (final id in nativeIds) {
      p.permission(id, optionId: option);
    }
    await pumpAcp();
    expect(requests, hasLength(16));
    p.blockedWrite = Completer<void>();
    for (final request in requests.take(15)) {
      s.permissionReply(request.requestId, option);
    }
    final last = requests.last.requestId;
    expect(
      () => s.permissionReply(last, option),
      throwsA(isA<RpcException>().having((e) => e.reason, 'reason', ErrorCode.busy)),
    );
    await pumpAcp();
    expect(s.pendingPermissionCount, 1);
    expect(resolved.map((r) => r.requestId), requests.take(15).map((r) => r.requestId));
    expect(s.state, AgentState.waitingApproval);
    expect(s.failure, isNull);
    expect(p.client.isClosed, isFalse);
    p.blockedWrite!.complete();
    p.blockedWrite = null;
    await pumpAcp();
    s.permissionReply(last, option);
    await pumpAcp();
    expect(s.pendingPermissionCount, 0);
    expect(s.state, AgentState.running);
    expect(resolved.last.requestId, last);
    expect(resolved.every((r) => r.outcome == AgentPermissionOutcome.selected), isTrue);
    final replies = p.writes.where((message) => message.containsKey('result'));
    expect(replies.map((r) => r['id']), nativeIds);
    expect(replies.map((r) => ((r['result'] as Json)['outcome'] as Json)['optionId']), everyElement(option));
  });

  test('an admitted permission reply still fails the session if native writing fails', () async {
    s.acceptPrompt('native write failure');
    await pumpAcp();
    p.permission('native-write-failure');
    await pumpAcp();
    p.blockedWrite = Completer<void>();
    s.permissionReply(requests.single.requestId, 'opaque/allow');
    final failure = StateError('native stdin failed');
    p.blockedWrite!.completeError(failure);
    p.blockedWrite = null;
    await pumpAcp();
    expect(s.state, AgentState.failed);
    expect(s.failure, same(failure));
    expect(resolved.single.outcome, AgentPermissionOutcome.selected);
  });

  test('Stop refuses saturated stdin without resolving choices or failing and retries after drain', () async {
    s.acceptPrompt('saturated Stop');
    await pumpAcp();
    final ids = [for (var i = 0; i < 16; i++) '${'r' * 4090}-$i'];
    final options = <String>[];
    var remaining = 1024 * 1024;
    for (var i = 0; i < ids.length; i++) {
      final emptyReply = {'jsonrpc': '2.0', 'id': ids[i], 'result': {'outcome': {'outcome': 'selected', 'optionId': ''}}};
      final overhead = utf8.encode('${jsonEncode(emptyReply)}\n').length;
      final option = 'o' * (i < 15 ? 65000 : remaining - overhead);
      options.add(option);
      remaining -= overhead + option.length;
      p.permission(ids[i], optionId: option);
    }
    expect(remaining, 0);
    await pumpAcp();
    p.blockedWrite = Completer<void>();
    for (var i = 0; i < requests.length; i++) {
      s.permissionReply(requests[i].requestId, options[i]);
    }
    expect(() => s.stop(), throwsA(isA<RpcException>().having((e) => e.reason, 'reason', ErrorCode.busy)));
    await pumpAcp();
    expect(s.state, AgentState.running);
    expect(s.failure, isNull);
    expect(clock.action, isNull);
    expect(stops, isEmpty);
    p.permission('late-native-permission');
    await pumpAcp();
    final pending = requests.last.requestId;
    expect(s.pendingPermissionCount, 1);
    expect(() => s.stop(), throwsA(isA<RpcException>().having((e) => e.reason, 'reason', ErrorCode.busy)));
    await pumpAcp();
    expect(s.state, AgentState.waitingApproval);
    expect(s.pendingPermissionCount, 1);
    expect(resolved.where((r) => r.requestId == pending), isEmpty);
    expect(s.failure, isNull);
    expect(p.client.isClosed, isFalse);
    p.blockedWrite!.complete();
    p.blockedWrite = null;
    await pumpAcp();
    s.stop();
    await pumpAcp();
    expect(s.state, AgentState.stopping);
    expect(s.pendingPermissionCount, 0);
    expect(resolved.last.requestId, pending);
    expect(resolved.last.outcome, AgentPermissionOutcome.cancelled);
    expect(p.writes[p.writes.length - 2]['id'], 'late-native-permission');
    expect(p.writes.last['method'], 'session/cancel');
    clock.fire();
    expect(stops.single.outcome, AgentStopOutcome.notConfirmed);
    expect(s.state, AgentState.stopping);
    expect(p.client.isClosed, isFalse);
    await finish('cancelled');
    expect(s.state, AgentState.idle);
    expect(stops.last.outcome, AgentStopOutcome.stopped);
    expect(stops.last.late, isTrue);
  });

  test('an admitted Stop still fails on actual native stdin I/O error', () async {
    s.acceptPrompt('Stop write failure');
    await pumpAcp();
    p.blockedWrite = Completer<void>();
    s.stop();
    final failure = StateError('native cancel write failed');
    p.blockedWrite!.completeError(failure);
    p.blockedWrite = null;
    await pumpAcp();
    expect(s.state, AgentState.failed);
    expect(s.failure, same(failure));
  });

  test('bounded native permission IDs preserve exact selected and cancelled replies', () async {
    s.acceptPrompt('bounded permission IDs');
    final selectedId = 'x' * 4096;
    final cancelledId = '${'\u0001' * 682}tail';
    p.permission(selectedId);
    p.permission(cancelledId);
    await pumpAcp();
    expect(requests, hasLength(2));
    expect(s.pendingPermissionCount, 2);
    s.permissionReply(requests.first.requestId, 'opaque/allow');
    s.stop();
    await pumpAcp();
    final replies = p.writes.where((entry) => entry.containsKey('result')).toList();
    expect(replies.map((entry) => entry['id']), [selectedId, cancelledId]);
    expect(replies.map((entry) => (entry['result'] as Json)['outcome']), [
      {'outcome': 'selected', 'optionId': 'opaque/allow'},
      {'outcome': 'cancelled'},
    ]);
    expect(resolved.map((entry) => entry.outcome), [
      AgentPermissionOutcome.selected,
      AgentPermissionOutcome.cancelled,
    ]);
    expect(s.state, AgentState.stopping);
    expect(p.client.isClosed, isFalse);
    expect(p.writes.last['method'], 'session/cancel');
  });

  for (final entry in {
    'multi-MiB': 'p' * (2 * 1024 * 1024),
    'escaped over budget': '\u0001' * 683,
    'UTF-8 over budget': '界' * 1366,
  }.entries) {
    test('${entry.key} native permission ID fails before publishing or retaining it', () async {
      s.acceptPrompt('invalid permission ID');
      p.permission(entry.value);
      await pumpAcp();
      expect(s.state, AgentState.failed);
      expect(s.failure, isA<AcpProtocolException>());
      expect(s.failure.toString(), contains('request id'));
      expect(s.pendingPermissionCount, 0);
      expect(requests, isEmpty);
      expect(resolved, isEmpty);
      expect(p.writes.where((message) => message.containsKey('result')), isEmpty);
      expect(p.client.largeLineOwned, isFalse);
      expect(p.client.largeLineWaiting, isFalse);
    });
  }

  test('oversized native ID cannot accumulate behind existing pending permissions', () async {
    s.acceptPrompt('multiple pending permissions');
    p.permission('first');
    p.permission('second');
    await pumpAcp();
    expect(s.pendingPermissionCount, 2);
    p.permission('p' * (2 * 1024 * 1024));
    await pumpAcp();
    expect(s.state, AgentState.failed);
    expect(requests, hasLength(2));
    expect(s.pendingPermissionCount, 0);
    expect(resolved.map((entry) => entry.outcome), [
      AgentPermissionOutcome.cancelled,
      AgentPermissionOutcome.cancelled,
    ]);
    expect(p.writes.where((message) => message.containsKey('result')), isEmpty);
    expect(
      () => s.permissionReply(requests.first.requestId, 'opaque/allow'),
      throwsA(isA<RpcException>().having((error) => error.reason, 'reason', ErrorCode.unknownRequest)),
    );
  });
  test('a reply to a resolved request fails unknown-request and writes nothing to the transport', () async {
    s.acceptPrompt('hello');
    p.permission('p');
    await pumpAcp();
    final id = requests.single.requestId;
    s.permissionReply(id, 'opaque/allow');
    final count = p.writes.length;
    expect(
      () => s.permissionReply(id, 'opaque/allow'),
      throwsA(
        isA<RpcException>().having(
          (e) => e.reason,
          'reason',
          'unknown-request',
        ),
      ),
    );
    expect(p.writes, hasLength(count));
  });
  test(
    'Stop writes the cancelled outcome before session/cancel (transport order)',
    () async {
      s.acceptPrompt('hello');
      p.permission('p1');
      p.permission('p2');
      await pumpAcp();
      p.blockedWrite = Completer<void>();
      s.stop();
      expect(s.state, AgentState.stopping);
      expect(p.writes.skip(1).map((e) => e['id'] ?? e['method']), [
        'p1',
        'p2',
        'session/cancel',
      ]);
      expect(
        resolved.map((r) => r.outcome),
        everyElement(AgentPermissionOutcome.cancelled),
      );
      expect(
        () => s.permissionReply(requests.first.requestId, 'opaque/allow'),
        throwsA(isA<RpcException>()),
      );
    },
  );
  for (final reason in [
    'cancelled',
    'end_turn',
    'max_tokens',
    'max_turn_requests',
    'refusal',
  ]) {
    for (final late in [false, true]) {
      test(
        'Stop $reason ${late ? 'after deadline' : 'before deadline'} classifies actual result once',
        () async {
          s.acceptPrompt('hello');
          s.stop();
          s.stop();
          if (late) {
            clock.fire();
            expect(stops.single.outcome, AgentStopOutcome.notConfirmed);
            expect(s.state, AgentState.stopping);
          }
          await finish(reason);
          expect(
            stops.last.outcome,
            reason == 'cancelled'
                ? AgentStopOutcome.stopped
                : AgentStopOutcome.finishedFirst,
          );
          expect(stops.last.late, late);
          expect(stops.last.stopReason, reason);
          expect(s.state, AgentState.idle);
          expect(ends, hasLength(1));
          p.result(getPromptId(), {'stopReason': reason});
          await pumpAcp();
          expect(stops, hasLength(late ? 2 : 1));
        },
      );
    }
  }
  for (final late in [false, true]) {
    test(
      'error answer after Stop yields endedWithError ${late ? 'late' : ''}',
      () async {
        s.acceptPrompt('hello');
        s.stop();
        if (late) clock.fire();
        p.error(getPromptId(), -9876, 'adapter own error');
        await pumpAcp();
        expect(stops.last.outcome, AgentStopOutcome.endedWithError);
        expect(stops.last.message, 'adapter own error');
        expect(stops.last.late, late);
        expect(ends.single.message, 'adapter own error');
        expect(s.state, AgentState.idle);
      },
    );
  }
  test('prompt answered end_turn after Stop yields finishedFirst even before cancel flush', () async {
    s.acceptPrompt('hello');
    p.blockedWrite = Completer<void>();
    s.stop();
    await finish('end_turn');
    expect(stops.single.outcome, AgentStopOutcome.finishedFirst);
  });
  test('stop idle reports notRunning without stdin writes', () {
    s.stop();
    expect(stops.single.outcome, AgentStopOutcome.notRunning);
    expect(p.writes, isEmpty);
  });
  test('stopReason refusal returns to idle', () async {
    s.acceptPrompt('hello');
    await finish('refusal');
    expect(ends.single.stopReason, 'refusal');
    expect(s.state, AgentState.idle);
  });
  test('prompt error returns idle with turnEnded error and preserves unmatched code/message', () async {
    s.acceptPrompt('hello');
    p.error(getPromptId(), -9876, 'synthetic sign-in wording not real auth');
    await pumpAcp();
    expect(s.state, AgentState.idle);
    expect(ends.single.error, 'adapter-error');
    expect(ends.single.message, 'synthetic sign-in wording not real auth');
    final wire = ends.single.toJson();
    expect(wire['nativeCode'], -9876);
    expect(wire['nativeMessage'], 'synthetic sign-in wording not real auth');
    expect(wire['nativeMessageTruncated'], isNot(true));
    expect(events.first.text, 'hello');
  });
  test('observed prompt authentication error returns idle with auth-required and exact native diagnostics', () async {
    s.acceptPrompt('hello');
    p.error(getPromptId(), -32000, 'Authentication required');
    await pumpAcp();
    expect(s.state, AgentState.idle);
    expect(ends.single.error, ErrorCode.authRequired);
    expect(ends.single.message, 'Authentication required');
    expect(ends.single.nativeCode, -32000);
    expect(ends.single.nativeMessage, 'Authentication required');
    expect(ends.single.nativeMessageTruncated, isNot(isTrue));
    expect(s.sessionId, 'host');
    expect(s.nativeSessionId, 'native');
    expect(p.client.isClosed, isFalse);
    s.acceptPrompt('after external sign-in');
    expect(s.state, AgentState.running);
    await finish('end_turn');
    expect(ends, hasLength(2));
    expect(ends.last.error, isNull);
    expect(s.state, AgentState.idle);
  });
  for (final (code, message) in [
    (-32001, 'Authentication required'),
    (-32000, 'Authentication required.'),
  ]) {
    test(
      'prompt authentication near-match $code "$message" stays generic with native diagnostics',
      () async {
        s.acceptPrompt('hello');
        p.error(getPromptId(), code, message);
        await pumpAcp();
        expect(s.state, AgentState.idle);
        expect(ends.single.error, 'adapter-error');
        expect(ends.single.message, message);
        expect(ends.single.nativeCode, code);
        expect(ends.single.nativeMessage, message);
        expect(ends.single.nativeMessageTruncated, isNot(isTrue));
      },
    );
  }
  test('prompt native diagnostics mark UTF-8 truncation rather than claiming an exact error', () async {
    final message = '值' * 2000;
    s.acceptPrompt('hello');
    p.error(getPromptId(), -9876, message);
    await pumpAcp();
    final wire = ends.single.toJson();
    expect(wire['nativeCode'], -9876);
    expect(wire['nativeMessage'], '值' * 1365);
    expect(wire['nativeMessageTruncated'], isTrue);
    expect(ends.single.error, 'adapter-error');
    expect(s.state, AgentState.idle);
  });
  test(
    'stdout EOF fails an idle session without requiring another prompt',
    () async {
      await p.input.close();
      await p.client.done;
      expect(s.state, AgentState.failed);
      expect(s.failure, isA<AcpClosedException>());
      expect(ends, isEmpty);
      expect(() => s.acceptPrompt('after EOF'), throwsA(isA<RpcException>()));
    },
  );

  test('more than 16 permissions cancels extra and emits notice', () async {
    s.acceptPrompt('hello');
    for (var i = 0; i < 17; i++) {
      p.permission(i);
    }
    await pumpAcp();
    expect(requests, hasLength(16));
    expect(s.pendingPermissionCount, 16);
    expect(p.writes.last['id'], 16);
    expect((p.writes.last['result'] as Json)['outcome'], {
      'outcome': 'cancelled',
    });
    expect(events.last.kind, AgentEventKind.notice);
  });
  test(
    'unrepresentable permission metadata visibly fails without hidden approval',
    () async {
      s.acceptPrompt('hello');
      p.permission('p', optionId: 'x' * 70000);
      await pumpAcp();
      expect(s.state, AgentState.failed);
      expect(s.failure.toString(), contains('permission'));
      expect(p.writes.where((e) => e.containsKey('result')), isEmpty);
    },
  );
  test('close and failure lifecycle prevent late turn transitions', () async {
    s.acceptPrompt('hello');
    p.permission('p');
    await pumpAcp();
    s.beginClosing();
    expect(s.state, AgentState.closing);
    await finish('cancelled');
    expect(s.state, AgentState.closing);
    s.ended();
    expect(s.state, AgentState.ended);
    expect(() => s.acceptPrompt('later'), throwsA(isA<RpcException>()));
  });
  test(
    'starting Continue session normalizes load replay before ready',
    () async {
      s.dispose();
      s = AgentSession(
        sessionId: 'host',
        client: p.client,
        nativeSessionId: 'saved',
        onState: states.add,
        onPermissionRequested: requests.add,
        onPermissionResolved: resolved.add,
        onStopResult: stops.add,
        onTurnEnded: ends.add,
        enqueueEvents: (lines) {
          final decoder = AgentEventDecoder();
          for (final line in lines) {
            events.addAll(decoder.add(line));
          }
          decoder.close();
        },
      );
      await s.replayStarted();
      p.send({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': {
          'sessionId': 'saved',
          'update': {
            'sessionUpdate': 'user_message_chunk',
            'content': {'type': 'text', 'text': 'history'},
          },
        },
      });
      await pumpAcp();
      await s.replayEnded();
      expect(events.map((e) => e.kind), [
        AgentEventKind.replay,
        AgentEventKind.user,
        AgentEventKind.replay,
      ]);
      expect(s.state, AgentState.starting);
      s.ready(nativeSessionId: 'saved');
      expect(s.state, AgentState.idle);
      expect(p.writes, isEmpty);
    },
  );
  test('turnEnded waits for enqueue but not desktop delivery', () async {
    final enqueue = Completer<void>();
    s.dispose();
    s = AgentSession(
      sessionId: 'host',
      client: p.client,
      onState: states.add,
      onPermissionRequested: requests.add,
      onPermissionResolved: resolved.add,
      onStopResult: stops.add,
      onTurnEnded: ends.add,
      enqueueEvents: (_) => enqueue.future,
    );
    s.ready(nativeSessionId: 'native');
    s.acceptPrompt('hello');
    await finish('end_turn');
    expect(ends, isEmpty);
    enqueue.complete();
    await pumpAcp();
    expect(ends, hasLength(1));
    expect(s.state, AgentState.idle);
  });
}
