import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart';

import '../render/cell_metrics.dart';

/// The grid that fits a terminal viewport at its current font metrics.
///
/// Always represents a usable terminal: [cols] ≥ [minCols], [rows] ≥ [minRows].
/// Constructed by [ViewportResolver] (always at least [minCols]×[minRows]).
@immutable
class TerminalGrid {
  final int cols;
  final int rows;

  const TerminalGrid(this.cols, this.rows)
      : assert(cols > 0),
        assert(rows > 0);

  /// Smallest grid a human can use. Below this the viewport is in a layout
  /// transition (sidebar animation, worktree switch, zero-width tab frame).
  /// Pushing a smaller grid to the PTY would force every TUI to reflow to
  /// infinitesimal dimensions and then back — the visible "jump."
  ///
  /// Counterpart of orca's MIN_PANE_FIT_COLS (8) and MIN_PANE_FIT_ROWS (4).
  static const int minCols = 8;
  static const int minRows = 4;

  /// Pixel floor for the available paint area, mirroring orca's
  /// MIN_PANE_FIT_WIDTH_PX (48) / MIN_PANE_FIT_HEIGHT_PX (24). With tiny fonts a
  /// container can satisfy the 8×4 *cell* floor while still being a near-zero
  /// transition frame; this catches that case too (double guard, pixels + cells).
  static const double minWidthPx = 48;
  static const double minHeightPx = 24;

  /// Whether `(cols, rows)` is at least the usable floor.
  static bool isUsable(int cols, int rows) =>
      cols >= minCols && rows >= minRows;

  @override
  bool operator ==(Object other) =>
      other is TerminalGrid && other.cols == cols && other.rows == rows;

  @override
  int get hashCode => Object.hash(cols, rows);

  @override
  String toString() => 'TerminalGrid($cols×$rows)';
}

/// Parameters for resolving a terminal grid from a viewport size.
///
/// Captures everything the resolver needs: the available paint area (already
/// with host padding subtracted), the measured cell dimensions at the current
/// font, and any space reserved for chrome (scrollbar gutter, etc.).
class ViewportQuery {
  /// Available paint area. Hosts subtract their own padding (e.g. 36px
  /// horizontal, 8px vertical) before passing it here.
  final Size available;

  /// Measured cell dimensions at the current font size + DPR.
  /// Sub-pixel precision; must match what the painter uses.
  final CellMetrics cell;

  /// Space reserved for chrome that lives inside the paint area but should
  /// not be occupied by cells — e.g. a scrollbar gutter. The resolver
  /// subtracts this from [available] before computing the cell grid.
  final EdgeInsets reserve;

  const ViewportQuery({
    required this.available,
    required this.cell,
    this.reserve = EdgeInsets.zero,
  });
}

