import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';

import 'acp/acp_client.dart';
import 'codex/codex_client.dart';
import 'qualification.dart';
import 'qualified_adapters.dart';
import 'runtime_transport.dart';

class RuntimeIdentity {
  RuntimeIdentity(this.name, this.version, this.claims);
  final String name, version;
  final AdapterClaims claims;
}

class RuntimeChoice {
  RuntimeChoice(this.label, this.result, this.kind);
  final String label, kind;
  final Json result;
}

class RuntimePermission {
  RuntimePermission(
    this.id,
    this.turnId,
    this.title,
    this.preview,
    this.choices,
    this.cancellation,
  );
  final Object id;
  final String turnId, title;
  final String? preview;
  final List<RuntimeChoice> choices;
  final Json cancellation;
}

class RuntimeQuestion {
  RuntimeQuestion(
    this.id,
    this.turnId,
    this.questions, {
    this.asyncItem = false,
  });
  final bool asyncItem;
  final Object id;
  final String turnId;
  final List<AgentQuestion> questions;
}

class RuntimeReply {
  RuntimeReply(this.id, this.result);
  final Object id;
  final Json result;
}

class RuntimeUpdate {
  RuntimeUpdate(
    this.kind,
    this.text, {
    this.truncated = false,
    this.event,
    this.question,
    this.optionalNotice,
  });
  final RuntimeQuestion? question;
  final String? optionalNotice;
  final bool truncated;
  final AgentEvent? event;
  final AgentEventKind kind;
  final String text;
}

class RuntimeTurnResult {
  const RuntimeTurnResult(
    this.stopReason, {
    this.isCancelled = false,
    this.truncated = false,
    this.error,
  });
  final String stopReason;
  final Object? error;
  final bool isCancelled, truncated;
}

/// Operation mapping only. Service owns units/records/drafts; AgentSession owns
/// root state and interaction records. No parallel lifecycle or raw event queue.
abstract class RuntimeDriver implements RuntimeTransport {
  RuntimeTransport get transport;
  AcpClient? get acp => null;
  String? get turnId => null;
  void observeExit() {}
  Object? Function(RuntimeUpdate)? normalizeUpdate;
  bool Function(int)? reserveEarly;
  void Function(int)? releaseEarly;
  void Function()? onTurnIdentity;
  Object? Function(RuntimePermission)? onPermission;
  Object? Function(RuntimeQuestion)? onQuestion;
  void Function(Object?)? onRetired;
  void checkCanSteer(String expectedTurn) => throw RpcException(
    ErrorCode.methodNotAvailable,
    'native steering unavailable',
  );
  Future<void> steer(String thread, String expectedTurn, String text) =>
      throw RpcException(
        ErrorCode.methodNotAvailable,
        'native steering unavailable',
      );
  bool get largeLineOwned;
  bool get largeLineWaiting;
  Future<RuntimeIdentity> initialize();
  Future<String> newSession(
    String cwd, {
    List<Json> mcpServers = const [],
    void Function(String)? onCreated,
  });
  Future<void> loadSession(
    String id,
    String cwd, {
    List<Json> mcpServers = const [],
  });
  Future<void> resumeSession(
    String id,
    String cwd, {
    List<Json> mcpServers = const [],
  });
  Future<RuntimeTurnResult> prompt(String id, String text);
  Future<void> cancel(String id);
  Future<void> cancelWithPermissions(String id, Iterable<Object> requests);
  Future<void> reply(Object id, Json result);
  @override
  bool get isClosed => transport.isClosed;
  @override
  Object? get failure => transport.failure;
  @override
  Future<void> get done => transport.done;
  @override
  set onFailure(void Function(Object)? handler) =>
      transport.onFailure = handler;
  @override
  set consumeNotification(FutureOr<void> Function(Object)? handler) =>
      transport.consumeNotification = handler;
  @override
  Future<void> close() => transport.close();
}

class AcpRuntimeDriver extends RuntimeDriver {
  AcpRuntimeDriver(this.client, {this.qualified = qualifiedAdapters});
  final AcpClient client;
  final List<(String, String, List<String>)> qualified;
  @override
  AcpClient get acp => client;
  @override
  RuntimeTransport get transport => client;
  @override
  bool get largeLineOwned => client.largeLineOwned;
  @override
  bool get largeLineWaiting => client.largeLineWaiting;
  @override
  Future<RuntimeIdentity> initialize() async {
    final i = await client.initialize();
    return RuntimeIdentity(
      i.adapterName,
      i.adapterVersion ?? '',
      qualifyAdapter(i, qualified: qualified),
    );
  }

