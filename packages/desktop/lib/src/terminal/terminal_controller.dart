import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:host_protocol/host_protocol.dart';

import '../host_link.dart';
import 'terminal_surface.dart';

/// The desktop's view of one terminal pane's host terminal (design D9):
/// `none` (no link; a restored pane) -> `starting` -> `live` -> `closing` ->
/// `ended`, and `ended` -> `starting` through **Start shell**. A pane without
/// a [TerminalLink] is `none`.
enum TerminalStatus { none, starting, live, closing, ended }

/// One pane's link to a host terminal: its surface, its status and what the
/// pane shows about it. Created by [TerminalController.start], which is also
/// the only writer.
class TerminalLink extends ChangeNotifier {
  TerminalLink._({
    required this.paneId,
    required this.surface,
    required this.profileId,
    required this.profileName,
    required this.workspaceId,
    required this._onChanged,
  });

  final String paneId;
  final TerminalSurface surface;
  final String profileId;
  final String profileName;
  final String? workspaceId;
  final void Function() _onChanged;

  TerminalStatus _status = TerminalStatus.starting;
  String? _terminalId;
  TerminalExited? _exit;
  String? _error;
  String? _notice;
  bool _closeRequested = false;
  bool _inputPaused = false;

  TerminalStatus get status => _status;
  String? get terminalId => _terminalId;

  /// The host's `terminal/exited`, once the shell ended on its own.
  TerminalExited? get exit => _exit;

  /// Why the terminal could not start or close, shown in the pane.
  String? get error => _error;

  /// Why a live link was dropped (the host went away).
  String? get notice => _notice;

  /// The user confirmed closing: any exit removes the pane (design D9).
  bool get closeRequested => _closeRequested;

  /// Input beyond the queue bound is being discarded.
  bool get inputPaused => _inputPaused;

  // Wiring owned by TerminalController.
  TerminalChannels? _channels;
  StreamSubscription<Uint8List>? _outputSub;
  StreamSubscription<(int, int)>? _sizeSub;
  StreamSubscription<Uint8List>? _inputSub;
  Completer<(int, int)?>? _firstSize;
  (int, int)? _latestSize;
  (int, int)? _sentSize;
  Timer? _resizeTimer;
  bool _feedPaused = false;
  bool _abandoned = false;
  bool _released = false;
  bool _finished = false;
  bool _disposed = false;
  final Queue<Uint8List> _inputQueue = Queue();
  int _inputQueued = 0;
  bool _writing = false;
  VoidCallback? _pendingListener;

  void _set({
    TerminalStatus? status,
    TerminalExited? exit,
    String? Function()? error,
    String? Function()? notice,
    bool? closeRequested,
    bool? inputPaused,
  }) {
    _status = status ?? _status;
    _exit = exit ?? _exit;
    if (error != null) _error = error();
    if (notice != null) _notice = notice();
    _closeRequested = closeRequested ?? _closeRequested;
    _inputPaused = inputPaused ?? _inputPaused;
    if (_disposed) return;
    notifyListeners();
    _onChanged();
  }

