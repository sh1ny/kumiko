import 'terminal_link_provider.dart';

/// Default link provider shipped by the library: detects bare URLs in rendered
/// text. Replaces the engine's former Rust hint-regex pass. Always enabled —
/// URLs need no filesystem validation. Activation (launching) is the host's job
/// via `TerminalView.onLinkActivate`.
class UrlLinkProvider extends TerminalLinkProvider {
  UrlLinkProvider();

  // Same pattern the Rust hint pass used (alacritty default subset).
  static final RegExp _pattern =
      RegExp(r'(?:https?|ftp|file)://[^\s]+', caseSensitive: false);

  @override
  Iterable<LinkSpan> scan(String lineText) sync* {
    for (final m in _pattern.allMatches(lineText)) {
      yield LinkSpan(start: m.start, end: m.end, payload: m.group(0)!);
    }
  }

  @override
  bool isEnabled(LinkSpan span) => true;
}
