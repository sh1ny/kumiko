import 'dart:io';

import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

/// A unit ended right after its spawn can still be in the shim, before it
/// became a session leader: its process group does not exist yet. The kill
/// guard must still reach it (found on macOS, where the shim is slower).
void main() {
  test('a leader that has not made its group yet is still signalled', () async {
    // A fresh child stays in this process's group until it calls setsid.
    final child = await Process.start('sleep', ['30']);
    addTearDown(() => child.kill(ProcessSignal.sigkill));
    final started = posixProcessStartTime(child.pid)!;

    final outcome = killProcessGroup(child.pid, started, posixSigterm);

    expect(outcome, KillOutcome.signalled);
    await child.exitCode.timeout(const Duration(seconds: 5));
  }, skip: Platform.isWindows ? 'POSIX process groups' : false);
}
