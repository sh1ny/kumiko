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
/// `status-fd`, `setsid`, `open-slave`, `tiocsctty`, `dup2`, `exec`;
/// `status-timeout` when the shim reported nothing for 5 s; `status-read` when
/// the host could not read the status pipe) and [errno] the OS error (`errno`
/// on POSIX, `GetLastError` on Windows).
///
/// The spawn has done its own cleanup when this is thrown: it ended the
/// process it could identify, or, when it could not ([unconfirmedPid]),
/// sent no signal by that pid. Closing the PTY master can still hang up
/// the terminal's processes, and the host may later signal processes it
/// finds by their marker. Whether the unit's ledger row is deleted or left
/// unresolved is the host's settlement, not this error's.
class SpawnFailed implements Exception {
  const SpawnFailed(this.stage, this.errno, {this.unconfirmedPid});

  final String stage;
  final int errno;

  /// Set when the unit's start time could not be read and its absence could
  /// not be proved either (#18): a process may still run at this pid, and it
  /// was not signalled. The host keeps the unit's row unresolved. This pid is
  /// a diagnostic only, never a leader identity to signal.
  final int? unconfirmedPid;

  @override
  String toString() => unconfirmedPid == null
      ? 'spawn failed at $stage (OS error $errno)'
      : 'spawn failed at $stage (OS error $errno); unit $unconfirmedPid '
            'not confirmed gone';
}

/// A POSIX unit's start time could not be read, yet the OS did not confirm
/// that no process has its [pid] (#18). Nothing shows whether a process there
/// is the unit, so the spawn sent it no signal. The host keeps the unit's row
/// unresolved until the user confirms; [pid] is a diagnostic only.
class SpawnIdentityUnconfirmed implements Exception {
  const SpawnIdentityUnconfirmed(this.pid, this.containmentId);

  final int pid;
  final String containmentId;

  @override
  String toString() =>
      'unit $pid ($containmentId): start time unreadable and the process is '
      'not confirmed gone';
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
