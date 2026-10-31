import 'dart:async';
import 'dart:math';

import 'package:domain/domain.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:host_protocol/host_protocol.dart';

import '../host_link.dart';
import '../view_closer.dart';
import 'agent_transcript.dart';

export 'agent_transcript.dart';

const agentChatKind = 'agent-chat';
const agentCloseWarning = 'Are you sure you want to stop the running agent?';
const agentAuthGuidance =
    'Claude Code is not signed in. Run claude in a terminal and sign in natively, then Retry.';

enum AgentLinkPhase { pending, live, closing, ended }

class AgentLink {
  AgentLink({
    required this.paneId,
    required this.workspaceId,
    required this.runtimeName,
    this.sessionId,
  });
  final String paneId;
  final String workspaceId;
  String runtimeName;
  String? sessionId;
  String? runtimeProfileId;
  AgentAdapter? adapter;
  List<String> capabilities = const [];
  final AgentTranscript transcript = AgentTranscript();
  final TextEditingController prompt = TextEditingController();
  final FocusNode promptFocus = FocusNode();
  final Map<String, AgentPermission> _pendingPermissions = {};
  Iterable<AgentPermission> get permissions sync* {
    final retained = <String>{};
    for (final entry in transcript.entries) {
      final permission = entry.permission;
      if (permission == null) continue;
      retained.add(permission.request.requestId);
      yield permission;
    }
    for (final entry in _pendingPermissions.entries) {
      if (!retained.contains(entry.key)) yield entry.value;
    }
  }

  Iterable<AgentPermission> get hiddenPendingPermissions {
    final retained = {
      for (final entry in transcript.entries)
        if (entry.permission != null) entry.permission!.request.requestId,
    };
    return _pendingPermissions.entries
        .where((e) => !retained.contains(e.key))
        .map((e) => e.value);
  }

  AgentLinkPhase phase = AgentLinkPhase.ended;
  AgentState state = AgentState.ended;
  int seq = -1;
  bool connected = false;
  bool known = false;
  bool saved = false;
  bool hostLost = false;
  bool closeRequested = false;
  bool abandoned = false;
  bool sending = false;
  bool stopping = false;
  bool streamFailed = false;
  String? error;
  String? errorCode;
  String? lastPrompt;
  AgentStopResultParams? stopResult;
  StreamSubscription<AgentEvent>? _events;

  bool get canSend =>
      connected &&
      phase == AgentLinkPhase.live &&
      state == AgentState.idle &&
      !sending &&
      !streamFailed;
  bool get canStop =>
      connected &&
      phase == AgentLinkPhase.live &&
      !stopping &&
      (state == AgentState.running || state == AgentState.waitingApproval);
  bool get canContinue => connected && known && phase == AgentLinkPhase.ended;
  bool get canRetry =>
      connected &&
      ((phase == AgentLinkPhase.ended &&
              state == AgentState.failed &&
              (!known || errorCode == ErrorCode.authRequired)) ||
          (phase == AgentLinkPhase.live &&
              state == AgentState.idle &&
              errorCode == ErrorCode.authRequired &&
              lastPrompt != null));
  bool get canNewSession => connected && phase == AgentLinkPhase.ended;
  bool get live =>
      phase == AgentLinkPhase.live || phase == AgentLinkPhase.closing;
  String get statusLabel {
    if (hostLost) return 'Stopped or unknown';
    if (saved) return 'Saved, not running';
    if (streamFailed) return 'Failed';
    if (phase == AgentLinkPhase.pending) return 'Starting';
    return switch (state) {
      AgentState.starting => 'Starting',
      AgentState.idle => 'Idle',
      AgentState.running => 'Running',
      AgentState.waitingApproval => 'Waiting for approval',
      AgentState.stopping => 'Stopping',
      AgentState.closing => 'Closing',
      AgentState.ended => 'Ended',
      AgentState.failed => 'Failed',
    };
  }

  String? get stopLabel {
    final result = stopResult;
    if (result == null) return null;
    final label = switch (result.outcome) {
      AgentStopOutcome.stopped => 'Stopped',
      AgentStopOutcome.finishedFirst => 'Finished before Stop',
      AgentStopOutcome.endedWithError => 'Turn ended with an error after Stop',
      AgentStopOutcome.notConfirmed => 'Stop not confirmed',
      AgentStopOutcome.notRunning => 'No turn running',
    };
    return '$label${result.late ? ' (after the deadline)' : ''}';
  }

  void _dispose() {
    prompt.dispose();
    promptFocus.dispose();
  }
}

