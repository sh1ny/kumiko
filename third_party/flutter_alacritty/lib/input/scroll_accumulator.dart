/// Alacritty `AccumulatedScroll` + line extraction from `scroll_terminal`.
///
/// Positive [ingest] dy (finger/trackpad moves down) → positive remainder →
/// scroll up into history / program "up" direction.
class ScrollAccumulator {
  ScrollAccumulator({required this.cellHeight});

  final double cellHeight;
  double _remainderPx = 0;

  double get remainderPx => _remainderPx;

  void reset() => _remainderPx = 0;

  /// Add pixel delta (already OS-scaled) times [multiplier]. Returns whole
  /// lines crossed this call (signed). Keeps sub-line remainder in
  /// [remainderPx], matching Alacritty's `% height` retention.
  int ingest({required double dyPx, required double multiplier}) {
    if (cellHeight <= 0) return 0;
    _remainderPx += dyPx * multiplier;
    final lines = (_remainderPx / cellHeight).truncate();
    if (lines != 0) {
      _remainderPx -= lines * cellHeight;
    }
    return lines;
  }
}
