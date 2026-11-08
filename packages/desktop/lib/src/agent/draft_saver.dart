import 'dart:async';
import 'dart:collection';

import 'package:host_protocol/host_protocol.dart';

/// Sends one `agent/draftSave`.
typedef DraftSend = Future<AgentDraftSaveResult> Function(
  AgentDraftSaveParams params,
);

/// There is no host to send a draft to (design D3: *host lost*).
class DraftHostLost implements Exception {
  const DraftHostLost();
  @override
  String toString() => 'DraftHostLost';
}

/// Lets at most [limit] operations run at once; the others wait in order.
/// One queue serves every link, so saves are bounded across links (design D3,
/// ≤ 8 in flight), and a second serves restore loads.
class DraftQueue {
  DraftQueue({this.limit = 8});

  final int limit;
  int _running = 0;
  final Queue<Completer<void>> _waiting = Queue();

  int get running => _running;

  Future<T> run<T>(Future<T> Function() operation) async {
    if (_running >= limit) {
      final turn = Completer<void>();
      _waiting.add(turn);
      // The slot is handed over, not released, so `_running` stays put.
      await turn.future;
    } else {
      _running++;
    }
    try {
      return await operation();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _running--;
      }
    }
  }
}

/// The words the pane shows after *Draft not saved:* or *Draft not loaded:*.
String draftFailureReason(Object error) => switch (error) {
  RpcException(:final reason, :final message) => switch (reason) {
    ErrorCode.draftTooLarge => 'too long',
    ErrorCode.draftCap => 'draft storage full',
    ErrorCode.draftUnavailable =>
      message.contains('not responding') || message.contains('did not answer')
          ? 'draft storage not responding'
          : 'draft storage unavailable',
    ErrorCode.unknownSession => 'no saved session',
    _ => message.isEmpty ? reason : message,
  },
  DraftHostLost() || ConnectionClosedException() => 'host lost',
  TimeoutException() => 'the host did not answer',
  _ => '$error',
};

/// What a send holds on to until its result arrives (design D3, the
/// submission guard).
typedef DraftSubmission = ({int revision, bool synced, int editSeq});

/// Keeps one session's stored draft current (design D3).
///
/// Every composer edit raises the revision; a save carries the composer text
/// and the revision at the moment it is sent. At most one save is in flight,
/// and the edits that arrive meanwhile coalesce into one more, sent with the
/// then-current text. The host's answers keep the revision above the stored
/// floor (`stale-revision` carries it), and a refusal leaves the link
/// *unsaved* with its reason until a later save succeeds.
class DraftSaver {
  DraftSaver({
    required this.text,
    required this.send,
    required this.queue,
    required this.onChange,
    this.debounce = const Duration(milliseconds: 500),
    this.maxAge = const Duration(seconds: 2),
    this.deadline = const Duration(seconds: 10),
  });

  /// The composer's text now.
  final String Function() text;
  final DraftSend send;
  final DraftQueue queue;
  final void Function() onChange;
  final Duration debounce;
  final Duration maxAge;
  final Duration deadline;

  /// A re-save after `stale-revision` is above the floor, so it is not
  /// refused again; the bound only protects against a host that misbehaves.
  static const int _maxStaleResends = 3;

  /// Saves sent and not yet answered, timed-out ones included. A host that
  /// stops answering must not collect more.
  static const int _maxUnanswered = 2;

  String? sessionId;
  int _revision = 0;
  bool _synced = false;

  /// Counts edits; a save remembers the count its text was taken at.
  int _editSeq = 0;
  int _savedSeq = 0;
  int _generation = 0;
  int _attempt = 0;
  bool _inFlight = false;
  int _unanswered = 0;
  bool _due = false;
  int _staleResends = 0;
  int? _guardSeq;
  String? _failure;
  String? _failureCode;
  int _failEpoch = 0;
  bool _disposed = false;
  Timer? _quiet;
  Timer? _age;
  final List<void Function()> _watchers = [];

  /// The revision of the composer text.
  int get revision => _revision;

  /// The host has told this link the stored revision.
  bool get synced => _synced;

  bool get bound => sessionId != null;

  /// The composer was edited since the link was created.
  bool get edited => _editSeq > 0;

  /// The composer holds text the host has not confirmed.
  bool get dirty => _editSeq > _savedSeq;

