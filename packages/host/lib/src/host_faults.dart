import 'dart:isolate';

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

  /// Writing a profile or the default profile fails.
  bool get profileWriteFails => _active.contains(TestFault.profileWriteFails);

  /// Saving the Personal layout fails.
  bool get layoutSaveFails => _active.contains(TestFault.layoutSaveFails);

  /// Saving the Personal layout never finishes while this stays on.
  bool get layoutSaveHangs => _active.contains(TestFault.layoutSaveHangs);

  /// Windows: a pseudo-console close never returns.
  bool get consoleCloseHangs => _active.contains(TestFault.consoleCloseHangs);

  /// A terminal's output never reaches end of file once read to its end.
  bool get ptyNoEof => _active.contains(TestFault.ptyNoEof);

  final Map<String, ResolveFault> _resolve = {};
  final Map<String, List<SendPort>> _hung = {};

  /// Takes the fault set for the next resolution of [path], if any.
  ResolveFault? takeResolveFault(String path) => _resolve.remove(path);

  void setResolveFault(String path, ResolveFault? fault) {
    if (fault == null) {
      _resolve.remove(path);
    } else {
      _resolve[path] = fault;
    }
  }

  /// A hung resolution of [path] waits on [port] for its release.
  void registerHung(String path, SendPort port) =>
      (_hung[path] ??= []).add(port);

  /// Lets every hung resolution of [path] return.
  void releaseResolve(String path) {
    for (final port in _hung.remove(path) ?? const <SendPort>[]) {
      port.send(true);
    }
  }

  void set(TestFault fault, {required bool enabled}) {
    if (enabled) {
      _active.add(fault);
    } else {
      _active.remove(fault);
    }
  }
}

/// A fault of the next resolution of one path: a delay, or a hang until
/// released.
class ResolveFault {
  const ResolveFault({this.delay = Duration.zero, this.hang = false});
  final Duration delay;
  final bool hang;
}
