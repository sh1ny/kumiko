import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'libc.dart';
import 'process_table.dart';

typedef _KillNative = Int32 Function(Int32, Int32);
typedef _KillDart = int Function(int, int);

// Errno and leaf calls. `kill`, `killpg` and `proc_pidinfo` are leaf calls,
// and the errno accessor is bound before any of them can fail (`errno()` in
// the wrappers below and in the `PosixProcessTable` constructor): no VM
// transition runs between the call and the read of its errno, so a "no such
// process" is never read as another error. All three are short and wait on
// nothing, as a leaf call must be (design D4, A4).
//
// `proc_listpids` and the environment `sysctl` still read errno without a
// leaf binding. Their answers grow with the process count or the
// environment, and neither errno reaches the kill path: the first only goes
// into a message, the second is rechecked by the marker scan (issue #31).

final _KillDart _kill = libc.lookupFunction<_KillNative, _KillDart>(
  'kill',
  isLeaf: true,
);
final _KillDart _killpg = libc.lookupFunction<_KillNative, _KillDart>(
  'killpg',
  isLeaf: true,
);

final int Function() _getuid = libc
    .lookupFunction<Uint32 Function(), int Function()>('getuid');

/// `SIGTERM` and `SIGKILL` have the same numbers on Linux and macOS.
const int posixSigterm = 15;
const int posixSigkill = 9;

/// `kill(pid, signal)`; returns 0 or the errno of this call.
int posixKill(int pid, int signal) {
  errno(); // bound before the call, so nothing runs between it and the read
  return _kill(pid, signal) == 0 ? 0 : errno();
}

Object? _probeBinding;

/// Looks up `kill` and the errno accessor now, so that a later
/// [posixKill] probe does no first-use lookup between the call and its errno
/// read. The spawn calls it before `Process.start` (#18).
void bindPosixProbe() {
  _probeBinding ??= (_kill, errno());
}

/// `killpg(pgrp, signal)`; returns 0 or the errno of this call.
int posixKillpg(int pgrp, int signal) {
  errno(); // bound before the call, so nothing runs between it and the read
  return _killpg(pgrp, signal) == 0 ? 0 : errno();
}

/// The POSIX process table: `/proc` on Linux, `libproc` and `sysctl` on
/// macOS (design D9).
abstract class PosixProcessTable implements ProcessTable {
  factory PosixProcessTable() =>
      Platform.isMacOS ? _MacProcessTable() : _LinuxProcessTable();

  PosixProcessTable._() {
    errno(); // bind the accessor before the first leaf call that can fail
  }

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
  List<int> listPids() => listProcPids(
    () => [
      for (final e in Directory('/proc').listSync(followLinks: false)) e.path,
    ],
  );

  /// The fields of a `/proc/<pid>/stat` text after `comm`, which may hold
  /// spaces and parentheses: `[state, ppid, ...]`.
  static List<String> _statFields(String stat) =>
      stat.substring(stat.lastIndexOf(')') + 2).split(' ');

  static bool _vanished(FileSystemException e) {
    final code = e.osError?.errorCode;
    return code == enoent || code == esrch;
  }

  /// Linux evidence of a full exit (design D2): `/proc/<pid>` gone, unless
  /// `/proc` is mounted with `hidepid`; another start time; or one status
  /// read of a zombie leader counted as the only thread.
  @override
  Set<int> confirmedExits(Map<int, int?> pids) {
    bool hidden;
    try {
      hidden = procHidesPids(File('/proc/self/mountinfo').readAsStringSync());
    } on FileSystemException {
      hidden = true;
    }
    return {
      for (final MapEntry(key: pid, value: known) in pids.entries)
        if (_exitConfirmed(pid, known, hidden: hidden)) pid,
    };
  }

  @override
  Set<int> foreignPids(Set<int> pids) => const {};

