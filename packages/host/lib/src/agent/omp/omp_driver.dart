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
  bool _nativeExited = false;

  // The pending table stays in AgentSession. This synchronous query makes
  // duplicate detection independent of transcript enqueue or delivery.
  bool Function(String id)? hasPendingApproval;

  @override
  void observeExit() => _nativeExited = true;

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
  Future<void> reply(Object id, Json result) =>
      client.send(_interactionReply(id, result));

  static Json _interactionReply(Object id, Json result) => {
    'type': 'extension_ui_response',
    'id': id,
    ...result,
  };

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
            turn.agentInvoked = invoked;
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
  Future<void> cancel(String id) => cancelWithPermissions(id, const []);

  /// Refusal leaves Stop and all of its pending approvals unchanged.
  @override
  Future<void> cancelWithPermissions(String id, Iterable<Object> requests) {
    final turn = _turn;
    if (turn?.id == null || _nativeExited || client.isClosed) {
      return Future.value();
    }
    return turn!.abort ??= client
        .admitCommand(
          'abort',
          before: requests.cast<RuntimeReply>().map(
            (reply) => _interactionReply(reply.id, reply.result),
          ),
          timeout: const Duration(seconds: 10),
        )
        .then<void>(
          (_) {},
          onError: (Object error) {
            _interruption = error.toString();
            throw error;
          },
        );
  }

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
      if (type == 'extension_ui_request') {
        return _interaction(frame, null, []);
      }
      if (type == 'rpc_frame_error') return _frameError(frame, null, []);
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
    if (type == 'rpc_frame_error') return _frameError(frame, turn, lines);
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
      onRetired?.call(RuntimeRetired(_session, turn.id));
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

  Object? _frameError(Json frame, _Turn? turn, List<Uint8List> lines) {
    switch (frame['originalType']) {
      case 'message_start' ||
          'message_update' ||
          'message_end' ||
          'notice' ||
          'tool_execution_start' ||
          'tool_execution_update' ||
          'tool_execution_end' ||
          'tool_stream_update':
        final count = turn == null ? _idleNotices++ : turn.notices++;
        if (count < 8) {
          _update(
            lines,
            turn,
            AgentEventKind.notice,
            'OMP output omitted an oversized event.',
          );
        }
        return _delivery(lines);
      default:
        throw OmpProtocolException('OMP omitted an uncorrelatable RPC frame');
    }
  }

  Object? _interaction(Json frame, _Turn? turn, List<Uint8List> lines) {
    final method = frame['method'];
    if (method == 'cancel') {
      onRetired?.call(_interactionId(frame['targetId']));
      return null;
    }
    if (method == 'notify') {
      if (_interactionNoticeIndex(turn) < 8) {
        _addLines(
          lines,
          RuntimeUpdate(
            AgentEventKind.notice,
            _safeDisplay(
              clampUtf8(
                frame['message'] is String
                    ? frame['message'] as String
                    : 'OMP notification',
                256,
              ),
            ),
          ),
        );
      }
      return _delivery(lines);
    }
    if (!const {
      'select',
      'confirm',
      'input',
      'editor',
      'ask',
      'form',
    }.contains(method)) {
      return null;
    }
    final id = _interactionId(frame['id']);
    if (hasPendingApproval?.call(id) ?? false) {
      throw OmpProtocolException('duplicate live OMP approval id');
    }
    if (_nativeExited) return null;
    final request =
        method == 'select' &&
            turn != null &&
            turn.accepted &&
            turn.agentInvoked &&
            turn.abort == null &&
            !draining
        ? _approval(frame, id, turn.id!)
        : null;
    final offer = onPermission;
    if (request != null && offer != null) {
      final notice = offer(request);
      if (notice is Iterable<Uint8List> && _interactionNoticeIndex(turn) < 8) {
        lines.addAll(notice);
      }
      return _delivery(lines);
    }
    reply(id, const {'cancelled': true}).ignore();
    final index = _interactionNoticeIndex(turn);
    if (index <= 8) {
      _addLines(
        lines,
        RuntimeUpdate(
          AgentEventKind.notice,
          index == 8
              ? 'further OMP requests declined'
              : 'OMP asked: $method — not supported in Kumiko yet; declined',
        ),
      );
    }
    return _delivery(lines);
  }

  int _interactionNoticeIndex(_Turn? turn) =>
      draining ? 9 : (turn == null ? _idleNotices++ : turn.notices++);

  static String _interactionId(Object? id) {
    if (id is! String || id.isEmpty || jsonStringContentBytes(id) > 4096) {
      throw OmpProtocolException('invalid OMP UI request id');
    }
    return id;
  }

  static final _elision = RegExp(
    r'…\[\d+ (?:chars|items) elided for RPC frame\]|\[…\d+ch elided…\]',
  );
  static final _displayControls = RegExp(
    r'[\x00-\x09\x0b-\x1f\x7f-\x9f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]',
  );
  static String _safeDisplay(String text) => text.replaceAllMapped(
    _displayControls,
    (m) => '\\u${m[0]!.codeUnitAt(0).toRadixString(16).padLeft(4, '0')}',
  );

  static RuntimePermission? _approval(Json frame, String id, String turnId) {
    const header = 'Allow tool: ';
    final title = frame['title'];
    final options = frame['options'];
    if (title is! String ||
        title.length > maxPermissionPreviewBytes ||
        !title.startsWith(header) ||
        (title.contains('\n')
                ? title.substring(header.length, title.indexOf('\n'))
                : title.substring(header.length))
            .trim()
            .isEmpty ||
        _elision.hasMatch(title) ||
        options is! List ||
        options.length < 2 ||
        options.length > 6 ||
        frame.keys.any(
          (key) =>
              !const {'type', 'id', 'method', 'title', 'options'}.contains(key),
        )) {
      return null;
    }
    final labels = <String>{};
    for (final option in options) {
      if (option is! String ||
          option.length > maxPermissionNameBytes ||
          _elision.hasMatch(option) ||
          _displayControls.hasMatch(option) ||
          option.contains('\n') ||
          !labels.add(option)) {
        return null;
      }
    }
    final once = switch (options) {
      ['Approve', 'Deny'] => 'Approve',
      ['Approve', final String session, 'Deny']
          when _sessionGrant.hasMatch(session) =>
        'Approve',
      [final String grant, final String always, 'Approve Once', 'Deny']
          when (_directoryGrant(grant) || _targetGrant(grant)) &&
              always == 'Always $grant' =>
        'Approve Once',
      [
        final String folder,
        final String grant,
        final String alwaysFolder,
        final String always,
        'Approve Once',
        'Deny',
      ]
          when _directoryGrant(folder) &&
              _targetGrant(grant) &&
              alwaysFolder == 'Always $folder' &&
              always == 'Always $grant' =>
        'Approve Once',
      _ => null,
    };
    if (once == null) return null;
    final preview = _safeDisplay(title);
    if (jsonStringContentBytes(preview) > maxPermissionPreviewBytes) {
      return null;
    }
    return RuntimePermission(
      id,
      turnId,
      'OMP tool approval',
      preview,
      [
        RuntimeChoice(once, {'value': once}, 'allow_once'),
        RuntimeChoice('Deny', {'value': 'Deny'}, 'reject_once'),
      ],
      const {'cancelled': true},
    );
  }

  static final _sessionGrant = RegExp(
    r'^Approve \S(?:.*\S)? for this session$',
  );
  static bool _directoryGrant(String label) =>
      label.startsWith('Approve Directory: ') &&
      label.substring('Approve Directory: '.length).trim().isNotEmpty;
  static bool _targetGrant(String label) =>
      label == 'Approve' || label == 'Approve File';

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
  bool agentInvoked = false;
  int earlyCount = 0, earlyBytes = 0, tools = 0, notices = 0;
  final staged = <RuntimeUpdate>[];
  final terminal = Completer<RuntimeTurnResult>();
  RuntimeTurnResult? earlyEnd;
  Future<void>? abort;
}
