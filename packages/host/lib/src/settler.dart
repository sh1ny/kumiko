import 'dart:async';
import 'dart:io';

import 'package:process_containment/process_containment.dart';

import 'host_faults.dart';
import 'host_log.dart';
import 'ledger.dart';

/// A unit this host instance started and still holds a handle to.
class LiveUnit {
  LiveUnit(this.unit);
  final ContainedUnit unit;

  /// The unit's leader process has exited.
  bool exited = false;
}

/// The result of ending or reconciling one unit: cleaned, or unresolved with
/// a reason.
class UnitOutcome {
  const UnitOutcome.cleaned() : cleaned = true, reason = null;
  const UnitOutcome.unresolved(String this.reason) : cleaned = false;

  final bool cleaned;
  final String? reason;
}

/// What the Windows rules of design D8 can know about earlier host instances.
class WindowsEvidence {
  const WindowsEvidence({this.attestedInstance});

  /// The prior host instance whose outer job the desktop attests it
  /// terminated with zero active processes (`priorHost.jobTerminated`).
  final int? attestedInstance;
}

/// The one place that ends units: for a unit ended by the host, for
/// reconciliation of earlier instances' rows, and for a retry. It terminates
/// containments, runs one shared marker scan on POSIX, and records the
/// outcome in the ledger (design D5, D8, D9).
class Settler {
  Settler({
    required this.ledger,
    required this.log,
    required this.faults,
    ProcessTable? table,
  }) : _table = table ?? (Platform.isWindows ? null : PosixProcessTable());

  final Ledger ledger;
  final HostLog log;
  final HostFaults faults;
  final ProcessTable? _table;

  /// Terminates and scans for [rows], without writing the ledger. [live]
  /// holds the handles this host instance still has.
  Future<Map<String, UnitOutcome>> settle(
    List<UnitRow> rows, {
    required Map<String, LiveUnit> live,
    WindowsEvidence evidence = const WindowsEvidence(),
  }) async {
    final reasons = <String, String?>{};
    await Future.wait([
      for (final row in rows)
        _terminate(
          row,
          live[row.containmentId],
          evidence,
        ).then((reason) => reasons[row.containmentId] = reason),
    ]);

    MarkerScanResult? scan;
    final table = _table;
    if (table != null && rows.isNotEmpty) {
      scan = await runMarkerScan(
        table: faults.killFails ? _NoKillTable(table) : table,
        markers: {for (final r in rows) r.containmentId},
        oldestCreatedAt: rows
            .map((r) => r.createdAt)
            .reduce((a, b) => a.isBefore(b) ? a : b),
      );
    }

    return {
      for (final row in rows)
        row.containmentId: _outcome(
          reasons[row.containmentId] ?? _scanFailure(scan, row),
        ),
    };
  }

  /// POSIX: the marker scan for a unit whose spawn failed after its leader
  /// may have started; null when nothing carrying its marker remains. On
  /// Windows there is nothing to scan (null).
  Future<String?> scanFailedSpawn(UnitRow row) async {
    final table = _table;
    if (table == null) return null;
    final scan = await runMarkerScan(
      table: faults.killFails ? _NoKillTable(table) : table,
      markers: {row.containmentId},
      oldestCreatedAt: row.createdAt,
    );
    return _scanFailure(scan, row);
  }

  UnitOutcome _outcome(String? reason) => reason == null
      ? const UnitOutcome.cleaned()
      : UnitOutcome.unresolved(reason);

  String? _scanFailure(MarkerScanResult? scan, UnitRow row) {
    if (scan == null) return null;
    if (!scan.listed) return 'scan-unlistable';
    if (scan.timedOut) return 'scan-timeout';
    if (scan.unreadablePid != null) {
      return 'scan-unreadable:${scan.unreadablePid}';
    }
    for (final m in scan.remaining) {
      if (m.marker == row.containmentId) return 'marked-survivor:${m.pid}';
    }
    return null;
  }

  /// Null when the unit's containment is confirmed gone.
  Future<String?> _terminate(
    UnitRow row,
    LiveUnit? live,
    WindowsEvidence evidence,
  ) async {
    if (live != null) {
      if (faults.terminateHangs) await Completer<void>().future;
      if (faults.killFails) return _faultedTerminate(live);
      final result = await live.unit.terminate();
      return result.terminated ? null : result.reason;
    }
    final pid = row.pid;
    final started = row.startedAt;
    if (Platform.isWindows) {
      if (_windowsConfirmed(row, evidence)) return null;
      if (pid != null && started != null && isProcessAlive(pid, started)) {
        // Descendants cannot be enumerated without the lost job handle.
        terminatePid(pid);
        return 'windows-descendants-unconfirmed';
      }
      return pid == null ? 'pending-without-pid' : 'windows-job-unconfirmed';
    }
    // POSIX: a pending entry without a pid is unresolved whatever the scan
    // finds (ADR 0001); the scan still ends anything carrying its marker.
    if (pid == null || started == null) return 'pending-without-pid';
    return _terminateRecorded(pid, started);
  }

