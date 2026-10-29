import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// The process's own symbol table: libc on Linux, libSystem on macOS. Looked
/// up lazily, so importing this library on Windows loads nothing.
final DynamicLibrary libc = DynamicLibrary.process();

final Pointer<Int32> Function() _errnoLocation = libc
    .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
      Platform.isMacOS ? '__error' : '__errno_location',
    );

/// The calling thread's `errno`. Read it right after the failing call.
int errno() => _errnoLocation().value;

// errno values that are the same on Linux and macOS.
const int eperm = 1;
const int enoent = 2;
const int esrch = 3;
const int eacces = 13;

/// `setsid()`: -1 on failure.
final int Function() setsid = libc
    .lookupFunction<Int32 Function(), int Function()>('setsid');

final int Function(int) _getsid = libc
    .lookupFunction<Int32 Function(Int32), int Function(int)>('getsid');

/// The session id of [pid], or null when it cannot be read (gone, or in a
/// session the caller may not query). POSIX only.
int? sessionIdOf(int pid) {
  final sid = _getsid(pid);
  return sid == -1 ? null : sid;
}

final int Function(
  Pointer<Utf8>,
  Pointer<Pointer<Utf8>>,
  Pointer<Pointer<Utf8>>,
)
execve = libc
    .lookupFunction<
      Int32 Function(
        Pointer<Utf8>,
        Pointer<Pointer<Utf8>>,
        Pointer<Pointer<Utf8>>,
      ),
      int Function(
        Pointer<Utf8>,
        Pointer<Pointer<Utf8>>,
        Pointer<Pointer<Utf8>>,
      )
    >('execve');

/// `signal(sig, handler)`; pass `nullptr` for `SIG_DFL`.
final Pointer<Void> Function(int, Pointer<Void>) signal = libc
    .lookupFunction<
      Pointer<Void> Function(Int32, Pointer<Void>),
      Pointer<Void> Function(int, Pointer<Void>)
    >('signal');

final int Function(int, Pointer<Void>, Pointer<Void>) sigprocmask = libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<Void>, Pointer<Void>),
      int Function(int, Pointer<Void>, Pointer<Void>)
    >('sigprocmask');

/// `SIG_SETMASK`: 2 on Linux, 3 on macOS.
int get sigSetmask => Platform.isMacOS ? 3 : 2;

/// `fcntl(fd, cmd, int arg)`; variadic, so it needs `VarArgs` on arm64.
final int Function(int, int, int) fcntlInt = libc
    .lookupFunction<
      Int32 Function(Int32, Int32, VarArgs<(Int32,)>),
      int Function(int, int, int)
    >('fcntl');

const int fSetfd = 2;
const int fdCloexec = 1;

final int Function(int) sysconf = libc
    .lookupFunction<Int64 Function(Int32), int Function(int)>('sysconf');
