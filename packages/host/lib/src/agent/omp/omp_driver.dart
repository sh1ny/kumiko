import 'dart:async';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';

import '../qualification.dart';
import '../runtime_driver.dart';
import 'omp_client.dart';

class OmpRuntimeDriver extends RuntimeDriver {
  OmpRuntimeDriver(this.client, this.version) {
    client.normalizeNotification = _frame;
    unawaited(
      client.done.then((_) {
        final turn = _turn;
        if (turn == null) return;
        _turn = null;
        _messages.clear();
        turn.terminal.completeError(
          client.failure ?? OmpProtocolException('transport closed'),
        );
      }),
    );
  }

  static const continueUnavailable =
      'OMP Continue is not supported in this Kumiko version';
  final OmpClient client;
  final String version;
  final _ready = Completer<void>();
  final _messages = <String, Set<int>>{};
  final _refusedPromptIds = <String>{};
  Future<RuntimeIdentity>? _initializing;
  String? _session;
  _Turn? _turn;
  int _idleNotices = 0;
  String? _interruption;
  bool draining = false;

  @override
  OmpClient get transport => client;
  @override
  bool get largeLineOwned => client.largeLineOwned;
  @override
  bool get largeLineWaiting => client.largeLineWaiting;
  @override
  String? get turnId => _turn?.id;
  @override
  String? get interruptionReason => _interruption;
  @override
  Map<String, String> get activeNativeTurns =>
      _session != null && turnId != null ? {_session!: turnId!} : const {};
  Future<RuntimeTurnResult>? get pendingTurn => _turn?.terminal.future;

  Future<void> waitReady() async {
    await Future.any([
      _ready.future,
      client.done.then<void>((_) {
        if (!_ready.isCompleted) {
          throw client.failure ??
              OmpProtocolException('output closed before ready');
        }
      }),
    ]).timeout(
      const Duration(seconds: 60),
      onTimeout: () => throw OmpProtocolException('OMP ready timed out'),
    );
  }

  @override
  Future<RuntimeIdentity> initialize() => _initializing ??= _initialize();

  Future<RuntimeIdentity> _initialize() async {
    await waitReady();
    try {
      await client.request('set_event_filter', {
        'events': null,
        'messageUpdates': 'delta',
      });
    } on Object catch (error) {
      throw OmpProtocolException('set_event_filter: $error');
    }
    return RuntimeIdentity(
      'omp-rpc',
      version,
      AdapterClaims(const [
        'prompt',
        'streaming',
        'cancel',
      ], continueUnavailable),
    );
  }

  @override
  Future<String> newSession(
    String cwd, {
    List<Json> mcpServers = const [],
    void Function(String)? onCreated,
  }) async {
    final Object? state;
    try {
      state = await client.request('get_state');
    } on Object catch (error) {
      throw OmpProtocolException('get_state: $error');
    }
    final id = state is Json ? state['sessionId'] : null;
    if (id is! String || id.isEmpty || jsonStringContentBytes(id) > 4096) {
      throw OmpProtocolException('invalid OMP sessionId');
    }
    _session = id;
    onCreated?.call(id);
    return id;
  }

  @override
  Future<void> loadSession(
    String id,
    String cwd, {
    List<Json> mcpServers = const [],
  }) => throw RpcException(ErrorCode.methodNotAvailable, continueUnavailable);

  @override
  Future<void> resumeSession(
    String id,
    String cwd, {
    List<Json> mcpServers = const [],
  }) => loadSession(id, cwd, mcpServers: mcpServers);

  @override
  Future<void> reply(Object id, Json result) => throw RpcException(
    ErrorCode.methodNotAvailable,
    'OMP permission answers are not supported in this Kumiko version',
  );

  @override
  Future<RuntimeTurnResult> prompt(String id, String text) {
    final (admission, result) = admitPrompt(text, (_) {});
    admission.ignore();
    return result;
  }

