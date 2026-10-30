import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';

import 'host_faults.dart';
import 'host_log.dart';
import 'host_options.dart';
import 'ledger.dart';
import 'settler.dart';

/// What the desktop told the host in `hello` that unit launches depend on.
class DesktopInfo {
  const DesktopInfo({this.pid, this.startTime, this.outerJobHeld = false});

  final int? pid;
  final int? startTime;
  final bool outerJobHeld;
}

/// Starts, tracks and ends this host instance's units (design D2-D4).
class UnitManager {
  UnitManager({
    required this.ledger,
    required this.log,
    required this.faults,
    required this.settler,
    required this.options,
  });

  final Ledger ledger;
  final HostLog log;
  final HostFaults faults;
  final Settler settler;
  final HostOptions options;

  /// Units with a handle: running, or unresolved and retryable.
  final Map<String, LiveUnit> live = {};

  /// Set while earlier instances' rows are reconciled: launches are refused.
  bool reconciling = true;

  /// Set once the host is ending: launches are refused.
  bool shuttingDown = false;

  DesktopInfo desktop = const DesktopInfo();

  /// Called when ending units marks one unresolved, so the desktop learns
  /// the new cleanup state (`cleanup/state`).
  void Function() onUnresolved = () {};

  int _launching = 0;
  final Set<String> _ending = {};
  final Map<String, Future<UnitOutcome>> _endings = {};
  final Random _random = Random.secure();

  /// Units counting against the cap: live handles and launches in flight.
  int get unitCount => live.length + _launching;

