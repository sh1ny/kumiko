import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:flutter/services.dart';

/// Decides when printable [KeyEvent]s should be deferred to [ImeSession] /
/// `TextInputClient` instead of [encodeKey].
///
/// **Alacritty reference** (`alacritty/src/event.rs` + `input/keyboard.rs`):
/// winit delivers IME on a separate `WindowEvent::Ime` channel (Preedit/Commit);
/// `key_input` is a no-op while `display.ime.preedit()` is active. Flutter has
/// no parallel channel — we use `TextInputClient` plus this routing table.
/// Composing suppression lives in [TerminalView._onKeyFallback] (all keys).
///
/// Platform split is intentional:
/// - **Linux (fcitx/IBus):** while IME is attached in English mode, GTK still
///   delivers ASCII via hardware keys — defer only during an active composing
///   range so `encodeKey` keeps working.
/// - **macOS / Windows:** the OS IME often emits hardware keys *before*
///   `updateEditingValue` establishes a composing range — defer all uncomposed
///   printables while attached so pinyin/CJK reaches TextInput (with
///   [FocusNode.consumeKeyboardToken] in [TerminalView]).
abstract final class ImeKeyRouting {
  /// Keys that must always reach [encodeKey], never be deferred to TextInput.
  static final Set<LogicalKeyboardKey> terminalKeys = {
    LogicalKeyboardKey.backspace,
    LogicalKeyboardKey.delete,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.escape,
    LogicalKeyboardKey.tab,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.home,
    LogicalKeyboardKey.end,
    LogicalKeyboardKey.pageUp,
    LogicalKeyboardKey.pageDown,
    LogicalKeyboardKey.insert,
  };

  /// True when this [KeyEvent] is a text character IME should own (not
  /// Backspace/DEL/C0 controls — macOS may set `character` on those).
  static bool isDeferrablePrintableKeyEvent(
    KeyEvent event,
    HardwareKeyboard hw,
  ) {
    if (hw.isControlPressed || hw.isAltPressed || hw.isMetaPressed) {
      return false;
    }
    if (terminalKeys.contains(event.logicalKey)) {
      return false;
    }
    final ch = event.character;
    if (ch == null || ch.isEmpty) return false;
    for (final unit in ch.codeUnits) {
      if (unit < 0x20 || unit == 0x7f) return false;
    }
    return true;
  }

  /// Returns true when a printable key with no Ctrl/Alt/Meta should return
  /// [KeyEventResult.ignored] from the terminal focus handler.
  static bool shouldDeferPrintableToTextInput({
    required bool imeAttached,
    required bool imeComposing,
    TargetPlatform? platform,
  }) {
    if (!imeAttached) return false;
    if (imeComposing) return true;
    return deferUncomposedPrintableOn(platform ?? defaultTargetPlatform);
  }

  /// Whether printable keys should be deferred before the platform reports an
  /// active composing range. Override via [setDeferUncomposedPrintableOverride]
  /// for tests or future host-specific policy.
  static bool deferUncomposedPrintableOn(TargetPlatform platform) {
    final override = _deferUncomposedOverride;
    if (override != null) {
      return override(platform);
    }
    return switch (platform) {
      TargetPlatform.macOS || TargetPlatform.windows => true,
      TargetPlatform.linux => false,
      _ => false,
    };
  }

  static bool Function(TargetPlatform platform)? _deferUncomposedOverride;

  @visibleForTesting
  static void setDeferUncomposedPrintableOverride(
    bool Function(TargetPlatform platform)? override,
  ) {
    _deferUncomposedOverride = override;
  }
}
