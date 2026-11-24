@Timeout(Duration(minutes: 2))
library;

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
    // Ended by the signal, not by `sleep` finishing on its own.
    expect(await child.exitCode, -posixSigterm);
  }, skip: Platform.isWindows ? 'POSIX process groups' : false);

  test('terminating a unit whose shim never made its group ends it', () async {
    // `sh` stands in for a shim stopped before `setsid`: it ignores the
    // shim arguments and stays in this process's group.
    final unit = await spawnPosixUnit(
      shimExecutable: '/bin/sh',
      shimArgs: ['-c', 'exec sleep 30', 'sh'],
      containmentId: 'kill-group-pre-setsid',
      argv: ['unused'],
    );
    addTearDown(() => unit.process.kill(ProcessSignal.sigkill));

    // Grace and wait are hang guards, not expected outcomes (AGENTS.md
    // rule 4): SIGTERM ends `sleep` at once.
    final result = await unit.terminate(
      grace: const Duration(minutes: 1),
      killWait: const Duration(minutes: 1),
    );

    expect(result.terminated, isTrue, reason: result.reason);
    expect(await unit.exitCode, -posixSigterm);
  }, skip: Platform.isWindows ? 'POSIX process groups' : false);
}
