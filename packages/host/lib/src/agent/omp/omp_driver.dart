import 'dart:async';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';

import '../qualification.dart';
import '../runtime_driver.dart';
import '../tool_secret_redaction.dart';
import '../tools/tool_catalog.dart';
import 'omp_children.dart';
import 'omp_client.dart';
import 'omp_host_tools.dart';
import 'omp_history.dart';
import 'omp_session_file.dart';
import 'omp_tool_activity.dart';

class OmpRuntimeDriver extends RuntimeDriver {
  OmpRuntimeDriver(
    this.client,
    this.version, {
    this.runId = 'omp',
    this._toolSecrets,
  }) {
    client.normalizeNotification = _frame;
    unawaited(
      client.done.then((_) {
        _closeQuiescence?.complete();
        _closeQuiescence = null;
        _hostTools.revoke();
        _replay = null;
        _children = null;
        final turn = _turn;
        if (turn == null) return;
        _turn = null;
        _messages.clear();
        _activity.reset();
        turn.terminal.completeError(
          client.failure ?? OmpProtocolException('transport closed'),
        );
      }),
    );
  }

  final String runId;
  final Iterable<String> Function()? _toolSecrets;
  static const rootCapabilities = ['prompt', 'streaming', 'cancel'];
  final OmpClient client;
  late final _hostTools = OmpHostTools(client);
  final String version;
  final _ready = Completer<void>();
  final _messages = <String, Set<int>>{};
  final _refusedPromptIds = <String>{};
  late final _activity = OmpToolActivity(cardPrefix: runId);
  List<Uint8List>? _replay;
  int _historyEpoch = 0;
  int? _replayEpoch;
  String? _historyUnavailable;
  String? get sessionFile => _sessionFile;
  String? _sessionFile;
  Future<RuntimeIdentity>? _initializing;
  OmpChildren? _children;
  bool _nativeWork = false;
  Future<void>? _backgroundAbort;
  final _cancelledChildren = <String>{};
  bool _historyReading = false;
  Completer<void>? _closeQuiescence;
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
  void observeExit() => stopNativeWrites();

  /// Stop issuing replies before deliberately closing native stdin.
  void stopNativeWrites() {
    _nativeExited = true;
    _hostTools.revoke();
  }

  bool get hostToolsRegistered => _hostTools.registered;

  Future<String?> registerHostTools(ToolRole role) {
    if (_session == null) throw StateError('OMP session identity not verified');
    return _hostTools.register(role);
  }

  void bindHostTools(
    ToolRunFacts facts, {
    required void Function() onSucceeded,
  }) => _hostTools.bind(facts, onSucceeded);

  void revokeHostTools() => _hostTools.revoke();

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
  AgentDelegated? get delegated {
    final children = _children;
    if (children == null) return null;
    return AgentDelegated(
      activeChildren: children.active,
      incomplete: children.incomplete || (!_showChildEvents && _nativeWork),
      nativeWork: _showChildEvents && _nativeWork,
      childVisibilityUnavailable: _showChildEvents && !children.available,
    );
  }

  bool get _showChildEvents => _children?.views == true;

  @override
  Map<String, String> get activeNativeTurns => {
    if (_session != null && turnId != null) _session!: turnId!,
    if (_children case final children?)
      for (final child in children.known)
        if (child.cancellable) child.key: child.ticket,
  };

  /// A yielded prompt is not enough: OMP may still own deferred or child work.
  Future<void>? waitForCloseQuiescence() {
    if (client.isClosed || !_hasWork) return null;
    return (_closeQuiescence ??= Completer<void>()).future;
  }

  bool get _hasWork =>
      _turn != null ||
      _nativeWork ||
      (_children?.active ?? 0) != 0 ||
      _children?.incomplete == true;

  void _checkCloseQuiescence() {
    if (_closeQuiescence == null || _hasWork) return;
    _closeQuiescence!.complete();
    _closeQuiescence = null;
  }

  Future<void> configureChildren({required bool views}) async {
    final children = _children = OmpChildren(runId, views: views);
    final level = views ? 'events' : 'progress';
    const timeout = Duration(seconds: 10);
    try {
      final subscribed = await client.command(
        'set_subagent_subscription',
        fields: {'level': level},
        timeout: timeout,
      );
      if (subscribed is! Json || subscribed['level'] != level) {
        children.unavailable();
        return;
      }
      final seeded = await client.command(
        'get_subagents',
        timeout: timeout,
        decodeData: (data) {
          children.seed(data);
          return true;
        },
      );
      if (seeded != true) children.unavailable();
    } on OmpRemoteException {
      children.unavailable();
    } on TimeoutException {
      children.unavailable();
    }
  }