  /// Why the latest text was not stored, or null.
  String? get failure => _failure;
  String? get failureCode => _failureCode;

  /// The text of a submission being sent is not saved again.
  bool get _blocked => _guardSeq != null && _editSeq == _guardSeq;

  /// A composer edit.
  void edit() {
    if (_disposed) return;
    _editSeq++;
    _revision++;
    if (bound) _arm();
    _notify();
  }

  /// The composer belongs to saved session [id]. [storedRevision] is known for
  /// a new session (0) and not yet for a restored one.
  void bind(String id, {int? storedRevision}) {
    if (_disposed) return;
    sessionId = id;
    if (storedRevision != null) _sync(storedRevision);
    if (dirty && !_blocked) _arm();
    _notify();
  }

  /// The session has no saved record any more: nothing is sent.
  void unbind() {
    sessionId = null;
    _cancelTimers();
    _due = false;
    _synced = false;
    _notify();
  }

  /// The host told the stored revision: a load, an acknowledgement or a
  /// `stale-revision` reply.
  void markSynced(int stored) {
    if (_disposed) return;
    _sync(stored);
    _notify();
  }

  void _sync(int stored) {
    _synced = true;
    // Unsaved text must be saved above the floor.
    final target = stored + (dirty ? 1 : 0);
    if (_revision < target) _revision = target;
  }

  /// A new host (or none) is on the other end: nothing sent so far counts.
  void hostLost() {
    if (_disposed) return;
    _generation++;
    _inFlight = false;
    _unanswered = 0;
    _due = false;
    _synced = false;
    _cancelTimers();
    if (_guardSeq != null) {
      // The text was being sent; it may or may not have been removed. It is
      // still in the composer, so it is saved again after Restart host.
      _guardSeq = null;
      _editSeq++;
    }
    if (bound && dirty) {
      _fail(null, 'host lost');
    } else {
      _notify();
    }
  }

  /// The host's draft store answers again (`agent/draftStoreReady`): saves a
  /// link that was refused for being unavailable, once.
  void retryUnavailable() {
    if (_disposed || _failureCode != ErrorCode.draftUnavailable) return;
    requestNow();
  }

  /// The stored copy may be gone (the draft store was reset): the composer's
  /// text counts as unsaved again and is sent, unless there is nothing to
  /// store or a submission holds it (its result decides, as in [endSubmit]).
  void resave() {
    if (_disposed || !bound || _blocked) return;
    if (!dirty) {
      if (text().isEmpty) return;
      _editSeq++;
      _revision++;
    }
    _request();
  }

  /// Sends the unsaved text at once, unless a save is out (then right after).
  void requestNow() => _request();

  /// A send takes the composer text: nothing of it is saved from here until
  /// the result arrives, and the send names the revision it carries.
  DraftSubmission beginSubmit() {
    _cancelTimers();
    _due = false;
    _guardSeq = _editSeq;
    return (revision: _revision, synced: _synced, editSeq: _editSeq);
  }

  /// The composer is unchanged since [submission].
  bool unchangedSince(DraftSubmission submission) =>
      _editSeq == submission.editSeq;

  /// The send's result arrived. [cleared]: the accepted text was removed from
  /// the composer (the host removed the draft with it).
  void endSubmit(
    DraftSubmission submission, {
    required bool accepted,
    required bool cleared,
  }) {
    if (_disposed || _guardSeq == null) return;
    _guardSeq = null;
    if (accepted) {
      if (cleared) {
        _savedSeq = _editSeq;
        _failure = null;
        _failureCode = null;
        _cancelTimers();
        _due = false;
        _notify();
      } else if (dirty && bound) {
        _arm();
      }
      return;
    }
    if (_editSeq == submission.editSeq) {
      // The host may have removed the text; the composer still holds it.
      _editSeq++;
      if (_revision <= submission.revision) _revision = submission.revision + 1;
    }
    _request();
    _notify();
  }

  /// Sends what is unsaved at once and completes when it is stored, when a
  /// save fails, or after [timeout].
  Future<void> flush({Duration? timeout}) async {
    if (_disposed || !bound || !dirty || _blocked) return;
    final epoch = _failEpoch;
    _cancelTimers();
    _request();
    await _until(
      () => !dirty || (_failEpoch > epoch && !_inFlight && !_due),
      timeout ?? deadline,
    );
  }