  (Future<void>, Future<RuntimeTurnResult>) admitPrompt(
    String text,
    void Function(bool agentInvoked) accept,
  ) {
    if (_turn != null) {
      throw RpcException(ErrorCode.turnRunning, 'OMP turn active');
    }
    final turn = _Turn();
    _turn = turn;
    _interruption = null;
    final admission = client
        .command(
          'prompt',
          fields: {'message': text},
          onIssued: (id) => turn.id = id,
          onSuccess: (data) {
            final invoked = data is! Json || data['agentInvoked'] != false;
            accept(invoked);
            turn.accepted = true;
            final lines = <Uint8List>[];
            for (final update in turn.staged) {
              _addLines(lines, update);
            }
            turn.staged.clear();
            final terminal = invoked
                ? turn.earlyEnd
                : const RuntimeTurnResult('completed');
            return terminal == null
                ? _delivery(lines)
                : _terminalDelivery(lines, turn, terminal);
          },
        )
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {
            if (!turn.accepted && identical(_turn, turn)) {
              _turn = null;
              _messages.clear();
              final id = turn.id;
              if (id != null) {
                // Some pre-dispatch errors also get a terminal frame on the
                // next wire turn. A plain admission refusal may have none.
                if (error is OmpRemoteException && turn.earlyEnd == null) {
                  if (_refusedPromptIds.length == 64) {
                    _refusedPromptIds.remove(_refusedPromptIds.first);
                  }
                  _refusedPromptIds.add(id);
                }
                onNativeTurnEnded?.call(
                  _session!,
                  id,
                  RuntimeTurnResult('error', error: error),
                );
              }
              turn.terminal.completeError(error, stack);
              if (error is TimeoutException) client.fail(error);
            }
            if (!turn.accepted) Error.throwWithStackTrace(error, stack);
          },
        );
    return (admission, turn.terminal.future);
  }

  @override
  Future<void> cancel(String id) {
    final turn = _turn;
    if (turn?.id == null) return Future.value();
    return turn!.abort ??= client
        .command('abort', timeout: const Duration(seconds: 10))
        .then<void>(
          (_) {},
          onError: (Object error) {
            _interruption = error.toString();
            throw error;
          },
        );
  }

  @override
  Future<void> cancelWithPermissions(String id, Iterable<Object> requests) =>
      cancel(id);

  void _end(_Turn turn, RuntimeTurnResult result) {
    if (!identical(_turn, turn)) return;
    _turn = null;
    _messages.clear();
    _idleNotices = 0;
    onNativeTurnEnded?.call(_session!, turn.id!, result);
    turn.terminal.complete(result);
  }

  Object? _frame(Json frame) {
    final type = frame['type'];
    if (!_ready.isCompleted) {
      if (type != 'ready') return null;
      final versions = frame['supportedProtocolVersions'];
      if (versions is! List || !versions.contains(1)) {
        throw OmpProtocolException(
          'unsupported OMP RPC protocol ${versions is List ? versions.take(16).toList() : '(missing versions)'}',
        );
      }
      _ready.complete();
      return null;
    }
    final turn = _turn;
    final lines = <Uint8List>[];
    if (type == 'extension_ui_request') {
      return _interaction(frame, turn, lines);
    }
    if (type == 'prompt_result') {
      final id = frame['id'];
      if (id is String &&
          frame['agentInvoked'] == false &&
          frame['status'] == 'error' &&
          _refusedPromptIds.remove(id)) {
        _promptError(frame['error']);
        return null;
      }
      if (turn == null ||
          turn.id == null ||
          id != turn.id ||
          turn.earlyEnd != null) {
        throw OmpProtocolException('unexpected OMP prompt result');
      }
      final result = switch (frame['status']) {
        'completed' => const RuntimeTurnResult('completed'),
        'aborted' => const RuntimeTurnResult('cancelled', isCancelled: true),
        'error' => _promptError(frame['error']),
        _ => throw OmpProtocolException('invalid OMP prompt result'),
      };
      if (!turn.accepted) {
        _stage(turn, null);
        turn.earlyEnd = result;
        return null;
      }
      return _terminalDelivery(lines, turn, result);
    }
    if (type == 'notice') {
      final message = frame['message'];
      if (message is String) {
        _update(lines, turn, AgentEventKind.notice, clampUtf8(message, 4096));
      }
    } else if (type is String &&
        (type.startsWith('auto_retry_') ||
            type.startsWith('auto_compaction_') ||
            type.startsWith('manual_compaction_'))) {
      _update(lines, turn, AgentEventKind.notice, 'OMP $type');
    } else if (turn != null && type == 'tool_execution_start') {
      turn.tools++;
    } else if (turn != null &&
        (type == 'message_start' ||
            type == 'message_update' ||
            type == 'message_end')) {
      _message(frame, type as String, turn, lines);
    }
    return _delivery(lines);
  }

  static RuntimeTurnResult _promptError(Object? payload) {
    final message = payload is Json ? payload['message'] : payload;
    final code = payload is Json ? payload['code'] : null;
    if (message is! String ||
        (code != null && code is! String && code is! int)) {
      throw OmpProtocolException('invalid OMP prompt result');
    }
    final error = OmpRemoteException(message, code);
    return RuntimeTurnResult(
      'error',
      error: error,
      truncated: error.message != message,
    );
  }

  Object? _interaction(Json frame, _Turn? turn, List<Uint8List> lines) {
    final method = frame['method'];
    final interactive = const {
      'select',
      'confirm',
      'input',
      'editor',
      'ask',
      'form',
    }.contains(method);
    if (!interactive && method != 'notify') return null;
    if (interactive) {
      final id = frame['id'];
      if (id is! String || id.isEmpty || jsonStringContentBytes(id) > 4096) {
        throw OmpProtocolException('invalid OMP UI request id');
      }
      client
          .send({'type': 'extension_ui_response', 'id': id, 'cancelled': true})
          .catchError(client.fail);
    }
    final count = turn == null ? _idleNotices++ : turn.notices++;
    if (count > 8 || draining) return null;
    final title = _safeTitle(frame['title'] ?? frame['message'] ?? method);
    final notice = count == 8
        ? 'further OMP requests declined'
        : interactive
        ? 'OMP asked: $title — not supported in Kumiko yet; declined'
        : title;
    _addLines(lines, RuntimeUpdate(AgentEventKind.notice, notice));
    return _delivery(lines);
  }

  static String _safeTitle(Object? value) {
    final text = value is String ? clampUtf8(value, 256) : 'request';
    return text.replaceAllMapped(
      RegExp(
        r'[\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]',
      ),
      (m) => '\\u${m[0]!.codeUnitAt(0).toRadixString(16).padLeft(4, '0')}',
    );
  }

  void _message(Json frame, String type, _Turn turn, List<Uint8List> lines) {
    final message = frame['message'];
    if (message is! Json || message['role'] != 'assistant') return;
    final id = frame['messageId'];
    if (id is! String || id.isEmpty || jsonStringContentBytes(id) > 4096) {
      throw OmpProtocolException('invalid OMP messageId');
    }
    if (type == 'message_end') {
      final seen = _messages.remove(id);
      final content = message['content'];
      if (content is! List) return;
      for (var index = 0; index < content.length; index++) {
        if (seen?.contains(index) ?? false) continue;
        final block = content[index];
        if (block is! Json) continue;
        if (block case {'type': 'text', 'text': final String text}) {
          _update(lines, turn, AgentEventKind.agentText, text);
        } else if (block case {
          'type': 'thinking',
          'thinking': final String thought,
        }) {
          _update(lines, turn, AgentEventKind.thought, thought);
        }
      }
      return;
    }
    final seen = _messages.putIfAbsent(id, () {
      if (_messages.length >= 64) {
        throw OmpProtocolException('too many open OMP messages');
      }
      return <int>{};
    });
    if (type != 'message_update') return;
    final event = frame['assistantMessageEvent'];
    if (event is! Json) return;
    final kind = switch (event['type']) {
      'text_delta' => AgentEventKind.agentText,
      'thinking_delta' => AgentEventKind.thought,
      _ => null,
    };
    if (kind == null) return;
    final index = event['contentIndex'];
    final text = event['delta'];
    if (index is! int || index < 0 || text is! String) {
      throw OmpProtocolException('invalid OMP message delta');
    }
    if (!seen.contains(index) && seen.length >= 256) {
      throw OmpProtocolException('too many OMP content indexes');
    }
    seen.add(index);
    _update(lines, turn, kind, text);
  }

  void _update(
    List<Uint8List> lines,
    _Turn? turn,
    AgentEventKind kind,
    String text,
  ) {
    if (draining || text.isEmpty) return;
    final update = RuntimeUpdate(kind, text);
    if (turn != null && !turn.accepted) {
      _stage(turn, update);
    } else {
      _addLines(lines, update);
    }
  }

  void _stage(_Turn turn, RuntimeUpdate? update) {
    turn.earlyCount++;
    turn.earlyBytes += update == null
        ? 4096
        : jsonStringContentBytes(update.text) + 64;
    if (turn.earlyCount > 64 || turn.earlyBytes > 256 * 1024) {
      throw OmpProtocolException(
        'OMP output before admission exceeds staging limit',
      );
    }
    if (update != null) turn.staged.add(update);
  }

  void _addLines(List<Uint8List> lines, RuntimeUpdate update) {
    final normalized = normalizeUpdate?.call(update);
    if (normalized is Iterable<Uint8List>) lines.addAll(normalized);
  }

  RuntimeDelivery _terminalDelivery(
    List<Uint8List> lines,
    _Turn turn,
    RuntimeTurnResult result,
  ) {
    if (turn.tools > 0) {
      _update(
        lines,
        turn,
        AgentEventKind.notice,
        'OMP ran ${turn.tools} tool calls; tool activity is not shown in Kumiko yet',
      );
    }
    return RuntimeDelivery(lines, 0, null, () => _end(turn, result));
  }

  RuntimeDelivery? _delivery(List<Uint8List> lines) =>
      lines.isEmpty ? null : RuntimeDelivery(lines, 0, null, null);
}

class _Turn {
  String? id;
  bool accepted = false;
  int earlyCount = 0, earlyBytes = 0, tools = 0, notices = 0;
  final staged = <RuntimeUpdate>[];
  final terminal = Completer<RuntimeTurnResult>();
  RuntimeTurnResult? earlyEnd;
  Future<void>? abort;
}
