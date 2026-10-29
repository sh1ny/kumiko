import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'libc.dart';

/// The name of the environment variable that marks a unit's processes.
const String unitMarkerVariable = 'KUMIKO_UNIT';

/// The `--unit-exec` shim (design D2): runs in a Dart process that
/// `Process.start` created, becomes a session leader and replaces itself with
/// the target program. The pid survives, so the pid recorded after
/// `Process.start` is the unit's own, and `dart:io` keeps reaping the exit
/// status and owning stdio.
///
/// [args] are `<containment-id> [--pty <slave>] -- <argv...>`. Never returns:
/// it either `execve`s or exits with 2 (usage), 126/127 (cannot execute) or 1
/// (setup failure). POSIX only.
///
/// With `--pty <slave>` the shim's stdout pipe from `Process.start` becomes a
/// *status pipe*: it is moved to a high close-on-exec descriptor, and the
/// slave terminal (opened after `setsid`, made the controlling terminal with
/// `TIOCSCTTY`) is `dup2`ed onto 0, 1 and 2. A failing step writes one JSON
/// line `{"stage": "<step>", "errno": N}` to the status pipe and exits; a
/// successful `execve` closes it with nothing written, which the host reads as
/// "the program started". Stages: `status-fd`, `exec`, `setsid`, `open-slave`,
/// `tiocsctty`, `dup2`.
Never runUnitExec(List<String> args) {
  if (Platform.isWindows) _fail('unit-exec is POSIX only', 1);
  const usage =
      'usage: --unit-exec <containment-id> [--pty <slave>] -- '
      '<argv...>';
  if (args.isEmpty || args[0].isEmpty) _fail(usage, 2);
  final slave = args.length > 2 && args[1] == '--pty' ? args[2] : null;
  final dashes = slave == null ? 1 : 3;
  if (args.length < dashes + 2 || args[dashes] != '--') _fail(usage, 2);
  final id = args[0];
  final argv = args.sublist(dashes + 1);
  errno(); // bind it now; the first use must not sit between a call and its errno

  var statusFd = -1;
  if (slave != null) {
    // Keep the pipe the host reads, before fd 1 is replaced.
    for (final floor in const [200, 64, 10]) {
      statusFd = fcntlInt(1, fDupfdCloexec, floor);
      if (statusFd != -1) break;
    }
    if (statusFd == -1) {
      _fail('status pipe: fcntl failed (errno ${errno()})', 1);
    }
  }

  final env = Map<String, String>.of(Platform.environment);
  env[unitMarkerVariable] = id;
  final program = _resolveProgram(argv.first, env['PATH']);
  if (program == null) {
    if (slave != null) _statusFail(statusFd, 'exec', enoent, 127);
    _fail('${argv.first}: not found', 127);
  }

  // Prepare every native buffer before touching process state.
  final pathPtr = program.toNativeUtf8();
  final argvPtr = _stringArray(argv);
  final envpPtr = _stringArray([
    for (final e in env.entries) '${e.key}=${e.value}',
  ]);
  final slavePtr = slave?.toNativeUtf8();

  _markFdsCloseOnExec();
  _resetSignals();
  if (setsid() == -1) {
    final err = errno();
    if (slave != null) _statusFail(statusFd, 'setsid', err, 1);
    _fail('setsid failed (errno $err)', 1);
  }

  if (slavePtr != null) {
    // No O_NOCTTY: the open may already make it the controlling terminal on
    // Linux and macOS; TIOCSCTTY below makes that explicit and certain.
    final tty = posixOpen(slavePtr, oRdwr, 0);
    if (tty == -1) _statusFail(statusFd, 'open-slave', errno(), 1);
    if (ioctlInt(tty, tiocsctty, 0) == -1) {
      _statusFail(statusFd, 'tiocsctty', errno(), 1);
    }
    for (var fd = 0; fd <= 2; fd++) {
      if (posixDup2(tty, fd) == -1) _statusFail(statusFd, 'dup2', errno(), 1);
    }
    if (tty > 2) posixClose(tty);
  }

  execve(pathPtr, argvPtr, envpPtr);
  final err = errno();
  final code = err == eacces ? 126 : 127;
  if (slave != null) _statusFail(statusFd, 'exec', err, code);
  _fail('execve $program failed (errno $err)', code);
}

/// Reports a failed step on the status pipe and exits.
Never _statusFail(int statusFd, String stage, int err, int code) {
  final line = jsonEncode({'stage': stage, 'errno': err});
  final bytes = utf8.encode('$line${String.fromCharCode(10)}');
  final buf = calloc<Uint8>(bytes.length);
  buf.asTypedList(bytes.length).setAll(0, bytes);
  var offset = 0;
  while (offset < bytes.length) {
    final n = posixWrite(statusFd, buf + offset, bytes.length - offset);
    if (n < 0 && errno() == eintr) continue;
    if (n <= 0) break;
    offset += n;
  }
  exit(code);
}

Never _fail(String message, int code) {
  stderr.writeln('unit-exec: $message');
  exit(code);
}

String? _resolveProgram(String name, String? path) {
  if (name.contains('/')) return name;
  for (final dir in (path ?? '/usr/bin:/bin').split(':')) {
    if (dir.isEmpty) continue;
    final candidate = '$dir/$name';
    if (FileSystemEntity.isFileSync(candidate)) return candidate;
  }
  return null;
}

Pointer<Pointer<Utf8>> _stringArray(List<String> items) {
  final array = calloc<Pointer<Utf8>>(items.length + 1);
  for (var i = 0; i < items.length; i++) {
    array[i] = items[i].toNativeUtf8();
  }
  array[items.length] = nullptr;
  return array;
}

/// Marks every descriptor above 2 close-on-exec, so the kernel closes them
/// atomically inside `execve`. Closing them one by one first would pull
/// descriptors out from under the VM's live event-handler threads.
void _markFdsCloseOnExec() {
  final fds = <int>[];
  try {
    final dir = Directory(Platform.isLinux ? '/proc/self/fd' : '/dev/fd');
    for (final entry in dir.listSync(followLinks: false)) {
      final fd = int.tryParse(
        entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
      );
      if (fd != null && fd > 2) fds.add(fd);
    }
  } on FileSystemException {
    // Fall back to the descriptor limit.
    final open = sysconf(Platform.isMacOS ? 5 : 4); // _SC_OPEN_MAX
    final limit = open < 0 || open > 65536 ? 65536 : open;
    for (var fd = 3; fd < limit; fd++) {
      fds.add(fd);
    }
  }
  for (final fd in fds) {
    fcntlInt(fd, fSetfd, fdCloexec); // EBADF for the listing's own handle
  }
}

/// Empties the signal mask of this thread and puts every signal back to its
/// default action: the VM ignores `SIGPIPE`, and an ignored signal would
/// otherwise survive `execve` into the unit.
void _resetSignals() {
  final empty = calloc<Uint8>(256); // zero bytes are an empty sigset_t
  sigprocmask(sigSetmask, empty.cast<Void>(), nullptr);
  calloc.free(empty);
  for (var sig = 1; sig <= 31; sig++) {
    signal(sig, nullptr); // SIGKILL/SIGSTOP fail harmlessly
  }
}
