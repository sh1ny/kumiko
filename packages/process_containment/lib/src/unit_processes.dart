import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'fs_identity.dart';
import 'libc.dart';
import 'posix_process_table.dart';
import 'process_table.dart';
import 'windows_api.dart';

/// The identity a unit's leader is expected to run while it is still the
/// shell (ADR 0014 decision 5): fixed before the spawn from the executable the
/// host resolves for `execve`, never observed after start. Linux compares the
/// file's device and inode, macOS its canonical path. A plain value, so it
/// crosses isolates.
class ExecutableIdentity {
  const ExecutableIdentity(this.value);

  /// `dev:ino` on Linux, the `realpath` on macOS.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is ExecutableIdentity && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ExecutableIdentity($value)';
}

/// The identity of the executable at [path], symbolic links resolved, or
/// null when it cannot be read. Always null on Windows, which has no `exec`:
/// a Windows unit's leader is always its shell.
ExecutableIdentity? executableIdentity(String path) {
  if (Platform.isWindows) return null;
  final value = Platform.isMacOS ? posixRealPath(path) : posixFileId(path);
  return value == null ? null : ExecutableIdentity(value);
}

/// What a unit's processes are read from: plain values, so a probe can be
/// sent to a worker isolate.
class UnitProbe {
  const UnitProbe({required this.leaderPid, this.job, this.expectedLeader});

  /// The unit's own process (`ContainedUnit.pid`): the session leader on
  /// POSIX, the process created into the job on Windows.
  final int leaderPid;

  /// Windows: the unit's job handle. Handles are process-wide, so any
  /// isolate may query it while the owner keeps it open.
  final int? job;

  /// POSIX: the leader's expected image (see [executableIdentity]). Without
  /// one the leader reads [LeaderState.unreadable].
  final ExecutableIdentity? expectedLeader;
}

/// What the unit's leader runs at the read.
enum LeaderState {
  /// The shell's own image (always on Windows while the leader lives).
  shell,

  /// Another image: the shell was replaced by `exec`.
  replaced,

  /// The image could not be read or there is nothing to compare it with.
  unreadable,

  /// The leader has exited (or is a zombie).
  gone,
}

/// One read of a unit's processes.
class UnitProcesses {
  const UnitProcesses({
    required this.leader,
    required this.others,
    this.leaderName,
  });

  final LeaderState leader;

  /// The leader's image name when [leader] is [LeaderState.replaced].
  final String? leaderName;

  /// Every live process of the unit besides its leader, zombies excluded, in
  /// ascending pid order.
  final List<int> others;
}

/// Reads the processes of the unit [probe] describes (ADR 0014 decision 4):
/// the members of its job (Windows) or its session (Linux `/proc/<pid>/stat`,
/// macOS `getsid`). Throws [ProcessTableUnlistable] when the membership
/// cannot be listed at all.
UnitProcesses readUnitProcesses(UnitProbe probe) {
  if (Platform.isWindows) return _readWindows(probe);
  final members = Platform.isMacOS
      ? _macSessionMembers(probe.leaderPid)
      : _linuxSessionMembers(probe.leaderPid);
  final others = [
    for (final pid in members)
      if (pid != probe.leaderPid) pid,
  ]..sort();
  if (!members.contains(probe.leaderPid)) {
    return UnitProcesses(leader: LeaderState.gone, others: others);
  }
  final expected = probe.expectedLeader;
  if (expected == null) {
    return UnitProcesses(leader: LeaderState.unreadable, others: others);
  }
  final actual = Platform.isMacOS
      ? _macImagePath(probe.leaderPid)
      : posixFileId('/proc/${probe.leaderPid}/exe');
  if (actual == null) {
    return UnitProcesses(leader: LeaderState.unreadable, others: others);
  }
  if (actual == expected.value) {
    return UnitProcesses(leader: LeaderState.shell, others: others);
  }
  return UnitProcesses(
    leader: LeaderState.replaced,
    leaderName: processImageName(probe.leaderPid),
    others: others,
  );
}