  @override
  Future<String> newSession(
    String cwd, {
    List<Json> mcpServers = const [],
    void Function(String)? onCreated,
  }) => client.newSession(cwd, mcpServers: mcpServers, onCreated: onCreated);
  @override
  Future<void> loadSession(
    String id,
    String cwd, {
    List<Json> mcpServers = const [],
  }) async {
    await client.loadSession(id, cwd, mcpServers: mcpServers);
  }

  @override
  Future<void> resumeSession(
    String id,
    String cwd, {
    List<Json> mcpServers = const [],
  }) async {
    await client.resumeSession(id, cwd, mcpServers: mcpServers);
  }

  @override
  Future<RuntimeTurnResult> prompt(String id, String text) => client
      .prompt(id, text)
      .then(
        (r) => RuntimeTurnResult(
          r.stopReason,
          isCancelled: r.isCancelled,
          truncated: r.truncated,
        ),
      );
  @override
  Future<void> cancel(String id) => client.cancel(id);
  @override
  Future<void> cancelWithPermissions(String id, Iterable<Object> requests) =>
      client.cancelWithPermissions(id, requests);
  @override
  Future<void> reply(Object id, Json result) => client.reply(id, result);
}

class RuntimeDelivery {
  RuntimeDelivery(this.lines, this.bytes, this._release, this.after);
  final Iterable<Uint8List> lines;
  final int bytes;
  final void Function(int)? _release;
  final void Function()? after;
  bool released = false;
  void release() {
    if (released) return;
    released = true;
    _release?.call(bytes);
  }
}

class _EarlyNative {
  _EarlyNative(
    this.turn,
    this.bytes, {
    this.update,
    this.terminal,
    this.interaction,
  });
  final String turn;
  final int bytes;
  final Object? interaction;
  final RuntimeUpdate? update;
  final RuntimeTurnResult? terminal;
}

class CodexRuntimeDriver extends RuntimeDriver {
  CodexRuntimeDriver(this.client, this.version) {
    client.normalizeNotification = _notification;
    client.onRequest = _request;
    client.takeBuffered = _takeBuffered;
    client.onUnsupported = (feature, reason) => normalizeUpdate?.call(
      RuntimeUpdate(AgentEventKind.notice, '$feature unavailable: $reason'),
    );
    client.onFailure = (error) {
      _retireMapping(error);
      _onFailure?.call(error);
    };
  }
  final CodexClient client;
  final String version;
  String? root;
  String? _turnId;
  String? _earlyId;
  bool _unknownChildNoticed = false;
  bool _nativeExited = false;
  @override
  void observeExit() {
    _nativeExited = true;
  }

  bool _steeringUnavailable = false;
  final _itemFlags = <String, int>{};
  bool _identityOmissionPending = false;
  bool _identityOmissionShown = false;
  bool _seenItem(String key, int mask) => ((_itemFlags[key] ?? 0) & mask) != 0;
  void _markItem(String key, int mask) {
    if (!_itemFlags.containsKey(key) && _itemFlags.length >= 4096) {
      _itemFlags.remove(_itemFlags.keys.first);
      if (!_identityOmissionShown) _identityOmissionPending = true;
    }
    _itemFlags[key] = (_itemFlags[key] ?? 0) | mask;
  }

  Completer<RuntimeTurnResult>? _turn;
  final _early = <_EarlyNative>[];
  int _earlyBytes = 0;
  RuntimeDelivery? _delivery;
  void Function(Object)? _onFailure;
  @override
  set onFailure(void Function(Object)? handler) => _onFailure = handler;
  @override
  String? get turnId => _turnId;
  @override
  RuntimeTransport get transport => client;
  @override
  bool get largeLineOwned => client.largeLineOwned;
  @override
  bool get largeLineWaiting => client.largeLineWaiting;
  @override
  Future<RuntimeIdentity> initialize() async {
    final i = await client.initialize();
    if (i.version != null && i.version != version) {
      throw CodexProtocolException('Codex initialization version mismatch');
    }
    return RuntimeIdentity(
      'codex-app-server',
      version,
      AdapterClaims(const [
        'prompt',
        'streaming',
        'tools',
        'permissions',
        'cancel',
        'steer',
        'questions',
      ], 'native-history-unavailable'),
    );
  }

