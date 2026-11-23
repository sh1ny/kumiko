import 'dart:convert';
import 'dart:typed_data';

import 'package:host/src/agent/omp/omp_client.dart';
import 'package:host/src/agent/omp/omp_driver.dart';
import 'package:host/src/agent/runtime_driver.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/omp_peer.dart';

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
    await Future<void>(() {});
    expect(peer.writes.last, {
      'type': 'extension_ui_response',
      'id': 'approval',
      'cancelled': true,
    });
    expect(events.single, contains(r'Do not hide\u202e'));
    peer.result('k3', {'agentInvoked': false});
    await admission;
    await terminal;
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
      await Future<void>(() {});
      expect(
        peer.writes.skip(3).map((command) => command['id']),
        List.generate(10, (n) => 'ask$n'),
      );
      expect(
        peer.writes.skip(3).every((command) => command['cancelled'] == true),
        isTrue,
      );
      expect(events, hasLength(9));
      expect(events.last, contains('further OMP requests declined'));
    },
  );

  test('OMP: Tool activity in a turn', () async {
    await readySession();
    final events = <String>[];
    recordOutput(events);
    final (admission, terminal) = driver.admitPrompt('hello', (_) {});
    peer.result('k3');
    for (var n = 0; n < 3; n++) {
      peer.send({'type': 'tool_execution_start', 'toolCallId': 'tool$n'});
    }
    peer.send({'type': 'prompt_result', 'id': 'k3', 'status': 'completed'});
    await admission;
    await terminal;
    expect(events.single, contains('OMP ran 3 tool calls'));
  });
}
