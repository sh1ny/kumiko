import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';

import 'acp/acp_client.dart';
import 'normalizer.dart';
import 'qualification.dart';

abstract interface class AgentDeadline {
  void cancel();
}

typedef AgentDeadlineFactory = AgentDeadline Function(
  Duration duration,
  void Function() callback,
);

class _TimerDeadline implements AgentDeadline {
  _TimerDeadline(Duration duration, void Function() callback)
    : _timer = Timer(duration, callback);
  final Timer _timer;
  @override
  void cancel() => _timer.cancel();
}

/// Sole owner of live turn state. Does not own a process, record, event channel
/// or stderr. Callbacks send existing control DTOs directly. [enqueueEvents]
/// MUST complete at bounded enqueue, not desktop delivery. Its backpressure
/// gates ACP's next line; Stop/close do not await it or native stdin.
class AgentSession {
  AgentSession({
    required this.sessionId,
    required this.client,
    required this.onState,
    required this.onPermissionRequested,
    required this.onPermissionResolved,
    required this.onStopResult,
    required this.onTurnEnded,
    required this.enqueueEvents,
    AgentDeadlineFactory? deadlineFactory,
    AgentTools? tools,
    bool toolsAuthenticated = false,
    String Function(String)? redact,
    this.claims,
    this._nativeSessionId,
  }) : _deadlineFactory = deadlineFactory ?? _TimerDeadline.new,
       _redact = redact ?? _unredacted,
       // ignore: prefer_initializing_formals
       _tools = tools,
       // ignore: prefer_initializing_formals
       _toolsAuthenticated = toolsAuthenticated {
    client.normalizeNotification = _normalize;
    client.consumeNotification = _consume;
    client.onPermissionRequest = _permission;
    client.onFailure = fail;
    _publish();
  }
  final String sessionId;
  final AcpClient client;

  /// Removes Kumiko tool secrets from adapter text before it leaves the host
  /// (transcript notices, turn-end and stop messages).
  final String Function(String) _redact;
  static String _unredacted(String text) => text;
  final AdapterClaims? claims;
  final void Function(AgentStateParams) onState;
  final void Function(AgentPermissionRequestedParams) onPermissionRequested;
  final void Function(AgentPermissionResolvedParams) onPermissionResolved;
  final void Function(AgentStopResultParams) onStopResult;
  final void Function(AgentTurnEndedParams) onTurnEnded;
  final FutureOr<void> Function(Iterable<Uint8List>) enqueueEvents;
  final AgentDeadlineFactory _deadlineFactory;
  AgentState _state = AgentState.starting;
  AgentState get state => _state;
  int _seq = 0;
  int get seq => _seq;
  String? _nativeSessionId;
  String? get nativeSessionId => _nativeSessionId;
  Object? failure;
  final _permissions = <String, _Permission>{};
  int get pendingPermissionCount => _permissions.length;
  int _requestId = 0;
  int _turn = 0;
  bool _hasTurn = false;
  bool _stopped = false;
  bool _notConfirmed = false;
  bool _disposed = false;
  bool _nativeExited = false;
  AgentDeadline? _deadline;
  Future<void> _events = Future.value();

  /// Accepted local and adapter events have entered the bounded relay.
  /// After failing the session and closing ACP, the service awaits this before
  /// freezing the final event count; this does not wait for desktop delivery.
  Future<void> get eventsEnqueued => _events;

  /// Tools status of this live run (null: not tracked, e.g. unit tests).
  AgentTools? get tools => _tools;
  AgentTools? _tools;
  bool _toolsAuthenticated;
  bool _firstTurnEnded = false;

  /// A bridge authenticated with this run's secret. Not yet used becomes the
  /// status of a run that was not started.
  void toolsAuthenticated() {
    _toolsAuthenticated = true;
    if (_tools?.status == AgentToolsStatus.notStarted) {
      _setTools(const AgentTools(AgentToolsStatus.notYetUsed));
    }
  }

  /// A Kumiko tool call succeeded: the terminal status for the run, even over
  /// a recorded delivery failure for the adapter version.
  void toolsCalled() {
    _toolsAuthenticated = true;
    if (_tools != null && _tools!.status != AgentToolsStatus.connected) {
      _setTools(const AgentTools(AgentToolsStatus.connected));
    }
  }

  void _setTools(AgentTools next) {
    _tools = next;
    if (!_disposed && !_terminal) _publish();
  }

