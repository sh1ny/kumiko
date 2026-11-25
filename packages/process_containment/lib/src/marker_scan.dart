import 'dart:async';

import 'process_table.dart';
import 'unit_exec.dart';

/// A process carrying a unit marker.
class MarkedProcess {
  const MarkedProcess(this.pid, this.startTime, this.marker);
  final int pid;
  final int startTime;
  final String marker;

  @override
  String toString() => 'MarkedProcess($pid, $marker)';
}

/// Result of [runMarkerScan] for every unit being ended or reconciled.
class MarkerScanResult {
  const MarkerScanResult({
    this.listed = true,
    this.timedOut = false,
    this.unreadablePid,
    this.killed = const [],
    this.remaining = const [],
  });

  /// False when the process table could not be listed.
  final bool listed;

  /// A pass ran past its timeout.
  final bool timedOut;

  /// A process in the population that could not be read and whose full
  /// exit was not confirmed before the scan listed the processes again.
  final int? unreadablePid;

  /// Marked processes the scan sent `SIGKILL`.
  final List<MarkedProcess> killed;

  /// Marked processes still present on the final pass.
  final List<MarkedProcess> remaining;

  /// Why the units cannot be called cleaned, or null when they can.
  String? get failure {
    if (!listed) return 'scan-unlistable';
    if (timedOut) return 'scan-timeout';
    if (unreadablePid != null) return 'scan-unreadable:$unreadablePid';
    if (remaining.isNotEmpty) return 'marked-survivor:${remaining.first.pid}';
    return null;
  }

  bool get clean => failure == null;

  @override
  String toString() =>
      'MarkerScanResult(failure: $failure, killed: $killed, '
      'remaining: $remaining)';
}

class _Pass {
  bool listed = true;
  bool timedOut = false;

  /// Pids that could not be read and whose full exit is not confirmed, in
  /// listing order, with their start times where known.
  final pending = <int, int?>{};

  /// A pid could not be read, whatever the exit check found: the second
  /// listing must come after that evidence.
  bool notRead = false;

  final matches = <MarkedProcess>[];
}

/// Scans the current user's processes that started at or after
/// [oldestCreatedAt] minus 1 s for [markers], kills the matches with
/// `SIGKILL`, and scans again (design D9). At most two passes of
/// [passTimeout] each; [passExpiredForTesting] replaces the pass clock's
/// check before each pid.
///
/// A process the first pass cannot read (a refused or null snapshot, a
/// zombie, or a failed environment read) is *pending* unless
/// [ProcessTable.confirmedExits] confirms its full exit. The population
/// filter (another uid, or a known start before the window) runs first; a
/// null snapshot whose exit is not confirmed is skipped when
/// [ProcessTable.foreignPids] names it. Every exit check runs at the pid's
/// own failed read, inside the pass clock, never deferred to the end of the
/// pass. A pending pid is cleared only by a confirmed exit before the
/// second listing, at that check or while the scan settles for at most 1 s; it
/// disappearing later clears nothing, and the settle's expiry is never an
/// outcome in itself: an unconfirmed pid is `scan-unreadable` (issue #40,
/// design D1, C1).
///
/// Any match or pid not read, pending or not, makes the second pass run, so
/// the second listing always comes after the exit evidence. The second
/// pass only verifies: it kills nothing, a marked process there is a
/// survivor, and a pid there that cannot be read and is not confirmed
/// exited is unreadable (C2).
///
/// A process can start a child after the final listing and vanish before
/// it is read; the scan does not see that child. By the owner's decision
/// that race is left to OS-provided grouping (ADR 0001, issue #9; design
/// D6, C7).
Future<MarkerScanResult> runMarkerScan({
  required ProcessTable table,
  required Set<String> markers,
  required DateTime oldestCreatedAt,
  Duration passTimeout = const Duration(seconds: 10),
  bool Function()? passExpiredForTesting,
}) async {
  Future<_Pass> pass() => _pass(
    table,
    markers,
    oldestCreatedAt,
    passTimeout,
    passExpiredForTesting,
  );

  final first = await pass();
  if (!first.listed) return const MarkerScanResult(listed: false);

  final killed = <MarkedProcess>[];
  final signalled = <MarkedProcess>[];
  for (final m in first.matches) {
    killed.add(m);
    if (table.kill(m.pid, m.startTime)) signalled.add(m);
  }
  if (first.timedOut) {
    // The timeout already fails the scan; its pending pids are dropped.
    return MarkerScanResult(timedOut: true, killed: killed);
  }
  if (first.matches.isEmpty && !first.notRead) {
    return const MarkerScanResult();
  }

  final unconfirmed = await _settle(table, signalled, first.pending);
  final second = await pass();
  return MarkerScanResult(
    listed: second.listed,
    timedOut: second.timedOut,
    unreadablePid: unconfirmed.firstOrNull ?? second.pending.keys.firstOrNull,
    killed: killed,
    remaining: second.matches,
  );
}