  @override
  Future<String> newSession(
    String cwd, {
    List<Json> mcpServers = const [],
    void Function(String)? onCreated,
  }) => client.request(
    'thread/start',
    {'cwd': cwd},
    decodeResult: (result) {
      if (result is! Json || result['thread'] is! Json) {
        throw CodexProtocolException('invalid thread/start');
      }
      final id = _identity(result['thread']! as Json, 'id');
      for (final key in [
        'model',
        'modelProvider',
        'cwd',
        'approvalsReviewer',
      ]) {
        if (result[key] is! String) {
          throw CodexProtocolException('invalid thread/start $key');
        }
      }
      final policy = result['approvalPolicy'];
      if (policy is! String &&
          !(policy is Json && policy['granular'] is Json)) {
        throw CodexProtocolException('invalid thread/start approvalPolicy');
      }
      if (result['sandbox'] is! Json) {
        throw CodexProtocolException('invalid thread/start sandbox');
      }
      root = id;
      onCreated?.call(id);
      return id;
    },
  );
  @override
  Future<void> loadSession(
    String id,
    String cwd, {
    List<Json> mcpServers = const [],
  }) => throw RpcException(
    ErrorCode.resumeUnavailable,
    'native history unavailable',
  );
  @override
  Future<void> resumeSession(
    String id,
    String cwd, {
    List<Json> mcpServers = const [],
  }) => throw RpcException(
    ErrorCode.resumeUnavailable,
    'native history unavailable',
  );
  @override
  Future<RuntimeTurnResult> prompt(String id, String text) {
    if (_turn != null) {
      throw RpcException(
        ErrorCode.turnRunning,
        'native turn is already active',
      );
    }
    final completion = Completer<RuntimeTurnResult>();
    _turn = completion;
    _turnId = null;
    _earlyId = null;
    Future<String> accepted;
    try {
      accepted = client.request(
        'turn/start',
        {
          'threadId': id,
          'input': [
            {'type': 'text', 'text': text},
          ],
        },
        requireAdmission: true,
        decodeResult: (result) {
          if (result is! Json || result['turn'] is! Json) {
            throw CodexProtocolException('invalid turn/start');
          }
          final native = result['turn']! as Json;
          final turn = _identity(native, 'id');
          if (native['status'] is! String || native['items'] is! List) {
            throw CodexProtocolException('invalid turn/start state');
          }
          _turnId = turn;
          onTurnIdentity?.call();
          return turn;
        },
      );
    } on Object {
      _turn = null;
      rethrow;
    }
    accepted.then<void>(
      (_) {},
      onError: (Object error, StackTrace st) {
        if (identical(_turn, completion)) {
          _retireMapping(error);
          if (error is TimeoutException) {
            client.close().ignore();
            _onFailure?.call(error);
          }
        }
      },
    );
    return completion.future;
  }

  void _retireMapping(Object error) {
    final c = _turn;
    _turn = null;
    _turnId = null;
    _earlyId = null;
    releaseEarly?.call(_earlyBytes);
    _earlyBytes = 0;
    _early.clear();
    _delivery?.release();
    _delivery = null;
    if (c != null && !c.isCompleted) c.completeError(error);
  }

  @override
  Future<void> close() async {
    _retireMapping(CodexProtocolException('native transport closed'));
    await client.close();
  }

  void _complete(RuntimeTurnResult result) {
    final c = _turn;
    _turn = null;
    _turnId = null;
    _earlyId = null;
    onRetired?.call(null);
    if (c != null && !c.isCompleted) c.complete(result);
  }

  void _stage(
    String turn, {
    RuntimeUpdate? update,
    RuntimeTurnResult? terminal,
    Object? interaction,
    int? charge,
  }) {
    final value =
        update?.event?.toJson() ??
        {
          'kind': update?.kind.name,
          'text': update?.text,
          'truncated': update?.truncated,
          if (update?.question != null)
            'questions': [
              for (final q in update!.question!.questions) q.toJson(),
            ],
        };
    final bytes =
        charge ??
        (update == null ? 256 : _boundedJsonBytes(value, 256 * 1024) + 1024);
    if (_early.length >= 64 ||
        _earlyBytes + bytes > 256 * 1024 ||
        !(reserveEarly?.call(bytes) ?? true)) {
      throw CodexProtocolException(
        'early native correlation capacity exceeded',
      );
    }
    _earlyBytes += bytes;
    _early.add(
      _EarlyNative(
        turn,
        bytes,
        update: update,
        terminal: terminal,
        interaction: interaction,
      ),
    );
  }

