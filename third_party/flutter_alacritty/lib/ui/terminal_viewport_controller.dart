import '../engine/terminal_engine.dart';
import 'terminal_viewport.dart';
import 'viewport_geometry.dart';
import 'viewport_resolver.dart';

/// Owns the resize lifecycle for one [TerminalView] pane.
///
/// [apply] runs synchronously inside [LayoutBuilder]: engine + mirror resize
/// immediately when the cell grid changes; [onPtyResize] fires after the engine
/// flush unless a [beginPtyHold] bracket is active (sidebar animation).
class TerminalViewportController {
  TerminalViewportController({
    required TerminalEngine engine,
    ViewportResolver? resolver,
    void Function(int cols, int rows)? onPtyResize,
    TerminalViewport? initialViewport,
  })  : _engine = engine,
        _resolver = resolver ?? const ViewportResolver(),
        _hostPtyResize = onPtyResize,
        committed = initialViewport {
    _engine.onPtyResize = _enginePtyHook;
  }

  final TerminalEngine _engine;
  final ViewportResolver _resolver;
  void Function(int cols, int rows)? _hostPtyResize;

  late final void Function(int cols, int rows) _enginePtyHook =
      (int cols, int rows) {
    if (_ptyHoldDepth > 0) {
      _heldPty = (cols: cols, rows: rows);
      return;
    }
    _hostPtyResize?.call(cols, rows);
  };

  TerminalViewport? committed;

  int _ptyHoldDepth = 0;
  ({int cols, int rows})? _heldPty;

  /// Measures [query], synchronously resizes the engine when the grid changes,
  /// and returns the committed viewport.
  TerminalViewport apply(
    ViewportQuery query, {
    double devicePixelRatio = 1.0,
  }) {
    final next = _resolver.resolve(query, devicePixelRatio: devicePixelRatio);
    final prev = committed;

    if (prev == null || !prev.sameGrid(next) || !_engine.isBound) {
      _engine.resize(columns: next.columns, rows: next.screenLines);
    } else if (!prev.sameCellMetrics(next)) {
      _engine.setCellPixels(
        next.cellWidth.round().clamp(1, 0xFFFF),
        next.cellHeight.round().clamp(1, 0xFFFF),
      );
    }

    committed = next;
    return next;
  }

  void updateHostPtyResize(void Function(int cols, int rows)? cb) {
    _hostPtyResize = cb;
  }

  /// Suppress [onPtyResize] while the host animates chrome. Engine/mirror still
  /// track the live viewport; call [endPtyHold] to flush one SIGWINCH.
  void beginPtyHold() => _ptyHoldDepth++;

  void endPtyHold({bool flush = true}) {
    if (_ptyHoldDepth <= 0) return;
    _ptyHoldDepth--;
    if (_ptyHoldDepth != 0) return;
    if (!flush) {
      _heldPty = null;
      return;
    }
    final held = _heldPty;
    _heldPty = null;
    if (held != null) {
      _hostPtyResize?.call(held.cols, held.rows);
    } else if (committed != null) {
      final c = committed!;
      _hostPtyResize?.call(c.columns, c.screenLines);
    }
  }

  void dispose() {
    if (_engine.onPtyResize == _enginePtyHook) {
      _engine.onPtyResize = null;
    }
  }
}
