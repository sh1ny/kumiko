import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:domain/domain.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:host_protocol/host_protocol.dart';

import '../host_link.dart';
import '../view_closer.dart';
import 'agent_transcript.dart';
import 'draft_saver.dart';

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
    required DraftQueue draftQueue,
    required DraftSend draftSend,
    required void Function() onDraftChanged,
    this.sessionId,
  }) {
    draft = DraftSaver(
      text: () => _disposed ? _finalText : prompt.text,
      send: draftSend,
      queue: draftQueue,
      onChange: onDraftChanged,
    );
    _lastText = prompt.text;
    prompt.addListener(_promptChanged);
  }
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

  /// Stores this session's composer text on the host (design D3).
  late final DraftSaver draft;
  int get draftRevision => draft.revision;

  /// Another pane already owns this session's composer: a session id has one
  /// link with a composer (design D3, one writer per session).
  bool composerHidden = false;

  /// The host's draft store is disabled (shown on every chat pane).
  bool draftStorageDisabled = false;

  /// Why the stored draft could not be read, until a save syncs the link.
  String? loadFailure;
  String? loadFailureCode;

  /// The close confirmation named an unsaved draft: confirming accepts it.
  bool draftWarned = false;
  String _lastText = '';
  bool _muted = false;
  bool _disposed = false;
  String _finalText = '';

  void _promptChanged() {
    final value = prompt.text;
    if (value == _lastText) return;
    _lastText = value;
    if (!_muted) draft.edit();
  }

  /// Sets the composer without counting an edit (a loaded or cleared draft).
  void _setComposer(String value) {
    _muted = true;
    try {
      prompt.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
      _lastText = value;
    } finally {
      _muted = false;
    }
  }

  /// Why the composer's text is not stored, for the pane and the close
  /// confirmation; null when it is stored, or there is nothing to lose.
  String? get unsavedReason {
    if (composerHidden) return null;
    // An emptied composer has nothing to lose, but a failed removal leaves
    // the old draft stored, and it comes back on reopen.
    if (prompt.text.isEmpty) return draft.dirty ? draft.failure : null;
    if (sessionId == null || !known) return 'session not saved yet';
    if (draftStorageDisabled) return 'draft storage unavailable';
    if (draft.failure != null && draft.dirty) return draft.failure;
    return null;
  }

  String? get draftNotice {
    if (composerHidden) return null;
    if (unsavedReason case final reason?) return 'Draft not saved: $reason';
    if (draftStorageDisabled && sessionId != null && known) {
      return 'Draft not saved: draft storage unavailable';
    }
    if (loadFailure != null && !draft.synced) {
      return 'Draft not loaded: $loadFailure';
    }
    return null;
  }

  /// Latest Kumiko tools status reported by the host for the live run, ordered
  /// with [seq]. Null until reported, and after host loss or a fresh restore.
  AgentTools? tools;
  String? get toolsLabel {
    final t = tools;
    if (t == null || hostLost || saved || phase == AgentLinkPhase.ended) {
      return null;
    }
    return switch (t.status) {
      AgentToolsStatus.notYetUsed => 'Kumiko tools: not yet used',
      AgentToolsStatus.connected => 'Kumiko tools: connected',
      AgentToolsStatus.notStarted => 'Kumiko tools: not started by the adapter',
      // The host sends a recorded adapter-version failure as
      // `for <adapter> <version>: <failure>` (spec: *Kumiko tools unavailable
      // for <adapter> <version>: <recorded failure>*), and an endpoint failure
      // as `endpoint-unavailable: <cause>`.
      AgentToolsStatus.unavailable => switch (t.reason) {
        null || '' => 'Kumiko tools unavailable',
        final r when r.startsWith('for ') => 'Kumiko tools unavailable $r',
        final r => 'Kumiko tools unavailable: $r',
      },
      AgentToolsStatus.unknown => null,
    };
  }

  int seq = -1;
  bool connected = false;
  bool known = false;
  bool saved = false;
  bool hostLost = false;
  bool closeRequested = false;

  /// **Stop** in the exit dialog closed this session: its pane stays, saved
  /// and not running (design D1).
  bool exitStop = false;

  /// The host could not confirm the unit ended (`agent/closeFailed`).
  String? closeFailure;
  bool abandoned = false;
  bool sending = false;
  bool stopping = false;
  bool streamFailed = false;
  String? error;
  String? errorCode;
  String? _resumeReason;
  String? lastPrompt;
  AgentStopResultParams? stopResult;
  StreamSubscription<AgentEvent>? _events;
  int _receivedEvents = 0;
  AgentExitedParams? _exit;
  Future<void>? _releasing;
  bool get _draining => _exit != null || _releasing != null;

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
  bool get canContinue =>
      connected && known && phase == AgentLinkPhase.ended && !_draining;
  // Native restoration retains resume-unavailable as the outer diagnostic.
  bool get requiresAuthentication =>
      errorCode == ErrorCode.authRequired ||
      (errorCode == ErrorCode.resumeUnavailable &&
          _resumeReason == ErrorCode.authRequired);
  bool get canRetry =>
      connected &&
      ((phase == AgentLinkPhase.ended &&
              state == AgentState.failed &&
              !_draining &&
              (!known || requiresAuthentication)) ||
          (phase == AgentLinkPhase.live &&
              state == AgentState.idle &&
              requiresAuthentication &&
              lastPrompt != null));
  bool get canNewSession =>
      connected && phase == AgentLinkPhase.ended && !_draining;
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
    if (_disposed) return;
    _finalText = prompt.text;
    _disposed = true;
    prompt.removeListener(_promptChanged);
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
  final _pendingStarts = <AgentLink>{};
  final _freshSelections = <AgentLink>{};
  final _earlyCloseFailures = <String, AgentCloseFailedParams>{};
  final List<StreamSubscription<Object?>> _subscriptions = [];
  final Set<StreamSubscription<AgentExitedParams>> _orphanSubscriptions = {};
  HostLink? _host;
  int _generation = 0;
  bool _disposed = false;
  AgentLink? linkOf(String paneId) => _links[paneId];

  final DraftQueue _draftQueue = DraftQueue();
  final DraftQueue _loadQueue = DraftQueue();
  bool _draftsDisabled = false;
  bool _resetting = false;
  String? _draftResetError;

  /// The host's draft store cannot be used: composer sends are refused until
  /// it is reset (design D4).
  bool get draftsDisabled => _draftsDisabled;

  /// Why the last **Reset draft storage** failed, or null.
  String? get draftResetError => _draftResetError;

  AgentLink _newLink({
    required String paneId,
    required String workspaceId,
    required String runtimeName,
    String? sessionId,
  }) => AgentLink(
    paneId: paneId,
    workspaceId: workspaceId,
    runtimeName: runtimeName,
    sessionId: sessionId,
    draftQueue: _draftQueue,
    draftSend: _saveDraft,
    onDraftChanged: _changed,
  )..draftStorageDisabled = _draftsDisabled;

  Future<AgentDraftSaveResult> _saveDraft(AgentDraftSaveParams params) async {
    final host = _host;
    if (host == null || !host.hello.capabilities.contains(Capability.agent)) {
      throw const DraftHostLost();
    }
    try {
      final result = await host.draftSave(params);
      if (_current(host, _generation)) _setDraftsDisabled(false);
      return result;
    } on RpcException catch (e) {
      if (_current(host, _generation)) _noteUnavailable(e);
      rethrow;
    }
  }

  /// The host disables drafts with a message that starts `drafts are
  /// disabled` (`draft_store.dart`); a stall or a reset in progress answers
  /// `draft-unavailable` too, but a reset is only offered for the former.
  void _noteUnavailable(RpcException e) {
    if (e.reason == ErrorCode.draftUnavailable &&
        e.message.startsWith('drafts are disabled')) {
      _setDraftsDisabled(true);
    }
  }

  void _setDraftsDisabled(bool disabled) {
    if (_draftsDisabled == disabled) return;
    _draftsDisabled = disabled;
    for (final link in _links.values) {
      link.draftStorageDisabled = disabled;
    }
    _changed();
  }

  /// The draft store became available: links refused for being unavailable
  /// save once, and loads refused the same way are asked again.
  void _draftStoreReady() {
    _setDraftsDisabled(false);
    for (final link in _links.values.toList()) {
      if (link.composerHidden) continue;
      if (link.loadFailureCode == ErrorCode.draftUnavailable &&
          !link.draft.synced &&
          link.known &&
          link.sessionId != null) {
        unawaited(_loadDraft(link));
      }
      link.draft.retryUnavailable();
    }
  }

  /// A reset deleted every stored draft: each open composer, saved before or
  /// not, stores its text again.
  void _resaveAll() {
    for (final link in _links.values.toList()) {
      if (!link.composerHidden) link.draft.resave();
    }
  }

  /// **Reset draft storage**: after [confirm], asks the host to discard its
  /// draft store. Offered only while drafts are disabled.
  Future<void> resetDraftStorage(
    String paneId,
    Future<bool> Function() confirm,
  ) async {
    final host = _host;
    if (host == null || !_draftsDisabled || _resetting) return;
    if (!await confirm()) return;
    if (!_current(host, _generation) || !_draftsDisabled || _resetting) return;
    _resetting = true;
    _draftResetError = null;
    _changed();
    try {
      await host.draftReset();
      if (_current(host, _generation)) {
        _draftStoreReady();
        _resaveAll();
      }
    } on RpcException catch (e) {
      if (_current(host, _generation)) _draftResetError = _describe(e);
    } on ConnectionClosedException {
      if (_current(host, _generation)) detach();
    } finally {
      _resetting = false;
      _changed();
    }
  }

  /// Reads the stored draft of [link]'s session (at most 8 at a time). A draft
  /// that arrives after the user typed only raises the revision.
  Future<void> _loadDraft(AgentLink link) async {
    final host = _host;
    final id = link.sessionId;
    if (host == null || id == null || link.composerHidden) return;
    final generation = _generation;
    link.loadFailure = null;
    link.loadFailureCode = null;
    bool stale() =>
        !_current(host, generation) || !_owns(link) || link.composerHidden;
    try {
      final loaded = await _loadQueue.run(
        () => stale()
            ? Future<AgentDraftLoadResult?>.value()
            : host
                  .draftLoad(id)
                  .timeout(const Duration(seconds: 10))
                  .then<AgentDraftLoadResult?>((r) => r),
      );
      if (loaded == null || stale()) return;
      _setDraftsDisabled(false);
      if (loaded.text case final text? when !link.draft.edited) {
        link._setComposer(text);
      }
      link.draft.markSynced(loaded.revision);
    } on RpcException catch (e) {
      if (stale()) return;
      _noteUnavailable(e);
      link.loadFailure = draftFailureReason(e);
      link.loadFailureCode = e.reason;
    } on TimeoutException {
      if (stale()) return;
      link.loadFailure = draftFailureReason(TimeoutException(null));
    } on ConnectionClosedException {
      if (_current(host, generation)) detach();
      return;
    }
    // Text typed or kept before the load is saved above whatever is stored.
    link.draft.requestNow();
    _changed();
  }

  /// A session id has one link with a composer: the first pane that names it.
  void _assignComposerOwners(Iterable<PaneNode> panes) {
    final owners = <String, AgentLink>{};
    for (final pane in panes) {
      final link = _links[pane.id];
      final id = link?.sessionId;
      if (link == null || id == null) continue;
      final owner = owners.putIfAbsent(id, () => link);
      final hidden = !identical(owner, link);
      if (link.composerHidden == hidden) continue;
      link.composerHidden = hidden;
      if (hidden) {
        link.draft.unbind();
      } else if (link.known && _host != null) {
        link.draft.bind(id);
        unawaited(_loadDraft(link));
      }
    }
  }

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
      if (link == null ||
          event.seq <= link.seq ||
          link.streamFailed ||
          link._exit != null) {
        return;
      }
      link.seq = event.seq;
      link.state = event.state;
      // Tools status rides the same sequence; a message without it changes nothing.
      if (event.tools != null) link.tools = event.tools;
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
      // Priority control may overtake the canonical turn/notice data. Keep
      // action metadata here; only the ordered channel appends the outcome.
      if (event.error == ErrorCode.authRequired) link.errorCode = event.error;
      _changed();
    });
    listen(host.agentExits, _exited);
    listen(host.agentCloseFailures, _closeFailed);
    if (host.hello.capabilities.contains(Capability.agent)) {
      listen<void>(host.draftStoreReady, (_) => _draftStoreReady());
    }
  }

  void _closeFailed(AgentCloseFailedParams event) {
    final link = _bySession.remove(event.sessionId);
    if (link == null) {
      // A start response and its terminal notification can share one read,
      // before the awaiting start binds the newly allocated session ID.
      // Every live native session owns a channel, so retain at most that cap.
      if (_pendingStarts.isNotEmpty &&
          _earlyCloseFailures.length < maxChannels) {
        _earlyCloseFailures[event.sessionId] = event;
      }
      return;
    }
    unawaited(link._events?.cancel());
    link._events = null;
    link.closeRequested = false;
    // The service relinquished transport ownership, but the durable cleanup
    // gate still owns any survivors. Never restore a fictitious live session
    // or describe this as a successful close.
    link.phase = AgentLinkPhase.ended;
    link.state = AgentState.failed;
    link.sending = false;
    link.stopping = false;
    link._exit = null;
    link.errorCode = event.reason;
    _disablePermissions(link);
    final failure =
        'Agent termination not confirmed: ${event.reason}${event.message == null ? '' : ': ${event.message}'}';
    link.closeFailure = failure;
    link.error = link.streamFailed ? '${link.error}\n$failure' : failure;
    _changed();
  }

  void detach() {
    _generation++;
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    _subscriptions.clear();
    _bySession.clear();
    _pendingStarts.clear();
    _earlyCloseFailures.clear();
    _host = null;
    for (final link in _links.values) {
      unawaited(link._events?.cancel());
      link._events = null;
      link._exit = null;
      link._releasing = null;
      link.connected = false;
      link.hostLost = true;
      link.saved = false;
      link.phase = AgentLinkPhase.ended;
      link.sending = false;
      link.stopping = false;
      link.draft.hostLost();
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
            _newLink(
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
        if (host != null) {
          if (link._exit != null) {
            unawaited(_releaseExited(host, link));
          } else if (link.live) {
            _closeOrphan(host, id);
          }
        }
      }
      _disposeLink(link, store: true);
    }
    _assignComposerOwners(panes);
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
      link.tools = null;
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
    // Each restored composer shows its own session's stored draft; the loads
    // run in the background, so the pane is usable while they are out.
    for (final link in candidates) {
      if (!_owns(link) || link.live || link.composerHidden) continue;
      final id = link.sessionId;
      if (id == null || !link.known) {
        link.draft.unbind();
        continue;
      }
      link.draft.bind(id);
      unawaited(_loadDraft(link));
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
        (previous.live ||
            previous.phase == AgentLinkPhase.pending ||
            previous._draining)) {
      return;
    }
    final link =
        _newLink(
            paneId: paneId,
            workspaceId: workspaceId,
            runtimeName: runtimeName,
          )
          ..phase = AgentLinkPhase.pending
          ..state = AgentState.starting
          ..connected = true
          ..runtimeProfileId = runtimeProfileId;
    // A conversation with a saved record owns its draft (it stays with that
    // session); only text that never had a record moves to the new one.
    if (previous != null && !previous.known) {
      link.prompt.value = previous.prompt.value;
    }
    _links[paneId] = link;
    _pendingStarts.add(link);
    if (previous != null) _disposeLink(previous, store: true);
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
      link.draft.bind(result.sessionId, storedRevision: 0);
      link.adapter = result.adapter;
      link.capabilities = result.capabilities;
      link.tools = result.tools;
      final earlyFailure = _earlyCloseFailures.remove(result.sessionId);
      if (earlyFailure != null) {
        _bySession[result.sessionId] = link;
        _closeFailed(earlyFailure);
      } else {
        _bind(host, link, result.eventChannel, generation);
      }
      savePaneState(paneId, {
        'sessionId': result.sessionId,
        'runtimeName': runtimeName,
      });
    } on RpcException catch (e) {
      if (_current(host, generation) && _owns(link)) _failed(link, e);
    } on ConnectionClosedException {
      if (_current(host, generation) && _owns(link)) detach();
    } finally {
      _pendingStarts.remove(link);
      if (_pendingStarts.isEmpty) _earlyCloseFailures.clear();
    }
    _changed();
  }

  Future<void> continueSession(String paneId) async {
    final link = _links[paneId];
    final host = _host;
    if (link == null ||
        host == null ||
        !link.canContinue ||
        _freshSelections.contains(link)) {
      return;
    }
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
    link.exitStop = false;
    link.closeFailure = null;
    link._resumeReason = null;
    link.streamFailed = false;
    link.seq = -1;
    link.transcript.clear();
    link._pendingPermissions.clear();
    link.stopResult = null;
    link.tools = null;
    final generation = _generation;
    _changed();
    try {
      final result = await host.continueAgent(id);
      if (!_current(host, generation) || !_owns(link)) {
        if (!_disposed && link.phase != AgentLinkPhase.ended) {
          _closeOrphan(host, id);
        }
        return;
      }
      link.adapter = result.adapter;
      link.capabilities = result.capabilities;
      link.tools = result.tools;
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

  Future<void> newSession(
    String paneId, {
    Future<String?> Function(RuntimeListResult profiles)? chooseProfile,
    Future<bool> Function(String paneId, String reason)? confirmDraftLoss,
  }) async {
    final link = _links[paneId];
    final host = _host;
    if (link == null ||
        host == null ||
        !link.canNewSession ||
        !_freshSelections.add(link)) {
      return;
    }
    final generation = _generation;
    bool current() =>
        _current(host, generation) && _owns(link) && link.canNewSession;
    try {
      var list = await host.runtimeList();
      if (!current()) return;
      // A surviving explicit choice remains authoritative. Only a deleted
      // original choice rejoins the normal default/profile-picker flow.
      var wanted = link.runtimeProfileId;
      if (!list.profiles.any((profile) => profile.id == wanted)) {
        wanted = list.defaultAvailable ? list.defaultId : null;
      }
      var profile = list.profiles.where((p) => p.id == wanted).firstOrNull;
      if (profile == null) {
        if (chooseProfile == null) {
          throw RpcException(
            ErrorCode.noRuntimeProfile,
            list.defaultReason ?? 'The default runtime profile is unavailable. Choose or add a profile.',
          );
        }
        final selected = await chooseProfile(list);
        if (!current() || selected == null) return;
        // The picker can outlive profile edits. Never replace an explicit
        // selection that disappeared while the dialog was open.
        list = await host.runtimeList();
        if (!current()) return;
        profile = list.profiles.where((p) => p.id == selected).firstOrNull;
        if (profile == null) {
          throw RpcException(
            ErrorCode.noRuntimeProfile,
            'The selected runtime profile is unavailable. Choose or add a profile.',
          );
        }
      }
      // The profile is settled, so Cancel here loses nothing the user chose.
      // Last, the old draft: start() lets go of this link, and with it of any
      // text that could not be stored (agent-sessions, *New session with a
      // draft that cannot be stored*).
      if (!await _draftSafeToLeave(link, confirmDraftLoss) || !current()) {
        return;
      }
      await start(
        paneId,
        workspaceId: link.workspaceId,
        runtimeName: profile.name,
        runtimeProfileId: profile.id,
      );
    } on RpcException catch (e) {
      if (current()) _failed(link, e);
    } on ConnectionClosedException {
      if (_current(host, generation) && _owns(link)) detach();
    } finally {
      _freshSelections.remove(link);
    }
    _changed();
  }

  /// Stores [link]'s composer text (bounded at 2 s, as the quit flush is) and
  /// answers whether New session may replace it: true when the text is stored
  /// or there is none, otherwise [confirm] names the reason and the loss.
  /// Text that never had a saved record moves to the new session, so it is not
  /// lost either.
  Future<bool> _draftSafeToLeave(
    AgentLink link,
    Future<bool> Function(String paneId, String reason)? confirm,
  ) async {
    if (!link.known || link.composerHidden) return true;
    // An edit during the wait is sent by another flush: the answer must
    // describe the text as it is when the wait ends. The whole wait is 2 s.
    Future<void> store() async {
      String seen;
      do {
        seen = link.prompt.text;
        await link.draft.flush(timeout: const Duration(seconds: 2));
      } while (!_disposed && link.prompt.text != seen && link.draft.dirty);
    }

    try {
      await store().timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // Still unsaved: named below.
    }
    if (_disposed || link.prompt.text.isEmpty) return true;
    // A save that is still out after the wait has no failure yet.
    final reason =
        link.unsavedReason ??
        (link.draft.dirty ? 'the host did not answer' : null);
    if (reason == null) return true;
    link.draftWarned = true;
    if (confirm == null) return false;
    final ok = await confirm(
      link.paneId,
      'Draft not saved: $reason. Its text will be lost.',
    );
    if (!ok) link.draftWarned = false;
    return ok;
  }

  Future<void> retry(
    String paneId, {
    Future<String?> Function(RuntimeListResult profiles)? chooseProfile,
  }) async {
    final link = _links[paneId];
    if (link == null || !link.canRetry) return;
    if (link.phase == AgentLinkPhase.ended) {
      if (link.known) {
        await continueSession(paneId);
      } else {
        await newSession(paneId, chooseProfile: chooseProfile);
      }
    } else {
      // Retry is an explicit user action; it never discards an unsent draft.
      await send(paneId, link.lastPrompt!, retry: true);
    }
  }

  void _bind(HostLink host, AgentLink link, int channel, int generation) {
    // Continue's reserved session can exit before its RPC continuation runs.
    // Never bind a released transport or replace its terminal diagnostic.
    if (link._releasing != null) return;
    final exit = link._exit;
    if (exit != null) {
      if (exit.reason == AgentExitReason.closed ||
          link.streamFailed ||
          exit.eventCount == 0) {
        unawaited(_releaseExited(host, link));
        return;
      }
    } else {
      if (link.phase != AgentLinkPhase.pending) return;
      link.phase = AgentLinkPhase.live;
    }
    link._receivedEvents = 0;
    link.saved = false;
    link.hostLost = false;
    _bySession[link.sessionId!] = link;
    link._events = host
        .attachAgent(link.sessionId!, channel)
        .listen(
          (event) {
            if (!_current(host, generation) || !_owns(link)) return;
            link.transcript.add(event);
            link._receivedEvents++;
            _drainExited(host, link);
            _changed();
          },
          onError: (Object error) {
            if (!_current(host, generation) || !_owns(link)) return;
            link.streamFailed = true;
            link.error = 'event stream error: $error';
            link.state = AgentState.failed;
            _disablePermissions(link);
            unawaited(link._events?.cancel());
            if (error is RpcException &&
                error.reason == ErrorCode.unknownSession) {
              // Attachment expiry can overtake a new start's binding. The
              // refusal proves there is no host owner to close or release.
              if (identical(_bySession[link.sessionId], link)) {
                _bySession.remove(link.sessionId);
              }
              link.phase = AgentLinkPhase.ended;
              link.sending = false;
              link.stopping = false;
              link._exit = null;
              link.errorCode = error.reason;
            } else if (link._exit != null) {
              unawaited(_releaseExited(host, link));
            } else {
              unawaited(
                host
                    .closeAgent(link.sessionId!)
                    .then<void>((_) {}, onError: (Object _) {}),
              );
            }
            _changed();
          },
          onDone: () {
            if (!_current(host, generation) || !_owns(link)) return;
            if (link._releasing != null) return;
            final exit = link._exit;
            if (exit != null && link._receivedEvents >= exit.eventCount) {
              _drainExited(host, link);
              return;
            }
            // A normal failed exit is complete at its final record count,
            // before release closes this channel. EOF before that count is
            // evidence of missing data, not successful draining.
            link.streamFailed = true;
            link.error = 'event stream ended before final transcript delivery';
            link.state = AgentState.failed;
            _disablePermissions(link);
            if (exit != null) {
              unawaited(_releaseExited(host, link));
            } else {
              unawaited(
                host
                    .closeAgent(link.sessionId!)
                    .then<void>((_) {}, onError: (Object _) {}),
              );
            }
            _changed();
          },
        );
  }

  /// Sends [text]. A send of the composer's own text names the draft revision
  /// it carries and holds the submission guard until the result arrives; a
  /// Retry ([retry]) resends the last prompt and touches no draft.
  Future<void> send(String paneId, String text, {bool retry = false}) async {
    final link = _links[paneId];
    final host = _host;
    if (link == null || host == null || !link.canSend || text.trim().isEmpty) {
      return;
    }
    if (text.length > maxAgentPromptBytes ||
        utf8.encode(text).length > maxAgentPromptBytes) {
      link.errorCode = ErrorCode.invalidParams;
      link._resumeReason = null;
      link.error =
          '${ErrorCode.invalidParams}: '
          'Prompt exceeds 256 KiB. Please shorten the prompt and try again.';
      link.transcript.add(AgentEvent.notice(link.error!));
      _changed();
      return;
    }
    final generation = _generation;
    final submission = !retry && text == link.prompt.text
        ? link.draft.beginSubmit()
        : null;
    link.sending = true;
    link.error = null;
    link.errorCode = null;
    link._resumeReason = null;
    link.lastPrompt = text;
    link.stopResult = null;
    // The host emits accepted prompts on the ordered event channel, including
    // when the adapter later fails. RPC rejection must not create user history.
    _changed();
    var submitted = false;
    var cleared = false;
    try {
      await host.promptAgent(
        AgentPromptParams(
          sessionId: link.sessionId!,
          text: text,
          draftRevision: submission?.revision,
          draftSynced: submission?.synced,
        ),
      );
      submitted = true;
      if (_current(host, generation) && _owns(link)) {
        final unchanged = submission != null
            ? link.draft.unchangedSince(submission)
            : false;
        // The host removed the draft with the accepted text; the composer
        // loses it too, unless the user changed it since Send.
        if (unchanged && link.prompt.text == text) {
          link._setComposer('');
          cleared = true;
        } else if (!retry && submission == null && link.prompt.text == text) {
          link.prompt.clear();
        }
      }
    } on RpcException catch (e) {
      if (!_current(host, generation) || !_owns(link)) return;
      link.errorCode = e.reason;
      link.error = _describe(e);
      link.transcript.add(AgentEvent.notice(link.error!));
    } on ConnectionClosedException {
      if (_current(host, generation)) detach();
    } finally {
      // Only accepted submissions wait for turn-ended to unlock Send. A local
      // failure must release the latch even when an unexpected error propagates.
      if (!submitted && _current(host, generation) && _owns(link)) {
        link.sending = false;
      }
      if (submission != null) {
        link.draft.endSubmit(submission, accepted: submitted, cleared: cleared);
      }
      _changed();
    }
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
  Future<Map<String, String>> warningsFor(List<String> paneIds) async {
    // Drafts are stored first, so only a draft that could not be stored is
    // named (agent-sessions "Closing with an unsaved draft says it will be
    // lost").
    await Future.wait([for (final id in paneIds) _storeDraft(id)]);
    final warnings = <String, String>{};
    for (final id in paneIds) {
      final link = _links[id];
      final running = _warnsOnClose(id);
      final unsaved = link?.unsavedReason;
      if (link != null) link.draftWarned = unsaved != null;
      if (!running && unsaved == null) continue;
      warnings[id] = [
        if (running) agentCloseWarning,
        if (unsaved != null && link!.prompt.text.isEmpty)
          'Draft not saved: $unsaved. The cleared draft stays stored and '
              'returns when the session reopens.'
        else if (unsaved != null)
          'Draft not saved: $unsaved. Its text will be lost.',
      ].join(' ');
    }
    return warnings;
  }

  /// Flushes [paneId]'s draft unless it is already known to be unsaved.
  Future<void> _storeDraft(String paneId) async {
    final link = _links[paneId];
    if (link == null || link.composerHidden || !link.draft.bound) return;
    if (link.draft.failure != null) return;
    await link.draft.flush();
  }

  bool _warnsOnClose(String paneId) {
    final link = _links[paneId];
    if (link == null || !link.connected || !link.live) return false;
    // Submission can already be accepted while its ACK/state is in flight.
    // Preserve confirmation without deriving a speculative Running status.
    if (link.sending) return true;
    return switch (link.state) {
      AgentState.running ||
      AgentState.waitingApproval ||
      AgentState.stopping => true,
      _ => false,
    };
  }

  @override
  Future<void> closeConfirmed(String paneId) async {
    final link = _links[paneId];
    final host = _host;
    if (link != null) {
      // The draft is stored before the session closes; if that fails and the
      // confirmation did not name it, the pane stays with its text.
      await _storeDraft(paneId);
      if (!_owns(link)) return;
      if (link.unsavedReason != null && !link.draftWarned) {
        _changed();
        return;
      }
    }
    if (link != null && host != null && link._draining) {
      // Explicit dismissal may discard the transcript; the native process
      // already exited, so release rather than send close to a dead session.
      await link._events?.cancel();
      link._events = null;
      await _releaseExited(host, link);
      if (_owns(link) && !link._draining) removePane(paneId);
      return;
    }
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

  /// What an exit would end in [paneId]'s session, for the exit dialog: its
  /// turn, a pending permission reply, a stop or a prompt on its way. Null for
  /// a session that is not running work (the same evidence a pane close uses).
  String? exitWork(String paneId) {
    final link = _links[paneId];
    if (link == null || !_warnsOnClose(paneId)) return null;
    if (link.state == AgentState.waitingApproval) {
      return 'waiting for a permission reply';
    }
    if (link.state == AgentState.stopping || link.stopping) return 'stopping';
    if (link.state == AgentState.running) return 'running a turn';
    return 'sending a prompt';
  }

  /// The quit flush for drafts: every composer's unsaved text is sent and the
  /// call completes when each is stored or has failed, or after [timeout].
  Future<void> flushDrafts({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    await Future.wait([
      for (final link in _links.values.toList())
        if (!link.composerHidden && link.draft.bound)
          link.draft.flush(timeout: timeout),
    ]);
  }

  /// **Stop** in the exit dialog: closes [paneId]'s session as a confirmed
  /// close does, but its pane stays, *Saved, not running* (design D1). Returns
  /// the error when the host refuses the close; a later `agent/closeFailed`
  /// shows as [AgentLink.closeFailure].
  Future<String?> stopForExit(String paneId) async {
    final link = _links[paneId];
    final host = _host;
    if (link == null ||
        host == null ||
        !link.live ||
        link.closeRequested ||
        link.exitStop) {
      return null;
    }
    final generation = _generation;
    link.exitStop = true;
    link.phase = AgentLinkPhase.closing;
    link.error = null;
    _changed();
    try {
      // The host rechecks the turn and owns cancel-before-terminate.
      await host.closeAgent(link.sessionId!);
    } on RpcException catch (e) {
      if (_current(host, generation) && _owns(link)) {
        link.exitStop = false;
        link.phase = AgentLinkPhase.live;
        link.error = _describe(e);
        _changed();
        return link.error;
      }
    } on ConnectionClosedException {
      if (_current(host, generation)) detach();
    }
    _changed();
    return null;
  }

  void _exited(AgentExitedParams event) {
    final link = _bySession[event.sessionId];
    final host = _host;
    if (link == null || host == null || link._exit != null) return;
    final pending = link.phase == AgentLinkPhase.pending;
    link._exit = event;
    link.phase = AgentLinkPhase.ended;
    link.sending = false;
    link.stopping = false;
    link.saved = false;
    _disablePermissions(link);
    final dismiss =
        link.closeRequested && event.reason == AgentExitReason.closed;
    link.closeRequested = false;
    // A session stopped from the exit dialog keeps its pane and its record.
    if (link.exitStop && event.reason == AgentExitReason.closed) {
      link.saved = link.known;
    }
    if (!link.streamFailed) {
      link.state = event.reason == AgentExitReason.failed
          ? AgentState.failed
          : AgentState.ended;
      if (event.reason == AgentExitReason.failed) {
        link.errorCode = event.error;
        link._resumeReason = event.resumeReason;
        link.error =
            '${event.error ?? 'Agent failed'}${event.status == null ? '' : ' (status ${event.status})'}${event.resumeReason == null ? '' : ': ${event.resumeReason}'}${event.message == null ? '' : ': ${event.message}'}';
      }
    }
    // Keep the terminal notification reserved until Continue has returned its
    // channel. Releasing sooner could enable another run before that earlier
    // continuation binds. Explicit dismissal can still release immediately.
    if (!pending) {
      if (event.reason == AgentExitReason.closed || link.streamFailed) {
        // Intentional close or a failed decoder cannot consume a final count.
        unawaited(_releaseExited(host, link));
      } else {
        _drainExited(host, link);
      }
    }
    if (dismiss) removePane(link.paneId);
    _changed();
  }

  void _drainExited(HostLink host, AgentLink link) {
    final exit = link._exit;
    if (exit != null && link._receivedEvents >= exit.eventCount) {
      unawaited(_releaseExited(host, link));
    }
  }

  Future<void> _releaseExited(HostLink host, AgentLink link) {
    final releasing = link._releasing;
    if (releasing != null) return releasing;
    final exit = link._exit;
    if (exit == null) return Future.value();
    final generation = _generation;
    return link._releasing =
        () async {
          try {
            await host.releaseAgent(exit.sessionId);
          } on RpcException catch (error) {
            // Consumer cancellation may already have relinquished the host owner.
            if (error.reason != ErrorCode.unknownSession) {
              if (_current(host, generation)) link.error = _describe(error);
              return;
            }
          } on ConnectionClosedException {
            if (_current(host, generation)) detach();
            return;
          }
          if (!_current(host, generation)) return;
          if (identical(_bySession[exit.sessionId], link)) {
            _bySession.remove(exit.sessionId);
          }
          link._exit = null;
          final events = link._events;
          link._events = null;
          await events?.cancel();
        }().whenComplete(() {
          if (_current(host, generation)) {
            link._releasing = null;
            _changed();
          }
        });
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

  /// Lets go of [link]. With [store], what is unsaved in its composer is
  /// sent first, so a pane that goes away keeps its draft.
  void _disposeLink(AgentLink link, {bool store = false}) {
    if (store && !_disposed) {
      unawaited(link.draft.finish());
    } else {
      link.draft.dispose();
    }
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
