import 'package:file_selector/file_selector.dart';

/// Asks the user for a folder (design D12). Widget tests inject a fake, so no
/// UI test opens a native dialog.
abstract interface class FolderPicker {
  /// The chosen folder's path, or null when the user cancels.
  Future<String?> pickFolder();
}

/// The native folder dialog, through `file_selector`.
class FileSelectorFolderPicker implements FolderPicker {
  const FileSelectorFolderPicker();

  @override
  Future<String?> pickFolder() => getDirectoryPath();
}