  Object? _takeBuffered() {
    if (_turnId == null || _early.isEmpty) return null;
    final lines = <Uint8List>[];
    RuntimeTurnResult? terminal;
    for (final record in _early) {
      if (record.turn != _turnId) {
        if (record.interaction case final RuntimePermission p) {
          client.replyAdmitted(p.id, p.cancellation).ignore();
        }
        if (record.interaction case final RuntimeQuestion q) {
          client.replyAdmitted(q.id, {'answers': {}}).ignore();
        }
        continue;
      }
      Object? interactionResult;
      if (record.interaction case final RuntimePermission p) {
        interactionResult = onPermission?.call(p);
      }
      if (record.interaction case final RuntimeQuestion q) {
        interactionResult = onQuestion?.call(q);
      }
      if (interactionResult is Iterable<Uint8List>) {
        lines.addAll(interactionResult);
      }
      if (record.update case final update?) {
        final normalized = normalizeUpdate?.call(update);
        if (normalized is Iterable<Uint8List>) lines.addAll(normalized);
      }
      terminal ??= record.terminal;
    }
    final bytes = _earlyBytes;
    _early.clear();
    _earlyBytes = 0;
    if (lines.fold<int>(0, (n, line) => n + line.length) > bytes) {
      throw CodexProtocolException(
        'early normalized output exceeds reserved credit',
      );
    }
    late final RuntimeDelivery delivery;
    delivery = RuntimeDelivery(lines, bytes, releaseEarly, () {
      if (identical(_delivery, delivery)) _delivery = null;
      if (terminal != null) _complete(terminal);
    });
    _delivery = delivery;
    return delivery;
  }

  Object? _notification(String method, Object? raw) {
    if (method == 'serverRequest/resolved' && raw is Json) {
      _identity(raw, 'threadId');
      if (raw['requestId'] is! String && raw['requestId'] is! int) {
        throw CodexProtocolException('invalid resolved request identity');
      }
      if (raw['threadId'] == root) onRetired?.call(raw['requestId']);
      return null;
    }
    if (raw is Json && raw['threadId'] is String && raw['threadId'] != root) {
      if (_unknownChildNoticed) return null;
      _unknownChildNoticed = true;
      return normalizeUpdate?.call(
        RuntimeUpdate(
          AgentEventKind.notice,
          'Codex unknown child ${clampJsonString(raw['threadId'].toString(), 4096)} activity withheld; relationship unavailable.',
        ),
      );
    }
    if (method == 'thread/started') {
      if (raw is! Json || raw['thread'] is! Json) {
        return normalizeUpdate?.call(
          RuntimeUpdate(
            AgentEventKind.notice,
            'Child metadata unavailable: unsupported optional shape.',
          ),
        );
      }
      final thread = raw['thread']! as Json;
      if (thread['id'] != root && !_unknownChildNoticed) {
        _unknownChildNoticed = true;
        return normalizeUpdate?.call(
          RuntimeUpdate(
            AgentEventKind.notice,
            'Codex unknown child activity withheld; relationship unavailable.',
          ),
        );
      }
      return null;
    }
    const core = {
      'turn/started',
      'turn/completed',
      'item/agentMessage/delta',
      'item/started',
      'item/completed',
      'item/commandExecution/outputDelta',
      'item/fileChange/outputDelta',
    };
    if (!core.contains(method)) return null;
    if (raw is! Json) throw CodexProtocolException('invalid $method');
    _identity(raw, 'threadId');
    final turnData = raw['turn'];
    final turn = method == 'turn/completed' || method == 'turn/started'
        ? (turnData is Json
              ? _identity(turnData, 'id')
              : throw CodexProtocolException('invalid turn event'))
        : _identity(raw, 'turnId');
    RuntimeTurnResult? terminal;
    RuntimeUpdate? update;
    if (method == 'turn/completed') {
      final data = turnData! as Json;
      final status = data['status'];
      if (!const ['completed', 'interrupted', 'failed'].contains(status)) {
        throw CodexProtocolException('invalid native terminal status');
      }
      final nativeError = data['error'];
      if (nativeError != null &&
          (nativeError is! Json || nativeError['message'] is! String)) {
        throw CodexProtocolException('invalid terminal error');
      }
      terminal = RuntimeTurnResult(
        status == 'interrupted'
            ? 'cancelled'
            : status == 'failed'
            ? 'error'
            : 'end_turn',
        isCancelled: status == 'interrupted',
        error: status == 'failed'
            ? CodexRemoteException(
                null,
                nativeError is Json
                    ? nativeError['message']! as String
                    : 'Native turn failed',
              )
            : null,
      );
    } else if (method == 'item/agentMessage/delta') {
      final itemId = _identity(raw, 'itemId');
      _markItem('$turn:$itemId', 1);
      final text = raw['delta'];
      if (text is! String) {
        throw CodexProtocolException('invalid message delta');
      }
      final bounded = clampUtf8(text, maxAgentTextChunkBytes);
      update = RuntimeUpdate(
        AgentEventKind.agentText,
        bounded,
        truncated: bounded.length != text.length,
      );
    } else if (method == 'turn/started') {
      if (turnData is! Json || turnData['status'] is! String) {
        throw CodexProtocolException('invalid turn/started');
      }
    } else {
      // Item mapping is reduced to bounded typed updates before leaving the
      // host-wide native line permit, including when the run has become idle.
      update = _item(method, raw);
    }
    if (raw['threadId'] != root || _turn == null) return null;
    if (update != null &&
        _identityOmissionPending &&
        (_turnId == null || turn == _turnId)) {
      _identityOmissionPending = false;
      _identityOmissionShown = true;
      update = RuntimeUpdate(
        update.kind,
        update.text,
        truncated: update.truncated,
        event: update.event,
        question: update.question,
        optionalNotice:
            'Native item identity history truncated at 4096 keys. ${update.optionalNotice ?? ''}',
      );
    }

    if (_turnId == null) {
      if (update != null || terminal != null) {
        _stage(turn, update: update, terminal: terminal);
      }
      return null;
    }
    if (turn != _turnId) return null;
    if (terminal != null) {
      _complete(terminal);
      return null;
    }
    return update == null ? null : normalizeUpdate?.call(update);
  }

