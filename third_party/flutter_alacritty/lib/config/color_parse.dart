/// Parses an alacritty-style color string into a packed int.
///
/// Accepts `#rrggbb` and `0xrrggbb` (→ `0x00RRGGBB`) and `#aarrggbb`
/// (→ `0xAARRGGBB`, alpha preserved). Returns null on any malformed input.
int? parseColor(String s) {
  var hex = s.trim();
  if (hex.startsWith('#')) {
    hex = hex.substring(1);
  } else if (hex.startsWith('0x') || hex.startsWith('0X')) {
    hex = hex.substring(2);
  } else {
    return null;
  }
  if (hex.length != 6 && hex.length != 8) return null;
  return int.tryParse(hex, radix: 16);
}
