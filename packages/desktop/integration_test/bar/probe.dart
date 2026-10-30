import 'dart:typed_data';

import 'package:desktop/src/terminal/alacritty_surface.dart';
import 'package:desktop/src/terminal/terminal_surface.dart';
import 'package:flutter_alacritty/flutter_alacritty.dart';
import 'package:flutter_alacritty/input/paste.dart';
import 'package:flutter_alacritty/input/term_mode.dart' as term_mode;
import 'package:flutter_alacritty/render/cell_flags.dart';

/// What the engine bar test reads from and does to the engine. Everything
/// else in the test goes through [TerminalSurface].
sealed class BarProbe {
  /// The adopted engine's probe (ADR 0010).
  static BarProbe create() => AlacrittyProbe();

  /// The candidate's name, as in spike-results.md.
  String get engine;

  TerminalSurface get surface;

  /// Lays the grid out at [cols]x[rows] without a view.
  void resizeHeadless(int cols, int rows);

  int get columns;
  int get rows;

  /// The code point in a cell; 0 for an empty cell.
  int codepointAt(int y, int x);

  /// Whether the cell holds a double-width character, or is the second
  /// (spacer) cell of one.
  bool isWide(int y, int x);
  bool isSpacer(int y, int x);

  /// A cell's foreground as 0xRRGGBB, as the view paints it.
  int fgAt(int y, int x);

  /// Bold, underline and inverse as 1, 2 and 4.
  int attrsAt(int y, int x);

  /// The colour the engine is configured to paint indexed colour [n] (0-15)
  /// with; 16-255 are the fixed xterm palette.
  int configuredColour(int n);

  /// Changes whenever the grid does.
  int get generation;

  bool get bracketedPaste;

  /// What the view's paste action sends for [text].
  void paste(String text);

  /// What the view sends for Ctrl+C.
  void ctrlC();
}

final class AlacrittyProbe extends BarProbe {
  @override
  String get engine => 'flutter_alacritty';

  @override
  final AlacrittySurface surface = AlacrittySurface();

  TerminalGridView get _grid => surface.engine.grid;

  @override
  void resizeHeadless(int cols, int rows) =>
      surface.engine.resize(columns: cols, rows: rows);

  @override
  int get columns => _grid.columns;
  @override
  int get rows => _grid.rows;

  @override
  int codepointAt(int y, int x) => _grid.codepointAt(y, x);

  @override
  bool isWide(int y, int x) => _grid.flagsAt(y, x) & kFlagWide != 0;
  @override
  bool isSpacer(int y, int x) => _grid.flagsAt(y, x) & kFlagWideSpacer != 0;

  @override
  int fgAt(int y, int x) => _grid.fgAt(y, x) & 0xFFFFFF;

  @override
  int attrsAt(int y, int x) {
    final f = _grid.flagsAt(y, x);
    return (f & kFlagBold != 0 ? 1 : 0) |
        (f & kFlagUnderline != 0 ? 2 : 0) |
        (f & kFlagInverse != 0 ? 4 : 0);
  }

  @override
  int configuredColour(int n) => TerminalConfig.defaults().colors.ansi[n];

  @override
  int get generation => _grid.generation;

  @override
  bool get bracketedPaste => term_mode.bracketedPaste(_grid.modeFlags);

  @override
  void paste(String text) =>
      surface.engine.write(pasteBytes(text, modeFlags: _grid.modeFlags));

  @override
  void ctrlC() => surface.engine.write(Uint8List.fromList([0x03]));
}
