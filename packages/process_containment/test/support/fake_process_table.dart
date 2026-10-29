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
    this.onKill,
  });

  final List<int> pids;
  final bool listFails;
  final ProcessSnapshot? Function(int pid) onSnapshot;
  final List<String> Function(int pid) onEnvironment;
  final bool Function(int pid, int startTime)? onKill;
  final List<(int, int)> kills = [];

  final int uid;

  @override
  int get currentUid => uid;

  @override
  List<int> listPids() {
    if (listFails) throw const ProcessTableUnlistable('scripted');
    return pids;
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
