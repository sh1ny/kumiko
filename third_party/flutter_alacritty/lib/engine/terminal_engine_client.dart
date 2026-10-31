import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../debug/terminal_scroll_trace.dart';
import '../input/term_mode.dart';
import '../render/mirror_grid.dart';
import '../src/rust/terminal_raster_present.dart';
import '../controller/terminal_search_options.dart';
import 'engine_binding.dart';

/// Coalesces PTY output per frame and feeds it to the engine off the UI thread,
/// then applies the returned damage to the grid. A single advance is ever in
/// flight (`_advancing`), giving natural backpressure under heavy output.
class TerminalEngineClient {
  TerminalEngineClient({
    required EngineBinding binding,
    required MirrorGrid grid,
    void Function(void Function())? schedule,
    this.onRasterPresent,
  })  : _binding = binding,
        _grid = grid,
        _schedule = schedule ??
            ((cb) {
              final binding = SchedulerBinding.instance;
              binding.addPostFrameCallback((_) => cb());
              // A post-frame callback only fires if a frame is actually produced.
              // Request one so sporadic output/input (e.g. a single keystroke's
              // echo) refreshes even when the UI is otherwise idle.
              binding.scheduleFrame();
            });

  final EngineBinding _binding;
  EngineBinding get binding => _binding;
  final MirrorGrid _grid;
  final void Function(void Function()) _schedule;

  /// When set, hot-path advances/scrolls use Rust-raster present (no full
  /// LineUpdate mirror). Selection/search still call [refreshView].
  void Function(RasterPresentFrame frame)? onRasterPresent;

  /// When true, use raster present APIs and chrome-only mirror applies.
  bool useRasterPresent = false;

  RasterPresentBinding? get _raster {
    final b = _binding;
    return b is RasterPresentBinding ? b as RasterPresentBinding : null;
  }

  bool get _rasterHotPath =>
      useRasterPresent && onRasterPresent != null && _raster != null;

  /// After user interaction (keys / program writes), drain ASAP via microtask
  /// for this window instead of waiting for the idle post-frame scheduler.
  static const interactiveWindow = Duration(milliseconds: 100);

  final BytesBuilder _buf = BytesBuilder(copy: false);

  /// Bytes taken from [_buf] whose advance is not applied to the grid yet.
  int _inFlight = 0;

  /// Bytes fed and not yet applied to the grid: queued plus in flight. It
  /// reaches 0 once the grid holds every byte fed.
  final ValueNotifier<int> pending = ValueNotifier<int>(0);

  void _updatePending() => pending.value = _buf.length + _inFlight;
  bool _drainScheduled = false;
  bool _advancing = false;

  /// Resizes applied so far; see [_applyScrollSinceResize].
  int _resizes = 0;
  DateTime? _interactiveUntil;
  int? _pendingColumns;
  int? _pendingRows;
  bool _disposed = false;

  /// When true, DEC 2026 synchronized output is active and MirrorGrid presents
  /// are deferred until the mode clears (then one full snapshot).
  bool _syncOutputActive = false;

  /// Looks at a held present again once the parser's deadline for a
  /// synchronized update (150 ms) can have passed: a program that died before
  /// ending it must not leave the screen frozen until its next byte of output.
  /// The engine applies an expired update when it takes the snapshot.
  Timer? _syncHoldCheck;
  static const Duration _syncHoldRecheck = Duration(milliseconds: 200);

  void _holdSynchronized() {
    _syncOutputActive = true;
    _syncHoldCheck ??= Timer(_syncHoldRecheck, _recheckSyncHold);
  }

  void _recheckSyncHold() {
    _syncHoldCheck = null;
    // An advance in flight applies its result through the same check.
    if (_disposed || !_syncOutputActive || _advancing) return;
    final modeFlags = _binding.fullSnapshot().modeFlags;
    // Applying an expired update can queue replies (a cursor position
    // query held in it): route them now, as an advance does, so the program
    // waiting on one is not left waiting for its next output.
    _binding.pumpEvents();
    if (synchronizedOutput(modeFlags)) {
      _syncHoldCheck = Timer(_syncHoldRecheck, _recheckSyncHold);
      return;
    }
    _syncOutputActive = false;
    refreshView();
  }

