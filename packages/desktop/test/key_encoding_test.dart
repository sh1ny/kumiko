import 'package:flutter/services.dart';
import 'package:flutter_alacritty/input/key_input.dart';
import 'package:flutter_test/flutter_test.dart';

/// The vendored engine's key encoding, where Kumiko relies on it.
void main() {
  test('Ctrl+Backslash sends FS (0x1c), the usual SIGQUIT character', () {
    // With the character, and with only the key label (Ctrl often clears
    // the character).
    for (final character in ['\\', null]) {
      expect(
        encodeKey(
          LogicalKeyboardKey.backslash,
          character,
          ctrl: true,
          modeFlags: 0,
        ),
        [0x1c],
        reason: 'character: $character',
      );
    }
  });
}
