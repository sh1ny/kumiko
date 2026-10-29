import 'dart:convert';
import 'dart:io';

/// The host's own diagnostic log (design D12): minimal JSON lines in
/// `<profile>/logs/host.log`, rotated at [maxBytes] with two files kept
/// (`host.log` and `host.log.1`). It is opened only after the profile lock is
/// held, and it records ids and codes, never content.
class HostLog {
  HostLog._(this._file, this._rotated, this.version, this.maxBytes, this._size);

  /// Rotation threshold per file (design D12).
  static const int defaultMaxBytes = 4 * 1024 * 1024;

  final File _file;
  final File _rotated;
  final String version;
  final int maxBytes;
  int _size;

  static HostLog open(
    Directory profile, {
    required String version,
    int maxBytes = defaultMaxBytes,
  }) {
    final sep = Platform.pathSeparator;
    final dir = Directory('${profile.path}${sep}logs')
      ..createSync(recursive: true);
    final file = File('${dir.path}${sep}host.log');
    final rotated = File('${dir.path}${sep}host.log.1');
    return HostLog._(
      file,
      rotated,
      version,
      maxBytes,
      file.existsSync() ? file.lengthSync() : 0,
    );
  }

  /// Appends one event. [ids] holds ids only (`unit`, `instance`, ...).
  void event(
    String op, {
    String? code,
    Duration? duration,
    Map<String, Object?> ids = const {},
  }) {
    final line =
        '${jsonEncode({'ts': DateTime.now().toUtc().toIso8601String(), 'component': 'host', 'version': version, 'op': op, 'durationMs': ?duration?.inMilliseconds, 'code': ?code, ...ids})}\n';
    final bytes = utf8.encode(line);
    try {
      if (_size > 0 && _size + bytes.length > maxBytes) _rotate();
      _file.writeAsBytesSync(bytes, mode: FileMode.append, flush: true);
      _size += bytes.length;
    } on FileSystemException {
      // Diagnostics never take the host down.
    }
  }

  void _rotate() {
    if (_rotated.existsSync()) _rotated.deleteSync();
    _file.renameSync(_rotated.path);
    _size = 0;
  }
}