  RuntimeUpdate? _item(String method, Json raw) {
    if (method.endsWith('outputDelta')) {
      final id = _identity(raw, 'itemId');
      final delta = raw['delta'];
      if (delta is! String) throw CodexProtocolException('invalid tool delta');
      final bounded = clampUtf8(delta, maxAgentToolItemBytes);
      return RuntimeUpdate(
        AgentEventKind.toolUpdate,
        '',
        event: _toolWithLoss(
          AgentEvent.tool(
            toolCallId: '$root:$id',
            update: true,
            content: [
              {
                'type': 'content',
                'content': {'type': 'text', 'text': bounded},
              },
            ],
          ),
          truncated: bounded != delta,
        ),
      );
    }
    final item = raw['item'];
    if (item is! Json) throw CodexProtocolException('invalid native item');
    final id = _identity(item, 'id');
    final type = item['type'];
    if (type is! String) throw CodexProtocolException('missing item type');
    final completed = method == 'item/completed';
    if (type == 'agentMessage') {
      final text = item['text'];
      if (text is! String) {
        throw CodexProtocolException('invalid agent message item');
      }
      if (!completed) return null;
      final key = '${raw['turnId']}:$id';
      if (_seenItem(key, 2)) return null;
      _markItem(key, 2);
      RuntimeQuestion? question;
      String? optionalNotice;
      final nativeQuestions = item['questions'];
      if (nativeQuestions != null) {
        try {
          if (_steeringUnavailable) {
            throw const FormatException('native steering unavailable');
          }
          if (nativeQuestions is! List ||
              _boundedJsonBytes(nativeQuestions, 64 * 1024) > 64 * 1024) {
            throw const FormatException('invalid async questions');
          }
          final questions = <AgentQuestion>[];
          for (var i = 0; i < nativeQuestions.length; i++) {
            final q = nativeQuestions[i];
            if (q is! Json || q['title'] is! String) {
              throw const FormatException('invalid async question');
            }
            final options = q['options'];
            if (options != null &&
                (options is! List || options.any((o) => o is! String))) {
              throw const FormatException('invalid async options');
            }
            questions.add(
              AgentQuestion(
                id: 'async-$i',
                header: 'Question',
                text: q['title']! as String,
                allowOther: options == null,
                options: [
                  if (options is List)
                    for (final option in options)
                      AgentQuestionOption(
                        id: option! as String,
                        label: option as String,
                      ),
                ],
              ),
            );
          }
          if (questions.isNotEmpty) {
            question = RuntimeQuestion(
              'item:$id',
              _identity(raw, 'turnId'),
              questions,
              asyncItem: true,
            );
          }
        } on Object {
          optionalNotice =
              'Async questions unavailable: unsupported optional shape.';
        }
      }
      final content = _seenItem(key, 1) ? '' : text;
      final bounded = clampUtf8(content, maxAgentTextChunkBytes);
      return RuntimeUpdate(
        AgentEventKind.agentText,
        bounded,
        truncated: content.length != bounded.length,
        question: question,
        optionalNotice: optionalNotice,
      );
    }
    if (type != 'commandExecution' && type != 'fileChange') return null;
    final status = item['status'];
    if (status is! String) throw CodexProtocolException('invalid tool status');
    String title;
    List<Json>? content;
    var truncated = false;
    var omitted = 0;
    if (type == 'commandExecution') {
      if (item['command'] is! String ||
          item['commandActions'] is! List ||
          item['cwd'] is! String) {
        throw CodexProtocolException('invalid command item');
      }
      title = clampUtf8(item['command']! as String, 4096);
      final output = item['aggregatedOutput'];
      if (output != null && output is! String) {
        throw CodexProtocolException('invalid command output');
      }
      if (output is String) {
        final bounded = clampUtf8(output, maxAgentToolItemBytes);
        truncated = bounded != output;
        content = [
          {
            'type': 'content',
            'content': {'type': 'text', 'text': bounded},
          },
        ];
      }
    } else {
      final changes = item['changes'];
      if (changes is! List) {
        throw CodexProtocolException('invalid file change item');
      }
      title = 'File changes';
      content = [];
      var bytes = 0;
      for (final change in changes) {
        if (change is! Json ||
            change['path'] is! String ||
            change['diff'] is! String ||
            change['kind'] is! Json) {
          throw CodexProtocolException('invalid file change path/diff/kind');
        }
        final kind = change['kind']! as Json;
        if (!const ['add', 'delete', 'update'].contains(kind['type']) ||
            (kind['type'] == 'update' &&
                kind['move_path'] != null &&
                kind['move_path'] is! String)) {
          throw CodexProtocolException('invalid file change kind');
        }
        // Validate every known core entry even after the display prefix fills.
        // Retained values share the existing encoded event/item budget.
        if (content.length >= 64) {
          omitted++;
          truncated = true;
          continue;
        }
        final path = clampUtf8(change['path']! as String, 4096);
        final diff = clampUtf8(
          change['diff']! as String,
          maxAgentToolItemBytes,
        );
        final bounded = <String, Object?>{
          'type': 'diff',
          'path': path,
          'newText': diff,
        };
        final size = _boundedJsonBytes(bounded, maxAgentEventBytes);
        if (bytes + size > maxAgentEventBytes - 16 * 1024) {
          omitted++;
          truncated = true;
          continue;
        }
        bytes += size;
        content.add(bounded);
        truncated |= path != change['path'] || diff != change['diff'];
      }
    }
    return RuntimeUpdate(
      completed ? AgentEventKind.toolUpdate : AgentEventKind.tool,
      '',
      event: _toolWithLoss(
        AgentEvent.tool(
          toolCallId: '$root:$id',
          update: completed,
          title: title,
          status: status,
          toolKind: type,
          content: content,
        ),
        truncated: truncated,
        omitted: omitted,
      ),
    );
  }