/// Owns only desktop display state. Host state notifications are authoritative;
/// data events never change the turn state, including late trailing data.
class AgentController extends ChangeNotifier implements ViewCloser {
  AgentController({
    required this.removePane,
    required this.savePaneState,
    required this.focusPane,
  });
  final void Function(String paneId) removePane;
  final void Function(String paneId, Json state) savePaneState;
  final void Function(String paneId) focusPane;
  final Map<String, AgentLink> _links = {};
  final Map<String, AgentLink> _bySession = {};
  final List<StreamSubscription<Object?>> _subscriptions = [];
  final Set<StreamSubscription<AgentExitedParams>> _orphanSubscriptions = {};
  HostLink? _host;
  int _generation = 0;
  bool _disposed = false;
  AgentLink? linkOf(String paneId) => _links[paneId];

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  bool _current(HostLink host, int generation) =>
      !_disposed && identical(host, _host) && generation == _generation;
  bool _owns(AgentLink link) =>
      !link.abandoned && identical(_links[link.paneId], link);

  void attach(HostLink host) {
    detach();
    _host = host;
    final generation = _generation;
    void listen<T>(Stream<T> source, void Function(T) receive) {
      _subscriptions.add(
        source.listen((event) {
          if (_current(host, generation)) receive(event);
        }),
      );
    }

    listen(host.agentStates, (event) {
      final link = _bySession[event.sessionId];
      if (link == null || event.seq <= link.seq || link.streamFailed) return;
      link.seq = event.seq;
      link.state = event.state;
      _changed();
    });
    listen(host.agentPermissionRequests, (event) {
      final link = _bySession[event.sessionId];
      if (link == null ||
          link._pendingPermissions.containsKey(event.requestId)) {
        return;
      }
      final permission = AgentPermission(event);
      link._pendingPermissions[event.requestId] = permission;
      link.transcript.addPermission(permission);
      _changed();
    });
    listen(host.agentPermissionResolutions, (event) {
      final link = _bySession[event.sessionId];
      final permission = link?._pendingPermissions.remove(event.requestId);
      if (permission == null) return;
      permission.resolution = event;
      permission.replying = false;
      _changed();
    });
    listen(host.agentStopResults, (event) {
      final link = _bySession[event.sessionId];
      if (link == null) return;
      // One current Stop outcome, replaced (not appended) by its late result.
      link.stopResult = event;
      link.stopping = false;
      _changed();
    });
    listen(host.agentTurnEnds, (event) {
      final link = _bySession[event.sessionId];
      if (link == null) return;
      link.sending = false;
      if (event.error != null ||
          (event.stopReason != null &&
              event.stopReason != 'end_turn' &&
              event.stopReason != 'cancelled')) {
        final message = event.error == ErrorCode.authRequired
            ? '$agentAuthGuidance\n${event.message ?? ''}'
            : event.message ?? 'Turn ended: ${event.stopReason ?? event.error}';
        link.transcript.add(AgentEvent.notice(message));
        if (event.error == ErrorCode.authRequired) link.errorCode = event.error;
      }
      _changed();
    });
    listen(host.agentExits, _exited);
    listen(host.agentCloseFailures, (event) {
      final link = _bySession[event.sessionId];
      if (link == null) return;
      link.closeRequested = false;
      link.phase = AgentLinkPhase.live;
      final failure =
          'Could not close the agent: ${event.reason}${event.message == null ? '' : ': ${event.message}'}';
      link.error = link.streamFailed ? '${link.error}\n$failure' : failure;
      _changed();
    });
  }

  void detach() {
    _generation++;
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    _subscriptions.clear();
    _bySession.clear();
    _host = null;
    for (final link in _links.values) {
      unawaited(link._events?.cancel());
      link._events = null;
      link.connected = false;
      link.hostLost = true;
      link.saved = false;
      link.phase = AgentLinkPhase.ended;
      link.sending = false;
      link.stopping = false;
      _disablePermissions(link);
    }
    _changed();
  }

  void sync(Iterable<PaneNode> panes) {
    final ids = <String>{};
    for (final pane in panes) {
      ids.add(pane.id);
      _links.putIfAbsent(
        pane.id,
        () =>
            AgentLink(
                paneId: pane.id,
                workspaceId: pane.workspace ?? '',
                runtimeName: pane.state['runtimeName'] is String
                    ? pane.state['runtimeName']! as String
                    : 'Claude Code',
                sessionId: pane.state['sessionId'] is String
                    ? pane.state['sessionId']! as String
                    : null,
              )
              ..connected =
                  _host?.hello.capabilities.contains(Capability.agent) == true,
      );
    }
    for (final link in _links.values.toList()) {
      if (ids.contains(link.paneId)) continue;
      _links.remove(link.paneId);
      link.abandoned = true;
      unawaited(link._events?.cancel());
      if (link.sessionId case final id?) {
        if (identical(_bySession[id], link)) _bySession.remove(id);
        final host = _host;
        if (host != null && link.live) _closeOrphan(host, id);
      }
      _disposeLink(link);
    }
  }

