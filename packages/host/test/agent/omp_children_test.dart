import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:host/src/agent/agent_session.dart';
import 'package:host/src/agent/omp/omp_driver.dart';
import 'package:host/src/agent/omp/omp_session_file.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/omp_peer.dart';

class _StopDeadline implements AgentDeadline {
  _StopDeadline(this.fire);
  final void Function() fire;
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
}

void main() {
  final directory = Directory.systemTemp.absolute.path;
  String file(String name) => p.join(directory, '$name.jsonl');
  Json lifecycle(String id, String status, {String? locator, String? owner}) =>
      {
        'type': 'subagent_lifecycle',
        'payload': {
          'id': id,
          'status': status,
          'sessionFile': locator ?? file(id),
          'parentToolCallId': ?owner,
        },
      };
  Json child(String id, Json event) => {
    'type': 'subagent_event',
    'payload': {'id': id, 'event': event},
  };
  Json message(String text) => {
    'type': 'message_end',
    'message': {
      'role': 'assistant',
      'content': [
        {'type': 'text', 'text': text},
      ],
    },
  };
  Json tool(String type, String text) => {
    'type': type,
    'toolCallId': 'native-id-reused',
    'toolName': 'read',
    if (type == 'tool_execution_start') 'args': {'input': text},
    if (type == 'tool_execution_end')
      'result': {
        'content': [
          {'type': 'text', 'text': text},
        ],
      },
    if (type == 'tool_execution_end') 'isError': false,
  };

  late OmpPeer peer;
  late OmpRuntimeDriver driver;
  late AgentSession session;
  late List<Json> events;
  late List<AgentStateParams> states;
  late List<AgentStopResultParams> stopped;
  late _StopDeadline deadline;
  late Completer<AgentTurnEndedParams> turnFinished;

  Future<void> barrier() async {
    final reached = peer.client.request('get_state');
    peer.result(peer.writes.last['id']! as String);
    await reached;
  }

  setUp(() async {
    peer = OmpPeer();
    addTearDown(peer.dispose);
    driver = OmpRuntimeDriver(peer.client, '18.20.1', runId: 'private-run');
    final ready = driver.initialize();
    peer.send({
      'type': 'ready',
      'supportedProtocolVersions': [1],
    });
    peer.result((await peer.commandAt(0))['id']! as String);
    await ready;
    final native = driver.newSession(directory);
    peer.result((await peer.commandAt(1))['id']! as String, {
      'sessionId': 'native-root',
      'isSettled': true,
      'hasPendingAsyncWork': false,
    });
    await native;
    final tracking = driver.configureChildren(views: true);
    peer.result((await peer.commandAt(2))['id']! as String, {
      'level': 'events',
    });
    final rosterId = (await peer.commandAt(3))['id']! as String;
    peer.send(lifecycle('finished-before-roster', 'completed'));
    peer.result(rosterId, {
      'subagents': [
        {'id': 'finished-before-roster', 'status': 'running'},
      ],
    });
    await tracking;
    events = [];
    states = [];
    stopped = [];
    turnFinished = Completer<AgentTurnEndedParams>();
    session = AgentSession(
      sessionId: 'saved-root',
      runId: 'private-run',
      driver: driver,
      onState: states.add,
      onStopResult: stopped.add,
      onPermissionRequested: (_) {},
      onPermissionResolved: (_) {},
      onTurnEnded: turnFinished.complete,
      deadlineFactory: (_, fire) => deadline = _StopDeadline(fire),
      enqueueEvents: (lines) {
        events.addAll(
          lines.map((line) => jsonDecode(utf8.decode(line)) as Json),
        );
      },
    )..ready(nativeSessionId: 'native-root');
    addTearDown(session.dispose);
    await driver.attachChildren();
  });

  test('OMP: Lifecycle observed while the snapshot is pending wins', () {
    expect(states.last.delegated?.activeChildren, 0);
    expect(events.where((e) => e['kind'] == 'child'), isEmpty);
  });

  Future<String> prompt() async {
    final accepted = session.acceptPrompt('work')!;
    final id = peer.writes.last['id']! as String;
    peer.result(id);
    peer.send({'type': 'agent_start'});
    await accepted;
    return id;
  }

  test('OMP: Interleaved native ids stay local to each child', () async {
    peer.send(lifecycle('one', 'started', owner: 'outer-task'));
    peer.send(lifecycle('two', 'started', owner: 'nested-task'));
    peer.send(child('one', tool('tool_execution_start', 'input one')));
    peer.send(child('two', tool('tool_execution_start', 'input two')));
    peer.send(child('two', message('two answer')));
    peer.send(child('one', message('one answer')));
    peer.send(child('one', tool('tool_execution_end', 'output one')));
    peer.send(child('two', tool('tool_execution_end', 'output two')));
    await barrier();

    expect(states.last.delegated?.activeChildren, 2);
    final messages = events
        .where((event) => event['kind'] == 'agentText')
        .toList();
    expect(messages.map((event) => event['text']), [
      'two answer',
      'one answer',
    ]);
    final one = messages.last['threadId'];
    final two = messages.first['threadId'];
    expect(one, isNot(two));
    expect(
      messages.every(
        (event) =>
            event['rootThreadId'] == 'private-run' &&
            !event.containsKey('parentThreadId'),
      ),
      isTrue,
    );
    final cards = events.where((event) => event['kind'] == 'tool').toList();
    expect(cards, hasLength(2));
    expect(cards[0]['toolCallId'], isNot(cards[1]['toolCallId']));
    final updates = events.where((event) => event['kind'] == 'toolUpdate');
    expect(updates.map((event) => (event['threadId'], event['toolCallId'])), [
      (one, cards[0]['toolCallId']),
      (two, cards[1]['toolCallId']),
    ]);
    expect(jsonEncode(events), isNot(contains('nested-task')));
  });

  test(
    'OMP: Child overflow marks uncertainty and withholds excess content',
    () async {
      for (var i = 0; i < 17; i++) {
        peer.send(lifecycle('child-$i', 'started'));
      }
      peer.send(child('child-16', message('unattributed content')));
      await barrier();
      expect(states.last.delegated?.activeChildren, 16);
      expect(states.last.delegated?.incomplete, isTrue);
      expect(jsonEncode(events), isNot(contains('unattributed content')));
    },
  );

  test('OMP: Unsupported or conflicting child facts cannot become idle or root output', () async {
    peer.send(lifecycle('known', 'started', locator: file('one')));
    peer.send(lifecycle('known', 'started', locator: file('another')));
    peer.send(child('known', message('ambiguous content')));
    await barrier();
    expect(states.last.delegated?.hasWork, isTrue);
    expect(states.last.delegated?.incomplete, isTrue);
    expect(jsonEncode(events), isNot(contains('ambiguous content')));
    session.stop();
    expect(
      peer.writes.where((command) => command['type'] == 'cancel_subagent'),
      isEmpty,
    );
    deadline.fire();
    expect(stopped.single.outcome, AgentStopOutcome.notConfirmed);
  });

  test('OMP: Prompt result does not clear child or background work', () async {
    final id = await prompt();
    peer.send(lifecycle('worker', 'started'));
    peer.send({
      'type': 'prompt_result',
      'id': id,
      'status': 'completed',
      'sessionSettled': false,
    });
    await turnFinished.future;
    expect(states.last.delegated?.activeChildren, 1);
    peer.send(lifecycle('worker', 'completed'));
    await barrier();
    expect(states.last.delegated?.hasWork, isTrue);
    peer.send({'type': 'session_settled'});
    await barrier();
    expect(states.last.delegated?.hasWork, isFalse);
  });

  for (final finish in ['aborted', 'completed']) {
    test(
      'OMP: Root Stop waits for the addressed child terminal cancellation ($finish)',
      () async {
        final id = await prompt();
        peer.send(lifecycle('worker', 'started'));
        peer.send({
          'type': 'prompt_result',
          'id': id,
          'status': 'completed',
          'sessionSettled': false,
        });
        await turnFinished.future;
        session.stop();
        final cancels = peer.writes.where(
          (c) => c['type'] == 'cancel_subagent',
        );
        expect(cancels, hasLength(1));
        expect(cancels.single['subagentId'], 'worker');
        for (final c in peer.writes.where(
          (c) => c['type'] == 'abort' || c['type'] == 'cancel_subagent',
        )) {
          peer.result(c['id']! as String, {'cancelled': true});
        }
        await barrier();
        expect(stopped, isEmpty);
        deadline.fire();
        expect(stopped.single.outcome, AgentStopOutcome.notConfirmed);
        peer.send({'type': 'session_settled'});
        await barrier();
        expect(stopped, hasLength(1));
        peer.send(lifecycle('worker', finish));
        await barrier();
        expect(
          stopped.last.outcome,
          finish == 'aborted'
              ? AgentStopOutcome.stopped
              : AgentStopOutcome.finishedFirst,
        );
        expect(stopped.last.late, isTrue);
      },
    );
  }

  test(
    'OMP: Busy multi-command Stop admits neither child cancellation',
    () async {
      final id = await prompt();
      peer.send(lifecycle('one', 'started'));
      peer.send(lifecycle('two', 'started'));
      peer.send({
        'type': 'prompt_result',
        'id': id,
        'status': 'completed',
        'sessionSettled': false,
      });
      await turnFinished.future;
      final pending = <Future<Object?>>[];
      final ids = <String>[];
      for (var i = 0; i < 31; i++) {
        pending.add(peer.client.request('get_state'));
        ids.add(peer.writes.last['id']! as String);
      }
      try {
        final before = peer.writes.length;
        expect(
          session.stop,
          throwsA(
            isA<RpcException>().having((e) => e.reason, 'code', ErrorCode.busy),
          ),
        );
        expect(peer.writes, hasLength(before));
        expect(stopped, isEmpty);
        expect(states.last.state, AgentState.idle);
      } finally {
        for (final id in ids) {
          peer.result(id);
        }
        await Future.wait(pending);
      }
    },
  );

  for (final finish in ['aborted', 'completed']) {
    test(
      'OMP: Abort acknowledgement is not terminal evidence ($finish)',
      () async {
        final id = await prompt();
        session.stop();
        final abort = peer.writes.last;
        expect(abort['type'], 'abort');
        peer.result(abort['id']! as String);
        await barrier();
        expect(stopped, isEmpty);
        expect(deadline.cancelled, isFalse);
        if (finish == 'aborted') deadline.fire();
        peer.send({
          'type': 'prompt_result',
          'id': id,
          'status': finish,
          'sessionSettled': true,
        });
        await turnFinished.future;
        expect(
          stopped.last.outcome,
          finish == 'aborted'
              ? AgentStopOutcome.stopped
              : AgentStopOutcome.finishedFirst,
        );
        expect(stopped.last.late, finish == 'aborted');
        expect(deadline.cancelled, isTrue);
      },
    );
  }

  test('OMP: Refused child Stop cannot report Stopped', () async {
    peer.send(lifecycle('worker', 'started'));
    await barrier();
    session.stop();
    final cancel = peer.writes.last;
    expect(cancel['type'], 'cancel_subagent');
    peer.result(cancel['id']! as String, {'cancelled': false});
    peer.send({'type': 'session_settled'});
    await barrier();
    deadline.fire();
    expect(stopped.single.outcome, AgentStopOutcome.notConfirmed);
    expect(states.last.delegated?.activeChildren, 1);
    peer.send(lifecycle('worker', 'completed'));
    await barrier();
    expect(stopped.last.outcome, AgentStopOutcome.finishedFirst);
  });

  for (final variant in [
    'valid',
    'reset',
    'wrong path',
    'no header',
    'closed run',
  ]) {
    test('OMP: Registered child history stays scoped ($variant)', () async {
      final path = file('child-hidden-locator');
      peer.send(lifecycle('worker', 'started', locator: path));
      await barrier();
      final key =
          events.singleWhere((e) => e['kind'] == 'child')['threadId']!
              as String;
      final params = AgentChildHistoryParams(
        sessionId: 'saved-root',
        runId: 'private-run',
        childKey: key,
        viewToken: 'view-1',
      );
      var current = true;
      final index = peer.writes.length;
      final reading = driver.childHistory(
        params,
        inspect: (candidate) async {
          expect(candidate, path);
          return 160;
        },
        current: () => current,
      );
      final command = await peer.commandAt(index);
      expect(
        command,
        allOf(
          containsPair('type', 'get_subagent_messages'),
          containsPair('sessionFile', path),
          containsPair('fromByte', 0),
        ),
      );
      current = variant != 'closed run';
      peer.result(command['id']! as String, {
        'sessionFile': variant == 'wrong path' ? file('different') : path,
        'fromByte': 0,
        'nextByte': 160,
        'reset': variant == 'reset',
        'entries': [
          if (variant != 'no header')
            {'type': 'session', 'id': 'child-native-session'},
          {
            'type': 'message',
            'message': {
              'role': 'user',
              'content': 'earlier subagent user message',
            },
          },
        ],
      });
      final result = await reading;
      await session.eventsEnqueued;
      final restored = events.where((e) => e['viewToken'] == 'view-1');
      if (variant == 'valid') {
        expect(result.status, AgentChildHistoryStatus.queued);
        expect(restored.map((e) => e['threadId']), [key, key, key]);
        expect(restored.map((e) => e['kind']), ['replay', 'user', 'replay']);
        expect(restored.elementAt(1)['text'], 'earlier subagent user message');
      } else {
        expect(result.status, AgentChildHistoryStatus.unavailable);
        expect(restored, isEmpty);
      }
      expect(
        jsonEncode([result.toJson(), events]),
        isNot(contains('child-hidden-locator')),
      );
    });
  }

  test(
    'OMP: Missing, oversized, or retired child history cannot be read',
    () async {
      final dir = Directory.systemTemp.createTempSync(
        'kumiko_omp_child_history_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final native = File(p.join(dir.path, 'child.jsonl'));
      peer.send(lifecycle('worker', 'started', locator: native.path));
      await barrier();
      final key =
          events.singleWhere((e) => e['kind'] == 'child')['threadId']!
              as String;
      const run = 'private-run';
      Future<AgentChildHistoryResult> read() => driver.childHistory(
        AgentChildHistoryParams(
          sessionId: 'saved-root',
          runId: run,
          childKey: key,
          viewToken: 'current-view',
        ),
        inspect: inspectOmpChildFile,
        current: () => true,
      );
      expect((await read()).status, AgentChildHistoryStatus.unavailable);
      native.openSync(mode: FileMode.write)
        ..truncateSync(maxOmpChildHistoryBytes + 1)
        ..closeSync();
      expect((await read()).status, AgentChildHistoryStatus.unavailable);
      peer.send(lifecycle('worker', 'completed', locator: native.path));
      for (var i = 0; i < 64; i++) {
        peer.send(lifecycle('completed-$i', 'started'));
        peer.send(lifecycle('completed-$i', 'completed'));
      }
      await barrier();
      await expectLater(
        read(),
        throwsA(
          isA<RpcException>().having(
            (e) => e.reason,
            'reason',
            ErrorCode.unknownSession,
          ),
        ),
      );
      expect(
        peer.writes.where((c) => c['type'] == 'get_subagent_messages'),
        isEmpty,
      );
      expect(events.where((e) => e['viewToken'] != null), isEmpty);
    },
  );
}