  void _publish() => onState(
    AgentStateParams(
      sessionId: sessionId,
      seq: ++_seq,
      state: _state,
      tools: _tools,
    ),
  );
  void _set(AgentState state) {
    if (_state == state || _disposed) return;
    _state = state;
    _publish();
  }

  /// Attach republishes authoritative current state after the desktop has
  /// registered its session/channel. No pre-start notification buffer needed.
  void publishState() {
    if (!_disposed) _publish();
  }

  void ready({required String nativeSessionId}) {
    if (_state != AgentState.starting) {
      throw StateError('session is not starting');
    }
    _nativeSessionId = nativeSessionId;
    _set(AgentState.idle);
  }

  /// Continue owns the actual load/resume requests; these hooks frame replay
  /// on the same ordered, bounded event path before transitioning to idle.
  Future<void> replayStarted() =>
      _enqueue(encodeAgentEvent(AgentEvent.replay(AgentReplayPhase.start)));
  Future<void> replayEnded() =>
      _enqueue(encodeAgentEvent(AgentEvent.replay(AgentReplayPhase.end)));
  Future<void> notice(String text) =>
      _enqueue(encodeAgentEvent(AgentEvent.notice(text)));

  /// Acceptance only: the host ACK must not wait for the adapter's result.
  /// One turn is active; completion is reported through control callbacks.
  void acceptPrompt(String text) {
    if (_state != AgentState.idle || _disposed) {
      throw RpcException(
        ErrorCode.turnRunning,
        'a turn is already running or the session is unavailable',
      );
    }
    if (utf8.encode(text).length > 256 * 1024) {
      throw RpcException(ErrorCode.invalidParams, 'prompt exceeds 256 KiB');
    }
    final completion = client.prompt(_nativeSessionId!, text);
    final turn = ++_turn;
    _hasTurn = true;
    _stopped = false;
    _notConfirmed = false;
    _set(AgentState.running);
    _enqueue(encodeAgentEvent(AgentEvent.text(AgentEventKind.user, text)))
        .ignore();
    completion.then<void>(
          (result) => _finish(turn, result, null),
          onError: (Object error, StackTrace stack) =>
              _finish(turn, null, error),
        )
        .ignore();
  }

  Object? _normalize(String method, Json params) {
    if (params['sessionId'] != _nativeSessionId) return null;
    final update = params['update'];
    if (update is! Json) throw AcpProtocolException('invalid session/update');
    return normalizeAcpUpdate(_redactJson(update)! as Json);
  }

  /// [_redact] applied to every string in adapter JSON before any of it
  /// reaches the transcript or the desktop.
  Object? _redactJson(Object? value) => switch (value) {
    final String s => _redact(s),
    final Map<Object?, Object?> m => <String, Object?>{
      for (final e in m.entries) e.key! as String: _redactJson(e.value),
    },
    final List<Object?> l => [for (final v in l) _redactJson(v)],
    _ => value,
  };

