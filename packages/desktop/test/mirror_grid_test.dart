import 'dart:typed_data';

import 'package:flutter_alacritty/render/mirror_grid.dart';
import 'package:flutter_test/flutter_test.dart';

/// The vendored mirror's scroll damage, where Kumiko patched it.
void main() {
  LineCells line(int row, String text) => LineCells(
    line: row,
    codepoints: Uint32List.fromList(text.codeUnits),
    fg: Uint32List(text.length),
    bg: Uint32List(text.length),
    flags: Uint16List(text.length),
  );

  GridUpdate scroll(int delta, List<LineCells> lines) => GridUpdate(
    full: false,
    rows: 5,
    columns: 1,
    lines: lines,
    cursorRow: 0,
    cursorCol: 0,
    cursorVisible: false,
    scrollLineDelta: delta,
  );

  test('scrolls applied before a paint add up, and their rows move', () {
    final grid = MirrorGrid()..initializeEmpty(5, 1);
    grid.takeDirtyRows();
    grid.takeScrollLineDelta();

    // Two one-line scrolls up, each revealing the new top row.
    grid.apply(scroll(1, [line(0, 'b')]));
    grid.apply(scroll(1, [line(0, 'a')]));

    // The painter shifts its retained frame by both and repaints both
    // revealed rows.
    expect(grid.takeScrollLineDelta(), 2);
    expect(grid.takeDirtyRows(), [0, 1]);
    expect(grid.codepointAt(0, 0), 'a'.codeUnitAt(0));
    expect(grid.codepointAt(1, 0), 'b'.codeUnitAt(0));
  });

  test('a row changed before a scroll is repainted where it moved to', () {
    final grid = MirrorGrid()..initializeEmpty(5, 1);
    grid.takeDirtyRows();
    grid.takeScrollLineDelta();

    grid.apply(scroll(0, [line(2, 'x')]));
    grid.apply(scroll(-1, [line(4, 'z')]));

    expect(grid.takeScrollLineDelta(), -1);
    expect(grid.takeDirtyRows(), [1, 4]);
    expect(grid.codepointAt(1, 0), 'x'.codeUnitAt(0));
  });
}
