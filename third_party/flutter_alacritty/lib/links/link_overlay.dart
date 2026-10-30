import 'package:flutter/foundation.dart';

/// A confirmed link column range on one viewport row (half-open `[start, end)`).
@immutable
class LinkCellRange {
  const LinkCellRange({required this.start, required this.end});
  final int start;
  final int end;
  bool contains(int col) => col >= start && col < end;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LinkCellRange && other.start == start && other.end == end);

  @override
  int get hashCode => Object.hash(start, end);
}

/// Immutable per-frame map of viewport-row -> enabled link ranges. Built by
/// `TerminalView` from enabled provider spans and read by `TerminalPainter` so
/// host-provided links underline like OSC 8 hyperlinks without touching grid flags.
@immutable
class LinkOverlay {
  const LinkOverlay(this._rows);
  final Map<int, List<LinkCellRange>> _rows;

  static const LinkOverlay empty = LinkOverlay(<int, List<LinkCellRange>>{});

  bool isLinkCell(int row, int col) {
    final ranges = _rows[row];
    if (ranges == null) return false;
    for (final r in ranges) {
      if (r.contains(col)) return true;
    }
    return false;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! LinkOverlay) return false;
    if (_rows.length != other._rows.length) return false;
    for (final entry in _rows.entries) {
      final otherRanges = other._rows[entry.key];
      if (otherRanges == null || otherRanges.length != entry.value.length) {
        return false;
      }
      for (var i = 0; i < entry.value.length; i++) {
        if (entry.value[i] != otherRanges[i]) return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll([
        for (final entry in _rows.entries)
          Object.hash(entry.key, Object.hashAll(entry.value)),
      ]);
}
