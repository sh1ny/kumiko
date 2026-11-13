import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';

import 'acp/acp_client.dart';
import 'codex/codex_client.dart';
import 'normalizer.dart';
import 'qualification.dart';
import 'runtime_driver.dart';

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
    AcpClient? client,
    RuntimeDriver? driver,
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
    String Function(String)? redactStreaming,
    Iterable<String> Function()? secrets,
    this.claims,
    this.runId,
    this.onQuestionRequested,
    this.onQuestionResolved,
    this.reserveEarly,
    this.releaseEarly,
    this.enqueueReserved,
    this._nativeSessionId,
  }) : client = driver ?? AcpRuntimeDriver(client!),
       _deadlineFactory = deadlineFactory ?? _TimerDeadline.new,
       _redact = redact ?? _unredacted,
       _redactStreaming = redactStreaming ?? redact ?? _unredacted,
       _secrets = secrets ?? _noSecrets,
       // ignore: prefer_initializing_formals
       _tools = tools,
       // ignore: prefer_initializing_formals
       _toolsAuthenticated = toolsAuthenticated {
    this.client.acp?.normalizeNotification = _normalize;
    this.client.consumeNotification = _consume;
    this.client.acp?.onPermissionRequest = _permission;
    this.client.onFailure = fail;
    this.client.normalizeUpdate = _nativeUpdate;
    this.client.onTurnIdentity = _publish;
    this.client.onDelegatedChanged = _delegatedChanged;
    this.client.onNativeTurnEnded = _nativeTurnEnded;
    this.client.onPermission = _nativePermission;
    this.client.onQuestion = _nativeQuestion;
    this.client.onRetired = _nativeRetired;
    this.client.reserveEarly = reserveEarly;
    this.client.releaseEarly = releaseEarly;
    _publish();
  }
  final String sessionId;
  final String? runId;
  final RuntimeDriver client;
  final bool Function(int)? reserveEarly;
  final void Function(int)? releaseEarly;
  final Future<void> Function(RuntimeDelivery)? enqueueReserved;
  final void Function(AgentQuestionRequestedParams)? onQuestionRequested;
  final void Function(AgentQuestionResolvedParams)? onQuestionResolved;
  final _questions = <String, _Question>{};

  /// Removes Kumiko tool secrets from adapter text before it leaves the host
  /// (transcript notices, turn-end and stop messages).
  final String Function(String) _redact;

  /// Streaming carry owns unfinished-token boundaries; diagnostics may already
  /// be clipped and use the separate public boundary-aware callback.
  final String Function(String) _redactStreaming;
  static String _unredacted(String text) => text;

  /// The secrets [_redact] removes, so a text chunk ending in the start of
  /// one can be held until the next chunk shows whether it continues.
  final Iterable<String> Function() _secrets;
  static Iterable<String> _noSecrets() => const [];
  String? _heldKind;
  Json _heldNativeIdentity = const {};
  String _held = '';

  /// Kind and last [_sentWindow] characters of the text already sent in
  /// consecutive chunks of that kind, so a match is followed across any
  /// number of chunk boundaries.
  String? _sentKind;
  String _sent = '';
  static const _sentWindow = 64;

  /// Text is held back only once the stream matches at least this many
  /// leading characters of a secret: by chance that is about 1 in 16
  /// million, so ordinary text is not split or delayed. A match always
  /// begins in sent text with fewer characters, so at most 3 characters of
  /// a secret are ever sent; the rest is held, then redacted.
  static const _minHeld = 4;
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
      runId: runId,
      turnId: client.turnId,
      delegated: _delegated,
    ),
  );
  AgentDelegated? get _delegated {
    final facts = client.delegated;
    if (_state == AgentState.ended && facts != null) {
      return const AgentDelegated();
    }
    if (facts == null) return null;
    return AgentDelegated(
      activeChildren: facts.activeChildren,
      incomplete: facts.incomplete,
      waitingRequests:
          _permissions.values
              .where(
                (p) => p.threadId != null && p.threadId != _nativeSessionId,
              )
              .length +
          _questions.values
              .where(
                (q) =>
                    q.request.threadId != null &&
                    q.request.threadId != _nativeSessionId,
              )
              .length,
    );
  }

  bool get _delegatedWork => _delegated?.hasWork ?? false;
  final _stopTurns = <String, String>{};
  final _stopResults = <String, RuntimeTurnResult>{};
  void _delegatedChanged() {
    if (_disposed || _terminal) return;
    _publish();
    _settleNativeStop();
  }

  void _nativeTurnEnded(String thread, String turn, RuntimeTurnResult result) {
    if (_stopped && _stopTurns[thread] == turn) {
      _stopResults[thread] = result;
      _settleNativeStop();
    }
  }

  void _settleNativeStop() {
    if (!_stopped || client.acp != null || _disposed || _terminal) return;
    if (_stopResults.length != _stopTurns.length || _delegatedWork) return;
    _deadline?.cancel();
    final results = _stopResults.values;
    final failed = results.where((r) => r.error != null).firstOrNull;
    final cancelled = results.any((r) => r.isCancelled);
    onStopResult(
      AgentStopResultParams(
        sessionId: sessionId,
        outcome: failed != null
            ? AgentStopOutcome.endedWithError
            : cancelled
            ? AgentStopOutcome.stopped
            : AgentStopOutcome.finishedFirst,
        message: failed == null ? null : _message(failed.error!),
        late: _notConfirmed,
      ),
    );
    _stopped = false;
    _set(AgentState.idle);
  }

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
  Future<void> replayEnded() {
    final held = _flushHeld();
    _sentKind = null;
    if (held.isNotEmpty) _enqueue(held).ignore();
    return _enqueue(encodeAgentEvent(AgentEvent.replay(AgentReplayPhase.end)));
  }

  Future<void> notice(String text) =>
      _enqueue(encodeAgentEvent(AgentEvent.notice(text)));

  /// Acceptance only: the host ACK must not wait for the adapter's result.
  /// One turn is active; completion is reported through control callbacks.
  /// The checks of [acceptPrompt], without its effect: a prompt that would
  /// be refused must not first remove a stored draft.
  void checkCanPrompt(String text) {
    // A native Stop can settle Idle before the previous host turn has
    // reported its end; that turn must finish before another is admitted.
    if (_state != AgentState.idle || _hasTurn || _disposed) {
      throw RpcException(
        ErrorCode.turnRunning,
        'a turn is already running or the session is unavailable',
      );
    }
    if (utf8.encode(text).length > 256 * 1024) {
      throw RpcException(ErrorCode.invalidParams, 'prompt exceeds 256 KiB');
    }
  }

  void acceptPrompt(String text) {
    checkCanPrompt(text);
    final completion = client.prompt(_nativeSessionId!, text);
    final turn = ++_turn;
    _hasTurn = true;
    _stopped = false;
    _notConfirmed = false;
    _set(AgentState.running);
    _enqueue(encodeAgentEvent(AgentEvent.text(AgentEventKind.user, text)))
        .ignore();
    completion
        .then<void>(
          (result) => _finish(turn, result, null),
          onError: (Object error, StackTrace stack) =>
              _finish(turn, null, error),
        )
        .ignore();
  }

  Object? _nativeUpdate(RuntimeUpdate update) {
    Iterable<Uint8List> prefix = const [];
    if (update.optionalNotice != null) {
      prefix = encodeAgentEvent(AgentEvent.notice(update.optionalNotice!));
    }
    if (update.question != null) {
      final result = _nativeQuestion(update.question!);
      if (result is Iterable<Uint8List>) prefix = prefix.followedBy(result);
    }
    final sourceEvent = update.event;
    final identity = <String, Object?>{
      if (sourceEvent?.threadId != null)
        'rootThreadId': sourceEvent!.rootThreadId,
      if (sourceEvent?.threadId != null) 'threadId': sourceEvent!.threadId,
      if (sourceEvent?.threadId != null)
        'parentThreadId': sourceEvent!.parentThreadId,
    };
    if (sourceEvent != null && sourceEvent.text == null ||
        sourceEvent != null && sourceEvent.kind == AgentEventKind.child) {
      return prefix
          .followedBy(_flushHeld())
          .followedBy(
            encodeAgentEvent(
              AgentEvent.fromJson(_redactJson(sourceEvent.toJson())! as Json),
            ),
          );
    }
    if (sourceEvent != null) {
      update = RuntimeUpdate(
        sourceEvent.kind,
        sourceEvent.text!,
        truncated: sourceEvent.truncated,
      );
    }
    if (update.kind == AgentEventKind.notice) {
      return _flushHeld().followedBy(
        encodeAgentEvent(AgentEvent.notice(_redact(update.text))),
      );
    }
    final kind = 'native:${update.kind.name}:${identity['threadId'] ?? ''}';
    final continues = _heldKind == kind;
    final flushed = continues ? const <Uint8List>[] : _flushHeld();
    if (_sentKind != kind) {
      _sentKind = kind;
      _sent = '';
    }
    if (update.truncated) {
      // Lost bytes break continuity. Mask a clipped boundary now rather than
      // carrying it into unrelated output that can release an exposed prefix.
      final clipped = _redact(
        _redactAfterSent('${continues ? _held : ''}${update.text}'),
      );
      _held = '';
      _heldKind = null;
      _sent = '';
      _sentKind = null;
      return prefix
          .followedBy(flushed)
          .followedBy(
            encodeAgentEvent(
              AgentEvent.fromJson({
                'kind': update.kind.name,
                ...identity,
                'text': clipped,
                'truncated': true,
              }),
            ),
          );
    }
    final carry = _redactAfterSent('${continues ? _held : ''}${update.text}');
    final hold = _heldLength(carry);
    _held = carry.substring(carry.length - hold);
    _heldKind = hold == 0 ? null : kind;
    _heldNativeIdentity = identity;
    final emit = carry.substring(0, carry.length - hold);
    final sent = '$_sent$emit';
    _sent = sent.length > _sentWindow
        ? sent.substring(sent.length - _sentWindow)
        : sent;
    return prefix
        .followedBy(flushed)
        .followedBy(
          emit.isEmpty
              ? const <Uint8List>[]
              : encodeAgentEvent(
                  AgentEvent.fromJson({
                    'kind': update.kind.name,
                    ...identity,
                    'text': emit,
                    if (update.truncated) 'truncated': true,
                  }),
                ),
        );
  }

  Object? _normalize(String method, Json params) {
    if (params['sessionId'] != _nativeSessionId) return null;
    final update = params['update'];
    if (update is! Json) throw AcpProtocolException('invalid session/update');
    final kind = update['sessionUpdate'];
    final content = update['content'];
    if (_textChunkKinds.contains(kind) &&
        content is Json &&
        content['type'] == 'text' &&
        content['text'] is String) {
      // A secret streamed across chunks is redacted once joined: carry the
      // held tail of the previous chunk of this kind, and hold back any tail
      // of this one that could be the start of a secret.
      final continues = kind == _heldKind;
      final flushed = continues ? const <Uint8List>[] : _flushHeld();
      if (kind != _sentKind) {
        _sentKind = kind! as String;
        _sent = '';
      }
      final carry = _redactAfterSent(
        '${continues ? _held : ''}${content['text']! as String}',
      );
      final hold = _heldLength(carry);
      _held = carry.substring(carry.length - hold);
      _heldKind = hold == 0 ? null : kind! as String;
      final emit = carry.substring(0, carry.length - hold);
      final sent = '$_sent$emit';
      _sent = sent.length > _sentWindow
          ? sent.substring(sent.length - _sentWindow)
          : sent;
      return [
        ...flushed,
        if (emit.isNotEmpty)
          ...normalizeAcpUpdate(
            _redactJson({
                  ...update,
                  'content': {...content, 'text': emit},
                })!
                as Json,
          ),
      ];
    }
    _sentKind = null;
    return [
      ..._flushHeld(),
      ...normalizeAcpUpdate(_redactJson(update)! as Json),
    ];
  }

  /// [text] redacted, including the rest of a secret whose first
  /// characters already went out in [_sent].
  String _redactAfterSent(String text) {
    var out = _redactStreaming(text);
    for (final secret in _secrets()) {
      for (var k = min(secret.length - 1, _sent.length); k >= 1; k--) {
        if (_sent.endsWith(secret.substring(0, k)) &&
            out.startsWith(secret.substring(k))) {
          out = '<redacted>${out.substring(secret.length - k)}';
          break;
        }
      }
    }
    return out;
  }

  static const _textChunkKinds = {
    'user_message_chunk',
    'agent_message_chunk',
    'agent_thought_chunk',
  };

  /// How much of the end of [carry] to hold: the part of the longest
  /// stream tail ([_sent] then [carry]) that is a proper prefix of a secret,
  /// once that tail is at least [_minHeld] long.
  int _heldLength(String carry) {
    final stream = '$_sent$carry';
    var best = 0;
    for (final secret in _secrets()) {
      for (var k = min(secret.length - 1, stream.length); k > best; k--) {
        if (stream.endsWith(secret.substring(0, k))) {
          best = k;
          break;
        }
      }
    }
    return best < _minHeld ? 0 : min(best, carry.length);
  }

  /// Releases a held chunk tail that no chunk completed. It is a secret cut
  /// short, not text, so it is sent redacted.
  List<Uint8List> _flushHeld() {
    final kind = _heldKind;
    if (kind == null) return const [];
    _heldKind = null;
    _held = '';
    _sentKind = null;
    if (kind.startsWith('native:')) {
      return encodeAgentEvent(
        AgentEvent.fromJson({
          'kind': kind.substring(7).split(':').first,
          ..._heldNativeIdentity,
          'text': '<redacted>',
        }),
      ).toList();
    }
    return normalizeAcpUpdate({
      'sessionUpdate': kind,
      'content': {'type': 'text', 'text': '<redacted>'},
    }).toList();
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

  Future<void> _consume(Object value) async {
    if (value is RuntimeDelivery) {
      if (_disposed) {
        value.release();
        return;
      }
      final queued = _events.then<void>((_) async {
        if (_disposed) {
          value.release();
          return;
        }
        if (enqueueReserved != null) {
          await enqueueReserved!(value);
        } else {
          value.release();
          await enqueueEvents(value.lines);
        }
      });
      _events = queued;
      await queued;
      value.after?.call();
      return;
    }
    await _enqueue(value as Iterable<Uint8List>);
  }

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

  Future<void> _finish(
    int turn,
    RuntimeTurnResult? result,
    Object? error,
  ) async {
    if (!_hasTurn || turn != _turn || _disposed || _terminal) return;
    error ??= result?.error;
    if (error != null && client.isClosed) {
      fail(error);
      return;
    }
    final held = _flushHeld();
    _sentKind = null;
    if (held.isNotEmpty) await _enqueue(held);
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
    if (client.acp != null || !_stopped) {
      _deadline?.cancel();
      _deadline = null;
    }
    // Successes and errors were classified and bounded synchronously by ACP
    // dispatch, so this credit-blocked frame never owns the native envelope.
    final stopReason = result?.stopReason;
    final message = error == null ? null : _message(error);
    if (_stopped && client.acp != null) {
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
    if (client.acp != null) _cancelPermissions();
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
        : error is CodexRemoteException
        ? clampUtf8(_redact(error.message), 4096)
        : null;
    onTurnEnded(
      AgentTurnEndedParams(
        sessionId: sessionId,
        stopReason: stopReason,
        error: error == null
            ? null
            : (error is AcpRemoteException && error.isAuthenticationRequired) ||
                  (error is CodexRemoteException &&
                      error.isAuthenticationRequired)
            ? ErrorCode.authRequired
            : 'adapter-error',
        message: message,
        nativeCode: error is AcpRemoteException
            ? error.code
            : error is CodexRemoteException
            ? error.code
            : null,
        nativeMessage: nativeMessage,
        nativeMessageTruncated:
            error is AcpRemoteException &&
                (error.messageTruncated ||
                    nativeMessage != _redact(error.message)) ||
            error is CodexRemoteException && error.messageTruncated,
      ),
    );
    if (client.acp != null || !_stopped) _set(AgentState.idle);
    _settleNativeStop();
  }

  String _message(Object error) => clampJsonString(
    _redact(
      error is AcpRemoteException
          ? error.message
          : error is CodexRemoteException
          ? error.message
          : error.toString(),
    ),
    4096,
  );
  bool get _terminal =>
      _state == AgentState.closing ||
      _state == AgentState.ended ||
      _state == AgentState.failed;

  void checkCanSteer(String expectedTurnId, String text) {
    if (_disposed ||
        _terminal ||
        !_hasTurn ||
        _stopped ||
        client.turnId != expectedTurnId) {
      throw RpcException(
        ErrorCode.turnRunning,
        'the native turn is no longer current',
      );
    }
    if (utf8.encode(text).length > 256 * 1024) {
      throw RpcException(ErrorCode.invalidParams, 'steering exceeds 256 KiB');
    }
    client.checkCanSteer(expectedTurnId);
  }

  RuntimeDelivery prepareSteer(String expectedTurnId, String text) {
    checkCanSteer(expectedTurnId, text);
    final lines = encodeAgentEvent(AgentEvent.text(AgentEventKind.user, text))
        .toList();
    final bytes = lines.fold<int>(0, (n, line) => n + line.length);
    if (!(reserveEarly?.call(bytes) ?? true)) {
      throw RpcException(ErrorCode.busy, 'transcript admission is full');
    }
    return RuntimeDelivery(lines, bytes, releaseEarly, null);
  }

  void acceptSteer(
    String expectedTurnId,
    String text,
    RuntimeDelivery delivery,
  ) {
    checkCanSteer(expectedTurnId, text);
    final completion = client.steer(_nativeSessionId!, expectedTurnId, text);
    _consume(delivery).catchError((Object error) {
      fail(error);
    });
    _observeNativeControl(completion, 'Steering');
  }

  Object? _nativePermission(RuntimePermission request) {
    if (_terminal ||
        _stopped ||
        (!_hasTurn && request.threadId == null) ||
        _permissions.length + _questions.length >= 16) {
      _observeWrite(client.reply(request.id, request.cancellation));
      return encodeAgentEvent(
        AgentEvent.notice(
          'Native interaction capacity or turn unavailable${request.threadId == null ? '' : ' for child ${request.threadId}'}; request cancelled.',
        ),
      );
    }
    final id = '$runId:permission-${++_requestId}';
    final options = <String, Object?>{};
    final display = <AgentPermissionOption>[];
    for (var i = 0; i < request.choices.length; i++) {
      final token = 'choice-$i';
      final c = request.choices[i];
      options[token] = c.result;
      display.add(
        AgentPermissionOption(
          optionId: token,
          name: _redact(c.label),
          kind: c.kind,
        ),
      );
    }
    // Two options that read alike after redaction (a native string equal to an
    // indexed object label) would be ambiguous buttons for different grants.
    for (var i = 0; i < display.length; i++) {
      if (request.choices[i].generated &&
          [
            for (var j = 0; j < display.length; j++)
              if (j != i) display[j].name,
          ].contains(display[i].name)) {
        _observeWrite(client.reply(request.id, request.cancellation));
        return encodeAgentEvent(
          AgentEvent.notice(
            'Native approval unavailable: option names are ambiguous; request cancelled.',
          ),
        );
      }
    }
    final preview = request.preview == null ? null : _redact(request.preview!);
    final title = _redact(
      request.threadId == null
          ? request.title
          : 'Child ${request.threadId}: ${request.title}',
    );
    final notification = AgentPermissionRequestedParams(
      sessionId: sessionId,
      requestId: id,
      title: title,
      preview: preview,
      options: display,
    );
    // An approval must not expose an apparently complete grant after losing
    // part of its preview or native choices to either existing display cap.
    if (notification.truncated || notification.preview != preview) {
      _observeWrite(client.reply(request.id, request.cancellation));
      return encodeAgentEvent(
        AgentEvent.notice(
          'Native approval unavailable: full details exceed display capacity; request cancelled. '
          '[display-v1 ${jsonEncode({
            'category': switch (request.title) {
              'Command approval' => 'command',
              'File change approval' => 'file-change',
              'Additional permissions' => 'additional-permissions',
              _ => 'other',
            },
            'isChild': request.threadId != null,
            'titleBytes': utf8.encode(title).length.clamp(0, 1048576),
            'previewBytes': utf8.encode(preview ?? '').length.clamp(0, 1048576),
            'maxNameBytes': display.fold<int>(0, (maximum, option) => max(maximum, utf8.encode(option.name).length)).clamp(0, 1048576),
            'optionCount': display.length.clamp(0, 1024),
            'titleLoss': notification.title != title,
            'previewLoss': notification.preview != preview,
            'namesLoss': [for (var i = 0; i < notification.options.length; i++) notification.options[i].name != display[i].name].any((lost) => lost),
            'countLoss': notification.options.length != display.length,
            'encodedLoss': notification.title != clampUtf8(title, maxPermissionTitleBytes) || notification.preview != (preview == null ? null : clampUtf8(preview, maxPermissionPreviewBytes)) || [for (var i = 0; i < notification.options.length; i++) notification.options[i].name != clampUtf8(display[i].name, maxPermissionNameBytes)].any((lost) => lost),
          })}]',
        ),
      );
    }
    _permissions[id] = _Permission(
      request.id,
      options,
      native: true,
      turnId: request.turnId,
      cancellation: request.cancellation,
      threadId: request.threadId,
    );
    if (_hasTurn) _set(AgentState.waitingApproval);
    _publish();
    onPermissionRequested(notification);
    return null;
  }

  Object? _nativeQuestion(RuntimeQuestion request) {
    if (_terminal ||
        _stopped ||
        (!_hasTurn && request.threadId == null) ||
        _permissions.length + _questions.length >= 16) {
      if (!request.asyncItem) {
        _observeWrite(client.reply(request.id, {'answers': {}}));
      }
      return encodeAgentEvent(
        AgentEvent.notice(
          'Native question capacity or turn unavailable${request.threadId == null ? '' : ' for child ${request.threadId}'}; request cancelled.',
        ),
      );
    }
    final id = '$runId:question-${++_requestId}';
    final display = <AgentQuestion>[];
    for (var i = 0; i < request.questions.length; i++) {
      final q = request.questions[i];
      display.add(
        AgentQuestion(
          id: 'question-$i',
          header: _redact(q.header),
          text: _redact(q.text),
          secret: q.secret,
          allowOther: q.allowOther || q.options.isEmpty,
          options: [
            for (var j = 0; j < q.options.length; j++)
              AgentQuestionOption(
                id: 'option-$j',
                label: _redact(q.options[j].label),
                description: q.options[j].description == null
                    ? null
                    : _redact(q.options[j].description!),
              ),
          ],
        ),
      );
    }
    // Normalization adds identities and envelope fields, so a question that
    // fit its native bound can exceed the control bound. Check the final
    // envelope before any state changes and refuse only this question.
    final AgentQuestionRequestedParams checked;
    try {
      checked = AgentQuestionRequestedParams.fromJson(
        AgentQuestionRequestedParams(
          sessionId: sessionId,
          seq: _seq + 1,
          runId: runId!,
          requestId: id,
          turnId: request.turnId,
          rootThreadId: _nativeSessionId,
          threadId: request.threadId ?? _nativeSessionId,
          parentThreadId: request.parentThreadId,
          questions: display,
        ).toJson(),
      );
    } on RpcException {
      if (!request.asyncItem) {
        _observeWrite(client.reply(request.id, {'answers': {}}));
      }
      return encodeAgentEvent(
        AgentEvent.notice(
          'Native question exceeds control capacity${request.threadId == null ? '' : ' for child ${request.threadId}'}; request cancelled.',
        ),
      );
    }
    if (_hasTurn) _set(AgentState.waitingApproval);
    _questions[id] = _Question(request, display);
    _publish();
    final dto = AgentQuestionRequestedParams.fromJson({
      ...checked.toJson(),
      'seq': ++_seq,
    });
    onQuestionRequested?.call(dto);
    return null;
  }

  void questionAnswer(AgentQuestionAnswerParams answer) {
    final pending = _questions[answer.requestId];
    if (pending == null ||
        answer.turnId != pending.request.turnId ||
        (!_hasTurn && pending.request.threadId == null) ||
        _stopped) {
      throw RpcException(
        ErrorCode.unknownRequest,
        'native question is no longer pending',
      );
    }
    if (answer.answers.length != pending.display.length) {
      throw RpcException(
        ErrorCode.invalidParams,
        'answer every offered question exactly once',
      );
    }
    final native = <String, Object?>{};
    for (var i = 0; i < pending.display.length; i++) {
      final q = pending.display[i];
      final original = pending.request.questions[i];
      final matching = answer.answers.where((a) => a.questionId == q.id);
      if (matching.length != 1) {
        throw RpcException(
          ErrorCode.invalidParams,
          'unknown question identity',
        );
      }
      final values = <String>[];
      for (final value in matching.single.values) {
        final option = q.options.indexWhere((o) => o.id == value);
        if (option < 0) {
          throw RpcException(ErrorCode.invalidParams, 'answer was not offered');
        }
        values.add(original.options[option].label);
      }
      // Free text travels apart from option identities, so it reaches Codex
      // unchanged even when it looks like one.
      final other = matching.single.other;
      if (other != null) {
        if (!q.allowOther) {
          throw RpcException(ErrorCode.invalidParams, 'answer was not offered');
        }
        values.add(other);
      }
      native[original.id] = {'answers': values};
    }
    final write = pending.request.asyncItem
        ? client.steer(
            pending.request.threadId ?? _nativeSessionId!,
            pending.request.turnId,
            'Answers for ${pending.request.id}: ${jsonEncode(native)}',
          )
        : client.reply(pending.request.id, {'answers': native});
    _questions.remove(answer.requestId);
    if (pending.request.threadId != null) _publish();
    if (pending.request.asyncItem) {
      _observeNativeControl(write, 'Steering');
    } else {
      _observeWrite(write);
    }
    _resolveQuestion(answer.requestId, pending, AgentQuestionOutcome.answered);
    if (_questions.isEmpty &&
        _permissions.isEmpty &&
        _state == AgentState.waitingApproval) {
      _set(AgentState.running);
    }
  }

  void _resolveQuestion(String id, _Question q, AgentQuestionOutcome outcome) =>
      onQuestionResolved?.call(
        AgentQuestionResolvedParams(
          sessionId: sessionId,
          seq: ++_seq,
          runId: runId!,
          requestId: id,
          outcome: outcome,
          turnId: q.request.turnId,
          rootThreadId: _nativeSessionId,
          threadId: q.request.threadId ?? _nativeSessionId,
          parentThreadId: q.request.parentThreadId,
        ),
      );
  void _nativeRetired(Object? rpcId) {
    for (final e in _permissions.entries.toList()) {
      if (!e.value.native ||
          (rpcId is RuntimeRetired
              ? (e.value.threadId ?? _nativeSessionId) != rpcId.threadId ||
                    e.value.turnId != rpcId.turnId
              : rpcId != null && e.value.rpcId != rpcId)) {
        continue;
      }
      _permissions.remove(e.key);
      onPermissionResolved(
        AgentPermissionResolvedParams(
          sessionId: sessionId,
          requestId: e.key,
          outcome: AgentPermissionOutcome.cancelled,
        ),
      );
    }
    for (final e in _questions.entries.toList()) {
      if (rpcId is RuntimeRetired
          ? (e.value.request.threadId ?? _nativeSessionId) != rpcId.threadId ||
                e.value.request.turnId != rpcId.turnId
          : rpcId != null &&
                (e.value.request.asyncItem || e.value.request.id != rpcId)) {
        continue;
      }
      _questions.remove(e.key);
      _resolveQuestion(e.key, e.value, AgentQuestionOutcome.cancelled);
    }
    _publish();
    if (_hasTurn &&
        _questions.isEmpty &&
        _permissions.isEmpty &&
        _state == AgentState.waitingApproval) {
      _set(AgentState.running);
    }
  }

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
        for (final option in options)
          if (option is Json)
            AgentPermissionOption.fromJson(_redactJson(option)! as Json),
      ],
    );
    // The desktop sees redacted option ids; the adapter gets its own back.
    // If two native ids redact alike, the first one offered is kept.
    final native = <String, Object?>{};
    for (final option in options) {
      if (option is Json && option['optionId'] is String) {
        final nativeId = option['optionId']! as String;
        native.putIfAbsent(_redact(nativeId), () => nativeId);
      }
    }
    _permissions[id] = _Permission(rpcId, native);
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
    final nativeOptionId = permission.options[optionId];
    if (nativeOptionId == null) {
      throw RpcException(
        ErrorCode.invalidParams,
        'option was not offered by this request',
      );
    }
    // Admission can refuse synchronously without consuming the user's choice.
    // Accepted native-write failures still fail the session asynchronously.
    if (permission.native &&
        ((!_hasTurn && permission.threadId == null) || _stopped)) {
      throw RpcException(
        ErrorCode.unknownRequest,
        'native permission is no longer pending',
      );
    }
    final write = client.reply(
      permission.rpcId,
      permission.native
          ? nativeOptionId as Json
          : {
              'outcome': {'outcome': 'selected', 'optionId': nativeOptionId},
            },
    );
    _permissions.remove(requestId);
    if (permission.threadId != null) _publish();
    _observeWrite(write);
    onPermissionResolved(
      AgentPermissionResolvedParams(
        sessionId: sessionId,
        requestId: requestId,
        outcome: AgentPermissionOutcome.selected,
        optionId: optionId,
      ),
    );
    if (_permissions.isEmpty &&
        _questions.isEmpty &&
        _state == AgentState.waitingApproval) {
      _set(AgentState.running);
    }
  }

  // Local admission is already complete. Optional rejection or an unknown
  // remote outcome must not retire the turn or resend the operation.
  void _observeNativeControl(Future<void> completion, String operation) {
    completion.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        if (_disposed || _terminal) return;
        if (client.isClosed) {
          fail(error);
        } else {
          notice(
            '$operation outcome unavailable or unknown: ${_redact(error.toString())}',
          ).ignore();
        }
      },
    );
  }

  void _observeWrite(Future<void> write) {
    write.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        if (!_disposed && !_terminal) fail(error);
      },
    );
  }

  void _answerCancelled(Object rpcId, [Json? nativeCancellation]) {
    // Leader exit closes native stdin before buffered stdout reaches EOF.
    // Retire desktop choices without writing into that lossless drain.
    if (_nativeExited) return;
    Future<void> write;
    try {
      write = client.reply(
        rpcId,
        nativeCancellation ??
            {
              'outcome': {'outcome': 'cancelled'},
            },
      );
    } on Object catch (error, stack) {
      // Automatic cancellation has no caller to receive an admission refusal.
      // Observe it on the same asynchronous failure path as native I/O.
      write = Future.error(error, stack);
    }
    _observeWrite(write);
  }

  void _cancelPermissions({bool answer = true}) {
    final questions = Map<String, _Question>.of(_questions);
    _questions.clear();
    for (final q in questions.entries) {
      if (answer && !q.value.request.asyncItem) {
        _answerCancelled(q.value.request.id, {'answers': {}});
      }
      _resolveQuestion(q.key, q.value, AgentQuestionOutcome.cancelled);
    }
    final pending = Map<String, _Permission>.of(_permissions);
    _permissions.clear();
    for (final entry in pending.entries) {
      if (answer) _answerCancelled(entry.value.rpcId, entry.value.cancellation);
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
    if (!_hasTurn && !_delegatedWork) {
      onStopResult(
        AgentStopResultParams(
          sessionId: sessionId,
          outcome: AgentStopOutcome.notRunning,
        ),
      );
      return;
    }
    if (_stopped) return;
    final addressedTurns = client.activeNativeTurns;
    final write = client.cancelWithPermissions(_nativeSessionId!, [
      for (final permission in _permissions.values)
        permission.native
            ? RuntimeReply(permission.rpcId, permission.cancellation!)
            : permission.rpcId,
      for (final q in _questions.values)
        if (!q.request.asyncItem) RuntimeReply(q.request.id, {'answers': {}}),
    ]);
    _stopped = true;
    _notConfirmed = false;
    _stopTurns
      ..clear()
      ..addAll(addressedTurns);
    _stopResults.clear();
    _cancelPermissions(answer: false);
    _set(AgentState.stopping);
    _deadline = _deadlineFactory(const Duration(seconds: 10), () {
      if ((!_hasTurn && !_delegatedWork && !_stopped) ||
          _terminal ||
          _disposed ||
          _notConfirmed) {
        return;
      }
      _notConfirmed = true;
      onStopResult(
        AgentStopResultParams(
          sessionId: sessionId,
          outcome: AgentStopOutcome.notConfirmed,
          message:
              client.interruptionReason ??
              (_delegated?.incomplete == true
                  ? 'Delegated activity incomplete; child interruption cannot be confirmed.'
                  : null),
        ),
      );
    });
    if (client.acp == null) {
      _observeNativeControl(write, 'Interruption');
    } else {
      _observeWrite(write);
    }
  }

  /// Immediate close transition; the service owns cancel grace and settlement.
  void beginClosing() {
    if (_disposed || _state == AgentState.ended) return;
    final running = _hasTurn || _delegatedWork;
    _set(AgentState.closing);
    _deadline?.cancel();
    _cancelPermissions();
    if (running && _nativeSessionId != null) {
      final cancellation = client.cancel(_nativeSessionId!);
      if (client.acp == null) {
        _observeNativeControl(cancellation, 'Interruption');
      } else {
        _observeWrite(cancellation);
      }
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
    client.observeExit();
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
    client.acp?.normalizeNotification = null;
    client.consumeNotification = null;
    client.acp?.onPermissionRequest = null;
    client.onFailure = null;
    client.normalizeUpdate = null;
    client.onPermission = null;
    client.onQuestion = null;
    client.onRetired = null;
    client.onTurnIdentity = null;
    client.onDelegatedChanged = null;
    client.onNativeTurnEnded = null;
  }
}

class _Permission {
  _Permission(
    this.rpcId,
    this.options, {
    this.native = false,
    this.turnId,
    this.cancellation,
    this.threadId,
  });
  final bool native;
  final String? turnId;
  final String? threadId;
  final Json? cancellation;
  final Object rpcId;

  /// Desktop (redacted) option id to the adapter's own id.
  final Map<String, Object?> options;
}

class _Question {
  _Question(this.request, this.display);
  final RuntimeQuestion request;
  final List<AgentQuestion> display;
}
