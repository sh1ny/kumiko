@TestOn('linux || mac-os')
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

/// The real process table's exit evidence (issue #40, design D2), against
/// real processes. Every wait is on an event or a bounded poll that fails
/// loudly (AGENTS.md rules 2 and 6); the file's timeout is only a hang
/// guard (rule 4).
void main() {
  final table = PosixProcessTable();

  /// Polls `ps` for [pid]'s [field] until [done] accepts it, failing loudly
  /// with what it waited for.
  Future<void> pollPs(
    int pid,
    String field,
    bool Function(String value) done,
    String waitingFor,
  ) async {
    var last = '';
    for (var i = 0; i < 6000; i++) {
      final ps = await Process.run('ps', ['-o', '$field=', '-p', '$pid']);
      last = (ps.stdout as String).trim();
      if (done(last)) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('gave up waiting for $waitingFor (pid $pid, last $field: "$last")');
  }

  test('a live child is not confirmed', () async {
    final child = await Process.start('sleep', ['600']);
    addTearDown(() async {
      child.kill(ProcessSignal.sigkill);
      await child.exitCode;
    });
    final start = table.snapshot(child.pid)!.startTime;

    expect(table.confirmedExits({child.pid: start}), isEmpty);
    expect(table.confirmedExits({child.pid: null}), isEmpty);
  });

  test('a waited-for child is confirmed', () async {
    final child = await Process.start('sleep', ['600']);
    final start = table.snapshot(child.pid)!.startTime;
    child.kill(ProcessSignal.sigkill);
    await child.exitCode; // reaped

    expect(table.confirmedExits({child.pid: start}), {child.pid});
  });

  test('an unreaped zombie is confirmed on Linux and not on macOS', () async {
    // The shell starts a child that blocks on a copy of the shell's stdin,
    // prints its pid and becomes `sleep`, which never reaps it.
    final parent = await Process.start('sh', [
      '-c',
      r'exec 3<&0; sh -c "read _ <&3" & echo $!; exec sleep 600',
    ]);
    addTearDown(() async {
      parent.kill(ProcessSignal.sigkill);
      await parent.exitCode;
    });
    final lines = parent.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    final child = int.parse(await lines.first);
    final start = table.snapshot(child)!.startTime;

    await pollPs(
      parent.pid,
      'comm',
      (comm) => comm.endsWith('sleep'),
      'the parent shell to exec sleep',
    );
    parent.stdin.writeln('go');
    await parent.stdin.flush();
    await pollPs(
      child,
      'stat',
      (stat) => stat.startsWith('Z'),
      'the released child to be an unreaped zombie',
    );

    final confirmed = table.confirmedExits({child: start});
    if (Platform.isMacOS) {
      // Still listed until its parent reaps it (design D2).
      expect(confirmed, isEmpty);
    } else {
      // A zombie leader counted as its only thread.
      expect(confirmed, {child});
    }
  });
}