  Future<void> attachChildren() async {
    final children = _children;
    if (children == null || !children.views || children.attached || draining) {
      return;
    }
    children.attached = true;
    await _deliverReplay([
      for (final child in children.known)
        ...encodeAgentEvent(children.lifecycle(child)),
    ]);
  }

  Future<AgentChildHistoryResult> childHistory(
    AgentChildHistoryParams params, {
    required Future<int?> Function(String) inspect,
    required bool Function() current,
  }) async {
    final children = _children;
    if (children == null ||
        !children.views ||
        !children.attached ||
        params.runId != runId ||
        !current()) {
      throw RpcException(
        ErrorCode.staleRun,
        'The OMP root run is no longer current.',
      );
    }
    final child = children.byKey(params.childKey);
    if (child == null) {
      throw RpcException(
        ErrorCode.unknownSession,
        'The OMP subagent is not available on this run.',
      );
    }
    final path = child.file;
    if (path == null) {
      return const AgentChildHistoryResult(
        AgentChildHistoryStatus.unavailable,
        reason: 'no-native-file',
      );
    }
    if (_historyReading) {
      throw RpcException(
        ErrorCode.busy,
        'A subagent history read is already in progress.',
      );
    }
    _historyReading = true;
    final ticket = child.ticket;
    bool sameChild() =>
        !draining &&
        !isClosed &&
        current() &&
        identical(children.byKey(params.childKey), child) &&
        ticket == child.ticket &&
        path == child.file;
    final clock = Stopwatch()..start();
    const budget = Duration(seconds: 10);
    var queued = false;
    try {
      final size = await inspect(path);
      if (size == null) {
        return const AgentChildHistoryResult(
          AgentChildHistoryStatus.unavailable,
          reason: 'native-file-unavailable',
        );
      }
      final remaining = budget - clock.elapsed;
      if (!sameChild() || remaining <= Duration.zero) {
        return const AgentChildHistoryResult(
          AgentChildHistoryStatus.unavailable,
          reason: 'stale-child',
        );
      }
      final response = await client.command(
        'get_subagent_messages',
        fields: {'sessionFile': path, 'fromByte': 0},
        timeout: remaining,
        decodeData: (data) => OmpHistory.childSnapshot(
          data,
          path: path,
          inspectedSize: size,
          root: runId,
          child: child.key,
          token: params.viewToken,
          encode: _encodeVisibleEvent,
        ),
      );
      if (response is! List<Uint8List> || !sameChild()) {
        return const AgentChildHistoryResult(
          AgentChildHistoryStatus.unavailable,
          reason: 'native-snapshot-unavailable',
        );
      }
      queued = true;
      _deliverReplay(response)
          .whenComplete(() => _historyReading = false)
          .ignore();
      return const AgentChildHistoryResult(AgentChildHistoryStatus.queued);
    } on OmpRemoteException {
      return const AgentChildHistoryResult(
        AgentChildHistoryStatus.unavailable,
        reason: 'native-reading-refused',
      );
    } on OmpProtocolException {
      return const AgentChildHistoryResult(
        AgentChildHistoryStatus.unavailable,
        reason: 'native-transport-closed',
      );
    } on TimeoutException {
      return const AgentChildHistoryResult(
        AgentChildHistoryStatus.unavailable,
        reason: 'native-read-timed-out',
      );
    } finally {
      if (!queued) _historyReading = false;
    }
  }