  AgentEvent _toolWithLoss(
    AgentEvent event, {
    bool truncated = false,
    int omitted = 0,
  }) => AgentEvent.fromJson({
    ...event.toJson(),
    if (truncated) 'truncated': true,
    if (truncated) 'contentTruncated': true,
    if (omitted > 0) 'omittedItems': omitted,
  });

  @override
  Future<void> cancel(String id) {
    if (_turnId == null) return Future.value();
    try {
      return cancelWithPermissions(id, const []);
    } on Object catch (error, stack) {
      return Future.error(error, stack);
    }
  }

  @override
  Future<void> cancelWithPermissions(String id, Iterable<Object> requests) {
    if (_turnId == null) {
      throw RpcException(
        ErrorCode.busy,
        'native turn identity is not yet available',
      );
    }
    return client.request<void>(
      'turn/interrupt',
      {'threadId': id, 'turnId': _turnId},
      requireAdmission: true,
      pauseForOutput: false,
      timeout: const Duration(seconds: 10),
      preceding: [
        for (final r in requests)
          if (r is RuntimeReply) {'id': r.id, 'result': r.result},
      ],
      decodeResult: (result) {
        if (result is! Json) {
          throw CodexProtocolException('invalid interrupt acknowledgement');
        }
      },
    );
  }

  @override
  Future<void> reply(Object id, Json result) =>
      client.replyAdmitted(id, result).timeout(const Duration(seconds: 10));
  @override
  void checkCanSteer(String expectedTurn) {
    if (_steeringUnavailable) {
      throw RpcException(
        ErrorCode.methodNotAvailable,
        'native steering unavailable',
      );
    }
    if (expectedTurn != _turnId || _turn == null) {
      throw RpcException(
        ErrorCode.turnRunning,
        'native turn is no longer current',
      );
    }
  }

  @override
  Future<void> steer(String thread, String expectedTurn, String text) {
    checkCanSteer(expectedTurn);
    return client
        .request<void>(
          'turn/steer',
          {
            'threadId': thread,
            'expectedTurnId': expectedTurn,
            'input': [
              {'type': 'text', 'text': text},
            ],
          },
          requireAdmission: true,
          pauseForOutput: false,
          timeout: const Duration(seconds: 10),
          decodeResult: (result) {
            if (result is! Json || result['turnId'] != expectedTurn) {
              _steeringUnavailable = true;
              throw CodexOptionalUnsupported(
                'steering',
                'native steer identity mismatch',
              );
            }
          },
        )
        .catchError((Object error) {
          if (error is CodexRemoteException && error.code == -32601) {
            _steeringUnavailable = true;
            throw CodexOptionalUnsupported('steering', error.message);
          }
          throw error;
        });
  }

