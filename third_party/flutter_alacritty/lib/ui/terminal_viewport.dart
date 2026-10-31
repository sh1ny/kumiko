import 'dart:ui';

import 'package:flutter/foundation.dart';

/// Alacritty `SizeInfo` counterpart: single authority for pixel layout and cell
/// grid. [TerminalViewportController.apply] keeps engine, mirror, and PTY aligned
/// to this tuple synchronously on each layout pass.
@immutable
final class TerminalViewport {
  const TerminalViewport({
    required this.windowWidth,
    required this.windowHeight,
    required this.cellWidth,
    required this.cellHeight,
    required this.paddingX,
    required this.paddingY,
    required this.columns,
    required this.screenLines,
    required this.devicePixelRatio,
  });

  final double windowWidth;
  final double windowHeight;
  final double cellWidth;
  final double cellHeight;

  /// Dynamic letterbox padding (Alacritty `dynamic_padding`).
  final double paddingX;
  final double paddingY;

  final int columns;
  final int screenLines;
  final double devicePixelRatio;

  double get cellAreaWidth => columns * cellWidth;
  double get cellAreaHeight => screenLines * cellHeight;

  double get paddingRight => windowWidth - paddingX - cellAreaWidth;
  double get paddingBottom => windowHeight - paddingY - cellAreaHeight;

  /// Pixel rect containing terminal cells (for hit-testing after subtracting
  /// [paddingX]/[paddingY] from local coordinates).
  Rect get cellRect => Rect.fromLTWH(
        paddingX,
        paddingY,
        cellAreaWidth,
        cellAreaHeight,
      );

  /// Cell grid dimensions sent on SIGWINCH (`columns` × `screenLines`).
  (int cols, int rows) get ptyWindowSize => (columns, screenLines);

  bool sameGrid(TerminalViewport other) =>
      columns == other.columns && screenLines == other.screenLines;

  bool sameCellMetrics(TerminalViewport other) =>
      cellWidth == other.cellWidth && cellHeight == other.cellHeight;

  @override
  bool operator ==(Object other) =>
      other is TerminalViewport &&
      other.windowWidth == windowWidth &&
      other.windowHeight == windowHeight &&
      other.cellWidth == cellWidth &&
      other.cellHeight == cellHeight &&
      other.paddingX == paddingX &&
      other.paddingY == paddingY &&
      other.columns == columns &&
      other.screenLines == screenLines &&
      other.devicePixelRatio == devicePixelRatio;

  @override
  int get hashCode => Object.hash(
        windowWidth,
        windowHeight,
        cellWidth,
        cellHeight,
        paddingX,
        paddingY,
        columns,
        screenLines,
        devicePixelRatio,
      );

  @override
  String toString() =>
      'TerminalViewport($columns×$screenLines @ ${cellWidth.toStringAsFixed(1)}×${cellHeight.toStringAsFixed(1)}, pad ${paddingX.toStringAsFixed(1)},${paddingY.toStringAsFixed(1)})';
}
