import 'dart:io';

/// A held, exclusive, non-blocking lock on `<profile>/kumiko.lock`.
///
/// The store can only be opened with one of these in hand (ADR 0003, D7).
class ProfileLock {
  ProfileLock._(this.profile, this._file);

  final Directory profile;
  final RandomAccessFile _file;
  bool _released = false;

  bool get isHeld => !_released;

  /// Opens the lock file once and takes an exclusive lock without blocking.
  /// Returns null when another process holds the lock.
  static Future<ProfileLock?> tryAcquire(Directory profile) async {
    final file = File('${profile.path}${Platform.pathSeparator}kumiko.lock');
    final raf = await file.open(mode: FileMode.append);
    try {
      await raf.lock(FileLock.exclusive);
    } on FileSystemException {
      await raf.close();
      return null;
    }
    return ProfileLock._(profile, raf);
  }

  /// Releases the lock and closes the file.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _file.unlock();
    await _file.close();
  }
}
