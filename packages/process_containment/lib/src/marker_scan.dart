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

  /// A live process in the population whose environment could not be read.
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
  int? unreadable;
  final matches = <MarkedProcess>[];
}

/// Scans the current user's processes that started at or after
/// [oldestCreatedAt] minus 1 s for [markers], kills the matches with
/// `SIGKILL`, and scans again (design D9). At most two passes of
/// [passTimeout] each.
Future<MarkerScanResult> runMarkerScan({
  required ProcessTable table,
  required Set<String> markers,
  required DateTime oldestCreatedAt,
  Duration passTimeout = const Duration(seconds: 10),
}) async {
  final first = await _pass(table, markers, oldestCreatedAt, passTimeout);
  if (!first.listed) return const MarkerScanResult(listed: false);

  final killed = <MarkedProcess>[];
  final signalled = <MarkedProcess>[];
  for (final m in first.matches) {
    killed.add(m);
    if (table.kill(m.pid, m.startTime)) signalled.add(m);
  }
  if (first.timedOut) {
    return MarkerScanResult(
      timedOut: true,
      unreadablePid: first.unreadable,
      killed: killed,
    );
  }
  if (first.matches.isEmpty) {
    return MarkerScanResult(unreadablePid: first.unreadable);
  }

  await _settle(table, signalled);
  final second = await _pass(table, markers, oldestCreatedAt, passTimeout);
  return MarkerScanResult(
    listed: second.listed,
    timedOut: second.timedOut,
    unreadablePid: second.unreadable ?? first.unreadable,
    killed: killed,
    remaining: second.matches,
  );
}

Future<_Pass> _pass(
  ProcessTable table,
  Set<String> markers,
  DateTime oldestCreatedAt,
  Duration timeout,
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

  for (var i = 0; i < pids.length; i++) {
    if (clock.elapsed >= timeout) {
      pass.timedOut = true;
      break;
    }
    if (i % 64 == 63) await Future<void>.delayed(Duration.zero);
    final pid = pids[i];

    final ProcessSnapshot? seen;
    try {
      seen = table.snapshot(pid);
    } on ProcessReadDenied {
      pass.unreadable ??= pid;
      continue;
    }
    if (seen == null || seen.zombie) continue;
    if (seen.uid != table.currentUid || seen.startedAt.isBefore(window)) {
      continue;
    }

    final List<String> env;
    try {
      env = table.environment(pid);
    } on Exception catch (e) {
      if (e is! ProcessGone && e is! ProcessReadDenied) rethrow;
      if (_stillThere(table, pid, seen)) pass.unreadable ??= pid;
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

/// The re-check after a failed environment read: gone, or a different start
/// time (the pid was reused), means the process we listed does not exist.
bool _stillThere(ProcessTable table, int pid, ProcessSnapshot seen) {
  try {
    final again = table.snapshot(pid);
    return again != null && !again.zombie && again.startTime == seen.startTime;
  } on ProcessReadDenied {
    return true;
  }
}

/// Gives killed processes a moment to disappear before the rescan.
Future<void> _settle(ProcessTable table, List<MarkedProcess> killed) async {
  final clock = Stopwatch()..start();
  var pending = killed;
  while (pending.isNotEmpty && clock.elapsed < const Duration(seconds: 1)) {
    pending = [
      for (final m in pending)
        if (_aliveWithStartTime(table, m)) m,
    ];
    if (pending.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}

bool _aliveWithStartTime(ProcessTable table, MarkedProcess m) {
  try {
    final s = table.snapshot(m.pid);
    return s != null && !s.zombie && s.startTime == m.startTime;
  } on ProcessReadDenied {
    return true;
  }
}