  Future<void> restore() async {
    final host = _host;
    if (host == null || !host.hello.capabilities.contains(Capability.agent)) {
      return;
    }
    final generation = _generation;
    final candidates = _links.values
        .where((l) => !l.live && l.phase != AgentLinkPhase.pending)
        .toList();
    for (final link in candidates) {
      link.connected = true;
      link.hostLost = false;
      link.seq = -1;
      link.closeRequested = false;
      link.state = AgentState.ended;
      link.known = false;
      link.saved = false;
    }
    final ids = candidates
        .map((l) => l.sessionId)
        .whereType<String>()
        .toSet()
        .toList();
    for (var offset = 0; offset < ids.length; offset += maxAgentRecordIds) {
      try {
        final records = await host.agentRecords(
          ids.sublist(offset, min(offset + maxAgentRecordIds, ids.length)),
        );
        if (!_current(host, generation)) return;
        for (final link in candidates) {
          if (!_owns(link) ||
              link.live ||
              link.phase == AgentLinkPhase.pending) {
            continue;
          }
          final record = records.records[link.sessionId];
          if (record == null) continue;
          link.known = record.known;
          link.saved = record.known;
        }
      } on RpcException catch (e) {
        if (!_current(host, generation)) return;
        for (final link in candidates) {
          if (_owns(link)) link.error = _describe(e);
        }
      } on ConnectionClosedException {
        return;
      }
    }
    _changed();
  }

  Future<void> start(
    String paneId, {
    required String workspaceId,
    required String runtimeName,
    String? runtimeProfileId,
  }) async {
    final host = _host;
    if (host == null ||
        _disposed ||
        !host.hello.capabilities.contains(Capability.agent)) {
      return;
    }
    final previous = _links[paneId];
    if (previous != null &&
        (previous.live || previous.phase == AgentLinkPhase.pending)) {
      return;
    }
    final link =
        AgentLink(
            paneId: paneId,
            workspaceId: workspaceId,
            runtimeName: runtimeName,
          )
          ..phase = AgentLinkPhase.pending
          ..state = AgentState.starting
          ..connected = true
          ..runtimeProfileId = runtimeProfileId;
    _links[paneId] = link;
    if (previous != null) _disposeLink(previous);
    savePaneState(paneId, {'runtimeName': runtimeName});
    _changed();
    final generation = _generation;
    try {
      final result = await host.startAgent(
        AgentStartParams(
          workspaceId: workspaceId,
          runtimeProfileId: runtimeProfileId,
        ),
      );
      if (!_current(host, generation) || !_owns(link)) {
        if (!_disposed) _closeOrphan(host, result.sessionId);
        return;
      }
      link.sessionId = result.sessionId;
      link.known = true;
      link.adapter = result.adapter;
      link.capabilities = result.capabilities;
      _bind(host, link, result.eventChannel, generation);
      savePaneState(paneId, {
        'sessionId': result.sessionId,
        'runtimeName': runtimeName,
      });
    } on RpcException catch (e) {
      if (_current(host, generation) && _owns(link)) _failed(link, e);
    } on ConnectionClosedException {
      if (_current(host, generation) && _owns(link)) detach();
    }
    _changed();
  }

  Future<void> continueSession(String paneId) async {
    final link = _links[paneId];
    final host = _host;
    if (link == null || host == null || !link.canContinue) return;
    final id = link.sessionId!;
    final existing = _bySession[id];
    if (existing != null && !identical(existing, link)) {
      focusPane(existing.paneId);
      return;
    }
    // Reserve before the await so two Continue clicks cannot race a duplicate.
    _bySession[id] = link;
    link.phase = AgentLinkPhase.pending;
    link.saved = false;
    link.state = AgentState.starting;
    link.error = null;
    link.errorCode = null;
    link.streamFailed = false;
    link.seq = -1;
    link.transcript.clear();
    link._pendingPermissions.clear();
    link.stopResult = null;
    final generation = _generation;
    _changed();
    try {
      final result = await host.continueAgent(id);
      if (!_current(host, generation) || !_owns(link)) {
        if (!_disposed) _closeOrphan(host, id);
        return;
      }
      link.adapter = result.adapter;
      link.capabilities = result.capabilities;
      _bind(host, link, result.eventChannel, generation);
    } on RpcException catch (e) {
      if (!_current(host, generation) || !_owns(link)) return;
      if (identical(_bySession[id], link)) _bySession.remove(id);
      _failed(link, e);
      if (e.reason == ErrorCode.turnRunning &&
          e.message.contains('already open')) {
        final owner = _links.values
            .where((l) => l.sessionId == id && l.live)
            .firstOrNull;
        if (owner != null) focusPane(owner.paneId);
      }
    } on ConnectionClosedException {
      if (_current(host, generation)) detach();
    }
    _changed();
  }

