part of 'messages.dart';

/// Native Codex control is usable only when both peers negotiated this set.
void requireCodexCapabilities(Set<String> capabilities) {
  for (final needed in const [
    Capability.agent,
    Capability.codex,
    Capability.agentExtensionsV1,
  ]) {
    if (!capabilities.contains(needed)) {
      throw RpcException(
        ErrorCode.methodNotAvailable,
        'Codex requires $needed',
      );
    }
  }
}

String _codexId(Json json, String key) {
  final value = _req<String>(json, key);
  if (value.isEmpty || jsonStringContentBytes(value) > 4096) {
    throw RpcException(ErrorCode.invalidParams, 'invalid "$key" identity');
  }
  return value;
}

String? _codexOptionalId(Json json, String key) =>
    json[key] == null ? null : _codexId(json, key);

void _codexControlBound(Json json, [int limit = 64 * 1024]) {
  if (utf8.encode(jsonEncode(json)).length > limit) {
    throw RpcException(
      ErrorCode.invalidParams,
      'extended control exceeds $limit encoded bytes',
    );
  }
}

int _codexSeq(Json json) {
  final seq = _req<int>(json, 'seq');
  if (seq < 0) throw RpcException(ErrorCode.invalidParams, 'invalid "seq"');
  return seq;
}

class AgentSteerParams {
  factory AgentSteerParams({
    required String sessionId,
    required String runId,
    required String expectedTurnId,
    required String text,
    int? draftRevision,
    bool? draftSynced,
  }) => AgentSteerParams.fromJson({
    'sessionId': sessionId,
    'runId': runId,
    'expectedTurnId': expectedTurnId,
    'text': text,
    'draftRevision': ?draftRevision,
    'draftSynced': ?draftSynced,
  });
  const AgentSteerParams._({
    required this.sessionId,
    required this.runId,
    required this.expectedTurnId,
    required this.text,
    this.draftRevision,
    this.draftSynced,
  });
  factory AgentSteerParams.fromJson(Json json) {
    // Leave headroom for the JSON-RPC envelope within the 1 MiB control cap.
    _codexControlBound(json, 1024 * 1024 - 4096);
    final prompt = AgentPromptParams.fromJson(json);
    return AgentSteerParams._(
      sessionId: _codexId(json, 'sessionId'),
      runId: _codexId(json, 'runId'),
      expectedTurnId: _codexId(json, 'expectedTurnId'),
      text: prompt.text,
      draftRevision: prompt.draftRevision,
      draftSynced: prompt.draftSynced,
    );
  }
  final String sessionId;
  final String runId;
  final String expectedTurnId;
  final String text;
  final int? draftRevision;
  final bool? draftSynced;
  Json toJson() => {
    'sessionId': sessionId,
    'runId': runId,
    'expectedTurnId': expectedTurnId,
    'text': text,
    'draftRevision': ?draftRevision,
    'draftSynced': ?draftSynced,
  };
}

class AgentQuestionOption {
  const AgentQuestionOption({
    required this.id,
    required this.label,
    this.description,
  });
  factory AgentQuestionOption.fromJson(Json json) => AgentQuestionOption(
    id: _codexId(json, 'id'),
    label: _req<String>(json, 'label'),
    description: _opt<String>(json, 'description'),
  );
  final String id;
  final String label;
  final String? description;
  Json toJson() => {'id': id, 'label': label, 'description': ?description};
}

class AgentQuestion {
  const AgentQuestion({
    required this.id,
    required this.header,
    required this.text,
    this.options = const [],
    this.allowOther = false,
    this.secret = false,
  });
  factory AgentQuestion.fromJson(Json json) {
    final options = [
      for (final value in _list<Json>(json, 'options'))
        AgentQuestionOption.fromJson(value),
    ];
    if (options.map((o) => o.id).toSet().length != options.length) {
      throw RpcException(
        ErrorCode.invalidParams,
        'duplicate question option identity',
      );
    }
    return AgentQuestion(
      id: _codexId(json, 'id'),
      header: _req<String>(json, 'header'),
      text: _req<String>(json, 'text'),
      options: options,
      allowOther: _opt<bool>(json, 'allowOther') ?? false,
      secret: _opt<bool>(json, 'secret') ?? false,
    );
  }
  final String id;
  final String header;
  final String text;
  final List<AgentQuestionOption> options;
  final bool allowOther;
  final bool secret;
  Json toJson() => {
    'id': id,
    'header': header,
    'text': text,
    'options': [for (final o in options) o.toJson()],
    'allowOther': allowOther,
    'secret': secret,
  };
}

