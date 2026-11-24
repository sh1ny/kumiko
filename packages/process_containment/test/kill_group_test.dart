import 'dart:io';

import 'package:process_containment/process_containment.dart';
import 'package:process_containment/src/kill_guard.dart' show killLiveUnitGroup;
import 'package:test/test.dart';

/// A unit ended right after its spawn can still be in the shim, before it
/// became a session leader: its process group does not exist yet. The kill
/// guard must still reach it (found on macOS, where the shim is slower).
/// Only a unit of this run gets that direct signal (`killLiveUnitGroup`);
/// a recorded unit never does (design D3).
void main() {
  test('a recorded unit whose group does not exist is failed and not '
      'signalled', () async {
    // A fresh child stays in this process's group: no group has its pid.
    final child = await Process.start('sleep', ['30']);
    addTearDown(() => child.kill(ProcessSignal.sigkill));
    final started = posixProcessStartTime(child.pid)!;

    final outcome = killProcessGroup(child.pid, started, posixSigterm);

    expect(outcome, KillOutcome.failed);
    expect(posixIsProcessAlive(child.pid, started), isTrue);
  }, skip: Platform.isWindows ? 'POSIX process groups' : false);

  test('a leader that has not made its group yet is still signalled', () async {
    // A fresh child stays in this process's group until it calls setsid.
    final child = await Process.start('sleep', ['30']);
    addTearDown(() => child.kill(ProcessSignal.sigkill));
    final started = posixProcessStartTime(child.pid)!;

    final outcome = killLiveUnitGroup(child.pid, started, posixSigterm);

    expect(outcome, KillOutcome.signalled);
    await child.exitCode.timeout(const Duration(seconds: 5));
  }, skip: Platform.isWindows ? 'POSIX process groups' : false);
}