  /// A pane that goes away: stores what is unsaved first, then lets go.
  Future<void> finish() async {
    try {
      await flush();
    } finally {
      dispose();
    }
  }

  void dispose() {
    _disposed = true;
    _cancelTimers();
    for (final watcher in _watchers.toList()) {
      watcher();
    }
  }

  // --- internals ----------------------------------------------------------

  void _arm() {
    _quiet?.cancel();
    _quiet = Timer(debounce, _expired);
    _age ??= Timer(maxAge, _expired);
  }

  void _cancelTimers() {
    _quiet?.cancel();
    _age?.cancel();
    _quiet = null;
    _age = null;
  }

  void _expired() {
    _cancelTimers();
    if (_disposed) return;
    _request();
  }

  void _request() {
    if (_disposed || !bound || !dirty || _blocked) return;
    if (_inFlight || _unanswered >= _maxUnanswered) {
      _due = true;
      return;
    }
    _dispatch();
  }

  void _dispatch() {
    _cancelTimers();
    _due = false;
    final id = sessionId!;
    final seq = _editSeq;
    final body = text();
    final revision = _revision;
    if (jsonStringContentBytes(body) > maxDraftBytes) {
      _fail(ErrorCode.draftTooLarge, 'too long');
      return;
    }
    final generation = _generation;
    final attempt = ++_attempt;
    _inFlight = true;
    _unanswered++;
    Timer? deadlineTimer;
    unawaited(() async {
      try {
        final result = await queue.run(() {
          // The deadline counts from the moment the request is sent.
          deadlineTimer = Timer(deadline, () {
            if (_disposed ||
                generation != _generation ||
                !_inFlight ||
                attempt != _attempt) {
              return;
            }
            _inFlight = false;
            _fail(null, 'the host did not answer');
          });
          return send(
            AgentDraftSaveParams(sessionId: id, text: body, revision: revision),
          );
        });
        if (_disposed || generation != _generation) return;
        _onOk(attempt, seq, result.revision);
      } on Object catch (error) {
        if (_disposed || generation != _generation) return;
        _onError(attempt, error);
      } finally {
        deadlineTimer?.cancel();
        if (generation == _generation) {
          _unanswered--;
          if (!_disposed && _due && !_inFlight) _request();
        }
      }
    }());
    _notify();
  }

  void _onOk(int attempt, int seq, int stored) {
    if (seq > _savedSeq) _savedSeq = seq;
    _synced = true;
    if (_revision < stored) _revision = stored;
    if (attempt == _attempt) _inFlight = false;
    _staleResends = 0;
    _failure = null;
    _failureCode = null;
    _notify();
  }

  void _onError(int attempt, Object error) {
    // A late answer to a save that timed out changes nothing: a later save
    // replaces whatever it left.
    if (attempt != _attempt || !_inFlight) return;
    _inFlight = false;
    if (error is RpcException && error.reason == ErrorCode.staleRevision) {
      final stored = storedRevisionOf(error);
      if (stored != null && _staleResends < _maxStaleResends) {
        _staleResends++;
        _synced = true;
        // The current composer text is saved once more, above the floor
        // (never the refused text), unless it is the text being sent.
        if (_revision <= stored) _revision = stored + 1;
        _notify();
        _request();
        return;
      }
    }
    _fail(
      error is RpcException ? error.reason : null,
      draftFailureReason(error),
    );
  }

  void _fail(String? code, String reason) {
    _cancelTimers();
    _due = false;
    _staleResends = 0;
    _failure = reason;
    _failureCode = code;
    _failEpoch++;
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    onChange();
    for (final watcher in _watchers.toList()) {
      watcher();
    }
  }

  Future<void> _until(bool Function() done, Duration timeout) async {
    if (done()) return;
    final finished = Completer<void>();
    void check() {
      if (!finished.isCompleted && (_disposed || done())) finished.complete();
    }

    _watchers.add(check);
    final timer = Timer(timeout, () {
      if (finished.isCompleted) return;
      if (!done()) {
        _inFlight = false;
        _fail(null, 'the host did not answer');
      }
      if (!finished.isCompleted) finished.complete();
    });
    try {
      await finished.future;
    } finally {
      timer.cancel();
      _watchers.remove(check);
    }
  }
}
