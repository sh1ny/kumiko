import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';

import '../host_faults.dart';
import '../host_log.dart';
import '../host_options.dart';
import '../profiles/profile_service.dart';
import '../settler.dart';
import '../unit_manager.dart';
import '../workspace_service.dart';
import 'terminal_io.dart';

/// The lifecycle of a host terminal (design T2).
enum TerminalStatus {
  /// The shell runs and its ids are out; no traffic on either channel yet.
  spawned,

  /// Attached: input is accepted and output is relayed.
  live,

  /// The shell exited; the last output is still being delivered.
  exiting,

  /// A close (or a failure) is ending the unit; output is discarded.
  closing,

  /// `terminal/exited` was sent; the channels stay open until release.
  ended,
}

/// A `ClosePseudoConsole` running, or stuck, on its closer isolate.
class _Closer {
  _Closer(this.done);
  final Future<void> done;

  Future<bool> completesWithin(Duration timeout) =>
      done.then((_) => true).timeout(timeout, onTimeout: () => false);
}

/// A console close that passed its timeout: it keeps one terminal admission
/// slot until the native call returns (design D3).
class _PendingCleanup {
  _PendingCleanup(this.terminalId, this.closer);
  final String terminalId;
  final _Closer closer;
}

class _Terminal {
  _Terminal({
    required this.id,
    required this.reservation,
    required this.unitId,
    required this.unit,
    required this.pty,
    required this.size,
  });

  final String id;
  final ChannelReservation reservation;
  final String unitId;
  final ContainedUnit unit;
  final PtyHandles pty;
  PtySize size;

  int get outputId => reservation.ids[0];
  int get inputId => reservation.ids[1];

  TerminalStatus status = TerminalStatus.spawned;
  bool attached = false;

  late PtyReaderIsolate reader;
  late PtyWriterIsolate writer;
  ChannelWriter? output;
  StreamSubscription<Uint8List>? input;
  Timer? attachTimer;

  // Exit.
  bool processExited = false;
  int? exitStatus;

  // Output relay. Messages from the reader are handled one at a time.
  Future<void> queue = Future.value();
  bool parked = true;
  bool eof = false;
  bool discarding = false;
  bool deadlineExpired = false;
  final Completer<void> outputDone = Completer();

  // The post-exit active reading clock (design D5).
  final Stopwatch readClock = Stopwatch();
  Duration activeRead = Duration.zero;
  Timer? readDeadline;

  Future<UnitOutcome>? ending;
  _Closer? closer;
  bool handlesReleased = false;

  /// How the terminal ended when it was closed rather than exited.
  TerminalExitReason closeReason = TerminalExitReason.closed;
  bool notifyOnClose = true;
}

/// The terminal service (host-terminals design D2-D5): `terminal/open`,
/// `attach`, `resize`, `close` and `release`, each terminal's PTY relayed as
/// raw bytes under credit, and its end confirmed before it is reported.
class TerminalService {
  TerminalService({
    required this.connection,
    required this.units,
    required this.profiles,
    required this.workspaces,
    required this.faults,
    required this.options,
    required this.log,
  });

  final Connection connection;
  final UnitManager units;
  final ProfileService profiles;
  final WorkspaceService workspaces;
  final HostFaults faults;
  final HostOptions options;
  final HostLog log;

  final Map<String, _Terminal> _terminals = {};
  final List<_PendingCleanup> _pending = [];
  final Random _random = Random.secure();
  int _opening = 0;
  bool _disposed = false;

  /// Console closes that passed their timeout and have not returned
  /// (Windows). Each holds one admission slot.
  int get pendingConsoleCleanups => _pending.length;

  /// Terminals the service still tracks (until released or closed).
  int get terminalCount => _terminals.length;

  int get _activeTerminals =>
      _opening +
      _terminals.values.where((t) => t.status != TerminalStatus.ended).length;

