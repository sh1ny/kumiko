import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// One entry's own find-data record: attributes, creation and last-write time
/// and the reparse tag (`dwReserved0`, meaningful only on a reparse point).
typedef WindowsFindRecord = ({
  int attributes,
  DateTime created,
  DateTime modified,
  int reparseTag,
});

final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

final int Function(Pointer<Utf16>, Pointer<Uint8>) _findFirstFile = _kernel32
    .lookupFunction<
      IntPtr Function(Pointer<Utf16>, Pointer<Uint8>),
      int Function(Pointer<Utf16>, Pointer<Uint8>)
    >('FindFirstFileW');

final int Function(int) _findClose = _kernel32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('FindClose');

const _findDataSize = 592; // sizeof(WIN32_FIND_DATAW), x64 and x86.
const _invalidHandle = -1;
// Microseconds between 1601-01-01 (FILETIME epoch) and 1970-01-01.
const _epochDelta = 11644473600 * 1000000;

DateTime _fileTime(ByteData data, int offset) {
  final ticks =
      data.getUint32(offset, Endian.little) |
      (data.getUint32(offset + 4, Endian.little) << 32);
  return DateTime.fromMicrosecondsSinceEpoch(
    ticks ~/ 10 - _epochDelta,
    isUtc: true,
  );
}

/// `FindFirstFileW` on [path] itself. The record describes the entry, never a
/// link's target. Null when the entry cannot be found. Nothing is opened.
WindowsFindRecord? windowsFindData(String path) {
  final long =
      path.length >= 240 && !path.startsWith(r'\') && path.contains(':')
      ? r'\\?\' + path
      : path;
  final name = long.toNativeUtf16();
  final buffer = calloc<Uint8>(_findDataSize);
  try {
    final handle = _findFirstFile(name, buffer);
    if (handle == _invalidHandle) return null;
    _findClose(handle);
    final data = ByteData.sublistView(buffer.asTypedList(_findDataSize));
    return (
      attributes: data.getUint32(0, Endian.little),
      created: _fileTime(data, 4),
      modified: _fileTime(data, 20),
      reparseTag: data.getUint32(36, Endian.little),
    );
  } finally {
    calloc.free(buffer);
    calloc.free(name);
  }
}