  /// Opens (or extends) the interactive drain window so PTY output following
  /// user input is scheduled via microtask rather than post-frame idle.
  void markInteractive([DateTime? now]) {
    if (_disposed) return;
    final t = now ?? DateTime.now();
    _interactiveUntil = t.add(interactiveWindow);
    if (_buf.isNotEmpty) _scheduleDrain(forceImmediate: true);
  }

  bool get _isInteractive =>
      _interactiveUntil != null && DateTime.now().isBefore(_interactiveUntil!);

  /// Fired only from [_flushPendingResize], after the engine reflow and mirror
  /// snapshot complete. Host wires this to `PtyBackend.resize`.
  void Function(int columns, int rows)? onPtyResize;

  /// Re-applies the current viewport. Uses [EngineBinding.searchIsActive] to
  /// pick [fullSnapshotSearched] vs [fullSnapshot] so search highlights stay
  /// in sync with the engine without a stale Dart-side search flag.
  ///
  /// Also used for selection/a11y/copy — always ships a full cell mirror even
  /// when [useRasterPresent] is on.
  void refreshView() {
    if (_disposed) return;
    if (_rasterHotPath) {
      final frame = _raster!.fullRasterPresent();
      _applyRasterChrome(frame);
      onRasterPresent!(frame);
      // Selection/search/a11y need the Dart cell mirror on demand.
      final update = _binding.searchIsActive()
          ? _binding.fullSnapshotSearched()
          : _binding.fullSnapshot();
      _grid.apply(update);
    } else {
      final update = _binding.searchIsActive()
          ? _binding.fullSnapshotSearched()
          : _binding.fullSnapshot();
      _grid.apply(update);
    }
    // Why: MirrorGrid._notifyRepaint already schedules a frame — a second
    // scheduleFrame here piles Frame Request Pending under scroll floods.
  }

  bool searchSet(
    String pattern, {
    TerminalSearchOptions options = const TerminalSearchOptions(),
  }) {
    final ok = _binding.searchSet(pattern, options: options);
    refreshView();
    return ok;
  }

  bool searchNext() {
    final ok = _binding.searchNext();
    refreshView();
    return ok;
  }

  bool searchPrev() {
    final ok = _binding.searchPrev();
    refreshView();
    return ok;
  }

  void searchClear() {
    _binding.searchClear();
    refreshView();
  }

  String? resolveHyperlink(int id) => _binding.resolveHyperlink(id);

  void feed(Uint8List bytes) {
    if (_disposed) return;
    _buf.add(bytes);
    _updatePending();
    _scheduleDrain();
  }

  void _scheduleDrain({bool forceImmediate = false}) {
    if (_drainScheduled || _advancing) return;
    _drainScheduled = true;
    if (forceImmediate || _isInteractive) {
      scheduleMicrotask(_drain);
    } else {
      _schedule(_drain);
    }
  }

  Future<void> _drain() async {
    _drainScheduled = false;
    if (_disposed) return;
    // Hold the advance guard across the WHOLE drain, including scroll apply
    // below. Otherwise a feed() arriving during an awaited scroll/advance slips
    // past _scheduleDrain's (_drainScheduled || _advancing) gate and starts a
    // second overlapping advanceAndTakeDamage on the same engine.
    //
    // Loop while bytes keep arriving during awaits so interactive TUI echo
    // collapses into fewer apply/notify cycles under one flight.
    _advancing = true;
    try {
      while (!_disposed) {
        if (_pendingColumns != null || _pendingRows != null) {
          _flushPendingResize();
        }
        if (_disposed || _buf.isEmpty) break;
        final batch = _buf.takeBytes();
        _inFlight = batch.length;
        final resizes = _resizes;
        if (_rasterHotPath) {
          final frame = await _raster!.advanceAndTakeRasterPresent(batch);
          if (_disposed) return;
          if (resizes == _resizes) {
            _applyRasterFrame(frame);
          } else {
            refreshView(); // the frame predates a resize
          }
        } else {
          final update = await _binding.advanceAndTakeDamage(batch);
          if (_disposed) return;
          _applyUpdate(resizes == _resizes ? update : _currentSnapshot());
        }
        if (_disposed) return;
        _inFlight = 0;
        _updatePending();
        _binding.pumpEvents(); // route PtyWrite/Title/Bell/Clipboard for this batch
      }
    } finally {
      _advancing = false;
      if (!_disposed) _flushPendingResize();
    }
    if (!_disposed && _buf.isNotEmpty) _scheduleDrain();
  }

