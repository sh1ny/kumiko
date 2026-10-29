import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'libc.dart';
import 'windows_api.dart' as win;

/// The identity of a directory.
sealed class DirectoryIdentity {
  const DirectoryIdentity();
}

/// A directory that was opened and identified.
final class ResolvedDirectory extends DirectoryIdentity {
  const ResolvedDirectory({required this.realPath, required this.id});

  /// The canonical path (`realpath`, `GetFinalPathNameByHandleW`) with no
  /// case folding: a case-sensitive volume can hold two directories whose
  /// paths differ only in case.
  final String realPath;

  /// `st_dev:st_ino` on POSIX; volume serial and the 128-bit file id on
  /// Windows. Equal ids mean the same directory, whatever path led to it.
  final String id;

  @override
  String toString() => 'ResolvedDirectory($id, $realPath)';
}

/// The path does not exist, is not a directory, or could not be opened.
final class TargetUnavailable extends DirectoryIdentity {
  const TargetUnavailable(this.detail);

  String get reason => 'target-unavailable';

  final String detail;

  @override
  String toString() => 'TargetUnavailable($detail)';
}

/// Resolves [path] to a canonical path and a file identity, following
/// symbolic links and junctions (design D4).
DirectoryIdentity directoryIdentity(String path) =>
    Platform.isWindows ? _windowsIdentity(path) : _posixIdentity(path);

// ---- POSIX ----

typedef _RealpathNative = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _StatNative = Int32 Function(Pointer<Utf8>, Pointer<Void>);
typedef _StatDart = int Function(Pointer<Utf8>, Pointer<Void>);

final Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>) _realpath = libc
    .lookupFunction<
      _RealpathNative,
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)
    >('realpath');

final void Function(Pointer<Void>) _free = libc
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
      'free',
    );

/// `stat`, with the 64-bit inode layout. On x86_64 macOS the plain symbol is
/// the legacy 32-bit inode variant, so `stat$INODE64` comes first; arm64
/// macOS has only `stat`. glibc before 2.33 exports `__xstat` instead.
final _StatDart _stat = () {
  if (Platform.isMacOS) {
    try {
      return libc.lookupFunction<_StatNative, _StatDart>(r'stat$INODE64');
    } on ArgumentError {
      return libc.lookupFunction<_StatNative, _StatDart>('stat');
    }
  }
  try {
    return libc.lookupFunction<_StatNative, _StatDart>('stat');
  } on ArgumentError {
    final xstat = libc
        .lookupFunction<
          Int32 Function(Int32, Pointer<Utf8>, Pointer<Void>),
          int Function(int, Pointer<Utf8>, Pointer<Void>)
        >('__xstat');
    return (Pointer<Utf8> path, Pointer<Void> buf) =>
        xstat(1, path, buf); // _STAT_VER_LINUX on x86_64
  }
}();

DirectoryIdentity _posixIdentity(String path) {
  final cPath = path.toNativeUtf8();
  Pointer<Utf8> resolved = nullptr;
  final buffer = calloc<Uint8>(256);
  try {
    resolved = _realpath(cPath, nullptr);
    if (resolved == nullptr) {
      return TargetUnavailable('realpath errno ${errno()}');
    }
    final real = resolved.toDartString();
    if (!FileSystemEntity.isDirectorySync(real)) {
      return TargetUnavailable('$real is not a directory');
    }
    if (_stat(resolved, buffer.cast<Void>()) != 0) {
      return TargetUnavailable('stat errno ${errno()}');
    }
    final data = ByteData.sublistView(buffer.asTypedList(256));
    // Linux: st_dev u64 at 0. macOS: st_dev i32 at 0. st_ino u64 at 8 on both.
    final dev = Platform.isMacOS
        ? data.getInt32(0, Endian.host)
        : data.getUint64(0, Endian.host);
    final ino = data.getUint64(8, Endian.host);
    return ResolvedDirectory(realPath: real, id: '$dev:$ino');
  } finally {
    if (resolved != nullptr) _free(resolved.cast<Void>());
    calloc.free(cPath);
    calloc.free(buffer);
  }
}

// ---- Windows ----

final int Function(int, Pointer<Utf16>, int, int) _getFinalPathNameByHandle =
    DynamicLibrary.open('kernel32.dll').lookupFunction<
      Uint32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32),
      int Function(int, Pointer<Utf16>, int, int)
    >('GetFinalPathNameByHandleW');

final int Function(int, int, Pointer<Void>, int) _getFileInformationByHandleEx =
    DynamicLibrary.open('kernel32.dll').lookupFunction<
      Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32),
      int Function(int, int, Pointer<Void>, int)
    >('GetFileInformationByHandleEx');

const int _fileIdInfo = 18;
const int _fileFlagBackupSemantics = 0x02000000;
const int _shareAll = 0x7;
const int _openExisting = 3;

DirectoryIdentity _windowsIdentity(String path) {
  final cPath = path.toNativeUtf16();
  final handle = win.createFileW(
    cPath,
    0,
    _shareAll,
    nullptr,
    _openExisting,
    _fileFlagBackupSemantics,
    0,
  );
  calloc.free(cPath);
  if (handle == -1) {
    return TargetUnavailable('CreateFileW error ${win.getLastError()}');
  }
  final nameBuffer = calloc<Uint16>(32768);
  final idBuffer = calloc<Uint8>(24); // FILE_ID_INFO
  try {
    final length = _getFinalPathNameByHandle(
      handle,
      nameBuffer.cast<Utf16>(),
      32768,
      0, // FILE_NAME_NORMALIZED | VOLUME_NAME_DOS
    );
    if (length == 0 || length >= 32768) {
      return TargetUnavailable(
        'GetFinalPathNameByHandleW error ${win.getLastError()}',
      );
    }
    final real = _stripNamespacePrefix(
      nameBuffer.cast<Utf16>().toDartString(length: length),
    );
    if (!FileSystemEntity.isDirectorySync(real)) {
      return TargetUnavailable('$real is not a directory');
    }
    if (_getFileInformationByHandleEx(
          handle,
          _fileIdInfo,
          idBuffer.cast<Void>(),
          24,
        ) ==
        0) {
      return TargetUnavailable(
        'GetFileInformationByHandleEx(FileIdInfo) error ${win.getLastError()}',
      );
    }
    final data = ByteData.sublistView(idBuffer.asTypedList(24));
    String hex(int from, int to) => [
      for (var i = from; i < to; i++)
        data.getUint8(i).toRadixString(16).padLeft(2, '0'),
    ].join();
    final serial = hex(0, 8);
    final fileId = hex(8, 24);
    return ResolvedDirectory(realPath: real, id: '$serial:$fileId');
  } finally {
    win.closeHandleNative(handle);
    calloc.free(nameBuffer);
    calloc.free(idBuffer);
  }
}

/// `\\?\C:\x` becomes `C:\x`, `\\?\UNC\server\share` becomes
/// `\\server\share`.
String _stripNamespacePrefix(String path) {
  if (path.startsWith(r'\\?\UNC\')) return r'\\' + path.substring(8);
  if (path.startsWith(r'\\?\')) return path.substring(4);
  return path;
}