  bool _exitConfirmed(int pid, int? known, {required bool hidden}) {
    try {
      if (known != null) {
        final ticks = int.tryParse(
          _statFields(File('/proc/$pid/stat').readAsStringSync())[19],
        );
        if (ticks != null && ticks != known) return true;
      }
      return linuxStatusConfirmsExit(
        File('/proc/$pid/status').readAsStringSync(),
      );
    } on FileSystemException catch (e) {
      return !hidden && _vanished(e);
    } on RangeError {
      return false; // a stat text we cannot parse proves nothing
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
      if (_vanished(e)) return null;
      throw const ProcessReadDenied();
    }
    final rest = _statFields(stat);
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
    .lookupFunction<_ProcPidinfoNative, _ProcPidinfoDart>(
      'proc_pidinfo',
      isLeaf: true,
    );
final _SysctlDart _sysctl = libc.lookupFunction<_SysctlNative, _SysctlDart>(
  'sysctl',
);

/// The pids of a `/proc` listing that [list] makes, as the entries' paths.
///
/// A process that exits while `/proc` is listed can make the listing fail
/// with ENOENT or ESRCH on its own `/proc/<pid>` entry. Only that failure is
/// listed again, at most 8 times in all. Every other failure, or a vanished
/// entry on all 8 attempts, throws [ProcessTableUnlistable], so the scan
/// still fails closed (issue #40, design D4).
List<int> listProcPids(List<String> Function() list) {
  const attempts = 8;
  final vanished = RegExp(r'^/proc/\d+/?$');
  for (var attempt = 1; ; attempt++) {
    try {
      return [
        for (final path in list())
          ?int.tryParse(path.split('/').lastWhere((s) => s.isNotEmpty)),
      ];
    } on FileSystemException catch (e) {
      final code = e.osError?.errorCode;
      final retry =
          (code == enoent || code == esrch) &&
          vanished.hasMatch(e.path ?? '') &&
          attempt < attempts;
      if (!retry) throw ProcessTableUnlistable('${e.path}: ${e.osError}');
    }
  }
}

/// Whether one read of `/proc/<pid>/status` proves the process has fully
/// exited: the leader is a zombie (`Z` or `X`) and the kernel still counts it
/// as the group's only thread.
///
/// `State:` and `Threads:` come from the same read, which is generated from
/// one task, so a sibling's `exec` cannot pair a dead leader's state with a
/// live leader's count. A count of 0 means the read could not lock the
/// signal state, which says nothing about the group, so only exactly 1
/// confirms (issue #40, design D2).
bool linuxStatusConfirmsExit(String status) {
  final state = RegExp(r'^State:\s+(\S)', multiLine: true).firstMatch(status);
  final threads = RegExp(
    r'^Threads:\s+(\d+)\s*$',
    multiLine: true,
  ).firstMatch(status);
  if (state == null || threads == null) return false;
  final zombie = state.group(1) == 'Z' || state.group(1) == 'X';
  return zombie && threads.group(1) == '1';
}

/// Whether the `proc` mount at `/proc`, as `/proc/self/mountinfo` describes
/// it, can hide a live process from us.
///
/// With `hidepid` other than `0` or `off`, `/proc/<pid>` is visible only to
/// a reader that may ptrace the process, so a live process of our own user
/// answers ENOENT once it becomes non-dumpable. The last `proc` mount at
/// `/proc` is the one in use. A mountinfo with no such mount, or one that
/// cannot be parsed, counts as hiding, so ENOENT is never trusted on a guess
/// (issue #40, design D2).
bool procHidesPids(String mountinfo) {
  String? options;
  for (final line in const LineSplitter().convert(mountinfo)) {
    final separator = line.indexOf(' - ');
    if (separator < 0) continue;
    final mount = line.substring(0, separator).split(' ');
    final fs = line.substring(separator + 3).split(' ');
    if (mount.length < 6 || fs.length < 3) continue;
    if (mount[4] != '/proc' || fs[0] != 'proc') continue;
    options = '${mount[5]},${fs[2]}';
  }
  if (options == null) return true;
  for (final option in options.split(',')) {
    if (!option.startsWith('hidepid=')) continue;
    final value = option.substring('hidepid='.length);
    if (value != '0' && value != 'off') return true;
  }
  return false;
}

/// The macOS pids of [pids] (pid to known start time) whose full exit is
/// confirmed.
///
/// [readStartTimes] holds the start times that the leaf
/// `proc_pidinfo(PROC_PIDTBSDINFO)` with `arg` 0 read successfully; another
/// start time than the known one means the pid was replaced. [listed] is
/// one complete `proc_listpids(PROC_ALL_PIDS)` listing made after those
/// reads, or null when it could not be made. It holds live and zombie
/// processes alike, so a pid absent from it has been reaped.
///
/// No call behind this waits, and no errno is taken as evidence (a listing
/// that fails reads it only for its diagnostic): a failed `arg` 0 read says
/// only that exit has begun, and the zombie-aware `arg` 1 read can
/// sleep. So a zombie that its parent has not reaped is not confirmed
/// (issue #40, design D2).
Set<int> macConfirmedExits({
  required Map<int, int?> pids,
  required Map<int, int> readStartTimes,
  required Set<int>? listed,
}) => {
  for (final MapEntry(key: pid, value: known) in pids.entries)
    if ((known != null &&
            readStartTimes[pid] != null &&
            readStartTimes[pid] != known) ||
        (listed != null && !listed.contains(pid)))
      pid,
};

/// The pids of [pids] absent from [ownListing], one complete macOS
/// `proc_listpids(PROC_UID_ONLY, <our uid>)` listing, and present in
/// [laterListing], one complete `proc_listpids(PROC_ALL_PIDS)` listing made
/// after it; none when either listing could not be made.
///
/// The first listing filters on each proc's credentials, which a zombie
/// keeps until it is reaped, so our own zombies are in it. A pid reaped
/// before it is absent from the later listing too, so only a pid shown to
/// exist under another user is named (issue #40, design D1).
Set<int> macForeignPids(
  Set<int> pids, {
  required Set<int>? ownListing,
  required Set<int>? laterListing,
}) => ownListing == null || laterListing == null
    ? const {}
    : {
        for (final pid in pids)
          if (!ownListing.contains(pid) && laterListing.contains(pid)) pid,
      };

/// The snapshot the macOS short read gives once the full read was refused.
///
/// A zombie is reported as a zombie whoever owns it: it is not running, and
/// every caller skips it or reads it as exited before comparing start times.
/// A zombie has no credentials, so the full read can refuse it even for one
/// of our own processes, and reading that refusal as unreadable would leave
/// a marker scan that met a passing zombie unresolved. Another user's live
/// process gets the placeholder start time 0: it is outside the scan
/// population, so its start time is not needed. A refusal for one of our
/// own live processes stays unreadable.
ProcessSnapshot macShortInfoSnapshot({
  required int uid,
  required bool zombie,
  required int currentUid,
}) {
  if (!zombie && uid == currentUid) throw const ProcessReadDenied();
  return ProcessSnapshot(
    startTime: 0,
    startedAt: DateTime.fromMicrosecondsSinceEpoch(0),
    uid: uid,
    zombie: zombie,
  );
}

class _MacProcessTable extends PosixProcessTable {
  _MacProcessTable() : super._();

  static const _procAllPids = 1;
  static const _procUidOnly = 4;
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
  List<int> listPids() => _listPids(_procAllPids, 0);

  /// One `proc_listpids` listing of [type] and [typeinfo]. The kernel stops
  /// early only when the buffer is full, so a listing that leaves room to
  /// spare is complete.
  List<int> _listPids(int type, int typeinfo) {
    // proc_listpids returns the number of bytes; grow the buffer until the
    // result leaves room to spare.
    var capacity = 0;
    final probe = _procListpids(type, typeinfo, nullptr, 0);
    if (probe <= 0) {
      throw ProcessTableUnlistable('proc_listpids errno ${errno()}');
    }
    capacity = probe + 256 * sizeOf<Int32>();
    for (var attempt = 0; attempt < 4; attempt++) {
      final buffer = calloc<Uint8>(capacity);
      try {
        final bytes = _procListpids(
          type,
          typeinfo,
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

  /// macOS evidence of a full exit (design D2): one leaf `arg` 0 read per
  /// pid with a known start time, then one complete listing after those
  /// reads, decided by [macConfirmedExits]. Nothing here waits, and no
  /// errno is evidence: a failed listing reads it only for its message.
  @override
  Set<int> confirmedExits(Map<int, int?> pids) {
    final read = <int, int>{
      for (final MapEntry(key: pid, value: known) in pids.entries)
        if (known != null) pid: ?_leafStartTime(pid),
    };
    Set<int>? listed;
    try {
      listed = listPids().toSet();
    } on ProcessTableUnlistable {
      listed = null;
    }
    return macConfirmedExits(pids: pids, readStartTimes: read, listed: listed);
  }

  /// The pids absent from one complete listing of our user's processes
  /// (`PROC_UID_ONLY`) and present in a complete full listing made after
  /// it, decided by [macForeignPids] (design D1).
  @override
  Set<int> foreignPids(Set<int> pids) {
    Set<int>? attempt(List<int> Function() list) {
      try {
        return list().toSet();
      } on ProcessTableUnlistable {
        return null;
      }
    }

    final own = attempt(() => _listPids(_procUidOnly, currentUid));
    final later = attempt(listPids);
    return macForeignPids(pids, ownListing: own, laterListing: later);
  }

  /// The start time from a successful full `arg` 0 read, else null.
  int? _leafStartTime(int pid) {
    final buffer = calloc<Uint8>(_bsdInfoSize);
    try {
      final n = _procPidinfo(
        pid,
        _procPidtbsdinfo,
        0,
        buffer.cast<Void>(),
        _bsdInfoSize,
      );
      if (n < _bsdInfoSize) return null;
      return _startMicros(
        ByteData.sublistView(buffer.asTypedList(_bsdInfoSize)),
      );
    } finally {
      calloc.free(buffer);
    }
  }

  /// `pbi_start_tvsec` and `pbi_start_tvusec` of a `proc_bsdinfo`, in µs.
  static int _startMicros(ByteData info) =>
      info.getUint64(120, Endian.host) * 1000000 +
      info.getUint64(128, Endian.host);

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
      final micros = _startMicros(data);
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

  /// macOS refuses `PROC_PIDTBSDINFO` for another user's process, and can
  /// refuse it for a zombie, but the short info, which carries the owner and
  /// the state, is readable for every process ([macShortInfoSnapshot]).
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
      return macShortInfoSnapshot(
        uid: data.getUint32(36, Endian.host), // pbsi_uid
        zombie: data.getUint32(12, Endian.host) == _szomb, // pbsi_status
        currentUid: currentUid,
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