  String _newId() {
    final bytes = List<int>.generate(6, (_) => _random.nextInt(256));
    return 'term-${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }

  RpcException _unknown(String id) => RpcException(
    ErrorCode.unknownTerminal,
    'there is no terminal $id',
    {'terminalId': id},
  );

  _Terminal _require(String id) => _terminals[id] ?? (throw _unknown(id));

  // --- open ----------------------------------------------------------------

  /// `terminal/open` (design D4): reserve two channel slots, resolve the
  /// profile, directory and environment, launch the shell under a PTY and
  /// answer with the ids once the spawn is confirmed executed.
  Future<TerminalOpenResult> open(TerminalOpenParams params) async {
    final profile = await profiles.find(params.profileId);
    if (profile == null) {
      throw RpcException(
        ErrorCode.invalidParams,
        'There is no profile "${params.profileId}".',
        {'detail': 'unknown-profile'},
      );
    }
    String? workspaceDir;
    final workspaceId = params.workspaceId;
    if (workspaceId != null) {
      final row = workspaces.requireRow(workspaceId);
      final unavailable =
          workspaces.record(row).availability == Availability.unavailable ||
          directoryIdentity(row.path) is! ResolvedDirectory;
      if (unavailable) {
        throw RpcException(
          ErrorCode.workspaceUnavailable,
          'the directory of workspace ${row.label} (${row.path}) is '
          'unavailable',
          {'workspace': workspaceId, 'path': row.path},
        );
      }
      workspaceDir = row.path;
    }
    final target = workspaceDir ?? _homeDirectory();

    if (_pending.isNotEmpty &&
        _activeTerminals + _pending.length >= options.unitCap) {
      throw RpcException(
        ErrorCode.consoleCleanupPending,
        'terminal console hosts are still closing; try again shortly',
        {'pending': _pending.length},
      );
    }
    final reservation = connection.reserveChannels(2);
    _opening++;
    String? unitId;
    try {
      try {
        unitId = await units.launch(
          target: target,
          kind: 'terminal',
          argv: [profile.executable, ...profile.args],
          workingDirectory: profile.cwd ?? target,
          environment: profile.env.isEmpty ? null : profile.env,
          pty: PtyOptions(size: PtySize(params.cols, params.rows)),
        );
      } on SpawnFailed catch (e) {
        throw _spawnRefusal(e, profile.executable);
      } on ProcessException catch (e) {
        throw spawnFailed('start', e.errorCode, e.message);
      }
      final live = units.live[unitId]!;
      final unit = live.unit;
      final handles = unit is PosixUnit
          ? unit.pty
          : unit is WindowsUnit
          ? unit.pty
          : null;
      if (handles == null) throw StateError('terminal unit without a PTY');
      final t = _Terminal(
        id: _newId(),
        reservation: reservation,
        unitId: unitId,
        unit: unit,
        pty: handles,
        size: PtySize(params.cols, params.rows),
      );
      try {
        t.reader = await PtyReaderIsolate.start(
          handles.readHandle,
          onChunk: (bytes) => _enqueue(t, () => _onChunk(t, bytes)),
          onEof: () => _enqueue(t, () => _onEof(t)),
          onError: (error) => _enqueue(t, () => _onReadError(t, error)),
          suppressEof: faults.ptyNoEof,
          scripted: faults.ptyScriptedOutput ? scriptedPtyOutput : const [],
        );
        t.writer = await PtyWriterIsolate.start(handles.writeHandle);
      } on Object {
        await _abandonOpen(t);
        rethrow;
      }
      _terminals[t.id] = t;
      unawaited(unit.exitCode.then((code) => _onProcessExit(t, code)));
      t.attachTimer = Timer(options.attachTimeout, () {
        if (t.status == TerminalStatus.spawned) {
          log.event('terminal-attach-timeout', ids: {'terminal': t.id});
          _beginClose(t, notify: false);
        }
      });
      log.event('terminal-open', ids: {'terminal': t.id, 'unit': unitId});
      return TerminalOpenResult(
        terminalId: t.id,
        outputChannel: t.outputId,
        inputChannel: t.inputId,
      );
    } on Object {
      reservation.release();
      rethrow;
    } finally {
      _opening--;
    }
  }

  /// A terminal whose isolates could not start: ended like any unit, then its
  /// handles closed.
  Future<void> _abandonOpen(_Terminal t) async {
    try {
      await units.end(t.unitId);
    } on Object {
      // The row stays for the next host to reconcile.
    }
    if (Platform.isWindows && t.pty.console != null) {
      (await ConsoleCloser.start(t.pty.console!)).done.ignore();
    }
    closePtyHandle(t.pty.readHandle);
    closePtyHandle(t.pty.writeHandle);
  }

  String _homeDirectory() {
    final home =
        Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
    if (home == null || home.isEmpty) {
      throw RpcException(
        ErrorCode.targetUnavailable,
        'the home directory is not known',
      );
    }
    return home;
  }

  RpcException _spawnRefusal(SpawnFailed e, String executable) {
    final missing = Platform.isWindows
        ? e.stage == 'CreateProcessW' && (e.errno == 2 || e.errno == 3)
        : e.stage == 'exec' && e.errno == 2;
    if (missing) {
      return executableNotFound(
        executable,
        osError: e.errno,
        message: 'Executable not found: $executable',
      );
    }
    return spawnFailed(e.stage, e.errno, 'Cannot start $executable: $e');
  }

  // --- attach ----------------------------------------------------------------

  /// `terminal/attach`: register both channels, grant the input window and
  /// start relaying output (design D4).
  Future<void> attach(TerminalAttachParams params) async {
    final t = _require(params.terminalId);
    if (t.status != TerminalStatus.spawned) {
      throw RpcException(
        ErrorCode.invalidParams,
        'terminal ${t.id} is already attached or ending',
      );
    }
    t.attachTimer?.cancel();
    t.output = connection.attachOutbound(t.outputId);
    t.attached = true;
    t.input = connection
        .attachInbound(t.inputId)
        .listen((bytes) => _onInput(t, bytes));
    t.status = TerminalStatus.live;
    t.parked = false;
    t.reader.next();
    if (t.processExited) _startExiting(t);
  }

  void _onInput(_Terminal t, Uint8List bytes) {
    final subscription = t.input;
    if (subscription == null || t.status == TerminalStatus.closing) return;
    // One chunk is with the writer at a time. While it is there the
    // subscription is paused, so credit stops returning (design D3).
    subscription.pause();
    t.writer.write(bytes).then<void>(
      (_) {
        if (t.input != null && t.status != TerminalStatus.closing) {
          subscription.resume();
        }
      },
      onError: (Object e) {
        if (t.status == TerminalStatus.live ||
            t.status == TerminalStatus.exiting) {
          _ioFailure(t, 'input: $e');
        }
      },
    );
  }

  // --- output --------------------------------------------------------------

  void _enqueue(_Terminal t, Future<void> Function() job) {
    t.queue = t.queue.then((_) => job()).catchError((Object e) {
      // A failed relay step ends the terminal below; nothing to add here.
    });
  }

  Future<void> _onChunk(_Terminal t, Uint8List bytes) async {
    t.parked = true;
    _stopReadClock(t);
    if (t.discarding || t.deadlineExpired) return;
    try {
      // Completes when the chunk is on the wire; until then the reader is
      // parked, so at most this chunk is ever held beyond the channel window.
      await t.output!.write(bytes);
    } on ChannelClosedException {
      if (t.status == TerminalStatus.live ||
          t.status == TerminalStatus.exiting) {
        _ioFailure(t, 'output channel closed');
      }
      return;
    }
    if (t.discarding || t.deadlineExpired) return;
    t.parked = false;
    t.reader.next();
    _startReadClock(t);
  }

  Future<void> _onEof(_Terminal t) async {
    t.eof = true;
    t.parked = true;
    _stopReadClock(t);
    if (!t.outputDone.isCompleted) t.outputDone.complete();
  }

  Future<void> _onReadError(_Terminal t, String error) async {
    log.event('terminal-read-failed', code: error, ids: {'terminal': t.id});
    if (t.status == TerminalStatus.live || t.status == TerminalStatus.exiting) {
      _ioFailure(t, 'read: $error');
    }
  }

  void _startReadClock(_Terminal t) {
    if (!t.processExited ||
        t.readClock.isRunning ||
        t.eof ||
        t.parked ||
        t.deadlineExpired ||
        t.discarding) {
      return;
    }
    t.readClock
      ..reset()
      ..start();
    t.readDeadline?.cancel();
    t.readDeadline = Timer(
      options.postExitReadDeadline - t.activeRead,
      () => _enqueue(t, () => _onReadDeadline(t)),
    );
  }

  void _stopReadClock(_Terminal t) {
    if (!t.readClock.isRunning) return;
    t.activeRead += t.readClock.elapsed;
    t.readClock.stop();
    t.readDeadline?.cancel();
  }

  Future<void> _onReadDeadline(_Terminal t) async {
    if (t.eof || t.parked || t.discarding) return;
    // 1 s of active reading after the exit without reaching the end: stop
    // reading; what was read has been (or is being) flushed (design D5).
    t.deadlineExpired = true;
    t.readClock.stop();
    t.reader.discard();
    log.event('terminal-read-deadline', ids: {'terminal': t.id});
    if (!t.outputDone.isCompleted) t.outputDone.complete();
  }

  // --- exit ----------------------------------------------------------------

  void _onProcessExit(_Terminal t, int code) {
    if (_disposed) return;
    t.processExited = true;
    t.exitStatus = code;
    if (t.status == TerminalStatus.live) _startExiting(t);
    // A shell that exited before the attach is reported once attached.
  }

  void _startExiting(_Terminal t) {
    t.status = TerminalStatus.exiting;
    unawaited(_end(t));
    if (Platform.isWindows) _startCloser(t);
    _startReadClock(t);
    unawaited(_runExit(t));
  }

  Future<void> _runExit(_Terminal t) async {
    try {
      await t.outputDone.future;
      // Messages of the reader are handled in order, so every chunk read has
      // been flushed by now.
      await t.queue;
      if (t.status != TerminalStatus.exiting) return;
      final outcome = await _end(t);
      if (t.status != TerminalStatus.exiting || _disposed) return;
      if (outcome.cleaned) {
        _endTerminal(
          t,
          TerminalExited(
            terminalId: t.id,
            status: t.exitStatus,
            reason: TerminalExitReason.exited,
            outputComplete: !t.deadlineExpired,
          ),
        );
      } else {
        _failTerminal(t, outcome.reason ?? 'cleanup-unresolved');
      }
    } on Object catch (e) {
      log.event('terminal-exit-failed', code: '$e', ids: {'terminal': t.id});
    }
  }

  /// The end routine for the terminal's unit, within the overall settlement
  /// deadline (design Resource Bounds). Joins an end already running.
  Future<UnitOutcome> _end(_Terminal t) => t.ending ??= () async {
    if (!units.live.containsKey(t.unitId)) return const UnitOutcome.cleaned();
    try {
      return await units.end(t.unitId).timeout(options.settleDeadline);
    } on TimeoutException {
      if (units.ledger.unit(t.unitId) != null) {
        units.ledger.markUnresolved(t.unitId, 'settlement-deadline');
        units.onUnresolved();
      }
      return const UnitOutcome.unresolved('settlement-deadline');
    } on Object catch (e) {
      return UnitOutcome.unresolved('end-failed: $e');
    }
  }();

  /// Sends `terminal/exited` and keeps the channels until release.
  void _endTerminal(_Terminal t, TerminalExited exited) {
    t.status = TerminalStatus.ended;
    t.attachTimer?.cancel();
    t.readDeadline?.cancel();
    connection.notify(Method.terminalExited, exited.toJson());
    log.event(
      'terminal-exited',
      code: exited.reason.wire,
      ids: {'terminal': t.id},
    );
    _releaseHandles(t);
  }

  /// Cleanup could not be confirmed: report it and let go of the channels.
  void _failTerminal(_Terminal t, String reason) {
    t.attachTimer?.cancel();
    t.readDeadline?.cancel();
    connection.notify(
      Method.terminalCloseFailed,
      TerminalCloseFailed(terminalId: t.id, reason: reason).toJson(),
    );
    log.event('terminal-close-failed', code: reason, ids: {'terminal': t.id});
    _forget(t);
    _closeChannels(t);
    _releaseHandles(t);
  }

  // --- resize ----------------------------------------------------------------

  void resize(TerminalResizeParams params) {
    final t = _require(params.terminalId);
    switch (t.status) {
      case TerminalStatus.spawned || TerminalStatus.live:
        break;
      case TerminalStatus.exiting:
        return;
      case TerminalStatus.closing || TerminalStatus.ended:
        throw _unknown(t.id);
    }
    final size = PtySize(params.cols, params.rows);
    try {
      ptyResize(t.pty, size);
    } on PtyIoException catch (e) {
      throw RpcException(ErrorCode.internalError, 'resize failed: $e');
    }
    t.size = size;
  }

  // --- close ---------------------------------------------------------------

  /// `terminal/close`: acknowledged as soon as the terminal is `closing`;
  /// termination completes later and is reported by `terminal/exited` or
  /// `terminal/closeFailed`.
  void close(TerminalCloseParams params) {
    final t = _require(params.terminalId);
    switch (t.status) {
      case TerminalStatus.spawned ||
          TerminalStatus.live ||
          TerminalStatus.exiting:
        _beginClose(t);
      case TerminalStatus.closing:
        break;
      case TerminalStatus.ended:
        throw _unknown(t.id);
    }
  }

  /// `terminal/release`: the desktop consumed everything after
  /// `terminal/exited`; the channels close and the terminal is forgotten.
  void release(TerminalReleaseParams params) {
    final t = _require(params.terminalId);
    switch (t.status) {
      case TerminalStatus.ended:
        _forget(t);
        _closeChannels(t);
      case TerminalStatus.spawned:
        throw RpcException(
          ErrorCode.notAttached,
          'terminal ${t.id} was never attached',
        );
      case TerminalStatus.live ||
          TerminalStatus.exiting ||
          TerminalStatus.closing:
        throw RpcException(
          ErrorCode.invalidParams,
          'terminal ${t.id} has not exited',
        );
    }
  }

  void _ioFailure(_Terminal t, String detail) {
    log.event('terminal-io-failed', code: detail, ids: {'terminal': t.id});
    _beginClose(t, reason: TerminalExitReason.ioError);
  }

  /// Enters `closing`: the reader switches to discard, the unit is ended
  /// within the settlement deadline and the result reported.
  void _beginClose(
    _Terminal t, {
    bool notify = true,
    TerminalExitReason reason = TerminalExitReason.closed,
  }) {
    if (_disposed ||
        t.status == TerminalStatus.closing ||
        t.status == TerminalStatus.ended) {
      return;
    }
    t.status = TerminalStatus.closing;
    t.closeReason = reason;
    t.notifyOnClose = notify;
    t.discarding = true;
    t.attachTimer?.cancel();
    t.readDeadline?.cancel();
    t.reader.discard();
    // Wake a coroutine waiting for the end of the output.
    if (!t.outputDone.isCompleted) t.outputDone.complete();
    unawaited(_runClose(t));
  }

  Future<void> _runClose(_Terminal t) async {
    final clock = Stopwatch()..start();
    try {
      final outcome = await _end(t);
      if (Platform.isWindows) {
        _startCloser(t);
        final remaining = options.settleDeadline - clock.elapsed;
        final wait = remaining < options.consoleCloseTimeout
            ? remaining
            : options.consoleCloseTimeout;
        if (wait > Duration.zero) await t.closer!.completesWithin(wait);
      }
      if (_disposed) return;
      if (outcome.cleaned) {
        if (t.notifyOnClose || t.attached) {
          connection.notify(
            Method.terminalExited,
            TerminalExited(
              terminalId: t.id,
              status: t.exitStatus,
              reason: t.closeReason,
              outputComplete: true,
            ).toJson(),
          );
        }
        log.event(
          'terminal-closed',
          code: t.closeReason.wire,
          ids: {'terminal': t.id},
        );
        _forget(t);
        _closeChannels(t);
        _releaseHandles(t);
      } else {
        _failTerminal(t, outcome.reason ?? 'cleanup-unresolved');
      }
    } on Object catch (e) {
      log.event('terminal-close-error', code: '$e', ids: {'terminal': t.id});
    }
  }

  void _forget(_Terminal t) => _terminals.remove(t.id);

  void _closeChannels(_Terminal t) {
    t.input?.cancel().ignore();
    t.input = null;
    if (t.attached) {
      connection.closeChannel(t.outputId).ignore();
      connection.closeChannel(t.inputId).ignore();
    } else {
      t.reservation.release();
    }
  }

  // --- handles -------------------------------------------------------------

  void _startCloser(_Terminal t) {
    if (t.closer != null) return;
    final hpcon = t.pty.console;
    if (hpcon == null) return;
    final Future<void> done;
    if (faults.consoleCloseHangs) {
      done = Completer<void>().future; // an injected stuck close
    } else {
      done = ConsoleCloser.start(hpcon).then((c) => c.done);
    }
    final closer = t.closer = _Closer(done);
    unawaited(() async {
      if (await closer.completesWithin(options.consoleCloseTimeout)) return;
      final entry = _PendingCleanup(t.id, closer);
      _pending.add(entry);
      log.event('console-cleanup-pending', ids: {'terminal': t.id});
      await closer.done.then((_) {}, onError: (Object _) {});
      _pending.remove(entry);
      log.event('console-cleanup-done', ids: {'terminal': t.id});
    }());
  }

  /// Stops the writer and, once the reader, the writer and the console close
  /// are done, closes the PTY handles. A reader stuck in a native read keeps
  /// its handle (nothing may close it under a blocked read) until it returns
  /// or the host exits.
  void _releaseHandles(_Terminal t) {
    if (t.handlesReleased) return;
    t.handlesReleased = true;
    t.writer.stop();
    if (Platform.isWindows) _startCloser(t);
    unawaited(() async {
      await t.closer?.done.then((_) {}, onError: (Object _) {});
      await Future.wait([t.reader.exited, t.writer.exited]);
      closePtyHandle(t.pty.readHandle);
      closePtyHandle(t.pty.writeHandle);
    }());
  }

  /// The connection ended: the host's shutdown ends every unit; nothing more
  /// is reported to a desktop that is gone.
  void dispose() {
    _disposed = true;
    for (final t in _terminals.values) {
      t.attachTimer?.cancel();
      t.readDeadline?.cancel();
      t.discarding = true;
      t.reader.discard();
    }
  }
}
