import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

const _caps = {
  Capability.agent,
  Capability.codex,
  Capability.agentExtensionsV1,
};

class _Pipe implements ByteSink {
  final input = StreamController<List<int>>();
  @override
  void add(List<int> bytes) => input.add(Uint8List.fromList(bytes));
  @override
  Future<void> flush() async {}
}

void main() {
  test('Codex: Compatible peers', () {
    expect(() => requireCodexCapabilities(_caps), returnsNormally);
    for (final missing in _caps) {
      expect(
        () => requireCodexCapabilities(_caps.difference({missing})),
        throwsA(
          isA<RpcException>()
              .having((e) => e.reason, 'reason', ErrorCode.methodNotAvailable)
              .having((e) => e.message, 'missing', contains(missing)),
        ),
      );
    }
  });
  test('Codex: Running turn identity published', () {
    const value = <String, Object?>{
      'sessionId': 's',
      'seq': 4,
      'state': 'running',
      'runId': 'run',
      'turnId': 'turn',
    };
    expect(AgentStateParams.fromJson(value).toJson(), value);
    expect(
      AgentStateParams.fromJson({'sessionId': 's', 'seq': 1, 'state': 'idle'})
          .toJson(),
      {'sessionId': 's', 'seq': 1, 'state': 'idle'},
    );
  });
  test('steer carries the exact run turn and draft revision', () {
    const value = <String, Object?>{
      'sessionId': 's',
      'runId': 'r',
      'expectedTurnId': 't',
      'text': 'next',
      'draftRevision': 8,
      'draftSynced': true,
    };
    expect(AgentSteerParams.fromJson(value).toJson(), value);
  });
  const question = <String, Object?>{
    'sessionId': 's',
    'seq': 5,
    'runId': 'r',
    'turnId': 't',
    'requestId': 'q',
    'rootThreadId': 'root',
    'threadId': 'child',
    'parentThreadId': 'root',
    'questions': [
      {
        'id': 'choice',
        'header': 'Choose',
        'text': 'Which?',
        'options': [
          {'id': 'yes', 'label': 'Yes'},
        ],
        'allowOther': true,
        'secret': false,
      },
    ],
  };
  test('Codex: Answer the current question', () {
    expect(AgentQuestionRequestedParams.fromJson(question).toJson(), question);
    const answer = <String, Object?>{
      'sessionId': 's',
      'runId': 'r',
      'turnId': 't',
      'requestId': 'q',
      'answers': [
        {
          'questionId': 'choice',
          'values': ['yes'],
        },
      ],
    };
    expect(AgentQuestionAnswerParams.fromJson(answer).toJson(), answer);
    const resolved = <String, Object?>{
      'sessionId': 's',
      'seq': 6,
      'runId': 'r',
      'turnId': 't',
      'requestId': 'q',
      'outcome': 'answered',
      'rootThreadId': 'root',
      'threadId': 'child',
      'parentThreadId': 'root',
    };
    expect(AgentQuestionResolvedParams.fromJson(resolved).toJson(), resolved);
  });
  test('extended controls require all negotiated capabilities', () {
    expect(methodCapability[Method.agentSteer], Capability.agentExtensionsV1);
    expect(
      methodCapability[Method.agentQuestionAnswer],
      Capability.agentExtensionsV1,
    );
  });
  test('identity and answer payloads are bounded without truncating IDs', () {
    final badId = 'x' * 4097;
    expect(
      () => AgentSteerParams.fromJson({
        'sessionId': 's',
        'runId': badId,
        'expectedTurnId': 't',
        'text': 'next',
      }),
      throwsA(isA<RpcException>()),
    );
    expect(
      () => AgentStateParams.fromJson({
        'sessionId': 's',
        'seq': 1,
        'state': 'running',
        'turnId': 't',
      }),
      throwsA(isA<RpcException>()),
    );
    expect(
      () => AgentQuestionRequestedParams.fromJson({
        ...question,
        'questions': [
          {
            'id': 'q',
            'text': 'x' * 65536,
            'header': '',
            'options': <Json>[],
            'allowOther': false,
            'secret': false,
          },
        ],
      }),
      throwsA(isA<RpcException>()),
    );
    expect(
      () => AgentQuestionAnswerParams.fromJson({
        'sessionId': 's',
        'runId': 'r',
        'turnId': 't',
        'requestId': 'q',
        'answers': [
          {
            'questionId': 'q',
            'values': ['x' * 65536],
          },
        ],
      }),
      throwsA(isA<RpcException>()),
    );
    expect(utf8.encode(jsonEncode(question)).length, lessThan(65536));
  });
  test('outbound constructors enforce the same encoded bounds', () {
    expect(
      () => const AgentStateParams(
        sessionId: 's',
        seq: 1,
        state: AgentState.running,
        turnId: 't',
      ).toJson(),
      throwsA(isA<RpcException>()),
    );
    expect(
      () => AgentSteerParams(
        sessionId: 's',
        runId: 'x' * 4097,
        expectedTurnId: 't',
        text: 'next',
      ).toJson(),
      throwsA(isA<RpcException>()),
    );
    expect(
      () => AgentQuestionRequestedParams(
        sessionId: 's',
        seq: 1,
        runId: 'r',
        requestId: 'q',
        questions: [AgentQuestion(id: 'q', header: '', text: 'x' * 65536)],
      ).toJson(),
      throwsA(isA<RpcException>()),
    );
    expect(
      () => AgentQuestionAnswerParams(
        sessionId: 's',
        runId: 'r',
        requestId: 'q',
        answers: [
          AgentQuestionAnswer(questionId: 'q', values: ['x' * 65536]),
        ],
      ).toJson(),
      throwsA(isA<RpcException>()),
    );
  });
  test(
    'question codecs traverse priority control while data has no credit',
    () async {
      final toHost = _Pipe();
      final toDesktop = _Pipe();
      final seen = Completer<AgentQuestionRequestedParams>();
      AgentQuestionAnswerParams? answer;
      final desktop = Connection(
        input: toDesktop.input.stream,
        output: toHost,
        capabilities: _caps,
        onNotification: (method, params) {
          if (method == Method.agentQuestionRequested) {
            seen.complete(AgentQuestionRequestedParams.fromJson(params));
          }
        },
      );
      final host = Connection(
        input: toHost.input.stream,
        output: toDesktop,
        capabilities: _caps,
        onHello: (_, _) => HelloInfo.ready('host'),
        onRequest: (method, params) {
          requireCodexCapabilities(_caps);
          if (method != Method.agentQuestionAnswer) {
            throw RpcException(ErrorCode.methodNotAvailable, method);
          }
          answer = AgentQuestionAnswerParams.fromJson(params);
          return const EmptyResult().toJson();
        },
      );
      addTearDown(() async {
        await host.close();
        await desktop.close();
        await toHost.input.close();
        await toDesktop.input.close();
      });
      await desktop.hello();
      final channel = host.openOutbound();
      var drained = false;
      channel
          .write(Uint8List(512))
          .then<void>((_) => drained = true, onError: (Object _) {});
      host.notify(
        Method.agentQuestionRequested,
        AgentQuestionRequestedParams.fromJson(question).toJson(),
      );
      expect((await seen.future).runId, 'r');
      await desktop.request(
        Method.agentQuestionAnswer,
        AgentQuestionAnswerParams(
          sessionId: 's',
          runId: 'r',
          turnId: 't',
          requestId: 'q',
          answers: const [
            AgentQuestionAnswer(questionId: 'choice', values: ['yes']),
          ],
        ).toJson(),
      );
      expect(answer!.requestId, 'q');
      expect(answer!.answers.single.values, ['yes']);
      expect(drained, isFalse);
    },
  );
}