  /// D8: the unit's host instance's outer job is attested terminated, or the
  /// desktop that held it no longer runs, so the OS closed the job.
  bool _windowsConfirmed(UnitRow row, WindowsEvidence evidence) {
    if (evidence.attestedInstance == row.hostInstanceId) return true;
    final instance = ledger.instance(row.hostInstanceId);
    final desktopPid = instance?.desktopPid;
    final desktopStart = instance?.desktopStartedAt;
    if (desktopPid == null || desktopStart == null) return false;
    return !isProcessAlive(desktopPid, desktopStart);
  }

  /// An injected kill failure: nothing is signalled, so a unit is gone only
  /// if it already ended by itself.
  String? _faultedTerminate(LiveUnit live) {
    final unit = live.unit;
    if (unit is WindowsUnit) {
      try {
        if (unit.jobHandle != 0 && jobActiveProcesses(unit.jobHandle) == 0) {
          return null;
        }
      } on Object {
        // fall through: not confirmed
      }
      return 'kill-failed:injected';
    }
    // The exit watcher can lag behind the process, so ask the OS as well.
    final gone = live.exited || !isProcessAlive(unit.pid, unit.startTime);
    return gone ? null : 'kill-failed:injected';
  }

  /// POSIX: SIGTERM to the recorded unit's group, 2 s grace, SIGKILL, 3 s
  /// wait, each guarded by pid and start time so a reused pid is never
  /// signalled.
  Future<String?> _terminateRecorded(int pid, int started) async {
    if (!isProcessAlive(pid, started)) return null;
    if (faults.killFails) return 'kill-failed:injected';
    switch (killProcessGroup(pid, started, posixSigterm)) {
      case KillOutcome.leaderGone || KillOutcome.startTimeMismatch:
        return null;
      case KillOutcome.failed:
        return 'kill-failed:$pid';
      case KillOutcome.signalled:
        break;
    }
    if (await _goneWithin(pid, started, const Duration(seconds: 2))) {
      return null;
    }
    switch (killProcessGroup(pid, started, posixSigkill)) {
      case KillOutcome.leaderGone || KillOutcome.startTimeMismatch:
        return null;
      case KillOutcome.failed:
        return 'kill-failed:$pid';
      case KillOutcome.signalled:
        break;
    }
    return await _goneWithin(pid, started, const Duration(seconds: 3))
        ? null
        : 'termination-timeout';
  }

  Future<bool> _goneWithin(int pid, int started, Duration limit) async {
    final clock = Stopwatch()..start();
    while (isProcessAlive(pid, started)) {
      if (clock.elapsed >= limit) return false;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return true;
  }

  /// Records [outcomes] in the ledger: cleaned units' rows are deleted
  /// (`unit-cleaned`), the others become unresolved with their reason.
  ///
  /// With [shuttingDown] a unit not confirmed cleaned keeps its row as it is,
  /// so the next host reconciles it; a row that was already unresolved gets a
  /// `shutdown-deadline` reason (design: Resource Bounds).
  void apply(
    List<UnitRow> rows,
    Map<String, UnitOutcome> outcomes, {
    bool shuttingDown = false,
  }) => log.batch(
    () => ledger.inTransaction(() {
      for (final row in rows) {
        final outcome = outcomes[row.containmentId];
        if (outcome == null) continue;
        if (outcome.cleaned) {
          ledger.delete(row.containmentId);
          log.event('unit-cleaned', ids: {'unit': row.containmentId});
        } else if (!shuttingDown) {
          ledger.markUnresolved(row.containmentId, outcome.reason!);
          log.event(
            'unit-unresolved',
            code: outcome.reason,
            ids: {'unit': row.containmentId},
          );
        } else if (row.state == 'unresolved') {
          ledger.markUnresolved(
            row.containmentId,
            'shutdown-deadline: ${outcome.reason}',
          );
          log.event(
            'unit-unresolved',
            code: 'shutdown-deadline',
            ids: {'unit': row.containmentId},
          );
        }
      }
    }),
  );
}

/// A process table whose kills fail (an injected kill failure).
class _NoKillTable implements ProcessTable {
  _NoKillTable(this._inner);
  final ProcessTable _inner;

  @override
  int get currentUid => _inner.currentUid;

  @override
  List<int> listPids() => _inner.listPids();

  @override
  ProcessSnapshot? snapshot(int pid) => _inner.snapshot(pid);

  @override
  List<String> environment(int pid) => _inner.environment(pid);

  @override
  bool kill(int pid, int startTime) => false;
}
