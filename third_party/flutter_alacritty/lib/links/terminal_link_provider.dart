import 'package:flutter/foundation.dart';

/// A half-open column range `[start, end)` on a single visible line, with an
/// opaque [payload] handed back to the host on activation.
@immutable
class LinkSpan {
  const LinkSpan({required this.start, required this.end, required this.payload});

  final int start;
  final int end;
  final String payload;

  /// Whether column [col] falls inside this span (half-open).
  bool contains(int col) => col >= start && col < end;
}

/// Host-injectable link source for `TerminalView`.
///
/// The View calls [scan] over a **single line** when the pointer hovers that
/// row (Orca/xterm-style lazy detection) and on click to recover payloads.
/// Providers that confirm links asynchronously (e.g. filesystem validation)
/// mutate their own state and call `notifyListeners`; the View refreshes the
/// hovered row only.
///
/// The library performs NO IO on a provider's behalf — keeping
/// flutter_alacritty embeddable and IO-free (Plan 2W library-seam principle).
abstract class TerminalLinkProvider extends ChangeNotifier {
  /// Synchronous candidate detection over one rendered line's text.
  Iterable<LinkSpan> scan(String lineText);

  /// Synchronous gate: should this candidate be drawn/clickable *now*?
  /// Async providers return false until their cache confirms the payload.
  bool isEnabled(LinkSpan span);
}
