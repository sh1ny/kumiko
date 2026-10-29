import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'libc.dart';
import 'process_table.dart';

typedef _KillNative = Int32 Function(Int32, Int32);
typedef _KillDart = int Function(int, int);

final _KillDart _kill = libc.lookupFunction<_KillNative, _KillDart>('kill');
final _KillDart _killpg = libc.lookupFunction<_KillNative, _KillDart>('killpg');

final int Function() _getuid = libc
    .lookupFunction<Uint32 Function(), int Function()>('getuid');

/// `SIGTERM` and `SIGKILL` have the same numbers on Linux and macOS.
const int posixSigterm = 15;
const int posixSigkill = 9;

/// `kill(pid, signal)`; returns 0 or the errno.
int posixKill(int pid, int signal) => _kill(pid, signal) == 0 ? 0 : errno();

/// `killpg(pgrp, signal)`; returns 0 or the errno.
int posixKillpg(int pgrp, int signal) =>
    _killpg(pgrp, signal) == 0 ? 0 : errno();

/// The POSIX process table: `/proc` on Linux, `libproc` and `sysctl` on
/// macOS (design D9).
abstract class PosixProcessTable implements ProcessTable {
  factory PosixProcessTable() =>
      Platform.isMacOS ? _MacProcessTable() : _LinuxProcessTable();

  PosixProcessTable._();

  @override
  final int currentUid = _getuid();

  @override
  bool kill(int pid, int startTime) {
    final ProcessSnapshot? now;
    try {
      now = snapshot(pid);
    } on ProcessReadDenied {
      return false;
    }
    if (now == null || now.zombie || now.startTime != startTime) return true;
    final err = posixKill(pid, posixSigkill);
    return err == 0 || err == esrch;
  }
}

class _LinuxProcessTable extends PosixProcessTable {
  _LinuxProcessTable() : super._();

  late final DateTime _boot = _bootTime();
  late final int _ticksPerSecond = () {
    final hz = sysconf(2); // _SC_CLK_TCK
    return hz > 0 ? hz : 100;
  }();

  static DateTime _bootTime() {
    // Boot time from the uptime keeps centisecond precision; /proc/stat's
    // btime is whole seconds.
    final uptime = File('/proc/uptime').readAsStringSync().split(' ').first;
    final micros = (double.parse(uptime) * 1e6).round();
    return DateTime.now().subtract(Duration(microseconds: micros));
  }

  /// Maps a failed `/proc/<pid>/...` read to a Dart exception.
  static Never _fail(FileSystemException e) {
    final code = e.osError?.errorCode;
    if (code == enoent || code == esrch) throw const ProcessGone();
    throw const ProcessReadDenied();
  }

  @override
  List<int> listPids() {
    try {
      return [
        for (final e in Directory('/proc').listSync(followLinks: false))
          ?int.tryParse(e.uri.pathSegments.lastWhere((s) => s.isNotEmpty)),
      ];
    } on FileSystemException catch (e) {
      throw ProcessTableUnlistable('${e.path}: ${e.osError}');
    }
  }

  @override
  ProcessSnapshot? snapshot(int pid) {
    final String stat;
    final String status;
    try {
      stat = File('/proc/$pid/stat').readAsStringSync();
      status = File('/proc/$pid/status').readAsStringSync();
    } on FileSystemException catch (e) {
      final code = e.osError?.errorCode;
      if (code == enoent || code == esrch) return null;
      throw const ProcessReadDenied();
    }
    // "pid (comm) S ppid ..."; comm may hold spaces and parentheses.
    final rest = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
    final state = rest[0];
    final ticks = int.parse(rest[19]); // field 22, starttime
    final uidMatch = RegExp(
      r'^Uid:\s+(\d+)',
      multiLine: true,
    ).firstMatch(status);
    if (uidMatch == null) throw const ProcessReadDenied();
    return ProcessSnapshot(
      startTime: ticks,
      startedAt: _boot.add(
        Duration(microseconds: ticks * 1000000 ~/ _ticksPerSecond),
      ),
      uid: int.parse(uidMatch.group(1)!),
      zombie: state == 'Z' || state == 'X',
    );
  }