/// The image basename of [pid]: `QueryFullProcessImageNameW` on Windows,
/// `/proc/<pid>/comm` on Linux, `proc_name` on macOS. Never arguments. Null
/// when it cannot be read.
String? processImageName(int pid) {
  if (Platform.isWindows) {
    final path = _windowsImagePath(pid);
    if (path == null) return null;
    final cut = path.lastIndexOf(r'\');
    return cut < 0 ? path : path.substring(cut + 1);
  }
  if (Platform.isMacOS) return _macName(pid);
  try {
    final comm = File('/proc/$pid/comm').readAsStringSync();
    final name = comm.endsWith('\n')
        ? comm.substring(0, comm.length - 1)
        : comm;
    return name.isEmpty ? null : name;
  } on FileSystemException {
    return null;
  }
}

// ---- Windows ----

const int _jobObjectBasicProcessIdList = 3;

UnitProcesses _readWindows(UnitProbe probe) {
  final job = probe.job;
  if (job == null) {
    throw const ProcessTableUnlistable('no job handle for the unit');
  }
  final live = _jobProcessIds(job).where(_windowsAlive).toList();
  final others = [
    for (final pid in live)
      if (pid != probe.leaderPid) pid,
  ]..sort();
  return UnitProcesses(
    leader: live.contains(probe.leaderPid)
        ? LeaderState.shell
        : LeaderState.gone,
    others: others,
  );
}

/// `JobObjectBasicProcessIdList`: the pids assigned to [job], nested jobs
/// included, grown until the list fits.
List<int> _jobProcessIds(int job) {
  var capacity = 64;
  for (var attempt = 0; attempt < 6; attempt++) {
    // JOBOBJECT_BASIC_PROCESS_ID_LIST: two DWORDs, then ULONG_PTR ids (x64).
    final size = 8 + capacity * 8;
    final buffer = calloc<Uint8>(size);
    try {
      final ok = queryInformationJobObject(
        job,
        _jobObjectBasicProcessIdList,
        buffer.cast<Void>(),
        size,
        nullptr,
      );
      final assigned = buffer.cast<Uint32>().value;
      if (ok == 0) {
        final code = getLastError();
        if (code != errorMoreData) {
          throw ProcessTableUnlistable('QueryInformationJobObject $code');
        }
        capacity = assigned > capacity ? assigned + 16 : capacity * 2;
        continue;
      }
      final listed = (buffer + 4).cast<Uint32>().value;
      final ids = (buffer + 8).cast<Uint64>();
      return [for (var i = 0; i < listed; i++) ids[i]];
    } finally {
      calloc.free(buffer);
    }
  }
  throw const ProcessTableUnlistable('job process list kept growing');
}

/// An exited process can stay listed while handles to it are open.
bool _windowsAlive(int pid) {
  final process = openProcessNative(processQueryLimitedInformation, 0, pid);
  if (process == 0) return true; // exists but unopenable: counted, safe side
  try {
    final code = calloc<Uint32>();
    try {
      return getExitCodeProcess(process, code) == 0 ||
          code.value == stillActive;
    } finally {
      calloc.free(code);
    }
  } finally {
    closeHandleNative(process);
  }
}

String? _windowsImagePath(int pid) {
  final process = openProcessNative(processQueryLimitedInformation, 0, pid);
  if (process == 0) return null;
  final buffer = calloc<Uint16>(32768);
  final length = calloc<Uint32>()..value = 32768;
  try {
    if (queryFullProcessImageName(process, 0, buffer.cast(), length) == 0) {
      return null;
    }
    return String.fromCharCodes(buffer.asTypedList(length.value));
  } finally {
    calloc.free(buffer);
    calloc.free(length);
    closeHandleNative(process);
  }
}

// ---- Linux ----

/// Live processes whose session (`/proc/<pid>/stat` field 6) is [sid].
List<int> _linuxSessionMembers(int sid) {
  final table = PosixProcessTable();
  final members = <int>[];
  for (final pid in table.listPids()) {
    final String stat;
    try {
      stat = File('/proc/$pid/stat').readAsStringSync();
    } on FileSystemException {
      continue; // gone meanwhile
    }
    // "pid (comm) S ppid pgrp session ..."; comm may hold spaces and ')'.
    final rest = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
    if (rest.length < 4) continue;
    final state = rest[0];
    if (state == 'Z' || state == 'X') continue;
    if (int.tryParse(rest[3]) == sid) members.add(pid);
  }
  return members;
}

// ---- macOS ----

typedef _ProcBufferNative = Int32 Function(Int32, Pointer<Uint8>, Uint32);
typedef _ProcBufferDart = int Function(int, Pointer<Uint8>, int);

final _ProcBufferDart _procPidpath = libc
    .lookupFunction<_ProcBufferNative, _ProcBufferDart>('proc_pidpath');
final _ProcBufferDart _procName = libc
    .lookupFunction<_ProcBufferNative, _ProcBufferDart>('proc_name');

const int _procPidpathinfoMaxsize = 4096;

/// Live processes whose `getsid` is [sid].
List<int> _macSessionMembers(int sid) {
  final table = PosixProcessTable();
  final members = <int>[];
  for (final pid in table.listPids()) {
    if (sessionIdOf(pid) != sid) continue;
    try {
      final s = table.snapshot(pid);
      if (s == null || s.zombie) continue;
    } on ProcessReadDenied {
      // Our own session's member we cannot inspect: counted, safe side.
    }
    members.add(pid);
  }
  return members;
}

/// The canonical path of [pid]'s image (`proc_pidpath`, then `realpath`).
String? _macImagePath(int pid) {
  final buffer = calloc<Uint8>(_procPidpathinfoMaxsize);
  try {
    final n = _procPidpath(pid, buffer, _procPidpathinfoMaxsize);
    if (n <= 0) return null;
    final path = buffer.cast<Utf8>().toDartString(length: n);
    return posixRealPath(path) ?? path;
  } finally {
    calloc.free(buffer);
  }
}

String? _macName(int pid) {
  final buffer = calloc<Uint8>(64);
  try {
    final n = _procName(pid, buffer, 64);
    if (n <= 0) return null;
    return buffer.cast<Utf8>().toDartString(length: n);
  } finally {
    calloc.free(buffer);
  }
}
