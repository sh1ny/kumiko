import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:host_protocol/host_protocol.dart';

/// Sends one `workbench/save`.
typedef SaveCall = Future<WorkbenchSaveResult> Function(
  Json layout,
  int revision,
);

enum SaveState { clean, pending, inFlight, failed }

/// Keeps the host's stored layout current (design D6).
///
/// Clean -change-> Pending -(500 ms quiet | 2 s dirty age | flush)-> InFlight
/// -ok-> Clean (Pending when something changed meanwhile); an error or the
/// 10 s deadline -> Failed; Failed -late ok covering the current layout->
/// Clean, -change | Retry-> Pending.
///
/// Every save carries the whole snapshot and a revision one above the highest
/// ever sent, so a late or replayed save can never replace a newer one. At
/// most one save is awaited at a time.
class LayoutSaver extends ChangeNotifier {
  LayoutSaver({
    required this._save,
    int revision = 0,
    this.debounce = const Duration(milliseconds: 500),
    this.maxDirtyAge = const Duration(seconds: 2),
    this.deadline = const Duration(seconds: 10),
  }) : _counter = revision;

  final SaveCall _save;
  final Duration debounce;
  final Duration maxDirtyAge;
  final Duration deadline;

  /// Resends after `stale-revision` are bounded, so a host that keeps
  /// answering it cannot loop us.
  static const int _maxStaleResends = 3;

  /// Saves sent and not yet answered, timed-out ones included. A host that
  /// stops answering keeps each request open on the connection, so more
  /// are not sent until one is answered (or the connection closes, which
  /// fails them all).
  static const int maxUnanswered = 2;

  Json? _latest;

  /// Counts changes; a save remembers the count its snapshot was taken at.
  int _changeSeq = 0;

  /// The highest change count known to be stored.
  int _storedSeq = 0;
  int _counter;
  int _acked = 0;
  final Map<int, int> _seqOf = {};

  SaveState _state = SaveState.clean;
  String? _notice;
  bool _disposed = false;

  /// The save being awaited: its revision, or null.
  int? _inFlight;
  int _staleResends = 0;

  /// A timer expired while a save was out: send the newest as it returns.
  bool _due = false;

  Timer? _quietTimer;
  Timer? _ageTimer;
  Timer? _deadlineTimer;

  SaveState get state => _state;

  /// Why the layout is not saved, or null.
  String? get notice => _notice;

  /// The highest revision ever sent (or raised to).
  int get counter => _counter;

  /// The highest revision the host acknowledged.
  int get acknowledged => _acked;

  /// Saves sent whose answer has not arrived, including timed-out ones.
  @visibleForTesting
  int get unansweredSaves => _seqOf.length;

  /// There are changes the host has not acknowledged.
  bool get dirty => _changeSeq > _storedSeq;

  /// Records a change: [snapshot] is the whole layout document.
  void change(Json snapshot) {
    if (_disposed) return;
    _latest = snapshot;
    _changeSeq++;
    if (_inFlight == null) _state = SaveState.pending;
    _quietTimer?.cancel();
    _quietTimer = Timer(debounce, _expired);
    _ageTimer ??= Timer(maxDirtyAge, _expired);
    notifyListeners();
  }

  /// Raises the revision counter, never lowers it.
  void raiseCounter(int revision) {
    if (revision > _counter) _counter = revision;
  }

  /// Retry: sends the newest layout at once.
  void retry() {
    if (_disposed || !dirty) return;
    if (_inFlight != null) {
      _due = true;
      return;
    }
    _dispatch();
  }

  /// Sends what is pending at once and completes when it is stored, when a
  /// save fails, or after [timeout].
  Future<void> flush({Duration timeout = const Duration(seconds: 2)}) async {
    if (_disposed || !dirty) return;
    final target = _changeSeq;
    if (_inFlight == null) {
      _dispatch();
    } else {
      _due = true;
    }
    final done = Completer<void>();
    void check() {
      if (done.isCompleted) return;
      if (_storedSeq >= target || _state == SaveState.failed) done.complete();
    }

    addListener(check);
    final timer = Timer(timeout, () {
      if (done.isCompleted) return;
      _inFlight = null;
      _fail('the host did not answer');
      if (!done.isCompleted) done.complete();
    });
    check();
    try {
      await done.future;
    } finally {
      timer.cancel();
      if (!_disposed) removeListener(check);
    }
  }