  Future<void> newSession(String paneId) async {
    final link = _links[paneId];
    if (link == null || !link.canNewSession) return;
    await start(
      paneId,
      workspaceId: link.workspaceId,
      runtimeName: link.runtimeName,
      runtimeProfileId: link.runtimeProfileId,
    );
  }

  Future<void> retry(String paneId) async {
    final link = _links[paneId];
    if (link == null || !link.canRetry) return;
    if (link.phase == AgentLinkPhase.ended) {
      if (link.known) {
        await continueSession(paneId);
      } else {
        await newSession(paneId);
      }
    } else {
      // Retry is an explicit user action; it never discards an unsent draft.
      await send(paneId, link.lastPrompt!);
    }
  }

  void _bind(HostLink host, AgentLink link, int channel, int generation) {
    link.phase = AgentLinkPhase.live;
    link.saved = false;
    link.hostLost = false;
    _bySession[link.sessionId!] = link;
    link._events = host
        .attachAgent(link.sessionId!, channel)
        .listen(
          (event) {
            if (!_current(host, generation) || !_owns(link)) return;
            link.transcript.add(event);
            _changed();
          },
          onError: (Object error) {
            if (!_current(host, generation) || !_owns(link)) return;
            link.streamFailed = true;
            link.error = 'event stream error: $error';
            link.state = AgentState.failed;
            _disablePermissions(link);
            unawaited(link._events?.cancel());
            unawaited(
              host
                  .closeAgent(link.sessionId!)
                  .then<void>((_) {}, onError: (Object _) {}),
            );
            _changed();
          },
        );
  }

  Future<void> send(String paneId, String text) async {
    final link = _links[paneId];
    final host = _host;
    if (link == null || host == null || !link.canSend || text.trim().isEmpty) {
      return;
    }
    final generation = _generation;
    link.sending = true;
    link.error = null;
    link.errorCode = null;
    link.lastPrompt = text;
    link.stopResult = null;
    // The host emits accepted prompts on the ordered event channel, including
    // when the adapter later fails. RPC rejection must not create user history.
    _changed();
    try {
      await host.promptAgent(
        AgentPromptParams(sessionId: link.sessionId!, text: text),
      );
      if (_current(host, generation) &&
          _owns(link) &&
          link.prompt.text == text) {
        link.prompt.clear();
      }
    } on RpcException catch (e) {
      if (!_current(host, generation) || !_owns(link)) return;
      link.sending = false;
      link.errorCode = e.reason;
      link.error = _describe(e);
      link.transcript.add(AgentEvent.notice(link.error!));
    } on ConnectionClosedException {
      if (_current(host, generation)) detach();
    }
    _changed();
  }

  Future<void> stop(String paneId) async {
    final link = _links[paneId];
    final host = _host;
    if (link == null || host == null || !link.canStop) return;
    final generation = _generation;
    link.stopping = true;
    link.stopResult = null;
    _changed();
    try {
      await host.stopAgent(link.sessionId!);
    } on RpcException catch (e) {
      if (_current(host, generation) && _owns(link)) {
        link.stopping = false;
        link.error = _describe(e);
      }
    } on ConnectionClosedException {
      if (_current(host, generation)) detach();
    }
    _changed();
  }

  Future<void> replyPermission(
    String paneId,
    String requestId,
    String optionId,
  ) async {
    final link = _links[paneId];
    final host = _host;
    final permission = link?._pendingPermissions[requestId];
    if (link == null ||
        host == null ||
        !link.connected ||
        permission == null ||
        !permission.pending ||
        permission.replying ||
        !permission.request.options.any((o) => o.optionId == optionId)) {
      return;
    }
    final generation = _generation;
    permission.replying = true;
    _changed();
    try {
      await host.replyAgentPermission(
        AgentPermissionReplyParams(
          sessionId: link.sessionId!,
          requestId: requestId,
          optionId: optionId,
        ),
      );
    } on RpcException catch (e) {
      if (!_current(host, generation) || !_owns(link)) return;
      permission.replying = false;
      if (e.reason == ErrorCode.unknownRequest) {
        permission.resolution = AgentPermissionResolvedParams(
          sessionId: link.sessionId!,
          requestId: requestId,
          outcome: AgentPermissionOutcome.cancelled,
        );
        link._pendingPermissions.remove(requestId);
      } else {
        link.error = _describe(e);
      }
    } on ConnectionClosedException {
      if (_current(host, generation)) detach();
    }
    _changed();
  }