  void _applyUpdate(GridUpdate update) {
    if (_disposed) return;
    if (!update.full &&
        _grid.columns > 0 &&
        update.lines.any((l) => l.codepoints.length != _grid.columns)) {
      // Engine resized before the mirror caught up — partial line width won't fit.
      update = _binding.fullSnapshot();
    }

    // DEC 2026: hold present while synchronized output is active. Mid-sync
    // damage is partial across advances, so on clear take one full snapshot.
    if (synchronizedOutput(update.modeFlags)) {
      _holdSynchronized();
      return;
    }
    if (_syncOutputActive) {
      _syncOutputActive = false;
      // Match [refreshView]: keep search match flags when search is active.
      final snap = _binding.searchIsActive()
          ? _binding.fullSnapshotSearched()
          : _binding.fullSnapshot();
      _grid.apply(snap);
      return;
    }
    _grid.apply(update);
  }

  /// Chrome-only mirror apply + raster upload (skips LineUpdate cell mirrors).
  void _applyRasterFrame(RasterPresentFrame frame) {
    if (synchronizedOutput(frame.modeFlags)) {
      _holdSynchronized();
      return;
    }
    if (_syncOutputActive) {
      _syncOutputActive = false;
      refreshView();
      return;
    }
    _applyRasterChrome(frame);
    onRasterPresent?.call(frame);
    // RasterPresentSurface + MirrorGrid chrome apply schedule their own frames.
  }

  void _applyRasterChrome(RasterPresentFrame frame) {
    _grid.apply(
      GridUpdate(
        full: false,
        rows: 0,
        columns: 0,
        lines: const [],
        cursorRow: frame.cursorLine,
        cursorCol: frame.cursorCol,
        cursorVisible: frame.cursorVisible,
        cursorShape: frame.cursorShape,
        cursorBlinking: frame.cursorBlinking,
        modeFlags: frame.modeFlags,
        displayOffset: frame.displayOffset,
        historySize: frame.historySize,
        defaultFg: frame.defaultFg,
        defaultBg: frame.defaultBg,
        cursorColor: frame.cursorColor,
        scrollFraction: frame.scrollFraction,
        scrollLineDelta: 0,
      ),
    );
  }

  void resize(int columns, int rows) {
    if (_disposed) return;
    _pendingColumns = columns;
    _pendingRows = rows;
    // Always flush synchronously so MirrorGrid tracks LayoutBuilder even while
    // a PTY drain is in flight (avoids painter clearing a viewport-sized area
    // but only drawing the stale grid row count).
    _flushPendingResize();
  }

  void _flushPendingResize() {
    final columns = _pendingColumns;
    final rows = _pendingRows;
    if (columns == null || rows == null) return;
    _pendingColumns = null;
    _pendingRows = null;
    _binding.resize(columns, rows);
    _resizes++;
    // Engine resize sets TermDamage::Full; sync snapshot keeps MirrorGrid in sync.
    refreshView();
    _schedulePtyResize(columns, rows);
  }

  void _schedulePtyResize(int columns, int rows) {
    void fire() => onPtyResize?.call(columns, rows);
    try {
      final phase = SchedulerBinding.instance.schedulerPhase;
      if (phase == SchedulerPhase.persistentCallbacks ||
          phase == SchedulerPhase.midFrameMicrotasks) {
        SchedulerBinding.instance.addPostFrameCallback((_) => fire());
        return;
      }
    } on Object {
      // Headless tests without a scheduler binding.
    }
    fire();
  }

  Future<void> scrollLines(int delta) async {
    TerminalScrollTrace.log(
      'client',
      'scrollLines($delta) before ${_gridPosSnapshot()}',
    );
    if (_rasterHotPath) {
      await _applyRasterSinceResize(_raster!.scrollLinesRaster(delta));
    } else {
      await _applyScrollSinceResize(_binding.scrollLines(delta));
    }
    TerminalScrollTrace.log(
      'client',
      'scrollLines($delta) after ${_gridPosSnapshot()}',
    );
  }

