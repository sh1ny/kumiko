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
  Future<String> launch({
    required String target,
    required String kind,
    required List<String> argv,
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
        unit = await _spawn(id, argv, identity.realPath);
      } on Object catch (e) {
        ledger.delete(id);
        throw RpcException(ErrorCode.internalError, 'spawn failed: $e');
      }
      if (faults.crashAfterSpawnBeforePid) _crash();

      try {
        ledger.markRunning(id, unit.pid, unit.startTime);
      } on Object {
        // Nothing records the process: end it and drop the pending row.
        unawaited(unit.terminate());
        ledger.delete(id);
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
  ) async {
    if (Platform.isWindows) {
      return spawnWindowsUnit(
        executable: argv.first,
        args: argv.sublist(1),
        containmentId: id,
        workingDirectory: workingDirectory,
      );
    }
    final unit = await spawnPosixUnit(
      shimExecutable: Platform.resolvedExecutable,
      containmentId: id,
      argv: argv,
      workingDirectory: workingDirectory,
    );
    // Nobody reads the unit's stdio in this change; keep its pipes empty.
    unit.process.stdout.drain<void>();
    unit.process.stderr.drain<void>();
    return unit;
  }

  bool _inAnyJob() {
    try {
      return isProcessHandleInJob(-1, 0); // current process, any job
    } on Object {
      return false;
    }
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
    final all = endUnits(ids, shuttingDown: true);
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
