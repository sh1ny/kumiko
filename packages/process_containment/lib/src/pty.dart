/// A terminal size in character cells.
class PtySize {
  const PtySize(this.cols, this.rows);

  final int cols;
  final int rows;

  /// The Windows `COORD` for this size: columns in the low 16 bits, rows in
  /// the high 16 bits.
  int get packedCoord => (cols & 0xFFFF) | ((rows & 0xFFFF) << 16);

  @override
  bool operator ==(Object other) =>
      other is PtySize && other.cols == cols && other.rows == rows;

  @override
  int get hashCode => Object.hash(cols, rows);

  @override
  String toString() => '${cols}x$rows';
}

/// Asks [spawnPosixUnit] or [spawnWindowsUnit] to attach the unit to a new
/// pseudo-terminal of [size] instead of giving it piped (POSIX) or `NUL`
/// (Windows) stdio.
class PtyOptions {
  const PtyOptions({required this.size, this.slavePathForTesting});

  final PtySize size;

  /// Test hook (POSIX): the slave path handed to the shim instead of the real
  /// one, to inject a slave-open failure.
  final String? slavePathForTesting;
}

/// A unit could not be started. [stage] names the failing step (POSIX shim:
/// `status-fd`, `setsid`, `open-slave`, `tiocsctty`, `dup2`, `exec`, or
/// `status-timeout` when the shim reported nothing for 5 s) and [errno] the OS
/// error (`errno` on POSIX, `GetLastError` on Windows). The unit has been
/// settled when this is thrown.
class SpawnFailed implements Exception {
  const SpawnFailed(this.stage, this.errno);

  final String stage;
  final int errno;

  @override
  String toString() => 'spawn failed at $stage (OS error $errno)';
}

/// The native handles of one pseudo-terminal, as plain integers: they are
/// process-wide, so they can be sent to the reader, writer and closer isolates
/// (design D3), each of which owns the handle it uses.
class PtyHandles {
  const PtyHandles({
    required this.readHandle,
    required this.writeHandle,
    this.console,
  });

  /// Output side: the master descriptor (POSIX) or the read end of the output
  /// pipe (Windows). Read it with [ptyReadChunk].
  final int readHandle;

  /// Input side: a `dup` of the master descriptor (POSIX) or the write end of
  /// the input pipe (Windows). Write it with [ptyWrite].
  final int writeHandle;

  /// The `HPCON` (Windows only; null on POSIX).
  final int? console;
}

/// A PTY read or write failed for a reason other than end of output.
class PtyIoException implements Exception {
  const PtyIoException(this.call, this.code);

  final String call;
  final int code;

  @override
  String toString() => '$call failed with OS error $code';
}

/// Upper bound of one [ptyReadChunk] result and of one [ptyWrite] call's
/// intended size (design D3 and ADR 0002 frames).
const int ptyChunkSize = 64 * 1024;