  Future<void> _consume(Object value) => _enqueue(value as Iterable<Uint8List>);
  Future<void> _enqueue(Iterable<Uint8List> lines) {
    if (_disposed) return Future.value();
    final queued = _events.then<void>((_) {
      if (!_disposed) return enqueueEvents(lines);
    });
    _events = queued;
    // Do not swallow the error for the caller/ACP reader; also fail visibly
    // when a locally generated event has no awaiting transport consumer.
    queued.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        fail(error);
      },
    );
    return queued;
  }

  Future<void> _finish(int turn, AcpPromptResult? result, Object? error) async {
    if (!_hasTurn || turn != _turn || _disposed || _terminal) return;
    if (error != null && client.isClosed) {
      fail(error);
      return;
    }
    await _enqueue(
      encodeAgentEvent(
        result != null
            ? AgentEvent.fromJson({
                'kind': AgentEventKind.turn.name,
                'stopReason': result.stopReason,
                if (result.truncated) 'truncated': true,
              })
            : error is AcpRemoteException && error.messageTruncated
            ? AgentEvent.fromJson({
                'kind': AgentEventKind.notice.name,
                'text': _redact(error.toString()),
                'truncated': true,
              })
            : AgentEvent.notice(_redact(error.toString())),
      ),
    );
    if (!_hasTurn || turn != _turn || _disposed || _terminal) return;
    _deadline?.cancel();
    _deadline = null;
    // Successes and errors were classified and bounded synchronously by ACP
    // dispatch, so this credit-blocked frame never owns the native envelope.
    final stopReason = result?.stopReason;
    final message = error == null ? null : _message(error);
    if (_stopped) {
      onStopResult(
        AgentStopResultParams(
          sessionId: sessionId,
          outcome: error != null
              ? AgentStopOutcome.endedWithError
              : result!.isCancelled
              ? AgentStopOutcome.stopped
              : AgentStopOutcome.finishedFirst,
          stopReason: stopReason,
          message: message,
          late: _notConfirmed,
        ),
      );
    }
    _cancelPermissions();
    _hasTurn = false;
    // The first turn end without authentication means the adapter never
    // started the bridge. The idle publication below carries the change.
    if (!_firstTurnEnded) {
      _firstTurnEnded = true;
      if (_tools?.status == AgentToolsStatus.notYetUsed &&
          !_toolsAuthenticated) {
        _tools = const AgentTools(AgentToolsStatus.notStarted);
      }
    }
    final nativeMessage = error is AcpRemoteException
        ? clampUtf8(_redact(error.message), 4096)
        : null;
    onTurnEnded(
      AgentTurnEndedParams(
        sessionId: sessionId,
        stopReason: stopReason,
        error: error == null
            ? null
            : error is AcpRemoteException && error.isAuthenticationRequired
            ? ErrorCode.authRequired
            : 'adapter-error',
        message: message,
        nativeCode: error is AcpRemoteException ? error.code : null,
        nativeMessage: nativeMessage,
        nativeMessageTruncated:
            error is AcpRemoteException &&
            (error.messageTruncated ||
                nativeMessage != _redact(error.message)),
      ),
    );
    _set(AgentState.idle);
  }

  String _message(Object error) => clampJsonString(
    _redact(error is AcpRemoteException ? error.message : error.toString()),
    4096,
  );
  bool get _terminal =>
      _state == AgentState.closing ||
      _state == AgentState.ended ||
      _state == AgentState.failed;

  Object? _permission(Object rpcId, Json params) {
    if (params['sessionId'] != _nativeSessionId) {
      throw AcpProtocolException('permission for unknown native session');
    }
    if (_terminal || _stopped || !_hasTurn) {
      _answerCancelled(rpcId);
      return null;
    }
    if (_permissions.length == 16) {
      _answerCancelled(rpcId);
      return encodeAgentEvent(
        AgentEvent.notice(
          'Too many pending permission requests; the extra request was cancelled.',
        ),
      );
    }
    final tool = _redactJson(params['toolCall']);
    final options = params['options'];
    if (tool is! Json || options is! List) {
      throw AcpProtocolException('invalid permission request');
    }
    // Opaque adapter ids never become desktop ids (numeric/string ids may
    // stringify identically). Keep the original JSON-RPC id for the answer.
    final id = 'permission-${++_requestId}';
    final dto = AgentPermissionRequestedParams(
      sessionId: sessionId,
      requestId: id,
      title:
          tool['title'] as String? ??
          tool['toolCallId'] as String? ??
          'Permission requested',
      preview: _permissionPreview(tool),
      options: [
        // Labels are redacted; the option id goes back to the adapter as is.
        for (final option in options)
          if (option is Json)
            AgentPermissionOption.fromJson({
              ...(_redactJson(option)! as Json),
              'optionId': ?option['optionId'],
            }),
      ],
    );
    _permissions[id] = _Permission(
      rpcId,
      dto.options.map((o) => o.optionId).toSet(),
    );
    _set(AgentState.waitingApproval);
    onPermissionRequested(dto);
    return null;
  }

  String? _permissionPreview(Json tool) {
    final content = tool['content'];
    if (content is! List) return null;
    for (final item in content) {
      if (item is! Json) continue;
      final block = item['content'];
      if (block is Json && block['type'] == 'text' && block['text'] is String) {
        return block['text']! as String;
      }
      if (item['type'] == 'diff' && item['newText'] is String) {
        return item['newText']! as String;
      }
    }
    return null;
  }

  void permissionReply(String requestId, String optionId) {
    final permission = _permissions[requestId];
    if (permission == null) {
      throw RpcException(
        ErrorCode.unknownRequest,
        'permission request is no longer pending',
      );
    }
    if (!permission.options.contains(optionId)) {
      throw RpcException(
        ErrorCode.invalidParams,
        'option was not offered by this request',
      );
    }
    // Admission can refuse synchronously without consuming the user's choice.
    // Accepted native-write failures still fail the session asynchronously.
    final write = client.reply(permission.rpcId, {
      'outcome': {'outcome': 'selected', 'optionId': optionId},
    });
    _permissions.remove(requestId);
    _observeWrite(write);
    onPermissionResolved(
      AgentPermissionResolvedParams(
        sessionId: sessionId,
        requestId: requestId,
        outcome: AgentPermissionOutcome.selected,
        optionId: optionId,
      ),
    );
    if (_permissions.isEmpty && _state == AgentState.waitingApproval) {
      _set(AgentState.running);
    }
  }

  void _observeWrite(Future<void> write) {
    write.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        if (!_disposed && !_terminal) fail(error);
      },
    );
  }

  void _answerCancelled(Object rpcId) {
    // Leader exit closes native stdin before buffered stdout reaches EOF.
    // Retire desktop choices without writing into that lossless drain.
    if (_nativeExited) return;
    Future<void> write;
    try {
      write = client.reply(rpcId, {
        'outcome': {'outcome': 'cancelled'},
      });
    } on Object catch (error, stack) {
      // Automatic cancellation has no caller to receive an admission refusal.
      // Observe it on the same asynchronous failure path as native I/O.
      write = Future.error(error, stack);
    }
    _observeWrite(write);
  }
  void _cancelPermissions({bool answer = true}) {
    final pending = Map<String, _Permission>.of(_permissions);
    _permissions.clear();
    for (final entry in pending.entries) {
      if (answer) _answerCancelled(entry.value.rpcId);
      onPermissionResolved(
        AgentPermissionResolvedParams(
          sessionId: sessionId,
          requestId: entry.key,
          outcome: AgentPermissionOutcome.cancelled,
        ),
      );
    }
  }

  /// Admits all cancellation messages before mutating Stop or permission state.
  /// Local saturation is a retryable RPC refusal, never native I/O failure.
  void stop() {
    if (_disposed || _terminal) return;
    if (!_hasTurn) {
      onStopResult(
        AgentStopResultParams(
          sessionId: sessionId,
          outcome: AgentStopOutcome.notRunning,
        ),
      );
      return;
    }
    if (_stopped) return;
    final write = client.cancelWithPermissions(
      _nativeSessionId!,
      _permissions.values.map((permission) => permission.rpcId),
    );
    _stopped = true;
    _cancelPermissions(answer: false);
    _set(AgentState.stopping);
    _deadline = _deadlineFactory(const Duration(seconds: 10), () {
      if (!_hasTurn || _terminal || _disposed || _notConfirmed) return;
      _notConfirmed = true;
      onStopResult(
        AgentStopResultParams(
          sessionId: sessionId,
          outcome: AgentStopOutcome.notConfirmed,
        ),
      );
    });
    _observeWrite(write);
  }

  /// Immediate close transition; the service owns cancel grace and settlement.
  void beginClosing() {
    if (_disposed || _state == AgentState.ended) return;
    final running = _hasTurn;
    _set(AgentState.closing);
    _deadline?.cancel();
    _cancelPermissions();
    if (running && _nativeSessionId != null) {
      _observeWrite(client.cancel(_nativeSessionId!));
    }
  }

  void ended() {
    _deadline?.cancel();
    _hasTurn = false;
    _cancelPermissions();
    _set(AgentState.ended);
  }

  /// Publishes failure and retires choices without closing the ACP reader.
  /// Buffered updates and late permission requests still drain through EOF.
  void observeExit() {
    _nativeExited = true;
    fail(const AcpClosedException());
  }

  void fail(Object error) {
    if (_disposed || _terminal) return;
    failure = error;
    _deadline?.cancel();
    _hasTurn = false;
    _cancelPermissions();
    _set(AgentState.failed);
  }

  /// Detaches callbacks and timers only. The owner closes the ACP transport
  /// separately and settles containment before disposing UnitPipes.
  void dispose() {
    if (_disposed) return;
    _cancelPermissions();
    _disposed = true;
    _deadline?.cancel();
    client.normalizeNotification = null;
    client.consumeNotification = null;
    client.onPermissionRequest = null;
    client.onFailure = null;
  }
}

class _Permission {
  _Permission(this.rpcId, this.options);
  final Object rpcId;
  final Set<String> options;
}