  @override
  List<String> environment(int pid) {
    final Uint8List bytes;
    try {
      bytes = File('/proc/$pid/environ').readAsBytesSync();
    } on FileSystemException catch (e) {
      _fail(e);
    }
    final entries = <String>[];
    var start = 0;
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] != 0) continue;
      if (i > start) {
        entries.add(
          utf8.decode(
            Uint8List.sublistView(bytes, start, i),
            allowMalformed: true,
          ),
        );
      }
      start = i + 1;
    }
    if (start < bytes.length) {
      entries.add(
        utf8.decode(Uint8List.sublistView(bytes, start), allowMalformed: true),
      );
    }
    return entries;
  }
}

// ---- macOS ----

typedef _ProcListpidsNative = Int32 Function(
  Uint32,
  Uint32,
  Pointer<Void>,
  Int32,
);
typedef _ProcListpidsDart = int Function(int, int, Pointer<Void>, int);
typedef _ProcPidinfoNative = Int32 Function(
  Int32,
  Int32,
  Uint64,
  Pointer<Void>,
  Int32,
);
typedef _ProcPidinfoDart = int Function(int, int, int, Pointer<Void>, int);
typedef _SysctlNative = Int32 Function(
  Pointer<Int32>,
  Uint32,
  Pointer<Void>,
  Pointer<Size>,
  Pointer<Void>,
  Size,
);
typedef _SysctlDart = int Function(
  Pointer<Int32>,
  int,
  Pointer<Void>,
  Pointer<Size>,
  Pointer<Void>,
  int,
);

final _ProcListpidsDart _procListpids = libc
    .lookupFunction<_ProcListpidsNative, _ProcListpidsDart>('proc_listpids');
final _ProcPidinfoDart _procPidinfo = libc
    .lookupFunction<_ProcPidinfoNative, _ProcPidinfoDart>('proc_pidinfo');
final _SysctlDart _sysctl = libc.lookupFunction<_SysctlNative, _SysctlDart>(
  'sysctl',
);

class _MacProcessTable extends PosixProcessTable {
  _MacProcessTable() : super._();

  static const _procAllPids = 1;
  static const _procPidtbsdinfo = 3;
  static const _bsdInfoSize = 136; // sizeof(struct proc_bsdinfo)
  static const _szomb = 5;
  static const _procPidtShortbsdinfo = 13;
  static const _shortInfoSize = 64; // sizeof(struct proc_bsdshortinfo)
  static const _ctlKern = 1;
  static const _kernProcargs2 = 49;
  static const _einval = 22;
  static const _enomem = 12;

  @override
  List<int> listPids() {
    // proc_listpids returns the number of bytes; grow the buffer until the
    // result leaves room to spare.
    var capacity = 0;
    final probe = _procListpids(_procAllPids, 0, nullptr, 0);
    if (probe <= 0) {
      throw ProcessTableUnlistable('proc_listpids errno ${errno()}');
    }
    capacity = probe + 256 * sizeOf<Int32>();
    for (var attempt = 0; attempt < 4; attempt++) {
      final buffer = calloc<Uint8>(capacity);
      try {
        final bytes = _procListpids(
          _procAllPids,
          0,
          buffer.cast<Void>(),
          capacity,
        );
        if (bytes <= 0) {
          throw ProcessTableUnlistable('proc_listpids errno ${errno()}');
        }
        if (bytes < capacity) {
          final ids = buffer.cast<Int32>();
          return [
            for (var i = 0; i < bytes ~/ sizeOf<Int32>(); i++)
              if (ids[i] > 0) ids[i],
          ];
        }
      } finally {
        calloc.free(buffer);
      }
      capacity *= 2;
    }
    throw const ProcessTableUnlistable('proc_listpids kept growing');
  }

