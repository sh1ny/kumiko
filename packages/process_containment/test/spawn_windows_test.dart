@TestOn('windows')
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/fixture_harness.dart';
import 'support/fixture_lines.dart';

/// Windows job primitives (design D3): nested unit jobs without breakaway,
/// suspended creation, NUL stdio, and an outer job that outlives nothing.
void main() {
  late Directory tmp;
  late String exe;
  late File out;
  var counter = 0;
  final units = <WindowsUnit>[];
  final jobs = <int>[];

  setUpAll(() async {
    (tmp, exe) = await compileFixtureHost();
  });

  tearDownAll(() => deleteTempDir(tmp));

  setUp(() {
    out = File(p.join(tmp.path, 'out${counter++}.txt'));
  });

  tearDown(() async {
    for (final unit in units) {
      await unit.terminate();
      unit.close();
    }
    units.clear();
    for (final job in jobs) {
      terminateJob(job);
      closeHandle(job);
    }
    jobs.clear();
  });

  WindowsUnit start(List<String> fixtureArgs, {String id = 'unit-win'}) {
    final unit = spawnWindowsUnit(
      executable: exe,
      args: ['--fixture', ...fixtureArgs],
      containmentId: id,
      environment: {'PC_FIXTURE_OUT': out.path},
    );
    units.add(unit);
    return unit;
  }

  test('breakaway child stays in unit job', () async {
    final unit = start(['breakaway']);
    final line = (await waitForLines(out, 1)).first;

    if (line.role.startsWith('breakaway-failed-')) {
      // The start failed: breakaway is refused for a job without the
      // breakaway limit. That satisfies the scenario.
      expect(line.role, 'breakaway-failed-5', reason: 'ERROR_ACCESS_DENIED');
      return;
    }
    final childPid = int.parse(line.role.split('-').last);
    addTearDown(() => terminatePid(childPid));
    expect(isPidInJob(childPid, unit.jobHandle), isTrue);
  });

  test('terminating the unit job ends every descendant', () async {
    final unit = start(['tree']);
    final lines = await waitForLines(out, 3);
    final starts = {for (final l in lines) l.pid: processStartTime(l.pid)!};
    expect(jobActiveProcesses(unit.jobHandle), greaterThanOrEqualTo(3));

    final watch = Stopwatch()..start();
    final result = await unit.terminate();
    print('measured: unit termination ${watch.elapsedMilliseconds} ms');

    expect(result.terminated, isTrue, reason: '${result.reason}');
    expect(jobActiveProcesses(unit.jobHandle), 0);
    starts.forEach((pid, start) {
      expect(isProcessAlive(pid, start), isFalse, reason: 'pid $pid');
    });
  });

  test('the unit job is created with kill-on-close', () async {
    final unit = start(['tree']);
    final lines = await waitForLines(out, 3);
    final starts = {for (final l in lines) l.pid: processStartTime(l.pid)!};

    unit.closeJob();

    // The process handle stays ours; wait for the exit through it.
    expect(
      await unit.exitCode.timeout(const Duration(seconds: 10)),
      isA<int>(),
    );
    starts.forEach((pid, start) {
      expect(isProcessAlive(pid, start), isFalse, reason: 'pid $pid');
    });
  });

  test('unit stdio is NUL', () async {
    start(['nul-stdio']);
    final line = (await waitForLines(out, 1)).single;

    expect(line.role, 'nul-stdio-eof');
  });

  test('start time is the process creation time', () async {
    final unit = start(['sleeper']);
    await waitForLines(out, 1);

    expect(unit.startTime, greaterThan(0));
    expect(processStartTime(unit.pid), unit.startTime);
  });

  test('a unit created by a host in the outer job stays inside it', () async {
    final outer = createJob();
    jobs.add(outer);
    final host = await Process.start(
      exe,
      ['--fixture', 'host-sim'],
      environment: {'PC_FIXTURE_OUT': out.path},
    );
    addTearDown(host.kill);
    assignPidToJob(outer, host.pid);
    host.stdin.writeln('go');
    await host.stdin.flush();

    // The host-sim line, and the line its sleeper unit writes.
    final lines = await waitForLines(out, 2);
    final line = lines.singleWhere((l) => l.role.startsWith('host-sim-unit-'));
    final unitPid = int.parse(line.role.split('-').last);
    final unitStart = processStartTime(unitPid)!;

    expect(isPidInJob(unitPid, outer), isTrue, reason: 'nested: also in outer');
    expect(jobActiveProcesses(outer), greaterThanOrEqualTo(2));

    // Closing the outer job reaches the unit although the unit has its own.
    expect(terminateJob(outer), isTrue);
    await host.exitCode.timeout(const Duration(seconds: 10));
    expect(isProcessAlive(unitPid, unitStart), isFalse);
  });

  test('command line quoting survives spaces and quotes', () {
    expect(
      quoteWindowsCommandLine(['a b', 'c"d', r'e\', '', r'f g\']),
      r'"a b" c\"d e\ "" "f g\\"',
    );
  });
}
