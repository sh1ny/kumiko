import 'package:host_protocol/host_protocol.dart';

/// Faults a test build can inject (`test/fault.set`). A release host has no
/// way to set one, so every flag stays off.
class HostFaults {
  final Set<TestFault> _active = {};

  bool get pendingWriteFails => _active.contains(TestFault.pendingWriteFails);

  /// The write of a spawned unit's pid and start time fails, after 1 s.
  bool get runningWriteFails => _active.contains(TestFault.runningWriteFails);
  bool get crashAfterPendingWrite =>
      _active.contains(TestFault.crashAfterPendingWrite);
  bool get crashAfterSpawnBeforePid =>
      _active.contains(TestFault.crashAfterSpawnBeforePid);

  /// The spawn fails after the unit started, as when its start time cannot
  /// be read: after 1 s the leader is killed and the spawn throws.
  bool get identityReadFails => _active.contains(TestFault.identityReadFails);

  /// Every kill the host would send fails.
  bool get killFails => _active.contains(TestFault.killFails);

  /// Terminating a running unit never finishes, so ending it outlives any
  /// deadline.
  bool get terminateHangs => _active.contains(TestFault.terminateHangs);

  void set(TestFault fault, {required bool enabled}) {
    if (enabled) {
      _active.add(fault);
    } else {
      _active.remove(fault);
    }
  }
}