  Object? _deliverInteraction(Object interaction, String turn, Json raw) {
    if (_turnId == null) {
      var charge = _boundedJsonBytes(raw, 64 * 1024) + 1024;
      if (interaction is RuntimePermission) {
        if (interaction.preview != null) {
          charge += _boundedJsonBytes(interaction.preview, 256 * 1024);
        }
        for (final choice in interaction.choices) {
          charge += _boundedJsonBytes(choice.label, 256 * 1024);
        }
      }
      _stage(turn, interaction: interaction, charge: charge);
      return null;
    }
    return interaction is RuntimePermission
        ? onPermission?.call(interaction)
        : onQuestion?.call(interaction as RuntimeQuestion);
  }

  String _identity(Json data, String key) {
    final value = data[key];
    if (value is! String ||
        value.isEmpty ||
        clampJsonString(value, 4096) != value) {
      throw CodexProtocolException('invalid $key');
    }
    return value;
  }

  String? _approvalPreview(
    Json raw,
    Map<String, String> fields, {
    Json? permissions,
  }) {
    final lines = <String>[];
    for (final field in fields.entries) {
      final value = raw[field.key];
      if (value == null) continue;
      if (value is! String) {
        throw CodexProtocolException('invalid approval ${field.key}');
      }
      lines.add('${field.value}: $value');
    }
    if (permissions != null) {
      lines.add('Requested permissions: ${jsonEncode(permissions)}');
    }
    return lines.isEmpty ? null : lines.join('\n');
  }

