import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// The process's own symbol table: libc on Linux, libSystem on macOS. Looked
/// up lazily, so importing this library on Windows loads nothing.
final DynamicLibrary libc = DynamicLibrary.process();

final Pointer<Int32> Function() _errnoLocation = libc
    .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
      Platform.isMacOS ? '__error' : '__errno_location',
      isLeaf: true,
    );

/// The calling thread's `errno`. Read it right after the failing call; the
/// calls whose errno is reported (`execve`, `open`, `ioctl`, `dup2`, `fcntl`)
/// are leaf calls, so no VM transition runs in between and the first use of
/// this binding is made before them (`runUnitExec`).
int errno() => _errnoLocation().value;

// errno values that are the same on Linux and macOS.
const int eperm = 1;
const int enoent = 2;
const int esrch = 3;
const int eacces = 13;

/// `setsid()`: -1 on failure.
final int Function() setsid = libc
    .lookupFunction<Int32 Function(), int Function()>('setsid');

// mode_t is 16 bits on macOS, 32 on Linux.
final int Function(Pointer<Utf8>, int) _chmod = Platform.isMacOS
    ? libc.lookupFunction<
        Int32 Function(Pointer<Utf8>, Uint16),
        int Function(Pointer<Utf8>, int)
      >('chmod')
    : libc.lookupFunction<
        Int32 Function(Pointer<Utf8>, Uint32),
        int Function(Pointer<Utf8>, int)
      >('chmod');

/// Sets the permission bits of [path] to [mode]; false when it could not
/// (not the owner, a file system without them). POSIX only.
bool chmodPath(String path, int mode) {
  final native = path.toNativeUtf8();
  try {
    return _chmod(native, mode) == 0;
  } finally {
    malloc.free(native);
  }
}

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
    >('execve', isLeaf: true);

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
    >('fcntl', isLeaf: true);

const int fSetfd = 2;
const int fdCloexec = 1;

final int Function(int) sysconf = libc
    .lookupFunction<Int64 Function(Int32), int Function(int)>('sysconf');

// errno values used by the PTY code, the same on Linux and macOS.
const int eintr = 4;
const int eio = 5;

const int oRdwr = 2;

/// `O_NOCTTY`: 0x100 on Linux, 0x20000 on macOS.
int get oNoctty => Platform.isMacOS ? 0x20000 : 0x100;

/// `F_DUPFD_CLOEXEC`: 1030 on Linux, 67 on macOS.
int get fDupfdCloexec => Platform.isMacOS ? 67 : 1030;

/// `TIOCSWINSZ`: 0x5414 on Linux, `_IOW('t', 103, struct winsize)` on macOS.
int get tiocswinsz => Platform.isMacOS ? 0x80087467 : 0x5414;

/// `TIOCSCTTY`: 0x540E on Linux, `_IO('t', 97)` on macOS.
int get tiocsctty => Platform.isMacOS ? 0x20007461 : 0x540E;

final int Function(int) posixOpenpt = libc
    .lookupFunction<Int32 Function(Int32), int Function(int)>('posix_openpt');

final int Function(int) grantpt = libc
    .lookupFunction<Int32 Function(Int32), int Function(int)>('grantpt');

final int Function(int) unlockpt = libc
    .lookupFunction<Int32 Function(Int32), int Function(int)>('unlockpt');

/// The slave path of the pseudo-terminal whose master is [masterFd], or null
/// on failure. Linux uses the thread-safe `ptsname_r`; macOS has only
/// `ptsname`, whose static buffer is copied at once.
String? ptsnameOf(int masterFd) {
  if (Platform.isLinux) {
    final buf = calloc<Uint8>(256);
    try {
      final r = libc
          .lookupFunction<
            Int32 Function(Int32, Pointer<Uint8>, Size),
            int Function(int, Pointer<Uint8>, int)
          >('ptsname_r')(masterFd, buf, 256);
      return r == 0 ? buf.cast<Utf8>().toDartString() : null;
    } finally {
      calloc.free(buf);
    }
  }
  final p = libc
      .lookupFunction<
        Pointer<Utf8> Function(Int32),
        Pointer<Utf8> Function(int)
      >('ptsname')(masterFd);
  return p == nullptr ? null : p.toDartString();
}

/// `ioctl(fd, request, pointer)` for requests that take a pointer argument.
final int Function(int, int, Pointer<Void>) ioctlPointer = libc
    .lookupFunction<
      Int32 Function(Int32, Uint64, VarArgs<(Pointer<Void>,)>),
      int Function(int, int, Pointer<Void>)
    >('ioctl', isLeaf: true);

/// `ioctl(fd, request, int)` for requests that take an integer argument.
final int Function(int, int, int) ioctlInt = libc
    .lookupFunction<
      Int32 Function(Int32, Uint64, VarArgs<(IntPtr,)>),
      int Function(int, int, int)
    >('ioctl', isLeaf: true);

/// `open(path, flags, mode)`; `mode` is variadic.
final int Function(Pointer<Utf8>, int, int) posixOpen = libc
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Int32, VarArgs<(Int32,)>),
      int Function(Pointer<Utf8>, int, int)
    >('open', isLeaf: true);

final int Function(int) posixClose = libc
    .lookupFunction<Int32 Function(Int32), int Function(int)>('close');

final int Function(int) posixDup = libc
    .lookupFunction<Int32 Function(Int32), int Function(int)>('dup');

final int Function(int, int) posixDup2 = libc
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'dup2',
      isLeaf: true,
    );

final int Function(int, Pointer<Uint8>, int) posixRead = libc
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, Size),
      int Function(int, Pointer<Uint8>, int)
    >('read');

final int Function(int, Pointer<Uint8>, int) posixWrite = libc
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, Size),
      int Function(int, Pointer<Uint8>, int)
    >('write');

/// Sets the window size of the terminal behind [fd] (a master or slave).
/// Returns 0 or -1 (read [errno]).
int setWindowSize(int fd, int cols, int rows) {
  final ws = calloc<Uint16>(4); // struct winsize: row, col, xpixel, ypixel
  try {
    ws[0] = rows;
    ws[1] = cols;
    return ioctlPointer(fd, tiocswinsz, ws.cast<Void>());
  } finally {
    calloc.free(ws);
  }
}