class AgentQuestionRequestedParams {
  factory AgentQuestionRequestedParams({
    required String sessionId,
    required int seq,
    required String runId,
    required String requestId,
    required List<AgentQuestion> questions,
    String? turnId,
    String? rootThreadId,
    String? threadId,
    String? parentThreadId,
  }) => AgentQuestionRequestedParams.fromJson({
    'sessionId': sessionId,
    'seq': seq,
    'runId': runId,
    'requestId': requestId,
    'questions': [for (final q in questions) q.toJson()],
    'turnId': ?turnId,
    'rootThreadId': ?rootThreadId,
    'threadId': ?threadId,
    'parentThreadId': ?parentThreadId,
  });
  const AgentQuestionRequestedParams._({
    required this.sessionId,
    required this.seq,
    required this.runId,
    required this.requestId,
    required this.questions,
    this.turnId,
    this.rootThreadId,
    this.threadId,
    this.parentThreadId,
  });
  factory AgentQuestionRequestedParams.fromJson(Json json) {
    _codexControlBound(json);
    final questions = [
      for (final q in _list<Json>(json, 'questions')) AgentQuestion.fromJson(q),
    ];
    if (questions.isEmpty ||
        questions.map((q) => q.id).toSet().length != questions.length) {
      throw RpcException(
        ErrorCode.invalidParams,
        'invalid question identities',
      );
    }
    return AgentQuestionRequestedParams._(
      sessionId: _codexId(json, 'sessionId'),
      seq: _codexSeq(json),
      runId: _codexId(json, 'runId'),
      requestId: _codexId(json, 'requestId'),
      questions: questions,
      turnId: _codexOptionalId(json, 'turnId'),
      rootThreadId: _codexOptionalId(json, 'rootThreadId'),
      threadId: _codexOptionalId(json, 'threadId'),
      parentThreadId: _codexOptionalId(json, 'parentThreadId'),
    );
  }
  final String sessionId;
  final int seq;
  final String runId;
  final String requestId;
  final String? turnId;
  final String? rootThreadId;
  final String? threadId;
  final String? parentThreadId;
  final List<AgentQuestion> questions;
  Json toJson() => _checkedCodexControl({
    'sessionId': sessionId,
    'seq': seq,
    'runId': runId,
    'requestId': requestId,
    'turnId': ?turnId,
    'rootThreadId': ?rootThreadId,
    'threadId': ?threadId,
    'parentThreadId': ?parentThreadId,
    'questions': [for (final q in questions) q.toJson()],
  });
}

class AgentQuestionAnswer {
  const AgentQuestionAnswer({required this.questionId, required this.values});
  factory AgentQuestionAnswer.fromJson(Json json) => AgentQuestionAnswer(
    questionId: _codexId(json, 'questionId'),
    values: _list<String>(json, 'values'),
  );
  final String questionId;
  final List<String> values;
  Json toJson() => {'questionId': questionId, 'values': values};
}

class AgentQuestionAnswerParams {
  factory AgentQuestionAnswerParams({
    required String sessionId,
    required String runId,
    required String requestId,
    required List<AgentQuestionAnswer> answers,
    String? turnId,
  }) => AgentQuestionAnswerParams.fromJson({
    'sessionId': sessionId,
    'runId': runId,
    'requestId': requestId,
    'answers': [for (final a in answers) a.toJson()],
    'turnId': ?turnId,
  });
  const AgentQuestionAnswerParams._({
    required this.sessionId,
    required this.runId,
    required this.requestId,
    required this.answers,
    this.turnId,
  });
  factory AgentQuestionAnswerParams.fromJson(Json json) {
    _codexControlBound(json);
    final answers = [
      for (final answer in _list<Json>(json, 'answers'))
        AgentQuestionAnswer.fromJson(answer),
    ];
    if (answers.map((a) => a.questionId).toSet().length != answers.length) {
      throw RpcException(ErrorCode.invalidParams, 'duplicate answer identity');
    }
    return AgentQuestionAnswerParams._(
      sessionId: _codexId(json, 'sessionId'),
      runId: _codexId(json, 'runId'),
      requestId: _codexId(json, 'requestId'),
      turnId: _codexOptionalId(json, 'turnId'),
      answers: answers,
    );
  }
  final String sessionId;
  final String runId;
  final String requestId;
  final String? turnId;
  final List<AgentQuestionAnswer> answers;
  Json toJson() => _checkedCodexControl({
    'sessionId': sessionId,
    'runId': runId,
    'requestId': requestId,
    'turnId': ?turnId,
    'answers': [for (final a in answers) a.toJson()],
  });
}

enum AgentQuestionOutcome { answered, cancelled, unavailable }

class AgentQuestionResolvedParams {
  factory AgentQuestionResolvedParams({
    required String sessionId,
    required int seq,
    required String runId,
    required String requestId,
    required AgentQuestionOutcome outcome,
    String? turnId,
    String? rootThreadId,
    String? threadId,
    String? parentThreadId,
  }) => AgentQuestionResolvedParams.fromJson({
    'sessionId': sessionId,
    'seq': seq,
    'runId': runId,
    'requestId': requestId,
    'outcome': outcome.name,
    'turnId': ?turnId,
    'rootThreadId': ?rootThreadId,
    'threadId': ?threadId,
    'parentThreadId': ?parentThreadId,
  });
  const AgentQuestionResolvedParams._({
    required this.sessionId,
    required this.seq,
    required this.runId,
    required this.requestId,
    required this.outcome,
    this.turnId,
    this.rootThreadId,
    this.threadId,
    this.parentThreadId,
  });
  factory AgentQuestionResolvedParams.fromJson(Json json) {
    _codexControlBound(json);
    return AgentQuestionResolvedParams._(
      sessionId: _codexId(json, 'sessionId'),
      seq: _codexSeq(json),
      runId: _codexId(json, 'runId'),
      requestId: _codexId(json, 'requestId'),
      outcome: _enum(AgentQuestionOutcome.values, json, 'outcome'),
      turnId: _codexOptionalId(json, 'turnId'),
      rootThreadId: _codexOptionalId(json, 'rootThreadId'),
      threadId: _codexOptionalId(json, 'threadId'),
      parentThreadId: _codexOptionalId(json, 'parentThreadId'),
    );
  }
  final String sessionId;
  final int seq;
  final String runId;
  final String requestId;
  final AgentQuestionOutcome outcome;
  final String? turnId;
  final String? rootThreadId;
  final String? threadId;
  final String? parentThreadId;
  Json toJson() => _checkedCodexControl({
    'sessionId': sessionId,
    'seq': seq,
    'runId': runId,
    'requestId': requestId,
    'outcome': outcome.name,
    'turnId': ?turnId,
    'rootThreadId': ?rootThreadId,
    'threadId': ?threadId,
    'parentThreadId': ?parentThreadId,
  });
}

Json _checkedCodexControl(Json json) {
  _codexControlBound(json);
  return json;
}
