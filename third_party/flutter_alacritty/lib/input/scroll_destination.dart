import 'term_mode.dart';

/// Where wheel / trackpad / fling deltas go — local scrollback or the running
/// program via PTY bytes. Mirrors alacritty `scroll_terminal` routing.
enum ScrollDestination { history, program }

ScrollDestination scrollDestination({
  required int modeFlags,
  required bool shiftHeld,
}) {
  if (anyMouse(modeFlags)) return ScrollDestination.program;
  if (shiftHeld) return ScrollDestination.history;
  if (alternateScroll(modeFlags) && (modeFlags & kModeAltScreen) != 0) {
    return ScrollDestination.program;
  }
  return ScrollDestination.history;
}