  @override
  String? warnsOnClose(String paneId) {
    final link = _links[paneId];
    if (link == null || !link.connected || !link.live) return null;
    return switch (link.state) {
      AgentState.running ||
      AgentState.waitingApproval ||
      AgentState.stopping => agentCloseWarning,
      _ => null,
    };
  }

  @override
  Future<void> closeConfirmed(String paneId) async {
    final link = _links[paneId];
    final host = _host;
    if (link == null || host == null || !link.live) {
      removePane(paneId);
      return;
    }
    if (link.closeRequested) return;
    final generation = _generation;
    link.closeRequested = true;
    link.phase = AgentLinkPhase.closing;
    link.error = null;
    _changed();
    try {
      // The host rechecks turn state now and owns cancel-before-terminate.
      // Never send a redundant Stop based on evidence from before a dialog.
      await host.closeAgent(link.sessionId!);
    } on RpcException catch (e) {
      if (_current(host, generation) && _owns(link)) {
        link.closeRequested = false;
        link.phase = AgentLinkPhase.live;
        link.error = _describe(e);
      }
    } on ConnectionClosedException {
      if (_current(host, generation)) detach();
    }
    _changed();
  }

  void _exited(AgentExitedParams event) {
    final link = _bySession.remove(event.sessionId);
    final host = _host;
    if (link == null || host == null) return;
    unawaited(link._events?.cancel());
    link._events = null;
    link.phase = AgentLinkPhase.ended;
    link.sending = false;
    link.stopping = false;
    link.saved = false;
    _disablePermissions(link);
    unawaited(
      host
          .releaseAgent(event.sessionId)
          .then<void>((_) {}, onError: (Object _) {}),
    );
    if (link.closeRequested && event.reason == AgentExitReason.closed) {
      removePane(link.paneId);
    } else {
      link.closeRequested = false;
      if (!link.streamFailed) {
        link.state = event.reason == AgentExitReason.failed
            ? AgentState.failed
            : AgentState.ended;
        if (event.reason == AgentExitReason.failed) {
          link.errorCode = event.error;
          link.error =
              '${event.error ?? 'Agent failed'}${event.status == null ? '' : ' (status ${event.status})'}${event.resumeReason == null ? '' : ': ${event.resumeReason}'}${event.message == null ? '' : ': ${event.message}'}';
        }
      }
    }
    _changed();
  }

  void _failed(AgentLink link, RpcException error) {
    link.phase = AgentLinkPhase.ended;
    link.state = AgentState.failed;
    link.errorCode = error.reason;
    link.error = _describe(error);
  }

  static String _describe(RpcException error) {
    final resume = error.data['resumeReason'];
    return '${error.reason}${resume == null ? '' : ': $resume'}${error.message.isEmpty ? '' : ': ${error.message}'}';
  }

  void _disablePermissions(AgentLink link) {
    for (final permission in link._pendingPermissions.values) {
      permission.unavailable = true;
    }
    link._pendingPermissions.clear();
  }

  void _closeOrphan(HostLink host, String sessionId) {
    late final StreamSubscription<AgentExitedParams> sub;
    sub = host.agentExits.where((e) => e.sessionId == sessionId).listen((_) {
      _orphanSubscriptions.remove(sub);
      unawaited(sub.cancel());
      unawaited(
        host.releaseAgent(sessionId).then<void>((_) {}, onError: (Object _) {}),
      );
    });
    _orphanSubscriptions.add(sub);
    unawaited(
      host
          .closeAgent(sessionId)
          .then<void>(
            (_) {},
            onError: (Object _) {
              _orphanSubscriptions.remove(sub);
              unawaited(sub.cancel());
            },
          ),
    );
  }

  void _disposeLink(AgentLink link) {
    try {
      SchedulerBinding.instance.addPostFrameCallback((_) => link._dispose());
      SchedulerBinding.instance.ensureVisualUpdate();
    } on Object {
      link._dispose();
    }
  }

  @override
  void dispose() {
    detach();
    _disposed = true;
    for (final sub in _orphanSubscriptions) {
      unawaited(sub.cancel());
    }
    _orphanSubscriptions.clear();
    for (final link in _links.values) {
      _disposeLink(link);
    }
    _links.clear();
    super.dispose();
  }
}