Future<_Pass> _pass(
  ProcessTable table,
  Set<String> markers,
  DateTime oldestCreatedAt,
  Duration timeout,
  bool Function()? expired,
) async {
  final pass = _Pass();
  final List<int> pids;
  try {
    pids = table.listPids();
  } on ProcessTableUnlistable {
    return pass..listed = false;
  }
  final window = oldestCreatedAt.subtract(const Duration(seconds: 1));
  final clock = Stopwatch()..start();
  const prefix = '$unitMarkerVariable=';
  // The exit check of a pid that could not be read, at that read (D1).
  void unread(int pid, int? start, {bool ownerUnknown = false}) {
    pass.notRead = true;
    if (table.confirmedExits({pid: start}).contains(pid)) return;
    if (ownerUnknown && table.foreignPids({pid}).contains(pid)) return;
    pass.pending[pid] = start;
  }

  for (var i = 0; i < pids.length; i++) {
    if (expired?.call() ?? clock.elapsed >= timeout) {
      pass.timedOut = true;
      break;
    }
    if (i % 64 == 63) await Future<void>.delayed(Duration.zero);
    final pid = pids[i];

    final ProcessSnapshot? seen;
    try {
      seen = table.snapshot(pid);
    } on ProcessReadDenied {
      unread(pid, null);
      continue;
    }
    if (seen == null) {
      unread(pid, null, ownerUnknown: true);
      continue;
    }
    if (seen.uid != table.currentUid) continue;
    // Start time 0 is the macOS short read's placeholder: unknown.
    final start = seen.startTime == 0 ? null : seen.startTime;
    if (start != null && seen.startedAt.isBefore(window)) continue;
    if (seen.zombie) {
      unread(pid, start);
      continue;
    }

    final List<String> env;
    try {
      env = table.environment(pid);
    } on Exception catch (e) {
      if (e is! ProcessGone && e is! ProcessReadDenied) rethrow;
      unread(pid, start);
      continue;
    }
    for (final entry in env) {
      if (!entry.startsWith(prefix)) continue;
      final marker = entry.substring(prefix.length);
      if (markers.contains(marker)) {
        pass.matches.add(MarkedProcess(pid, seen.startTime, marker));
      }
      break;
    }
  }
  return pass;
}

/// Gives killed processes a moment to disappear, and pending pids a moment
/// for their full exit to be confirmed, before the rescan: at most 1 s,
/// polling every 10 ms, with one [ProcessTable.confirmedExits] call per
/// sweep. Returns the pending pids still unconfirmed, in listing order.
Future<List<int>> _settle(
  ProcessTable table,
  List<MarkedProcess> killed,
  Map<int, int?> pending,
) async {
  final clock = Stopwatch()..start();
  var alive = killed;
  final waiting = Map.of(pending);
  while ((alive.isNotEmpty || waiting.isNotEmpty) &&
      clock.elapsed < const Duration(seconds: 1)) {
    alive = [
      for (final m in alive)
        if (_aliveWithStartTime(table, m)) m,
    ];
    if (waiting.isNotEmpty) {
      final confirmed = table.confirmedExits(waiting);
      waiting.removeWhere((pid, _) => confirmed.contains(pid));
    }
    if (alive.isNotEmpty || waiting.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
  return waiting.keys.toList();
}

bool _aliveWithStartTime(ProcessTable table, MarkedProcess m) {
  try {
    final s = table.snapshot(m.pid);
    return s != null && !s.zombie && s.startTime == m.startTime;
  } on ProcessReadDenied {
    return true;
  }
}