  Future<void> scrollPixels(double deltaPx) async {
    TerminalScrollTrace.log(
      'client',
      'scrollPixels(${deltaPx.toStringAsFixed(1)}) before ${_gridPosSnapshot()}',
    );
    if (_rasterHotPath) {
      await _applyRasterSinceResize(_raster!.scrollPixelsRaster(deltaPx));
    } else {
      await _applyScrollSinceResize(_binding.scrollPixels(deltaPx));
    }
    TerminalScrollTrace.log(
      'client',
      'scrollPixels(${deltaPx.toStringAsFixed(1)}) after ${_gridPosSnapshot()}',
    );
  }

  Future<void> scrollToBottom() async {
    TerminalScrollTrace.log(
      'client',
      'scrollToBottom before ${_gridPosSnapshot()}',
    );
    if (_rasterHotPath) {
      await _applyRasterSinceResize(_raster!.scrollToBottomRaster());
    } else {
      await _applyScrollSinceResize(_binding.scrollToBottom());
    }
    TerminalScrollTrace.log(
      'client',
      'scrollToBottom after ${_gridPosSnapshot()}',
    );
  }

  Future<void> scrollToTop() async {
    TerminalScrollTrace.log(
      'client',
      'scrollToTop before ${_gridPosSnapshot()}',
    );
    if (_rasterHotPath) {
      await _applyRasterSinceResize(_raster!.scrollToTopRaster());
    } else {
      await _applyScrollSinceResize(_binding.scrollToTop());
    }
    TerminalScrollTrace.log(
      'client',
      'scrollToTop after ${_gridPosSnapshot()}',
    );
  }

  Future<void> scrollToOffset(double offsetLines) async {
    TerminalScrollTrace.log(
      'client',
      'scrollToOffset($offsetLines) before ${_gridPosSnapshot()}',
    );
    if (_rasterHotPath) {
      await _applyRasterSinceResize(_raster!.scrollToOffsetRaster(offsetLines));
    } else {
      await _applyScrollSinceResize(_binding.scrollToOffset(offsetLines));
    }
    TerminalScrollTrace.log(
      'client',
      'scrollToOffset($offsetLines) after ${_gridPosSnapshot()}',
    );
  }

  void _applyScrollUpdate(GridUpdate update) {
    if (_disposed) return;
    _applyUpdate(update);
    // MirrorGrid notify schedules the frame.
  }

  /// The engine's whole viewport now, with search marks when searching.
  GridUpdate _currentSnapshot() => _binding.searchIsActive()
      ? _binding.fullSnapshotSearched()
      : _binding.fullSnapshot();

  // A resize applies synchronously while an awaited engine call is in
  // flight, so that call's result can describe the grid before it. Such a
  // result is replaced by the engine's current state.
  Future<void> _applyScrollSinceResize(Future<GridUpdate> pending) async {
    final resizes = _resizes;
    final update = await pending;
    if (_disposed) return;
    _applyScrollUpdate(resizes == _resizes ? update : _currentSnapshot());
  }

  Future<void> _applyRasterSinceResize(
    Future<RasterPresentFrame> pending,
  ) async {
    final resizes = _resizes;
    final frame = await pending;
    if (_disposed) return;
    if (resizes == _resizes) {
      _applyRasterFrame(frame);
    } else {
      refreshView();
    }
  }

  void clearHistory() {
    _binding.clearHistory();
    refreshView();
  }

  /// Drain terminal→host events synchronously (e.g. OSC 52 paste reply).
  void pumpEventsNow() => _binding.pumpEvents();

  /// Runs any pending PTY ingest immediately. For unit/widget tests that do not
  /// pump frames (the default [schedule] uses post-frame callbacks).
  @visibleForTesting
  Future<void> drainForTest() async {
    while (_buf.isNotEmpty || _drainScheduled || _advancing) {
      if (_drainScheduled || _buf.isNotEmpty) {
        await _drain();
      } else {
        await Future<void>.delayed(Duration.zero);
      }
    }
  }

  void dispose() {
    _disposed = true;
    _syncHoldCheck?.cancel();
    _binding.dispose();
    pending.dispose();
  }

  String _gridPosSnapshot() => TerminalScrollTrace.pos(
        displayOffset: _grid.displayOffset,
        scrollFraction: _grid.scrollFraction,
        historySize: _grid.historySize,
      );
}
