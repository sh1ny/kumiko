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
/// [args] are `<containment-id> -- <argv...>`. Never returns: it either
/// `execve`s or exits with 2 (usage), 126/127 (cannot execute) or 1 (setup
/// failure). POSIX only.
Never runUnitExec(List<String> args) {
  if (Platform.isWindows) _fail('unit-exec is POSIX only', 1);
  if (args.length < 3 || args[1] != '--' || args[0].isEmpty) {
    _fail('usage: --unit-exec <containment-id> -- <argv...>', 2);
  }
  final id = args[0];
  final argv = args.sublist(2);

  final env = Map<String, String>.of(Platform.environment);
  env[unitMarkerVariable] = id;
  final program = _resolveProgram(argv.first, env['PATH']);
  if (program == null) _fail('${argv.first}: not found', 127);

  // Prepare every native buffer before touching process state.
  final pathPtr = program.toNativeUtf8();
  final argvPtr = _stringArray(argv);
  final envpPtr = _stringArray([
    for (final e in env.entries) '${e.key}=${e.value}',
  ]);

  _markFdsCloseOnExec();
  _resetSignals();
  if (setsid() == -1) _fail('setsid failed (errno ${errno()})', 1);

  execve(pathPtr, argvPtr, envpPtr);
  final err = errno();
  _fail('execve $program failed (errno $err)', err == eacces ? 126 : 127);
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