  /// Disposes the surface and the link, once.
  void _disposeNow() {
    if (_disposed) return;
    surface.dispose();
    dispose();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Owns the links of the workbench's terminal panes (design D7, D8, D9).
///
/// It opens and attaches host terminals, pumps their output into the pane's
/// [TerminalSurface] and the surface's input back, debounces resizes, and
/// follows `terminal/exited` and `terminal/closeFailed`. It never touches the
/// layout: removing a pane is [removePane].
class TerminalController extends ChangeNotifier {
  TerminalController({
    required this.surfaceFactory,
    required this.removePane,
    this.resizeInterval = const Duration(milliseconds: 50),
    this.pendingBound = 1024 * 1024,
    this.inputBound = 1024 * 1024,
  });

  final TerminalSurfaceFactory surfaceFactory;

  /// Removes a pane from the layout (a confirmed close ended its terminal).
  final void Function(String paneId) removePane;

  /// At most one resize per interval, plus a trailing one.
  final Duration resizeInterval;

  /// The channel is paused while the surface's `pending` is at or above this.
  final int pendingBound;

  /// Input queued for the host beyond this is discarded.
  final int inputBound;

  HostLink? _host;
  int _generation = 0;
  bool _disposed = false;
  final List<StreamSubscription<Object?>> _hostSubs = [];
  final Map<String, TerminalLink> _links = {};
  final Map<String, TerminalLink> _byTerminal = {};

  /// Terminals opened for a pane that was closed meanwhile (the orphan
  /// list): closed on arrival, released on their exit.
  final Set<String> _orphans = {};

  /// `terminal/exited` that came before the open that names it returned.
  final Map<String, TerminalExited> _unclaimed = {};
  int _opening = 0;

  /// The link of [paneId], or null for a pane that has none (status `none`).
  TerminalLink? linkOf(String paneId) => _links[paneId];

  TerminalStatus statusOf(String paneId) =>
      _links[paneId]?.status ?? TerminalStatus.none;

  bool get hasHost => _host != null;

  // --- the host ------------------------------------------------------------

  /// Follows [link]. A different host drops every link: the processes of
  /// the earlier one are gone with it.
  void attach(HostLink link) {
    if (identical(_host, link)) return;
    _dropLinks('The host was restarted; this terminal ended.');
    _host = link;
    _hostSubs
      ..add(link.terminalExits.listen(_onExited))
      ..add(link.terminalCloseFailures.listen(_onCloseFailed));
  }

  /// The host is gone.
  void detach() {
    if (_host == null) return;
    _dropLinks('The host connection was lost; this terminal ended.');
    _host = null;
  }

  void _dropLinks(String notice) {
    _generation++;
    for (final s in _hostSubs) {
      unawaited(s.cancel());
    }
    _hostSubs.clear();
    for (final link in _links.values) {
      _stopIo(link);
      if (link._status == TerminalStatus.ended) continue;
      link._set(
        status: TerminalStatus.ended,
        error: () => null,
        notice: () => notice,
        closeRequested: false,
      );
    }
    _byTerminal.clear();
    _orphans.clear();
    _unclaimed.clear();
  }

  bool _stale(int generation) => _disposed || generation != _generation;

  // --- start ---------------------------------------------------------------

  /// Starts a shell of [profileId] in the pane [paneId] (**Start shell**, or the
  /// launcher). The pane's surface lays out first, so the open carries the
  /// view's size. Completes once the terminal is live or has failed. Does
  /// nothing while the pane is `starting`, `live` or `closing`.
  Future<void> start(
    String paneId, {
    required String profileId,
    required String profileName,
    String? workspaceId,
  }) async {
    final host = _host;
    if (host == null) return;
    final previous = _links[paneId];
    if (previous != null && previous._status != TerminalStatus.ended) return;
    if (previous != null) {
      if (previous.terminalId case final id?) {
        _release(host, id, link: previous);
      }
      _discard(previous);
    }

    final generation = _generation;
    final link = TerminalLink._(
      paneId: paneId,
      surface: surfaceFactory(scrollbackLimit: defaultScrollbackLimit),
      profileId: profileId,
      profileName: profileName,
      workspaceId: workspaceId,
      onChanged: notifyListeners,
    );
    _links[paneId] = link;
    final firstSize = link._firstSize = Completer<(int, int)?>();
    // Input typed before the shell is live waits in the queue.
    link._inputSub = link.surface.input.listen((b) => _onInput(link, b));
    link._sizeSub = link.surface.size.listen((size) {
      link._latestSize = size;
      if (!firstSize.isCompleted) {
        firstSize.complete(size);
      } else {
        _requestResize(link);
      }
    });
    notifyListeners();

    final size = await firstSize.future;
    if (size == null || link._abandoned || _stale(generation)) return;
    final cols = min(size.$1, maxTerminalCols);
    final rows = min(size.$2, maxTerminalRows);
    TerminalChannels? channels;
    String? failure;
    _opening++;
    try {
      channels = await host.openTerminal(
        TerminalOpenParams(
          profileId: profileId,
          workspaceId: workspaceId,
          cols: cols,
          rows: rows,
        ),
      );
    } on RpcException catch (e) {
      failure = _describe('Could not start the shell', e);
    } on ConnectionClosedException {
      failure = 'Could not start the shell: the host is gone.';
    }
    _opening--;
    try {
      if (_stale(generation)) return;
      if (channels == null) {
        if (!link._abandoned) {
          link._set(status: TerminalStatus.ended, error: () => failure);
        }
        return;
      }
      if (link._abandoned) {
        // The pane was closed while the open was out: close, never attach.
        // A shell that already ended is only released.
        if (_unclaimed.remove(channels.terminalId) != null) {
          _release(host, channels.terminalId);
        } else {
          _closeOrphan(host, channels.terminalId);
        }
        return;
      }
      link
        .._channels = channels
        .._terminalId = channels.terminalId
        .._sentSize = (cols, rows);
      _byTerminal[channels.terminalId] = link;
      link._outputSub = channels.output.listen(
        (bytes) => _onOutput(link, bytes),
        onError: (Object _) {},
      );
      link._pendingListener = () => _onPending(link);
      link.surface.pending.addListener(link._pendingListener!);
      link._set(status: TerminalStatus.live, error: () => null);
      // The view may have resized while the open was out.
      _requestResize(link);
      _pumpInput(link);
      if (_unclaimed.remove(channels.terminalId) case final early?) {
        _handleExit(link, early);
      }
    } finally {
      // Only exits that raced an open in flight are kept.
      if (_opening == 0) _unclaimed.clear();
    }
  }

  static String _describe(String what, RpcException e) {
    final detail = e.message.isEmpty ? '' : ' (${e.message})';
    return '$what: ${e.reason}$detail';
  }

  // --- output --------------------------------------------------------------

  void _onOutput(TerminalLink link, Uint8List bytes) {
    link.surface.feed(bytes);
    _checkFeedBound(link);
  }

  /// Pauses the channel at the bound, so credit stops at the host. A chunk
  /// already received is fed whole, so the bound is exceeded by at most one.
  void _checkFeedBound(TerminalLink link) {
    if (link._feedPaused || link.surface.pending.value < pendingBound) return;
    link._feedPaused = true;
    link._outputSub?.pause();
  }

  void _onPending(TerminalLink link) {
    if (!link._feedPaused || link.surface.pending.value >= pendingBound) {
      return;
    }
    // Not from inside the engine's own notification.
    scheduleMicrotask(() => _resumeFeed(link));
  }

  void _resumeFeed(TerminalLink link) {
    if (link._abandoned || link._disposed || !link._feedPaused) return;
    if (link.surface.pending.value >= pendingBound) return;
    link._feedPaused = false;
    link._outputSub?.resume();
    _maybeFinish(link);
  }

  // --- exit ----------------------------------------------------------------

  void _onExited(TerminalExited e) {
    final link = _byTerminal[e.terminalId];
    if (link != null) {
      _handleExit(link, e);
    } else if (_orphans.remove(e.terminalId)) {
      _release(_host, e.terminalId);
    } else if (_opening > 0) {
      _unclaimed[e.terminalId] = e;
    }
  }

  void _handleExit(TerminalLink link, TerminalExited e) {
    link._exit = e;
    if (link._closeRequested) {
      // A confirmed close ends in removal, whatever the exit reason.
      _removeEnded(link);
    } else if (e.reason == TerminalExitReason.exited &&
        e.status == 0 &&
        e.outputComplete) {
      // A clean exit (status 0, complete output) closes the pane, as if the
      // user had (D9): no warning, and no wait for the engine, so output it
      // has not taken is dropped. Other ends stay visible as ended.
      _removeEnded(link);
    } else {
      _maybeFinish(link);
    }
  }

  /// Shows the ended state once the engine has taken every byte: the host
  /// sent `terminal/exited` after the last output byte, so what is still
  /// queued in the channel is all that is left. Then the host may forget the
  /// terminal.
  void _maybeFinish(TerminalLink link) {
    final exit = link._exit;
    if (exit == null || link._feedPaused || link._finished) return;
    link._finished = true;
    _stopIo(link, keepOutput: true);
    link._set(status: TerminalStatus.ended, exit: exit, closeRequested: false);
    if (link.terminalId case final id?) _release(_host, id, link: link);
  }

  void _onCloseFailed(TerminalCloseFailed f) {
    final link = _byTerminal[f.terminalId];
    if (link == null) return;
    // The host closes the channels of a terminal it could not confirm.
    link._released = true;
    _stopIo(link);
    link._set(
      status: TerminalStatus.ended,
      error: () => 'Could not confirm that the shell ended (${f.reason}).',
      closeRequested: false,
    );
  }

  void _removeEnded(TerminalLink link) {
    _stopIo(link);
    if (link.terminalId case final id?) _release(_host, id, link: link);
    removePane(link.paneId);
  }

  void _release(HostLink? host, String terminalId, {TerminalLink? link}) {
    if (link != null) {
      if (link._released) return;
      link._released = true;
    }
    if (host == null) return;
    unawaited(
      host
          .releaseTerminal(terminalId)
          .then<void>(
            (_) {},
            onError: (Object _) {}, // unknown-terminal, or the host is gone
          ),
    );
  }

  void _closeOrphan(HostLink host, String terminalId) {
    _orphans.add(terminalId);
    unawaited(
      host
          .closeTerminal(terminalId)
          .then<void>(
            (_) {},
            onError: (Object _) => _orphans.remove(terminalId),
          ),
    );
  }

  // --- resize --------------------------------------------------------------

  /// At most one `terminal/resize` per [resizeInterval]: the first goes at
  /// once, and a trailing one carries the newest size.
  void _requestResize(TerminalLink link) {
    if (link._status != TerminalStatus.live || link._resizeTimer != null) {
      return;
    }
    _sendResize(link);
  }

  void _sendResize(TerminalLink link) {
    final latest = link._latestSize;
    final id = link.terminalId;
    final host = _host;
    if (latest == null || id == null || host == null) return;
    final size = (
      min(latest.$1, maxTerminalCols),
      min(latest.$2, maxTerminalRows),
    );
    if (size == link._sentSize) return;
    link._sentSize = size;
    unawaited(
      host
          .resizeTerminal(id, size.$1, size.$2)
          .then<void>(
            (_) {},
            onError: (Object _) {}, // the terminal is ending
          ),
    );
    link._resizeTimer = Timer(resizeInterval, () {
      link._resizeTimer = null;
      if (link._status == TerminalStatus.live) _sendResize(link);
    });
  }

  // --- input ---------------------------------------------------------------

  void _onInput(TerminalLink link, Uint8List bytes) {
    final status = link._status;
    if (status == TerminalStatus.ended || link._abandoned) return;
    if (link._inputQueued + bytes.length > inputBound) {
      // The shell is not reading: refuse, and say so.
      if (!link._inputPaused) link._set(inputPaused: true);
      return;
    }
    link._inputQueue.add(bytes);
    link._inputQueued += bytes.length;
    _pumpInput(link);
  }

  Future<void> _pumpInput(TerminalLink link) async {
    final channels = link._channels;
    if (channels == null || link._writing) return;
    link._writing = true;
    try {
      while (link._inputQueue.isNotEmpty && !link._abandoned) {
        final head = link._inputQueue.first;
        await channels.write(head);
        if (link._inputQueue.isEmpty) break; // dropped meanwhile
        link._inputQueue.removeFirst();
        link._inputQueued -= head.length;
      }
    } on Object {
      // The channel closed under us: the exit follows.
      link._inputQueue.clear();
      link._inputQueued = 0;
    } finally {
      link._writing = false;
    }
    if (link._inputPaused && link._inputQueue.isEmpty && !link._abandoned) {
      link._set(inputPaused: false);
    }
  }

  // --- close ---------------------------------------------------------------

  /// Why closing [paneId] would end running work, or null (design D9). A
  /// `starting` terminal warns like a `live` one, since its shell is about to
  /// exist.
  String? warnsOnClose(String paneId) => switch (statusOf(paneId)) {
    TerminalStatus.starting => 'its shell is starting',
    TerminalStatus.live => 'its shell is running',
    _ => null,
  };

  /// The user confirmed closing [paneId]. Not live: the pane goes at once (a
  /// `starting` one leaves its open on the orphan list). Live: the intent is
  /// recorded, `terminal/close` sent, and the pane goes when the host reports
  /// the exit of any reason.
  Future<void> closeConfirmed(String paneId) async {
    final link = _links[paneId];
    final host = _host;
    if (link == null || host == null) {
      removePane(paneId);
      return;
    }
    switch (link._status) {
      case TerminalStatus.none ||
          TerminalStatus.starting ||
          TerminalStatus.ended:
        removePane(paneId);
      case TerminalStatus.closing:
        return;
      case TerminalStatus.live:
        final id = link.terminalId!;
        link._set(
          status: TerminalStatus.closing,
          closeRequested: true,
          error: () => null,
        );
        try {
          await host.closeTerminal(id);
        } on RpcException catch (e) {
          if (link._abandoned || !link._closeRequested) return;
          if (e.reason == ErrorCode.unknownTerminal && link._exit != null) {
            // The host already forgot it: its exit came first (D9).
            _removeEnded(link);
          } else {
            link._set(
              status: TerminalStatus.live,
              closeRequested: false,
              error: () => _describe('Could not close the terminal', e),
            );
          }
        } on ConnectionClosedException {
          // The host is gone and its processes with it.
        }
    }
  }

  // --- the layout ----------------------------------------------------------

  /// The panes of the layout have changed: a link whose pane is gone ends with
  /// it, and nothing keeps running invisibly.
  void sync(Set<String> paneIds) {
    for (final link in [..._links.values]) {
      if (!paneIds.contains(link.paneId)) _forget(link);
    }
  }

  void _forget(TerminalLink link) {
    _links.remove(link.paneId);
    link._abandoned = true;
    if (link._firstSize case final c? when !c.isCompleted) c.complete(null);
    final host = _host;
    final id = link.terminalId;
    switch (link._status) {
      case TerminalStatus.live || TerminalStatus.closing:
        if (id != null && host != null && !link._released) {
          _byTerminal.remove(id);
          _closeOrphan(host, id);
        }
      case TerminalStatus.ended:
        if (id != null) _release(host, id, link: link);
      case TerminalStatus.starting || TerminalStatus.none:
        break; // an open still out is closed on arrival
    }
    _discard(link);
    notifyListeners();
  }

  void _stopIo(TerminalLink link, {bool keepOutput = false}) {
    link._resizeTimer?.cancel();
    link._resizeTimer = null;
    unawaited(link._sizeSub?.cancel());
    link._sizeSub = null;
    unawaited(link._inputSub?.cancel());
    link._inputSub = null;
    link._inputQueue.clear();
    link._inputQueued = 0;
    if (link._pendingListener case final l?) {
      link.surface.pending.removeListener(l);
      link._pendingListener = null;
    }
    if (!keepOutput) {
      unawaited(link._outputSub?.cancel());
      link._outputSub = null;
    }
  }

  /// Ends [link]'s wiring and disposes it once the frame that still shows it
  /// is done.
  void _discard(TerminalLink link) {
    if (link._firstSize case final c? when !c.isCompleted) c.complete(null);
    _stopIo(link);
    if (link.terminalId case final id?) _byTerminal.remove(id);
    try {
      SchedulerBinding.instance
        ..addPostFrameCallback((_) => link._disposeNow())
        ..ensureVisualUpdate();
    } on Object {
      link._disposeNow(); // no binding: nothing is showing it
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    for (final s in _hostSubs) {
      unawaited(s.cancel());
    }
    _hostSubs.clear();
    for (final link in _links.values) {
      link._abandoned = true;
      if (link._firstSize case final c? when !c.isCompleted) c.complete(null);
      _stopIo(link);
      link._disposeNow();
    }
    _links.clear();
    super.dispose();
  }
}