  void _setNativeWork(bool active) {
    final children = _children;
    final wasIncomplete = children?.incomplete;
    final wasActive = _nativeWork;
    _nativeWork = active;
    if (!active) {
      _backgroundAbort = null;
      children?.settled();
    }
    if (children != null &&
        (wasActive != active || wasIncomplete != children.incomplete)) {
      onDelegatedChanged?.call();
    }
    _checkCloseQuiescence();
  }

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
      AdapterClaims(rootCapabilities, 'omp-locator-unavailable'),
    );
  }

  @override
  Future<String> newSession(
    String cwd, {
    List<Json> mcpServers = const [],
    void Function(String)? onCreated,
  }) async {
    final (String, String?, bool, int)? state;
    try {
      state = await _getIdentity();
    } on OmpRemoteException catch (error) {
      throw OmpProtocolException('get_state: $error');
    } on TimeoutException {
      throw OmpProtocolException('get_state timed out');
    }
    if (state == null) throw OmpProtocolException('invalid OMP sessionId');
    final (id, path, _, _) = state;
    _session = id;
    _sessionFile = path;
    onCreated?.call(id);
    return id;
  }

  Future<(String, String?, bool, int)?> _getIdentity({
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final state = await client.command(
      'get_state',
      timeout: timeout,
      decodeData: (data) {
        if (data is! Json) return null;
        final id = data['sessionId'];
        if (id is! String ||
            id.isEmpty ||
            id.length > 4096 ||
            jsonStringContentBytes(id) > 4096) {
          return null;
        }
        final settled =
            data['isSettled'] == true && data['hasPendingAsyncWork'] != true;
        _setNativeWork(!settled);
        return (
          id,
          ompSessionPath(data['sessionFile']),
          settled,
          _historyEpoch,
        );
      },
    );
    return state as (String, String?, bool, int)?;
  }

  /// Called only for a native process launched with the stored exact file.
  Future<AgentContinueMode> prepareContinue(String id, String file) async {
    ({bool settled, int epoch}) verify((String, String?, bool, int)? state) {
      if (state case (final nativeId, final path?, final settled, final epoch)
          when nativeId == id && sameOmpSessionPath(file, path)) {
        return (settled: settled, epoch: epoch);
      }
      throw OmpProtocolException('OMP did not confirm the saved conversation');
    }

    final start = verify(await _getIdentity());
    _session = id;
    _sessionFile = file;
    if (!start.settled) {
      _historyUnavailable = 'OMP was not idle while opening the session';
      return AgentContinueMode.resume;
    }

    final snapshot = OmpHistory(runId, encode: _encodeVisibleEvent);
    final clock = Stopwatch()..start();
    const budget = Duration(seconds: 60);
    const identityGrace = Duration(seconds: 10);
    var complete = false;
    String? cursor;
    try {
      for (
        var i = 0;
        i < OmpHistory.maxPages && _historyEpoch == start.epoch;
        i++
      ) {
        final remaining = budget - identityGrace - clock.elapsed;
        if (remaining <= Duration.zero) break;
        final page = await client.command(
          'get_messages_page',
          fields: {'limit': OmpHistory.pageSize, 'cursor': ?cursor},
          timeout: remaining,
          decodeData: snapshot.page,
        );
        if (page is! ({String? cursor})) break;
        cursor = page.cursor;
        if (cursor == null) {
          complete = snapshot.finish();
          break;
        }
      }
    } on OmpRemoteException catch (error) {
      _historyUnavailable = switch (error.code) {
        'session_busy' ||
        'stale_cursor' => 'OMP history changed while it was read',
        _ => 'OMP could not return history within the supported transport',
      };
    } on TimeoutException {
      _historyUnavailable = 'OMP history did not answer within the read limit';
    }
    // The one snapshot budget also covers its final identity check.
    final remaining = budget - clock.elapsed;
    if (remaining <= Duration.zero) {
      throw OmpProtocolException(
        'OMP history exceeded the identity verification budget',
      );
    }
    final end = verify(
      await _getIdentity(
        timeout: remaining < identityGrace ? remaining : identityGrace,
      ),
    );
    if (complete &&
        end.settled &&
        start.epoch == end.epoch &&
        end.epoch == _historyEpoch) {
      _replay = snapshot.lines;
      _replayEpoch = end.epoch;
      return AgentContinueMode.load;
    }
    _historyUnavailable ??=
        'OMP history was unavailable, changed, or exceeded the replay limit';
    return AgentContinueMode.resume;
  }

  Future<void> _deliverReplay(Iterable<Uint8List> lines) async {
    await client.consumeNotification?.call(
      RuntimeDelivery(lines, 0, null, null),
    );
  }

  @override
  Future<void> loadSession(
    String id,
    String cwd, {
    List<Json> mcpServers = const [],
  }) async {
    _requireReopened(id);
    final replay = _replay;
    _replay = null;
    if (replay == null || _historyEpoch != _replayEpoch) {
      _historyUnavailable = 'OMP history changed before attachment';
      await resumeSession(id, cwd);
      return;
    }
    await _deliverReplay([
      ...encodeAgentEvent(AgentEvent.replay(AgentReplayPhase.start)),
      ...replay,
      ...encodeAgentEvent(AgentEvent.replay(AgentReplayPhase.end)),
    ]);
  }

  @override
  Future<void> resumeSession(
    String id,
    String cwd, {
    List<Json> mcpServers = const [],
  }) async {
    _requireReopened(id);
    await _deliverReplay(
      encodeAgentEvent(
        AgentEvent.notice(
          'earlier messages not shown: ${_historyUnavailable ?? 'OMP history is unavailable'}',
        ),
      ),
    );
  }

  void _requireReopened(String id) {
    if (id != _session || isClosed) {
      throw OmpProtocolException('OMP saved conversation is unavailable');
    }
  }

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
            if (!invoked) _activity.reset();
            final lines = <Uint8List>[];
            for (final update in turn.staged) {
              if (!invoked && update.event != null) continue;
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
              _activity.reset();
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
              _checkCloseQuiescence();
              if (error is TimeoutException) client.fail(error);
            }
            if (!turn.accepted) Error.throwWithStackTrace(error, stack);
          },
        );
    return (admission, turn.terminal.future);
  }

  @override
  Future<void> cancel(String id) => cancelWithPermissions(id, const []);

  /// Admits the cancellation replies and correlated abort as one write.
  /// A busy refusal leaves Stop and all of its pending approvals unchanged.
  @override
  Future<void> cancelWithPermissions(String id, Iterable<Object> requests) {
    if (_nativeExited || client.isClosed) return Future.value();
    final turn = _turn;
    final children = _children;
    final newChildren = [
      if (children != null)
        for (final child in children.known)
          if (child.cancellable && !_cancelledChildren.contains(child.key))
            child,
    ];
    final root = turn?.id != null
        ? turn!.abort == null
        : _nativeWork && children != null && _backgroundAbort == null;
    if (!root && newChildren.isEmpty && requests.isEmpty) {
      return turn?.abort ?? _backgroundAbort ?? Future.value();
    }
    final commands = [
      if (root) ('abort', const <String, Object?>{}),
      for (final child in newChildren)
        ('cancel_subagent', <String, Object?>{'subagentId': child.id}),
    ];
    final (admission, replies) = client.admitBatch(
      commands,
      before: requests.cast<RuntimeReply>().map(
        (reply) => _interactionReply(reply.id, reply.result),
      ),
      timeout: const Duration(seconds: 10),
    );
    for (final child in newChildren) {
      _cancelledChildren.add(child.key);
    }
    final completed =
        Future.wait<void>([
          admission,
          for (var i = 0; i < replies.length; i++)
            replies[i].then<void>((result) {
              if (commands[i].$1 == 'cancel_subagent' &&
                  (result is! Json || result['cancelled'] != true)) {
                throw OmpProtocolException(
                  'OMP did not accept a subagent cancellation',
                );
              }
            }),
        ]).then<void>(
          (_) {},
          onError: (Object error) {
            _interruption = 'OMP did not confirm cancellation admission.';
            throw OmpProtocolException(_interruption!);
          },
        );
    if (root) {
      if (turn != null) {
        turn.abort = completed;
      } else {
        _backgroundAbort = completed;
      }
    }
    return completed;
  }

  void _end(_Turn turn, RuntimeTurnResult result) {
    if (!identical(_turn, turn)) return;
    _turn = null;
    _messages.clear();
    _activity.reset();
    _idleNotices = 0;
    onNativeTurnEnded?.call(_session!, turn.id!, result);
    turn.terminal.complete(result);
    _checkCloseQuiescence();
  }

  Object? _frame(Json frame) {
    final type = frame['type'];
    if (type == 'host_tool_call' || type == 'host_tool_cancel') {
      _hostTools.receive(frame, inputClosed: _nativeExited);
      return null;
    }
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
    if (type == 'agent_start' ||
        type == 'turn_start' ||
        type == 'message_start' ||
        type == 'message_update' ||
        type == 'session_info_update') {
      _historyEpoch++;
      if (type == 'agent_start' || type == 'turn_start') _setNativeWork(true);
    }
    if (type == 'session_settled') {
      _setNativeWork(false);
      return null;
    }
    if (type == 'subagent_lifecycle' ||
        type == 'subagent_progress' ||
        type == 'subagent_event') {
      return _childFrame(type! as String, frame['payload']);
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
      final settled = frame['sessionSettled'];
      if (settled is bool) _setNativeWork(!settled);
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
    if (draining) return null;
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
    } else if (type == 'tool_execution_start' ||
        type == 'tool_execution_update' ||
        type == 'tool_execution_end') {
      if (_canProjectToolEvents(turn)) {
        final event = _activity.frame(
          type as String,
          frame,
          active: turn != null,
        );
        if (event != null) _toolEvent(lines, turn, event);
      }
    } else if (turn != null &&
        (type == 'message_start' ||
            type == 'message_update' ||
            type == 'message_end')) {
      _message(frame, type as String, turn, lines);
    }
    return _delivery(lines);
  }

  Object? _childFrame(String type, Object? payload) {
    final children = _children;
    if (children == null) return null;
    final wasIncomplete = children.incomplete;
    final count = children.active;
    final lines = <Uint8List>[];
    for (final event in children.receive(type, payload, (key, ticket, result) {
      _cancelledChildren.remove(key);
      if (result != null) onNativeTurnEnded?.call(key, ticket, result);
    })) {
      if (!draining) lines.addAll(_encodeVisibleEvent(event));
    }
    if (children.active != count || children.incomplete != wasIncomplete) {
      onDelegatedChanged?.call();
    }
    _checkCloseQuiescence();
    return _delivery(lines);
  }

  Iterable<Uint8List> _encodeVisibleEvent(AgentEvent event) {
    if (event.kind == AgentEventKind.replay ||
        event.kind == AgentEventKind.child) {
      return encodeAgentEvent(event);
    }
    final secrets = _toolSecrets?.call();
    if (secrets == null || secrets.isEmpty) return encodeAgentEvent(event);
    final wire = event.toJson();
    String redact(String text) => redactToolSecrets(text, secrets);
    // Redact presentation fields, not the host-generated routing identities,
    // tool card IDs or the desktop's replay token.
    for (final key in const ['text', 'title', 'content', 'locations']) {
      if (wire[key] case final value?) {
        wire[key] = redactToolJson(value, redact);
      }
    }
    return encodeAgentEvent(
      AgentEvent.fromJson(wire, allowOmpChildEvents: true),
    );
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

  bool _canProjectToolEvents(_Turn? turn) =>
      !draining && (turn?.accepted != true || turn?.agentInvoked != false);

  Object? _frameError(Json frame, _Turn? turn, List<Uint8List> lines) {
    switch (frame['originalType']) {
      case 'tool_execution_start' ||
          'tool_execution_update' ||
          'tool_execution_end':
        if (!_canProjectToolEvents(turn)) return null;
        final event = _activity.omitted(active: turn != null);
        if (event != null) _toolEvent(lines, turn, event);
        return _delivery(lines);
      case 'tool_stream_update':
        return null;
      case 'subagent_lifecycle' || 'subagent_progress' || 'subagent_event':
        return _childFrame(frame['originalType']! as String, null);
      case 'message_start' ||
          'message_update' ||
          'message_end' ||
          'agent_start' ||
          'agent_end' ||
          'turn_start' ||
          'turn_end' ||
          'notice':
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

  void _toolEvent(List<Uint8List> lines, _Turn? turn, AgentEvent event) {
    final update = RuntimeUpdate(event.kind, '', event: event);
    if (turn != null && !turn.accepted) {
      // Stage projected fields, never the native frame. Charge for encoded
      // content and its bounded metadata before the prompt is admitted.
      var bytes = 192 + jsonStringContentBytes(event.title ?? event.text ?? '');
      for (final block in event.content) {
        bytes += 32 + jsonStringContentBytes(block['text']! as String);
      }
      _stage(turn, update, eventBytes: bytes);
    } else {
      _addLines(lines, update);
    }
  }

  void _stage(_Turn turn, RuntimeUpdate? update, {int? eventBytes}) {
    turn.earlyCount++;
    turn.earlyBytes +=
        eventBytes ??
        (update == null ? 4096 : jsonStringContentBytes(update.text) + 64);
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
    if (turn.agentInvoked && !draining) {
      for (final event in _activity.finish()) {
        _toolEvent(lines, turn, event);
      }
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
  int earlyCount = 0, earlyBytes = 0, notices = 0;
  final staged = <RuntimeUpdate>[];
  final terminal = Completer<RuntimeTurnResult>();
  RuntimeTurnResult? earlyEnd;
  Future<void>? abort;
}
