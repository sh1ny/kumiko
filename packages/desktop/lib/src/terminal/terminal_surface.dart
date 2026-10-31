import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// The one boundary between the desktop and a terminal engine (design D7).
///
/// The host relays raw PTY bytes; a surface turns them into a rendered,
/// interactive terminal. Each engine has one adapter implementing this, and
/// nothing outside the adapter imports the engine package (ADR 0010).
abstract interface class TerminalSurface {
  /// Bytes from the host's output channel, in order, exactly as relayed.
  void feed(Uint8List bytes);

  /// Bytes the user typed or pasted, for the host's input channel.
  Stream<Uint8List> get input;

  /// The grid size in cells as the view lays it out: `(cols, rows)`. A new
  /// listener first gets the current size, once the view has one.
  Stream<(int cols, int rows)> get size;

  /// The bytes passed to [feed] that the engine has not yet applied to its
  /// grid: bytes held before the engine is ready, bytes queued in the engine
  /// and the batch in flight. It falls to 0 once every fed byte is applied.
  /// The terminal controller stops reading the channel while it is at or
  /// above its bound (design D7).
  ValueListenable<int> get pending;

  /// The scrollback cap in lines.
  int get scrollbackLimit;

  /// The widget that renders the terminal and takes its input. It needs a
  /// `MaterialApp` above it (its search bar is a text field).
  Widget get view;

  /// Gives [view] the keyboard focus, when it is mounted. The workbench calls
  /// it whenever the window's focused pane changes.
  void requestFocus();

  void dispose();
}

/// Makes a surface with [scrollbackLimit] lines of scrollback.
typedef TerminalSurfaceFactory = TerminalSurface Function({
  int scrollbackLimit,
});

/// The default scrollback cap (design Resource Bounds).
const int defaultScrollbackLimit = 10000;
