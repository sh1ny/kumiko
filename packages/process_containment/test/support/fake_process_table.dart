import 'package:process_containment/process_containment.dart';

/// A process table scripted per pid, so the gone, reused and unreadable cases
/// of the marker scan are deterministic.
class FakeProcessTable implements ProcessTable {
  FakeProcessTable({
    required this.pids,
    this.uid = 1000,
    this.listFails = false,
    required this.onSnapshot,
    required this.onEnvironment,
    this.onConfirmedExits,
    this.onForeignPids,
    this.onKill,
    this.onList,
  });

  final List<int> pids;
  final bool listFails;
  final ProcessSnapshot? Function(int pid) onSnapshot;
  final List<String> Function(int pid) onEnvironment;
  final bool Function(int pid, int startTime)? onKill;

  /// The pids confirmed exited at this call; [confirmCalls] counts per pid.
  /// Without it, nothing is ever confirmed.
  final bool Function(int pid, int? startTime)? onConfirmedExits;

  /// Whether a pid with a null snapshot belongs to another user. Without
  /// it, no pid is foreign.
  final bool Function(int pid)? onForeignPids;

  /// The listing for the [listCount]th call (1-based); without it, [pids].
  final List<int> Function(int listCount)? onList;

  final List<(int, int)> kills = [];

  /// Every `listPids`, `confirmedExits` and `foreignPids` call in order, as
  /// `list`, `confirm:<pids>` or `foreign:<pids>`, so a test can assert that
  /// a confirmation came before a listing.
  final List<String> calls = [];

  /// How often `confirmedExits` was asked about each pid.
  final Map<int, int> confirmCalls = {};

  var _lists = 0;

  final int uid;

  @override
  int get currentUid => uid;

  @override
  List<int> listPids() {
    calls.add('list');
    _lists++;
    if (listFails) throw const ProcessTableUnlistable('scripted');
    return onList?.call(_lists) ?? pids;
  }

  /// How many times the table has been listed.
  int get listCount => _lists;

  @override
  Set<int> confirmedExits(Map<int, int?> pids) {
    calls.add('confirm:${pids.keys.join(',')}');
    for (final pid in pids.keys) {
      confirmCalls[pid] = (confirmCalls[pid] ?? 0) + 1;
    }
    return {
      for (final MapEntry(key: pid, value: start) in pids.entries)
        if (onConfirmedExits?.call(pid, start) ?? false) pid,
    };
  }

  @override
  Set<int> foreignPids(Set<int> pids) {
    calls.add('foreign:${pids.join(',')}');
    return {
      for (final pid in pids)
        if (onForeignPids?.call(pid) ?? false) pid,
    };
  }

  @override
  ProcessSnapshot? snapshot(int pid) => onSnapshot(pid);

  @override
  List<String> environment(int pid) => onEnvironment(pid);

  @override
  bool kill(int pid, int startTime) {
    kills.add((pid, startTime));
    return onKill?.call(pid, startTime) ?? true;
  }
}