  void _expired() {
    if (_disposed) return;
    if (_inFlight != null) {
      _due = true;
      return;
    }
    _dispatch();
  }

  void _cancelTimers() {
    _quietTimer?.cancel();
    _ageTimer?.cancel();
    _quietTimer = null;
    _ageTimer = null;
  }

  void _dispatch() {
    _cancelTimers();
    _due = false;
    final layout = _latest;
    if (layout == null || !dirty) return;
    if (_seqOf.length >= maxUnanswered) {
      // Sent as soon as an unanswered save is answered.
      _due = true;
      return;
    }
    final revision = ++_counter;
    _seqOf[revision] = _changeSeq;
    _inFlight = revision;
    _state = SaveState.inFlight;
    _deadlineTimer?.cancel();
    _deadlineTimer = Timer(deadline, () {
      if (_inFlight != revision) return;
      _inFlight = null;
      _fail('the host did not answer');
    });
    notifyListeners();
    unawaited(_run(revision, layout));
  }

  Future<void> _run(int revision, Json layout) async {
    try {
      final result = await _save(layout, revision);
      if (_disposed) return;
      _onOk(revision, result.revision);
    } on Object catch (e) {
      if (_disposed) return;
      _onError(revision, e);
    } finally {
      // Each save is answered once; a timed-out one keeps its entry until
      // its late answer is handled above.
      _seqOf.remove(revision);
      if (!_disposed && _due && _inFlight == null && dirty) _dispatch();
    }
  }

  void _onOk(int sent, int stored) {
    raiseCounter(stored);
    if (sent > _acked) _acked = sent;
    final seq = _seqOf[sent] ?? 0;
    if (seq > _storedSeq) _storedSeq = seq;
    if (_inFlight == sent) {
      _inFlight = null;
      _deadlineTimer?.cancel();
      _staleResends = 0;
      _settle();
      return;
    }
    // A late ok: it covers the current layout only when nothing changed
    // after its snapshot was taken.
    if (_inFlight == null && _state == SaveState.failed && !dirty) {
      _settle();
      return;
    }
    notifyListeners();
  }

  /// No save is out: Clean when everything is stored, else Pending.
  void _settle() {
    if (!dirty) {
      _cancelTimers();
      _notice = null;
      _state = SaveState.clean;
      _due = false;
    } else if (_due) {
      _dispatch();
      return;
    } else {
      _state = SaveState.pending;
      _quietTimer ??= Timer(debounce, _expired);
      _ageTimer ??= Timer(maxDirtyAge, _expired);
    }
    notifyListeners();
  }

  void _onError(int sent, Object error) {
    // A late error (the save timed out and its slot was freed) changes
    // nothing: a later save replaces whatever it left behind.
    if (_inFlight != sent) return;
    if (error is RpcException && error.reason == ErrorCode.staleRevision) {
      _inFlight = null;
      _deadlineTimer?.cancel();
      final stored = storedRevisionOf(error);
      if (stored != null) raiseCounter(stored);
      final seq = _seqOf[sent] ?? 0;
      if (_storedSeq >= seq) {
        // The snapshot was already stored at a later revision.
        _staleResends = 0;
        _settle();
        return;
      }
      if (_staleResends < _maxStaleResends) {
        _staleResends++;
        _dispatch();
        return;
      }
    }
    _inFlight = null;
    _deadlineTimer?.cancel();
    final reason = switch (error) {
      RpcException(:final message, :final reason) =>
        message.isEmpty ? reason : message,
      ConnectionClosedException() => 'the host is gone',
      _ => '$error',
    };
    _fail(reason);
  }

  void _fail(String reason) {
    _cancelTimers();
    _deadlineTimer?.cancel();
    _due = false;
    _staleResends = 0;
    _notice = 'Layout not saved: $reason';
    _state = SaveState.failed;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelTimers();
    _deadlineTimer?.cancel();
    super.dispose();
  }
}