  @override
  ProcessSnapshot? snapshot(int pid) {
    final buffer = calloc<Uint8>(_bsdInfoSize);
    try {
      final n = _procPidinfo(
        pid,
        _procPidtbsdinfo,
        0,
        buffer.cast<Void>(),
        _bsdInfoSize,
      );
      if (n <= 0) {
        final err = errno();
        if (err == eperm || err == eacces) return _foreignSnapshot(pid);
        return null; // ESRCH, or an empty answer for a pid that is gone
      }
      if (n < _bsdInfoSize) throw const ProcessReadDenied();
      final data = ByteData.sublistView(buffer.asTypedList(_bsdInfoSize));
      final status = data.getUint32(4, Endian.host);
      final uid = data.getUint32(20, Endian.host);
      final sec = data.getUint64(120, Endian.host);
      final usec = data.getUint64(128, Endian.host);
      final micros = sec * 1000000 + usec;
      return ProcessSnapshot(
        startTime: micros,
        startedAt: DateTime.fromMicrosecondsSinceEpoch(micros),
        uid: uid,
        zombie: status == _szomb,
      );
    } finally {
      calloc.free(buffer);
    }
  }

  /// macOS refuses `PROC_PIDTBSDINFO` for another user's process, but the
  /// short info, which carries the owner, is readable for every process. A
  /// process of another user is outside the scan population, so its start
  /// time is not needed; a refusal for one of our own stays unreadable.
  ProcessSnapshot? _foreignSnapshot(int pid) {
    final buffer = calloc<Uint8>(_shortInfoSize);
    try {
      final n = _procPidinfo(
        pid,
        _procPidtShortbsdinfo,
        0,
        buffer.cast<Void>(),
        _shortInfoSize,
      );
      if (n <= 0) {
        final err = errno();
        if (err == eperm || err == eacces) throw const ProcessReadDenied();
        return null;
      }
      if (n < _shortInfoSize) throw const ProcessReadDenied();
      final data = ByteData.sublistView(buffer.asTypedList(_shortInfoSize));
      final uid = data.getUint32(36, Endian.host); // pbsi_uid
      if (uid == currentUid) throw const ProcessReadDenied();
      return ProcessSnapshot(
        startTime: 0,
        startedAt: DateTime.fromMicrosecondsSinceEpoch(0),
        uid: uid,
        zombie: data.getUint32(12, Endian.host) == _szomb, // pbsi_status
      );
    } finally {
      calloc.free(buffer);
    }
  }

  @override
  List<String> environment(int pid) {
    final mib = calloc<Int32>(3);
    final size = calloc<Size>();
    try {
      mib[0] = _ctlKern;
      mib[1] = _kernProcargs2;
      mib[2] = pid;
      for (var attempt = 0; attempt < 4; attempt++) {
        size.value = 0;
        if (_sysctl(mib, 3, nullptr, size, nullptr, 0) != 0) {
          _failSysctl(errno());
        }
        // The size can grow between the two calls.
        final capacity = size.value + 4096;
        final buffer = calloc<Uint8>(capacity);
        try {
          size.value = capacity;
          if (_sysctl(mib, 3, buffer.cast<Void>(), size, nullptr, 0) != 0) {
            final err = errno();
            if (err == _enomem) continue;
            _failSysctl(err);
          }
          return _parseProcargs2(
            Uint8List.fromList(buffer.asTypedList(size.value)),
          );
        } finally {
          calloc.free(buffer);
        }
      }
      throw const ProcessReadDenied();
    } finally {
      calloc.free(mib);
      calloc.free(size);
    }
  }

  static Never _failSysctl(int err) {
    if (err == esrch || err == _einval) throw const ProcessGone();
    throw const ProcessReadDenied();
  }

  /// `argc`, the executable path, padding NULs, `argc` arguments, then the
  /// environment up to the first empty string.
  static List<String> _parseProcargs2(Uint8List bytes) {
    if (bytes.length < 4) return const [];
    final argc = ByteData.sublistView(bytes).getInt32(0, Endian.host);
    var i = 4;
    while (i < bytes.length && bytes[i] != 0) {
      i++; // executable path
    }
    while (i < bytes.length && bytes[i] == 0) {
      i++; // padding
    }
    for (var n = 0; n < argc && i < bytes.length; n++) {
      while (i < bytes.length && bytes[i] != 0) {
        i++;
      }
      i++;
    }
    final env = <String>[];
    while (i < bytes.length) {
      final start = i;
      while (i < bytes.length && bytes[i] != 0) {
        i++;
      }
      if (i == start) break;
      env.add(
        utf8.decode(
          Uint8List.sublistView(bytes, start, i),
          allowMalformed: true,
        ),
      );
      i++;
    }
    return env;
  }
}
