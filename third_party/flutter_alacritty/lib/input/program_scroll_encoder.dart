import 'dart:typed_data';

import 'mouse_input.dart';

/// Batch `lines` × SS3 cursor-up/down for alternate-scroll / alt-screen TUI.
/// Matches alacritty `scroll_terminal` alternate-scroll branch (always SS3).
Uint8List encodeAlternateScrollLines({required int lines, required bool up}) {
  if (lines <= 0) return Uint8List(0);
  final cmd = up ? 0x41 : 0x42;
  final out = BytesBuilder(copy: false);
  for (var i = 0; i < lines; i++) {
    out.addByte(0x1b);
    out.addByte(0x4f);
    out.addByte(cmd);
  }
  return out.toBytes();
}

/// Batch `lines` × SGR/X10 wheel reports at [col]/[row] (1-based).
Uint8List encodeMouseWheelLines({
  required int lines,
  required bool up,
  required int col,
  required int row,
  required int modeFlags,
}) {
  if (lines <= 0) return Uint8List(0);
  final action = up ? MouseAction.scrollUp : MouseAction.scrollDown;
  final out = BytesBuilder(copy: false);
  for (var i = 0; i < lines; i++) {
    final chunk = encodeMouse(0, action, col, row, modeFlags: modeFlags);
    assert(
      chunk != null,
      'encodeMouse returned null for wheel report (modeFlags=$modeFlags)',
    );
    if (chunk != null) out.add(chunk);
  }
  return out.toBytes();
}
