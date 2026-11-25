import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:host/src/agent/agent_session.dart';
import 'package:host/src/agent/omp/omp_client.dart';
import 'package:host/src/agent/omp/omp_driver.dart';
import 'package:host/src/agent/runtime_driver.dart';
import 'package:host/src/agent/tools/tool_catalog.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/omp_peer.dart';

class _ManualTimer implements Timer {
  _ManualTimer(this.callback);
  final void Function() callback;
  bool _active = true;
  @override
  bool get isActive => _active;
  @override
  int get tick => _active ? 0 : 1;
  @override
  void cancel() => _active = false;
  void fire() {
    if (!_active) throw StateError('registration timer is inactive');
    _active = false;
    callback();
  }
}

void main() {
  late OmpPeer peer;
  late OmpRuntimeDriver driver;

  setUp(() {
    peer = OmpPeer();
    addTearDown(peer.dispose);
    driver = OmpRuntimeDriver(peer.client, '18.20.1');
  });

  test('OMP: Readiness never arrives', () async {
    final initializing = driver.initialize();
    final refused = expectLater(
      initializing,
      throwsA(isA<OmpProtocolException>()),
    );
    peer.input.add('not JSON\n'.codeUnits);
    await refused;
    expect(peer.writes, isEmpty);
  });

  for (final id in [null, '', 'x' * 4097]) {
    final name = id == null ? 'absent' : (id.isEmpty ? 'empty' : 'oversize');
    test('OMP: Identity missing: $name', () async {
      final initializing = driver.initialize();
      peer.send({
        'type': 'ready',
        'supportedProtocolVersions': [1, 2],
      });
      peer.result('k1');
      await initializing;
      var recorded = false;
      final result = driver.newSession(
        '/fixture',
        onCreated: (_) {
          recorded = true;
        },
      );
      final refused = expectLater(result, throwsA(isA<OmpProtocolException>()));
      peer.result('k2', {'sessionId': ?id});
      await refused;
      expect(recorded, isFalse);
    });
  }

  Future<void> readySession() async {
    final starting = driver.initialize();
    peer.send({
      'type': 'ready',
      'supportedProtocolVersions': [1],
    });
    peer.result('k1');
    await starting;
    final created = driver.newSession('/fixture');
    peer.result('k2', {'sessionId': 'fixture'});
    await created;
  }

  Json delta(String type, String text, [String id = 'm']) => {
    'type': 'message_update',
    'messageId': id,
    'message': {'role': 'assistant'},
    'assistantMessageEvent': {'type': type, 'delta': text, 'contentIndex': 0},
  };

  void recordOutput(List<String> events) {
    driver.normalizeUpdate = (update) => [
      Uint8List.fromList(utf8.encode('${update.kind.name}:${update.text}')),
    ];
    driver.consumeNotification = (value) {
      final delivery = value as RuntimeDelivery;
      events.addAll(delivery.lines.map(utf8.decode));
      delivery.after?.call();
    };
  }

  test('OMP: Handled without the agent', () async {
    await readySession();
    recordOutput([]);
    final (admission, terminal) = driver.admitPrompt('local', (invoked) {
      expect(invoked, isFalse);
    });
    peer.result('k3', {'agentInvoked': false});
    await admission;
    expect((await terminal).stopReason, 'completed');
    expect(driver.activeNativeTurns, isEmpty);
  });

  test('OMP: Admission refused discards staged output', () async {
    await readySession();
    final events = <String>[];
    recordOutput(events);
    final (admission, terminal) = driver.admitPrompt('refused', (_) {
      fail('refused input must not commit');
    });
    final refused = expectLater(admission, throwsA(isA<OmpRemoteException>()));
    final ended = expectLater(terminal, throwsA(isA<OmpRemoteException>()));
    peer.send(delta('text_delta', 'discard'));
    peer.send({
      'type': 'response',
      'id': 'k3',
      'success': false,
      'error': 'refused',
    });
    await refused;
    await ended;
    expect(events, isEmpty);
    expect(driver.activeNativeTurns, isEmpty);
    final (nextAdmission, nextTerminal) = driver.admitPrompt('next', (_) {});
    peer.send({
      'type': 'prompt_result',
      'id': 'k3',
      'agentInvoked': false,
      'status': 'error',
      'error': {'message': 'refused', 'retryable': false},
    });
    peer.result('k4', {'agentInvoked': false});
    await nextAdmission;
    expect((await nextTerminal).stopReason, 'completed');
    expect(peer.client.isClosed, isFalse);
  });

  test('OMP: Streamed reply uses final text only for unseen blocks', () async {
    await readySession();
    final events = <String>[];
    recordOutput(events);
    final (admission, terminal) = driver.admitPrompt('hello', (_) {});
    peer.result('k3');
    peer.send(delta('text_delta', 'one'));
    peer.send({
      'type': 'message_end',
      'messageId': 'm',
      'message': {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'one'},
          {'type': 'text', 'text': 'two'},
        ],
      },
    });
    peer.send({'type': 'prompt_result', 'id': 'k3', 'status': 'completed'});
    await admission;
    await terminal;
    expect(events, ['agentText:one', 'agentText:two']);
  });

  test('OMP: Provider error', () async {
    await readySession();
    recordOutput([]);
    final (admission, terminal) = driver.admitPrompt('hello', (_) {});
    peer.result('k3');
    peer.send({
      'type': 'prompt_result',
      'id': 'k3',
      'status': 'error',
      'error': {
        'message': '401 invalid api key',
        'code': 'invalid_api_key',
        'retryable': false,
      },
    });
    await admission;
    final result = await terminal;
    final error = result.error! as OmpRemoteException;
    expect(error.message, '401 invalid api key');
    expect(error.code, 'invalid_api_key');
    expect(peer.client.isClosed, isFalse);
  });

  test('OMP: Tool approval requested before admission is declined', () async {
    await readySession();
    final events = <String>[];
    recordOutput(events);
    final (admission, terminal) = driver.admitPrompt('hello', (_) {});
    peer.send({
      'type': 'extension_ui_request',
      'id': 'approval',
      'method': 'select',
      'title': 'Do not hide\u202e',
    });
    final barrier = peer.client.request('get_state');
    peer.result('k4');
    await barrier;
    expect(
      peer.writes.singleWhere((f) => f['type'] == 'extension_ui_response'),
      {'type': 'extension_ui_response', 'id': 'approval', 'cancelled': true},
    );
    expect(events.single, contains('not supported in Kumiko yet; declined'));
    expect(events.single, isNot(contains('Do not hide')));
    peer.result('k3', {'agentInvoked': false});
    await admission;
    await terminal;
  });

  Json approval(String id, {String? title, List<String>? options}) => {
    'type': 'extension_ui_request',
    'id': id,
    'method': 'select',
    'title': title ?? 'Allow tool: bash\nCommand: echo test',
    'options': options ?? ['Approve', 'Deny'],
  };

  test(
    'OMP: Ambiguous or unrenderable approvals never offer authority',
    () async {
      await readySession();
      recordOutput([]);
      final offered = <RuntimePermission>[];
      driver.onPermission = (request) {
        offered.add(request);
        return null;
      };
      final (admitted, ended) = driver.admitPrompt('work', (_) {});
      peer.result('k3');
      await admitted;
      peer.send(approval('duplicate', options: ['Approve', 'Approve', 'Deny']));
      peer.send(approval('unknown', options: ['Go ahead', 'Deny']));
      peer.send(
        approval('large', title: 'Allow tool: bash\n${'x' * (17 * 1024)}'),
      );
      peer.send(
        approval('elided', title: 'Allow tool: bash\ncmd[…12ch elided…]'),
      );
      peer.send({...approval('marked'), 'selectionMarker': 'checkbox'});
      final longGrant = 'Approve Directory: ${'x' * maxPermissionNameBytes}';
      peer.send(
        approval(
          'large-option',
          options: [longGrant, 'Always $longGrant', 'Approve Once', 'Deny'],
        ),
      );
      peer.send(
        approval('valid', title: 'Allow tool: bash\nCommand: a\u202eb'),
      );
      peer.send({'type': 'prompt_result', 'id': 'k3', 'status': 'completed'});
      await ended;
      expect(peer.writes.skip(3).map((f) => f['id']), [
        'duplicate',
        'unknown',
        'large',
        'elided',
        'marked',
        'large-option',
      ]);
      expect(peer.writes.skip(3).every((f) => f['cancelled'] == true), isTrue);
      expect(offered.single.id, 'valid');
      expect(offered.single.preview, contains(r'a\u202eb'));
    },
  );

  test('OMP: Pre-admission, stopping and idle dialogs are declined', () async {
    await readySession();
    recordOutput([]);
    final offered = <Object>[];
    driver.onPermission = (request) {
      offered.add(request.id);
      return null;
    };
    final (admitted, ended) = driver.admitPrompt('work', (_) {});
    peer.send(approval('pre'));
    peer.result('k3');
    await admitted;
    final abort = driver.cancel('fixture');
    peer.send(approval('stopping'));
    peer.result('k4');
    peer.send({'type': 'prompt_result', 'id': 'k3', 'status': 'aborted'});
    await abort;
    await ended;
    peer.send(approval('idle'));
    final barrier = peer.client.request('get_state');
    peer.result('k5');
    await barrier;
    expect(offered, isEmpty);
    expect(
      peer.writes.where((f) => f['cancelled'] == true).map((f) => f['id']),
      ['pre', 'stopping', 'idle'],
    );
  });

  test('OMP: Non-approval dialogs cancel without accepting defaults', () async {
    await readySession();
    recordOutput([]);
    final (admitted, ended) = driver.admitPrompt('work', (_) {});
    peer.result('k3');
    await admitted;
    const methods = ['select', 'confirm', 'input', 'editor', 'ask', 'form'];
    for (final method in methods) {
      peer.send({
        'type': 'extension_ui_request',
        'id': method,
        'method': method,
        'title': 'Pick an editor',
        'options': ['Approve', 'Deny'],
      });
    }
    peer.send({'type': 'prompt_result', 'id': 'k3', 'status': 'completed'});
    await ended;
    expect(peer.writes.skip(3), [
      for (final method in methods)
        {'type': 'extension_ui_response', 'id': method, 'cancelled': true},
    ]);
  });

  for (final type in ['extension_ui_request', 'prompt_result', null]) {
    test('OMP: uncorrelatable $type overflow fails the turn', () async {
      await readySession();
      final (admitted, ended) = driver.admitPrompt('work', (_) {});
      final failed = expectLater(ended, throwsA(isA<OmpProtocolException>()));
      peer.result('k3');
      await admitted;
      peer.send({'type': 'rpc_frame_error', 'originalType': ?type});
      // The next native response is a barrier, not a delay to let the peer run.
      final barrier = peer.client.request('get_state');
      peer.result('k4');
      await expectLater(barrier, throwsA(isA<OmpProtocolException>()));
      await failed;
    });
  }

  test('OMP: duplicate live approval id fails without answering it', () async {
    await readySession();
    recordOutput([]);
    final offered = Completer<void>();
    driver.hasPendingApproval = (id) => id == 'same' && offered.isCompleted;
    driver.onPermission = (_) {
      offered.complete();
      return null;
    };
    final (admitted, ended) = driver.admitPrompt('work', (_) {});
    unawaited(ended.then<void>((_) {}, onError: (Object _) {}));
    peer.result('k3');
    await admitted;
    peer.send(approval('same'));
    final marker = peer.client.request('get_state');
    peer.result('k4');
    await marker;
    expect(offered.isCompleted, isTrue);
    final failed = expectLater(ended, throwsA(isA<OmpProtocolException>()));
    peer.send(approval('same'));
    final barrier = peer.client.request('get_state');
    peer.result('k5');
    await expectLater(barrier, throwsA(isA<OmpProtocolException>()));
    await failed;
    expect(
      peer.writes.where((f) => f['type'] == 'extension_ui_response'),
      isEmpty,
    );
  });

  test('OMP: A same-chunk withdrawal retires only its exact request', () async {
    await readySession();
    recordOutput([]);
    final pending = <Object>{};
    driver.onPermission = (request) {
      pending.add(request.id);
      return null;
    };
    driver.onRetired = pending.remove;
    driver.hasPendingApproval = pending.contains;
    final (admitted, ended) = driver.admitPrompt('work', (_) {});
    ended.ignore();
    peer.input.add(
      utf8.encode(
        [
          {'type': 'response', 'id': 'k3', 'success': true},
          approval('keep'),
          approval('gone'),
          {
            'type': 'extension_ui_request',
            'method': 'cancel',
            'id': 'keep',
            'targetId': 'gone',
          },
        ].map((frame) => '${jsonEncode(frame)}\n').join(),
      ),
    );
    final barrier = peer.client.request('get_state');
    peer.result('k4');
    await admitted;
    await barrier;
    expect(pending, {'keep'});
    expect(
      peer.writes.where((frame) => frame['type'] == 'extension_ui_response'),
      isEmpty,
    );
    peer.send({'type': 'prompt_result', 'id': 'k3', 'status': 'completed'});
    await ended;
  });

  test('OMP: Thinking and text interleave; one chunk commits first', () async {
    await readySession();
    final events = <String>[];
    recordOutput(events);
    final (admission, terminal) = driver.admitPrompt('hello', (_) {
      events.add('user');
    });
    peer.input.add(
      utf8.encode(
        [
          jsonEncode({'type': 'response', 'id': 'k3', 'success': true}),
          jsonEncode(delta('thinking_delta', 'thought')),
          jsonEncode({'type': 'future_event', 'payload': 'ignore'}),
          jsonEncode(delta('text_delta', 'reply', 'next')),
          jsonEncode({
            'type': 'prompt_result',
            'id': 'k3',
            'status': 'completed',
          }),
          '',
        ].join('\n'),
      ),
    );
    await admission;
    expect((await terminal).stopReason, 'completed');
    expect(events, ['user', 'thought:thought', 'agentText:reply']);
  });

  test(
    'OMP: Admission precedes output even when the result arrives early',
    () async {
      await readySession();
      final events = <String>[];
      recordOutput(events);
      final (admission, terminal) = driver.admitPrompt('hello', (_) {
        events.add('user');
      });
      driver.onNativeTurnEnded = (_, _, _) => events.add('turn');
      peer.send(delta('text_delta', 'early'));
      peer.send({'type': 'prompt_result', 'id': 'k3', 'status': 'completed'});
      peer.result('k3');
      await admission;
      await terminal;
      expect(events, ['user', 'agentText:early', 'turn']);
    },
  );

  test('OMP: pre-admission staging enforces its byte bound', () async {
    await readySession();
    final (admission, terminal) = driver.admitPrompt('hello', (_) {});
    final refused = expectLater(
      admission,
      throwsA(isA<OmpProtocolException>()),
    );
    final ended = expectLater(terminal, throwsA(isA<OmpProtocolException>()));
    peer.send(delta('text_delta', 'x' * (256 * 1024)));
    await refused;
    await ended;
  });

  test('OMP: Unknown event', () async {
    await readySession();
    final events = <String>[];
    recordOutput(events);
    final (admission, terminal) = driver.admitPrompt('hello', (_) {});
    peer.result('k3');
    peer.send({'type': 'unknown_event'});
    peer.send(delta('text_delta', 'known'));
    peer.send({'type': 'prompt_result', 'id': 'k3', 'status': 'completed'});
    await admission;
    await terminal;
    expect(events, ['agentText:known']);
  });

  for (final beforeAdmission in [false, true]) {
    final label = beforeAdmission
        ? 'early staging overflow'
        : 'Too many open messages';
    test('OMP: $label', () async {
      await readySession();
      final (admission, terminal) = driver.admitPrompt('hello', (_) {});
      final aborted = expectLater(
        terminal,
        throwsA(isA<OmpProtocolException>()),
      );
      if (!beforeAdmission) peer.result('k3');
      final admitted = beforeAdmission
          ? expectLater(admission, throwsA(isA<OmpProtocolException>()))
          : admission;
      for (var n = 0; n <= 64; n++) {
        peer.send(delta('text_delta', 'text', beforeAdmission ? 'm' : 'm$n'));
      }
      await admitted;
      await aborted;
      expect(driver.isClosed, isTrue);
    });
  }

  test('OMP: Oversized error text', () async {
    await readySession();
    recordOutput([]);
    final (admission, terminal) = driver.admitPrompt('hello', (_) {});
    peer.result('k3');
    peer.send({
      'type': 'prompt_result',
      'id': 'k3',
      'status': 'error',
      'error': 'x' * 4097,
    });
    await admission;
    final result = await terminal;
    expect(result.truncated, isTrue);
    expect((result.error! as OmpRemoteException).message.length, 4096);
  });

  test('OMP: Open URL request needs no response', () async {
    await readySession();
    final events = <String>[];
    recordOutput(events);
    peer.send({
      'type': 'extension_ui_request',
      'id': 'url',
      'method': 'open_url',
      'url': 'https://example.invalid',
    });
    peer.send({'type': 'notice', 'message': 'barrier'});
    await Future<void>(() {});
    expect(events, ['notice:barrier']);
    expect(peer.writes, hasLength(2));
  });

  test('OMP: unsupported HTML form is cancelled without echoing it', () async {
    await readySession();
    final events = <String>[];
    recordOutput(events);
    peer.send({
      'type': 'extension_ui_request',
      'id': 'form1',
      'method': 'form',
      'html': '<form><label>Private prompt text</label></form>',
    });
    await Future<void>(() {});
    expect(peer.writes.skip(2), [
      {'type': 'extension_ui_response', 'id': 'form1', 'cancelled': true},
    ]);
    expect(events, [
      'notice:OMP asked: form — not supported in Kumiko yet; declined',
    ]);
  });

  test(
    'OMP: Request after the turn is declined and notices are bounded',
    () async {
      await readySession();
      final events = <String>[];
      recordOutput(events);
      final (admission, terminal) = driver.admitPrompt('hello', (_) {});
      peer.result('k3');
      peer.send({'type': 'prompt_result', 'id': 'k3', 'status': 'completed'});
      await admission;
      await terminal;
      for (var n = 0; n < 10; n++) {
        peer.send({
          'type': 'extension_ui_request',
          'id': 'ask$n',
          'method': 'confirm',
          'title': 'request $n',
        });
      }
      final barrier = peer.client.request('get_state');
      peer.result('k4');
      await barrier;
      final replies = peer.writes.where(
        (f) => f['type'] == 'extension_ui_response',
      );
      expect(
        replies.map((command) => command['id']),
        List.generate(10, (n) => 'ask$n'),
      );
      expect(replies.every((command) => command['cancelled'] == true), isTrue);
      expect(events, hasLength(9));
      expect(events.last, contains('further OMP requests declined'));
    },
  );

  void recordEvents(List<AgentEvent> events) {
    driver.normalizeUpdate = (update) => encodeAgentEvent(
      update.event ??
          (update.kind == AgentEventKind.notice
              ? AgentEvent.notice(update.text)
              : AgentEvent.text(update.kind, update.text)),
    );
    driver.consumeNotification = (value) {
      final delivery = value as RuntimeDelivery;
      for (final line in delivery.lines) {
        events.add(AgentEvent.fromJson(jsonDecode(utf8.decode(line)) as Json));
      }
      delivery.after?.call();
    };
  }

  Json startTool(String id, String name, {Json? args}) => {
    'type': 'tool_execution_start',
    'toolCallId': id,
    'toolName': name,
    'args': args ?? {'path': '$id.txt'},
  };

  Json toolResult(
    String id,
    String name,
    String text, {
    bool progress = false,
    Object? isError,
    List<Json> extra = const [],
  }) => {
    'type': progress ? 'tool_execution_update' : 'tool_execution_end',
    'toolCallId': id,
    'toolName': name,
    'isError': ?isError,
    (progress ? 'partialResult' : 'result'): {
      'content': [
        {'type': 'text', 'text': text},
        ...extra,
      ],
      'details': {'text': 'NOT AN OUTPUT BLOCK'},
    },
  };

  void finishTurn(String id) =>
      peer.send({'type': 'prompt_result', 'id': id, 'status': 'completed'});

  Iterable<AgentEvent> cards(List<AgentEvent> events) => events.where(
    (e) => e.kind == AgentEventKind.tool || e.kind == AgentEventKind.toolUpdate,
  );

  test(
    'OMP: Root tool cards never absorb separately attributed child events',
    () async {
      await readySession();
      final events = <AgentEvent>[];
      recordEvents(events);
      final (admission, terminal) = driver.admitPrompt('hello', (_) {});
      peer.result('k3');
      await admission;
      peer.send(startTool('shared', 'read'));
      peer.send({
        ...toolResult('shared', 'read', 'child-only'),
        'childSessionId': 'child',
      });
      peer.send({
        'type': 'subagent_event',
        'event': startTool('other', 'write'),
      });
      peer.send(toolResult('shared', 'read', 'root-only'));
      finishTurn('k3');
      await terminal;
      final output = cards(events).toList();
      expect(output.map((e) => e.kind), [
        AgentEventKind.tool,
        AgentEventKind.toolUpdate,
      ]);
      expect(output.first.toolCallId, output.last.toolCallId);
      expect(output.last.status, 'completed');
      expect(output.last.content.map((c) => c['text']), contains('root-only'));
      expect(
        jsonEncode(events.map((e) => e.toJson()).toList()),
        isNot(contains('child-only')),
      );
    },
  );

  test(
    'OMP: Interleaved calls replace snapshots and complete separately',
    () async {
      await readySession();
      final events = <AgentEvent>[];
      recordEvents(events);
      final (admitted, completed) = driver.admitPrompt('one', (_) {});
      peer.result('k3');
      await admitted;
      peer.send(startTool('x', 'read'));
      peer.send(startTool('y', 'write'));
      peer.send(toolResult('x', 'read', 'first snapshot', progress: true));
      peer.send(toolResult('y', 'write', 'failed', isError: true));
      peer.send({
        'type': 'tool_stream_update',
        'toolCallId': 'x',
        'toolName': 'read',
        'update': 'opaque',
      });
      peer.send(toolResult('x', 'read', 'final'));
      finishTurn('k3');
      await completed;
      final output = cards(events).toList();
      final ids = output.take(2).map((e) => e.toolCallId).toList();
      expect(ids.toSet(), hasLength(2));
      expect(output.map((e) => e.toolCallId), [
        ids[0],
        ids[1],
        ids[0],
        ids[1],
        ids[0],
      ]);
      expect(output.map((e) => e.status), [
        'in_progress',
        'in_progress',
        'in_progress',
        'failed',
        'completed',
      ]);
      expect(output.last.content.map((c) => c['text']), [
        contains('x.txt'),
        'final',
      ]);
      expect(output.last.locations, isEmpty);
      expect(output.last.toolKind, isNull);
      final (next, done) = driver.admitPrompt('two', (_) {});
      peer.result('k4');
      await next;
      peer.send(startTool('x', 'read'));
      peer.send(toolResult('x', 'read', 'second prompt'));
      finishTurn('k4');
      await done;
      expect(cards(events).toList()[5].toolCallId, isNot(isIn(ids)));
    },
  );

  test(
    'OMP: Staged tool events follow acceptance and disappear on refusal',
    () async {
      await readySession();
      final events = <AgentEvent>[];
      recordEvents(events);
      void accepted(bool _) =>
          events.add(AgentEvent.text(AgentEventKind.user, 'prompt'));
      final (admitted, completed) = driver.admitPrompt('one', accepted);
      peer.send(startTool('early', 'read'));
      peer.send(delta('text_delta', 'middle'));
      peer.send(toolResult('early', 'read', 'result'));
      finishTurn('k3');
      peer.result('k3');
      await admitted;
      await completed;
      expect(events.map((event) => event.kind), [
        AgentEventKind.user,
        AgentEventKind.tool,
        AgentEventKind.agentText,
        AgentEventKind.toolUpdate,
      ]);
      events.clear();
      final (refused, failed) = driver.admitPrompt('two', accepted);
      final refusal = expectLater(refused, throwsA(isA<OmpRemoteException>()));
      final failure = expectLater(failed, throwsA(isA<OmpRemoteException>()));
      peer.send(startTool('early', 'read'));
      peer.send({
        'type': 'response',
        'id': 'k4',
        'success': false,
        'error': 'not admitted',
      });
      await refusal;
      await failure;
      expect(events, isEmpty);
    },
  );

  test('OMP: Missing or oversized tool data', () async {
    await readySession();
    final events = <AgentEvent>[];
    recordEvents(events);
    final (admitted, completed) = driver.admitPrompt('one', (_) {});
    peer.result('k3');
    await admitted;
    peer.send(toolResult('orphan', 'read', 'orphan payload'));
    peer.send({
      'type': 'rpc_frame_error',
      'originalType': 'tool_execution_end',
    });
    peer.send(startTool('big', 'read', args: {'arg': 'z' * 12000}));
    peer.send(toolResult('big', 'wrong-name', 'wrong tool'));
    peer.send(
      toolResult(
        'big',
        'read',
        'r' * (maxAgentToolItemBytes + 100),
        extra: [
          {'type': 'image', 'data': 'ignored data'},
        ],
      ),
    );
    peer.send(startTool('missing', 'read'));
    peer.send(toolResult('missing', 'read', 'invalid status', isError: 'true'));
    for (var i = 0; i < 16; i++) {
      peer.send(startTool('open-$i', 'write'));
    }
    finishTurn('k3');
    expect((await completed).stopReason, 'completed');
    final output = cards(events).toList();
    final starts = output.where((e) => e.kind == AgentEventKind.tool).toList();
    expect(starts, hasLength(17), reason: 'only 16 calls can be open at once');
    expect(starts.first.truncated, isTrue);
    expect(
      (starts.first.content.first['text']! as String).length,
      lessThan(4200),
    );
    final big = output
        .where((e) => e.toolCallId == starts.first.toolCallId)
        .last;
    expect(big.status, 'completed');
    expect(big.truncated, isTrue);
    expect(big.content[1]['text'], startsWith('rrrr'));
    final missing = output
        .where((e) => e.toolCallId == starts[1].toolCallId)
        .last;
    expect(missing.status, 'incomplete');
    expect(events.where((e) => e.kind == AgentEventKind.notice), hasLength(1));
    final wire = jsonEncode(events.map((e) => e.toJson()).toList());
    for (final forbidden in [
      'orphan payload',
      'wrong tool',
      'ignored data',
      'invalid status',
      'NOT AN OUTPUT BLOCK',
    ]) {
      expect(wire, isNot(contains(forbidden)));
    }
  });

  test('OMP: Recent tool ids evict in arrival order without consuming open capacity', () async {
    await readySession();
    final events = <AgentEvent>[];
    recordEvents(events);
    final (admitted, completed) = driver.admitPrompt('one', (_) {});
    peer.result('k3');
    await admitted;
    for (var i = 0; i <= 256; i++) {
      peer.send(startTool('done-$i', 'read'));
      peer.send(toolResult('done-$i', 'read', 'done'));
    }
    peer.send(startTool('done-1', 'not a new call'));
    peer.send(startTool('done-0', 'new call'));
    peer.send(toolResult('done-0', 'new call', 'last'));
    finishTurn('k3');
    await completed;
    final starts = cards(events)
        .where((e) => e.kind == AgentEventKind.tool)
        .toList();
    expect(starts, hasLength(258));
    expect(starts.last.title, 'new call');
    expect(starts.last.toolCallId, isNot(starts.first.toolCallId));
    expect(cards(events).last.status, 'completed');
  });

  test('OMP: A locally handled prompt cannot seed a later tool card', () async {
    await readySession();
    final events = <AgentEvent>[];
    recordEvents(events);
    final (admitted, done) = driver.admitPrompt('local command', (_) {});
    done.ignore();
    peer.send(startTool('shared', 'shell'));
    peer.result('k3', {'agentInvoked': false});
    peer.send(toolResult('shared', 'shell', 'late result'));
    await admitted;
    await done;

    final (next, result) = driver.admitPrompt('agent prompt', (_) {});
    peer.result('k4');
    await next;
    peer.send(startTool('shared', 'shell'));
    peer.send(toolResult('shared', 'shell', 'current result'));
    finishTurn('k4');
    await result;

    final output = cards(events).toList();
    expect(output.map((e) => e.kind), [
      AgentEventKind.tool,
      AgentEventKind.toolUpdate,
    ]);
    expect(output.first.toolCallId, output.last.toolCallId);
    expect(
      output.last.content.map((block) => block['text']),
      contains('current result'),
    );
  });

  test('OMP: Omitted arguments do not mark a tool card truncated', () async {
    await readySession();
    final events = <AgentEvent>[];
    recordEvents(events);
    final (admitted, done) = driver.admitPrompt('work', (_) {});
    peer.result('k3');
    await admitted;
    peer.send(startTool('no-args', 'clock')..remove('args'));
    peer.send(toolResult('no-args', 'clock', 'done'));
    finishTurn('k3');
    await done;
    final output = cards(events).toList();
    expect(output.first.content, isEmpty);
    expect(output.last.content.single['text'], 'done');
    expect(output.map((e) => e.truncated), [false, false]);
  });

  test('OMP: A redacted approval preview does not offer a choice', () async {
    await readySession();
    const hidden = 'test-only-sensitive-value';
    final events = <AgentEvent>[];
    final requests = <AgentPermissionRequestedParams>[];
    final ended = Completer<AgentTurnEndedParams>();
    final session = AgentSession(
      sessionId: 'host',
      driver: driver,
      onState: (_) {},
      onPermissionRequested: requests.add,
      onPermissionResolved: (_) {},
      onStopResult: (_) {},
      onTurnEnded: ended.complete,
      redact: (text) => text.replaceAll(hidden, '[redacted]'),
      enqueueEvents: (lines) {
        for (final line in lines) {
          events.add(
            AgentEvent.fromJson(jsonDecode(utf8.decode(line)) as Json),
          );
        }
      },
    )..ready(nativeSessionId: 'fixture');
    addTearDown(session.dispose);

    final admitted = session.acceptPrompt('work')!;
    peer.result('k3');
    await admitted;
    peer.send(
      approval('sensitive', title: 'Allow tool: bash\nCommand: $hidden'),
    );
    finishTurn('k3');
    expect((await ended.future).stopReason, 'completed');
    await session.eventsEnqueued;

    expect(requests, isEmpty);
    expect(peer.writes.where((f) => f['type'] == 'extension_ui_response'), [
      {'type': 'extension_ui_response', 'id': 'sensitive', 'cancelled': true},
    ]);
    expect(
      events.where((e) => e.kind == AgentEventKind.notice).single.text,
      contains('full details cannot be displayed'),
    );
    expect(events.map((e) => e.text).join(), isNot(contains(hidden)));
  });

  const facts = ToolRunFacts(
    sessionId: 'saved-session',
    role: ToolRole.coding,
    runtime: 'omp',
    adapter: 'omp-rpc',
    version: '18.20.1',
    target: '/immutable',
  );

  Json callback(String id) => {
    'type': 'host_tool_call',
    'id': id,
    'toolCallId': 'activity-$id',
    'toolName': ToolCatalog.sessionInfoName,
    'arguments': <String, Object?>{},
  };

  Iterable<Json> toolReplies() =>
      peer.writes.where((f) => f['type'] == 'host_tool_result');

  Future<void> commandBarrier(String id) async {
    final pending = peer.client.request('get_state');
    peer.result(id);
    await pending;
  }

  Future<void> bindTools(void Function() connected) async {
    final registration = driver.registerHostTools(ToolRole.coding);
    expect(peer.writes.last['type'], 'set_host_tools');
    peer.result('k3', {
      'toolNames': [ToolCatalog.sessionInfoName],
    });
    expect(await registration, isNull);
    driver.bindHostTools(facts, onSucceeded: connected);
  }

  test('OMP: Late registration acknowledgement cannot enable tools', () async {
    await readySession();
    late _ManualTimer timer;
    final result = runZoned(
      () => driver.registerHostTools(ToolRole.coding),
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) =>
            timer = _ManualTimer(callback),
      ),
    );
    expect(peer.writes.last['type'], 'set_host_tools');
    timer.fire();
    expect(await result, contains('timed out'));
    peer.result('k3', {
      'toolNames': [ToolCatalog.sessionInfoName],
    });
    peer.send(callback('late'));
    await commandBarrier('k4');
    expect(toolReplies().single, containsPair('isError', true));
    expect(
      peer.writes.where((f) => f['type'] == 'set_host_tools'),
      hasLength(1),
    );
  });

  test('OMP: Withdrawn or failed write cannot mark a tool connected (withdrawn and full)', () async {
    await readySession();
    final connected = Completer<void>();
    var uses = 0;
    await bindTools(() {
      uses++;
      connected.complete();
    });
    final blocked = peer.blockedWrite = Completer<void>();
    for (var n = 0; n < 8; n++) {
      peer.send(callback('call-$n'));
      peer.send({'type': 'host_tool_cancel', 'targetId': 'call-$n'});
    }
    peer.send(callback('excess'));
    await commandBarrier('k4');
    expect(toolReplies().map((f) => f['id']), [
      for (var n = 0; n < 8; n++) 'call-$n',
      'excess',
    ]);
    expect(
      toolReplies().where((f) => f['isError'] == true).single['id'],
      'excess',
    );
    expect(uses, 0);
    peer.blockedWrite = null;
    blocked.complete();
    await commandBarrier('k5');
    expect(uses, 0);
    peer.send(callback('new'));
    await connected.future;
    expect(uses, 1);
    expect(toolReplies().last['id'], 'new');
  });

  test(
    'OMP: Withdrawn or failed write cannot mark a tool connected (failed)',
    () async {
      await readySession();
      var uses = 0;
      await bindTools(() => uses++);
      final blocked = peer.blockedWrite = Completer<void>();
      peer.send(callback('failed-write'));
      await commandBarrier('k4');
      expect(toolReplies().single['id'], 'failed-write');
      peer.blockedWrite = null;
      blocked.completeError(StateError('write failed'));
      await peer.client.done;
      expect(uses, 0);
      expect(peer.client.failure, isA<OmpProtocolException>());
    },
  );

  Future<void> fillStdin({required int leaveBytes}) {
    const frame = {'type': 'fixture', 'value': ''};
    final overhead = utf8.encode('${jsonEncode(frame)}\n').length;
    return peer.client.send({
      ...frame,
      'value': 'x' * (1024 * 1024 - leaveBytes - overhead),
    });
  }

  test('OMP: A busy tool result falls back to a bounded refusal', () async {
    await readySession();
    final connected = Completer<void>();
    await bindTools(connected.complete);
    final blocked = peer.blockedWrite = Completer<void>();
    final filled = fillStdin(leaveBytes: 180)..ignore();
    try {
      peer.send(callback('busy-result'));
      await commandBarrier('k4');
      final reply = toolReplies().single;
      expect(reply['id'], 'busy-result');
      expect(reply['isError'], isTrue);
      expect(jsonEncode(reply['result']), contains('Kumiko tools are busy'));
      expect(connected.isCompleted, isFalse);
    } finally {
      peer.blockedWrite = null;
      blocked.complete();
    }
    await filled;
    peer.send(callback('later-result'));
    await connected.future;
    expect(toolReplies().last['id'], 'later-result');
  });

  test('OMP: An unwriteable mandatory tool refusal ends the run', () async {
    await readySession();
    var uses = 0;
    await bindTools(() => uses++);
    final blocked = peer.blockedWrite = Completer<void>();
    fillStdin(leaveBytes: 0).ignore();
    try {
      peer.send(callback('cannot-answer'));
      await peer.client.done;
      expect(peer.client.failure, isA<OmpProtocolException>());
      expect(toolReplies(), isEmpty);
      expect(uses, 0);
    } finally {
      peer.blockedWrite = null;
      blocked.complete();
    }
  });
}
