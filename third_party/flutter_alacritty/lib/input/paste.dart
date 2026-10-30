import 'dart:convert';
import 'dart:typed_data';

import 'term_mode.dart';

/// Encodes pasted [text] for the PTY. In bracketed-paste mode the text is
/// wrapped in ESC[200~ … ESC[201~ with all `\x1b` (ESC) and `\x03` (Ctrl+C)
/// stripped — matches alacritty event.rs:paste. Stripping ESC prevents any
/// embedded escape sequence (incl. the end-marker `\x1b[201~`) from breaking
/// out of the bracket and from being interpreted as a SGR / cursor command
/// by the receiving program. Stripping `\x03` works around shells that
/// incorrectly terminate bracketed paste on Ctrl+C.
///
/// In non-bracketed mode the text is sent raw. Callers in non-bracketed mode
/// should pre-normalize newlines if their PTY-side reader expects CR.
Uint8List pasteBytes(String text, {required int modeFlags}) {
  if (bracketedPaste(modeFlags)) {
    final safe = text.replaceAll(RegExp(r'[\x1b\x03]'), '');
    return Uint8List.fromList([
      ...'\x1b[200~'.codeUnits,
      ...utf8.encode(safe),
      ...'\x1b[201~'.codeUnits,
    ]);
  }
  return Uint8List.fromList(utf8.encode(text));
}