  String _newId() {
    final bytes = List<int>.generate(8, (_) => _random.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'u${ledger.instanceId}-$hex';
  }

  /// Launches a unit running [argv] (the program first) with [target] as its
  /// working directory, and returns its containment id.
  ///
  /// Order (design D4): refusals that need no I/O, identity resolution, the
  /// gate, the pending row committed, the spawn, pid and start time recorded.
  ///
  /// [target] is the directory the unit is attributed to (the cleanup gate and
  /// the ledger); the unit runs in [workingDirectory] when given, else in
  /// [target]. [environment] overrides variables for this unit only. With
  /// [pty] the unit runs on a pseudo-terminal (its handles are in the live
  /// unit); a [SpawnFailed] is rethrown once the unit has been settled.
  Future<String> launch({
    required String target,
    required String kind,
    required List<String> argv,
    String? workingDirectory,
    Map<String, String>? environment,
    PtyOptions? pty,
  }) async {
    if (shuttingDown) {
      throw RpcException(ErrorCode.shuttingDown, 'the host is shutting down');
    }
    if (reconciling) {
      throw RpcException(
        ErrorCode.reconciling,
        'the host is reconciling earlier units; try again when it is done',
      );
    }
    if (Platform.isWindows && !(desktop.outerJobHeld && _inAnyJob())) {
      throw RpcException(
        ErrorCode.outerJobMissing,
        'the desktop does not hold this host in its job; no unit is started',
      );
    }
    if (unitCount >= options.unitCap) {
      throw RpcException(
        ErrorCode.unitCap,
        'at most ${options.unitCap} units may run',
      );
    }

    _launching++;
    try {
      final identity = directoryIdentity(target);
      if (identity is! ResolvedDirectory) {
        throw RpcException(
          ErrorCode.targetUnavailable,
          'cannot resolve target $target: ${(identity as TargetUnavailable).detail}',
          {'target': target},
        );
      }
      if (ledger.isUnresolved(identity: identity.id, path: identity.realPath)) {
        throw RpcException(
          ErrorCode.cleanupUnresolved,
          'cleanup of earlier processes in ${identity.realPath} is unresolved',
          {'target': identity.realPath},
        );
      }

      final id = _newId();
      if (faults.pendingWriteFails) {
        throw RpcException(
          ErrorCode.storeError,
          'injected pending write failure',
        );
      }
      ledger.insertPending(
        containmentId: id,
        kind: kind,
        targetPath: identity.realPath,
        targetIdentity: identity.id,
      );
      if (faults.crashAfterPendingWrite) _crash();

      final ContainedUnit unit;
      try {
        unit = await _spawn(
          id,
          argv,
          workingDirectory ?? identity.realPath,
          environment,
          pty,
        );
        if (faults.identityReadFails) await _failIdentity(unit);
      } on Object catch (e) {
        await _settleFailedSpawn(id, e);
        if (e is SpawnFailed || e is ProcessException) rethrow;
        throw RpcException(ErrorCode.internalError, 'spawn failed: $e');
      }
      if (faults.crashAfterSpawnBeforePid) _crash();

      try {
        if (faults.runningWriteFails) {
          // Late enough that the unit has started its descendants.
          await Future<void>.delayed(const Duration(seconds: 1));
          throw RpcException(
            ErrorCode.storeError,
            'injected running write failure',
          );
        }
        ledger.markRunning(id, unit.pid, unit.startTime);
      } on Object {
        // The pending row stays until the unit is settled like any other:
        // termination, the marker scan, then the row is deleted or marked
        // unresolved, which gates the workspace.
        live[id] = LiveUnit(unit);
        try {
          await end(id);
        } on Object {
          // The row stays pending; the next host reconciles it.
          log.event('unit-end-failed', ids: {'unit': id});
        }
        rethrow;
      }
      final entry = live[id] = LiveUnit(unit);
      unawaited(
        unit.exitCode.then((_) {
          entry.exited = true;
          // A unit that ends by itself goes through the same routine as one
          // the host ends, guarded by the unit's state.
          if (!_ending.contains(id) &&
              !shuttingDown &&
              ledger.unit(id)?.state == 'running') {
            unawaited(end(id).then<void>((_) {}, onError: (Object _) {}));
          }
        }),
      );
      log.event('unit-launched', ids: {'unit': id});
      return id;
    } finally {
      _launching--;
    }
  }

  Future<ContainedUnit> _spawn(
    String id,
    List<String> argv,
    String workingDirectory,
    Map<String, String>? environment,
    PtyOptions? pty,
  ) async {
    if (Platform.isWindows) {
      return spawnWindowsUnit(
        executable: argv.first,
        args: argv.sublist(1),
        containmentId: id,
        workingDirectory: workingDirectory,
        environment: environment,
        pty: pty,
      );
    }
    final unit = await spawnPosixUnit(
      shimExecutable: Platform.resolvedExecutable,
      containmentId: id,
      argv: argv,
      workingDirectory: workingDirectory,
      environment: environment,
      pty: pty,
    );
    // A PTY unit's stdio is the terminal, and its pipes were consumed by the
    // spawn. Otherwise nobody reads the unit's stdio; keep its pipes empty.
    if (pty == null) {
      unit.process.stdout.drain<void>();
      unit.process.stderr.drain<void>();
    }
    return unit;
  }

  bool _inAnyJob() {
    try {
      return isProcessHandleInJob(-1, 0); // current process, any job
    } on Object {
      return false;
    }
  }

  /// Drops the pending row of a spawn that failed. A failed `Process.start`
  /// ran nothing. On POSIX any later failure may follow a started leader
  /// whose descendants outlive it, so the marker scan ends whatever carries
  /// the unit's marker first; a survivor marks the row unresolved. On
  /// Windows a failed spawn's job ends with it.
  Future<void> _settleFailedSpawn(String id, Object error) async {
    final row = ledger.unit(id);
    final reason = error is ProcessException || row == null
        ? null
        : await settler.scanFailedSpawn(row);
    if (reason == null) {
      ledger.delete(id);
    } else {
      ledger.markUnresolved(id, reason);
      onUnresolved();
    }
  }

  /// Fails a spawn after the unit started, as `spawnPosixUnit` does when the
  /// leader's start time cannot be read: the leader is killed, descendants
  /// it started are not (test faults only). On Windows the unit's job ends
  /// with the spawn, as it does when `spawnWindowsUnit` fails.
  Future<Never> _failIdentity(ContainedUnit unit) async {
    await Future<void>.delayed(const Duration(seconds: 1));
    if (unit is WindowsUnit) {
      await unit.terminate();
      unit.close();
    } else {
      Process.killPid(unit.pid, ProcessSignal.sigkill);
    }
    throw StateError('injected: start time could not be read');
  }

  /// An abrupt end, as a crash would be (test faults only).
  Never _crash() => exit(86);

  /// Ends one unit: terminate, scan, then delete its row or mark it
  /// unresolved. A second call for a unit being ended joins the first.
  Future<UnitOutcome> end(String containmentId) {
    final running = _endings[containmentId];
    if (running != null) return running;
    if (!live.containsKey(containmentId)) {
      return Future.error(
        RpcException(ErrorCode.invalidParams, 'unknown unit $containmentId'),
      );
    }
    final batch = endUnits([containmentId]);
    return batch.then((m) => m[containmentId]!);
  }

  /// Ends units with one shared termination and scan pass. With
  /// [shuttingDown] a unit not confirmed keeps its row (see [Settler.apply]).
  Future<Map<String, UnitOutcome>> endUnits(
    Iterable<String> ids, {
    bool shuttingDown = false,
  }) async {
    final mine = [
      for (final id in ids)
        if (live.containsKey(id) && _ending.add(id)) id,
    ];
    final done = Completer<Map<String, UnitOutcome>>();
    for (final id in mine) {
      _endings[id] = done.future.then((m) => m[id]!);
    }
    try {
      final rows = <UnitRow>[for (final id in mine) ?ledger.unit(id)];
      final outcomes = await settler.settle(rows, live: live);
      settler.apply(rows, outcomes, shuttingDown: shuttingDown);
      if (!shuttingDown && outcomes.values.any((o) => !o.cleaned)) {
        onUnresolved();
      }
      for (final row in rows) {
        if (outcomes[row.containmentId]!.cleaned) _release(row.containmentId);
      }
      done.complete(outcomes);
      return outcomes;
    } on Object catch (e) {
      done.completeError(e);
      rethrow;
    } finally {
      for (final id in mine) {
        _ending.remove(id);
        unawaited(
          _endings.remove(id)!.then<void>((_) {}, onError: (Object _) {}),
        );
      }
    }
  }

  /// Drops the handle of a unit that is cleaned or confirmed.
  void _release(String id) {
    final entry = live.remove(id);
    final unit = entry?.unit;
    if (unit is WindowsUnit) unit.close();
  }

  /// Releases handles of units whose rows were deleted by a confirmation.
  void releaseAll(Iterable<String> ids) => ids.forEach(_release);

  /// Ends every unit, in parallel, within [deadline]; whatever is not
  /// confirmed by then keeps its ledger row for the next host.
  Future<void> shutdown(Duration deadline) async {
    shuttingDown = true;
    final clock = Stopwatch()..start();
    while (_launching > 0 && clock.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final ids = live.keys.toList();
    // Units already being ended are left out of the new batch; their
    // running end is joined within the same deadline.
    final inProgress = [for (final id in ids) ?_endings[id]];
    final all = Future.wait([
      endUnits(ids, shuttingDown: true),
      for (final f in inProgress) f.then<void>((_) {}, onError: (Object _) {}),
    ]);
    try {
      await all.timeout(deadline - clock.elapsed);
    } on TimeoutException {
      // At the deadline the host stops: rows stay as they are, except that
      // an unresolved one is marked.
      for (final id in ids) {
        final row = ledger.unit(id);
        if (row != null && row.state == 'unresolved') {
          ledger.markUnresolved(id, 'shutdown-deadline: ${row.reason}');
        }
      }
      log.event('shutdown-deadline', ids: {'units': ids.length});
    }
  }
}
