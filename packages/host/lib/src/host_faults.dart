import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';

/// The chunks a reader yields with [TestFault.ptyScriptedOutput], in order:
/// escape sequences, NUL bytes and malformed UTF-8, with an escape sequence
/// and a multi-byte character split across chunk boundaries.
final List<Uint8List> scriptedPtyOutput = [
  Uint8List.fromList([...'SCRIPT;'.codeUnits, 0x1B, 0x5B, 0x33]),
  Uint8List.fromList([
    0x31,
    0x6D,
    ...'red'.codeUnits,
    0x1B,
    0x5B,
    0x30,
    0x6D,
    0x00,
    0xE2,
    0x82,
  ]),
  Uint8List.fromList([0xAC, 0xFF, 0xFE, 0xC3]),
  Uint8List.fromList([0x28, 0x00, 0x00, 0x1B, 0x5D, 0x30, 0x3B, 0x74, 0x07]),
  Uint8List.fromList([0x80, 0xBF, ...'ENDSCRIPT;'.codeUnits]),
];

/// Faults a test build can inject (`test/fault.set`). A release host has no
/// way to set one, so every flag stays off.
class HostFaults {
  final Set<TestFault> _active = {};

  bool get pendingWriteFails => _active.contains(TestFault.pendingWriteFails);

  /// The spawned unit's pid write fails after disabling this held fault.
  bool get runningWriteFails => _active.contains(TestFault.runningWriteFails);
  Completer<void>? _runningWriteFailureRelease;

  Future<void> waitForRunningWriteFailureRelease() {
    if (!runningWriteFails) return Future<void>.value();
    return (_runningWriteFailureRelease ??= Completer<void>()).future;
  }

  bool get crashAfterPendingWrite =>
      _active.contains(TestFault.crashAfterPendingWrite);
  bool get crashAfterSpawnBeforePid =>
      _active.contains(TestFault.crashAfterSpawnBeforePid);

  /// The spawn fails after the unit started, as when its start time cannot
  /// be read. Disabling the fault releases the leader kill, so tests can
  /// observe descendant readiness before triggering failure.
  bool get identityReadFails => _active.contains(TestFault.identityReadFails);
  Completer<void>? _identityFailureRelease;

  Future<void> waitForIdentityFailureRelease() {
    if (!identityReadFails) return Future<void>.value();
    return (_identityFailureRelease ??= Completer<void>()).future;
  }

  /// Every kill the host would send fails.
  bool get killFails => _active.contains(TestFault.killFails);

  /// Terminating a running unit waits while enabled, outliving any deadline
  /// unless the test explicitly releases it through the existing fault setter.
  bool get terminateHangs => _active.contains(TestFault.terminateHangs);
  Completer<void>? _terminationRelease;

  Future<void> waitForTerminationRelease() {
    if (!terminateHangs) return Future<void>.value();
    return (_terminationRelease ??= Completer<void>()).future;
  }

  /// Writing a profile or the default profile fails.
  bool get profileWriteFails => _active.contains(TestFault.profileWriteFails);

  /// `terminal/activity` reads every leader image as unreadable.
  bool get activityImageUnreadable =>
      _active.contains(TestFault.activityImageUnreadable);

  /// `terminal/activity` reads take [activitySlowRead], past the deadline.
  bool get activityReadSlow => _active.contains(TestFault.activityReadSlow);

  static const Duration activitySlowRead = Duration(seconds: 3);

  /// Process-table reads `terminal/activity` started, for the bound test.
  int activityReads = 0;

  /// The draft worker fails the commit of every draft change.
  bool get draftCommitFails => _active.contains(TestFault.draftCommitFails);

  /// The draft worker holds a commit open until this fault is turned off;
  /// turning it off calls [onDraftRelease] to let the held commit go.
  bool get draftCommitHangs => _active.contains(TestFault.draftCommitHangs);
  void Function()? onDraftRelease;

  /// `agent/draftReset` waits under its reservation while enabled.
  bool get draftResetHangs => _active.contains(TestFault.draftResetHangs);
  Completer<void>? _draftResetRelease;

  Future<void> waitForDraftResetRelease() {
    if (!draftResetHangs) return Future<void>.value();
    return (_draftResetRelease ??= Completer<void>()).future;
  }

  /// Saving the Personal layout fails.
  bool get layoutSaveFails => _active.contains(TestFault.layoutSaveFails);

  /// Saving the Personal layout never finishes while this stays on.
  bool get layoutSaveHangs => _active.contains(TestFault.layoutSaveHangs);

  /// Windows: a pseudo-console close never returns.
  bool get consoleCloseHangs => _active.contains(TestFault.consoleCloseHangs);

  /// A terminal's output never reaches end of file once read to its end.
  bool get ptyNoEof => _active.contains(TestFault.ptyNoEof);

  /// A terminal's exit report is held back 600 ms, and input written meanwhile
  /// fails.
  bool get ptyExitWindow => _active.contains(TestFault.ptyExitWindow);

  /// A terminal's reader yields [scriptedPtyOutput] before the PTY's own
  /// output.
  bool get ptyScriptedOutput => _active.contains(TestFault.ptyScriptedOutput);

  final Map<String, ResolveFault> _resolve = {};
  final Map<String, List<SendPort>> _hung = {};

  /// Existing held-fault state, observed only by the test host's stats seam.
  Map<String, int> get heldResolutions => {
    for (final entry in _hung.entries) entry.key: entry.value.length,
  };

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
      if (fault == TestFault.terminateHangs) {
        _terminationRelease?.complete();
        _terminationRelease = null;
      }
      if (fault == TestFault.draftCommitHangs) onDraftRelease?.call();
      if (fault == TestFault.draftResetHangs) {
        _draftResetRelease?.complete();
        _draftResetRelease = null;
      }
      if (fault == TestFault.runningWriteFails) {
        _runningWriteFailureRelease?.complete();
        _runningWriteFailureRelease = null;
      }
      if (fault == TestFault.identityReadFails) {
        _identityFailureRelease?.complete();
        _identityFailureRelease = null;
      }
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
