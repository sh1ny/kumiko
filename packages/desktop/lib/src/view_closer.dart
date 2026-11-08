/// Per-kind close policy. The workbench gathers warnings once, then asks each
/// owner to close against its current evidence (which may change in a dialog).
abstract interface class ViewCloser {
  /// Why closing each of [paneIds] would end running work, by pane id; panes
  /// that close silently are absent. Panes of other kinds are not named. One
  /// call covers a whole tab, so a terminal owner asks the host once.
  Future<Map<String, String>> warningsFor(List<String> paneIds);
  Future<void> closeConfirmed(String paneId);
}
