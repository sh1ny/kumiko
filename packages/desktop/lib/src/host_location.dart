import 'dart:io';

enum HostOs {
  windows,
  linux,
  macos;

  static HostOs get current => Platform.isWindows
      ? windows
      : Platform.isMacOS
      ? macos
      : linux;
}

/// The host executable: [override] (the compile-time
/// `--dart-define=KUMIKO_HOST=<path>`, for development only) when not empty,
/// otherwise `<app>/host/bin/kumiko_host[.exe]` beside [appExecutable].
String resolveHostExecutable({
  required String override,
  required String appExecutable,
  required HostOs os,
}) {
  if (override.isNotEmpty) return override;
  final windows = os == HostOs.windows;
  final sep = windows ? r'\' : '/';
  final cut = appExecutable.lastIndexOf(RegExp(windows ? r'[\\/]' : '/'));
  final appDir = cut < 0 ? '.' : appExecutable.substring(0, cut);
  return [
    appDir,
    'host',
    'bin',
    windows ? 'kumiko_host.exe' : 'kumiko_host',
  ].join(sep);
}

/// The per-OS default profile directory. The desktop never creates it: the
/// host that holds the profile lock does, so a refused second launch writes
/// nothing there. A base directory variable that is not an absolute path is
/// ignored, as the XDG spec asks: it would resolve against the working
/// directory, and a profile found there decides what a new terminal runs.
String defaultProfileDir({
  required HostOs os,
  required Map<String, String> env,
  required String home,
}) {
  final absolute = os == HostOs.windows
      ? RegExp(r'^([A-Za-z]:[\\/]|\\\\)')
      : RegExp('^/');
  String? set(String key) {
    final v = env[key];
    return v == null || !absolute.hasMatch(v) ? null : v;
  }

  switch (os) {
    case HostOs.windows:
      final base = set('LOCALAPPDATA') ?? '$home\\AppData\\Local';
      return '$base\\Kumiko';
    case HostOs.macos:
      return '$home/Library/Application Support/Kumiko';
    case HostOs.linux:
      final base = set('XDG_DATA_HOME') ?? '$home/.local/share';
      return '$base/kumiko';
  }
}