  Object? _request(Object id, String method, Object? raw) {
    // The leader is gone while accepted stdout may still be draining.
    // Never write cancellation/denial into its closed native stdin.
    if (_nativeExited) return null;
    Object? notice(String text) =>
        normalizeUpdate?.call(RuntimeUpdate(AgentEventKind.notice, text));
    final coreApproval =
        method == 'item/commandExecution/requestApproval' ||
        method == 'item/fileChange/requestApproval' ||
        method == 'item/permissions/requestApproval';
    if (!coreApproval &&
        method != 'item/tool/requestUserInput' &&
        method != 'mcpServer/elicitation/request') {
      client.deny(id, -32601, 'unsupported native request');
      return notice('Codex unsupported native request refused.');
    }
    if (raw is! Json) {
      if (coreApproval) {
        throw CodexProtocolException('invalid native approval');
      }
      throw CodexOptionalUnsupported('questions', 'invalid native request');
    }
    if (_boundedJsonBytes(raw, 64 * 1024) > 64 * 1024) {
      client.deny(id, -32602, 'interaction exceeds control capacity');
      return notice('Native interaction refused: control capacity exceeded.');
    }
    if (raw['threadId'] != root) {
      client.deny(id, -32601, 'untracked child interaction');
      return notice(
        'Codex unknown child ${clampJsonString(raw['threadId'].toString(), 4096)} request refused; relationship unavailable.',
      );
    }
    final active = _turnId ?? _earlyId;
    final turn = raw['turnId'];
    if (_turn == null || (active != null && turn != active)) {
      client.deny(id, -32602, 'retired native turn');
      return null;
    }
    if (turn is! String || turn.isEmpty) {
      if (coreApproval) {
        throw CodexProtocolException('missing approval turn');
      }
      throw CodexOptionalUnsupported('questions', 'missing question turn');
    }
    // Before acceptance, interactions are staged with their originating turn.
    // A response for another turn cannot surface or approve them.
    if (method == 'item/commandExecution/requestApproval' ||
        method == 'item/fileChange/requestApproval') {
      _identity(raw, 'itemId');
      if (raw['startedAtMs'] is! int) {
        throw CodexProtocolException('invalid approval timestamp');
      }
      final command = method == 'item/commandExecution/requestApproval';
      final decisions = command
          ? raw['availableDecisions']
          : const ['accept', 'acceptForSession', 'decline', 'cancel'];
      if (decisions is! List ||
          decisions.isEmpty ||
          decisions.length > maxPermissionOptions) {
        client.replyAdmitted(id, {'decision': 'decline'}).ignore();
        return notice(
          'Native approval unavailable: offered decisions missing or unsupported.',
        );
      }
      final choices = <RuntimeChoice>[];
      for (final decision in decisions) {
        if (decision is! String && decision is! Json) {
          throw CodexProtocolException('invalid approval decision');
        }
        final label = decision is String ? decision : jsonEncode(decision);
        final kind = decision == 'acceptForSession'
            ? 'allow_always'
            : decision == 'decline' || decision == 'cancel'
            ? 'reject_once'
            : 'allow_once';
        choices.add(RuntimeChoice(label, {'decision': decision}, kind));
      }
      return _deliverInteraction(
        RuntimePermission(
          id,
          turn,
          command ? 'Command approval' : 'File change approval',
          _approvalPreview(raw, {
            if (command) 'command': 'Command',
            if (command) 'cwd': 'Working directory',
            if (!command) 'grantRoot': 'Grant root',
            'reason': 'Reason',
          }),
          choices,
          {'decision': 'cancel'},
        ),
        turn,
        raw,
      );
    }
    if (method == 'item/permissions/requestApproval') {
      _identity(raw, 'itemId');
      _identity(raw, 'cwd');
      if (raw['permissions'] is! Json || raw['startedAtMs'] is! int) {
        throw CodexProtocolException('invalid additional permissions');
      }
      final requested = raw['permissions']! as Json;
      if (requested.keys.any(
        (key) => key != 'network' && key != 'fileSystem',
      )) {
        throw CodexProtocolException('unknown additional permission grant');
      }
      return _deliverInteraction(
        RuntimePermission(
          id,
          turn,
          'Additional permissions',
          _approvalPreview(raw, const {
            'cwd': 'Working directory',
            'reason': 'Reason',
          }, permissions: requested),
          [
            RuntimeChoice('Allow requested permissions for this turn', {
              'permissions': requested,
              'scope': 'turn',
            }, 'allow_once'),
            RuntimeChoice('Decline', {
              'permissions': {},
              'scope': 'turn',
            }, 'reject_once'),
          ],
          {'permissions': {}, 'scope': 'turn'},
        ),
        turn,
        raw,
      );
    }
    if (method == 'item/tool/requestUserInput') {
      try {
        _identity(raw, 'itemId');
        if (raw['isBlocking'] is! bool || raw['questions'] is! List) {
          throw const FormatException('invalid question shape');
        }
        final questions = <AgentQuestion>[];
        for (final q in raw['questions'] as List) {
          if (q is! Json) throw const FormatException('invalid question');
          final options = q['options'];
          if (options != null &&
              (options is! List ||
                  options.any(
                    (o) =>
                        o is! Json ||
                        o['label'] is! String ||
                        (o['description'] != null &&
                            o['description'] is! String),
                  ))) {
            throw const FormatException('invalid options');
          }
          questions.add(
            AgentQuestion.fromJson({
              'id': q['id'],
              'header': q['header'],
              'text': q['question'],
              'allowOther': q['isOther'] ?? false,
              'secret': q['isSecret'] ?? false,
              'options': [
                if (options is List)
                  for (final o in options)
                    if (o is Json)
                      {
                        'id': o['label'],
                        'label': o['label'],
                        'description': o['description'],
                      },
              ],
            }),
          );
        }
        if (questions.isEmpty) throw const FormatException('empty questions');
        return _deliverInteraction(
          RuntimeQuestion(id, turn, questions),
          turn,
          raw,
        );
      } on Object catch (e) {
        throw CodexOptionalUnsupported(
          'questions',
          'unsupported optional shape: $e',
        );
      }
    }
    if (method == 'mcpServer/elicitation/request') {
      client.replyAdmitted(id, {'action': 'cancel'}).ignore();
      return notice(
        'MCP elicitation unavailable: unsupported form or URL request.',
      );
    }
    client.deny(id, -32601, 'unsupported native request');
    return notice('Codex unsupported native request refused.');
  }
}

// Exact up to the existing control/early limit, without an escaping-expanded
// serialization buffer. Deep optional payloads are refused within that budget.
int _boundedJsonBytes(Object? value, int limit, [int depth = 0]) {
  if (limit < 0) return 1;
  if (depth > 64) return limit + 1;
  if (value is String) return jsonStringContentBytes(value) + 2;
  if (value is List<Object?>) {
    var n = 2;
    var first = true;
    for (final item in value) {
      if (!first) n++;
      first = false;
      n += _boundedJsonBytes(item, limit - n, depth + 1);
      if (n > limit) return n;
    }
    return n;
  }
  if (value is Json) {
    var n = 2;
    var first = true;
    for (final entry in value.entries) {
      if (!first) n++;
      first = false;
      n += jsonStringContentBytes(entry.key) + 3;
      if (n > limit) return n;
      n += _boundedJsonBytes(entry.value, limit - n, depth + 1);
      if (n > limit) return n;
    }
    return n;
  }
  return value == null ? 4 : value.toString().length;
}
