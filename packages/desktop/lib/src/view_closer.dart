/// Per-kind close policy. The workbench gathers warnings once, then asks each
/// owner to close against its current evidence (which may change in a dialog).
abstract interface class ViewCloser {
  String? warnsOnClose(String paneId);
  Future<void> closeConfirmed(String paneId);
}
