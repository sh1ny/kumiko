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

  /// Every kill the host would send fails.
  bool get killFails => _active.contains(TestFault.killFails);

  void set(TestFault fault, {required bool enabled}) {
    if (enabled) {
      _active.add(fault);
    } else {
      _active.remove(fault);
    }
  }
}
