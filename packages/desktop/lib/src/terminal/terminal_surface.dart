import 'dart:typed_data';

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

  /// The scrollback cap in lines.
  int get scrollbackLimit;

  /// The widget that renders the terminal and takes its input. It needs a
  /// `MaterialApp` above it (its search bar is a text field).
  Widget get view;

  void dispose();
}

/// Makes a surface with [scrollbackLimit] lines of scrollback.
typedef TerminalSurfaceFactory = TerminalSurface Function({
  int scrollbackLimit,
});

/// The default scrollback cap (design Resource Bounds).
const int defaultScrollbackLimit = 10000;
