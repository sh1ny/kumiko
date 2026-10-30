import 'dart:typed_data';

import 'term_mode.dart';

enum MouseAction { down, move, up, scrollUp, scrollDown }

/// Encodes a mouse event to terminal bytes, or null if not reportable in the
/// current mode. [col]/[row] are 1-based cell coordinates.
Uint8List? encodeMouse(
  int button,
  MouseAction action,
  int col,
  int row, {
  bool shift = false,
  bool alt = false,
  bool ctrl = false,
  required int modeFlags,
}) {
  if (!anyMouse(modeFlags)) return null;
  if (action == MouseAction.move &&
      (modeFlags & (kModeMouseDrag | kModeMouseMotion)) == 0) {
    return null; // motion only when a tracking mode wants it
  }

  final mods = (shift ? 4 : 0) + (alt ? 8 : 0) + (ctrl ? 16 : 0);

  if (sgrMouse(modeFlags)) {
    int cb;
    switch (action) {
      case MouseAction.scrollUp:
        cb = 64;
      case MouseAction.scrollDown:
        cb = 65;
      default:
        cb = button; // SGR reports the real button on release too ('m')
    }
    if (action == MouseAction.move) cb += 32;
    cb += mods;
    final fin = action == MouseAction.up ? 0x6d : 0x4d; // 'm' release else 'M'
    return Uint8List.fromList([0x1b, 0x5b, 0x3c, ...'$cb;$col;$row'.codeUnits, fin]);
  }

  // X10/normal: release is the generic "button 3".
  int xb;
  switch (action) {
    case MouseAction.up:
      xb = 3;
    case MouseAction.scrollUp:
      xb = 64;
    case MouseAction.scrollDown:
      xb = 65;
    default:
      xb = button;
  }
  if (action == MouseAction.move) xb += 32;
  xb += mods;
  int byte(int v) => (v + 32).clamp(0, 255);
  return Uint8List.fromList([0x1b, 0x5b, 0x4d, byte(xb), byte(col), byte(row)]);
}
