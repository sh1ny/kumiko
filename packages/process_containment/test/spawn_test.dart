@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/fixture_harness.dart';
import 'support/fixture_lines.dart';

/// Spawn primitives on the current OS (design D2, D3): units are contained
/// and marked, descendants stay attributable, termination is guarded.
void main() {
  late Directory tmp;
  late String exe;
  late File out;
  var counter = 0;
  final started = <ContainedUnit>[];
  final startedAt = DateTime.now();

  setUpAll(() async {
    (tmp, exe) = await compileFixtureHost();
  });

  tearDownAll(() => deleteTempDir(tmp));

  setUp(() {
    out = File(p.join(tmp.path, 'out${counter++}.txt'));
  });

  tearDown(() async {
    for (final unit in started) {
      await unit.terminate();
    }
    if (!Platform.isWindows && started.isNotEmpty) {
      // A descendant that left the session is only reachable by its marker.
      await runMarkerScan(
        table: PosixProcessTable(),
        markers: {for (final u in started) u.containmentId},
        oldestCreatedAt: startedAt,
      );
    }
    started.clear();
  });

  Future<ContainedUnit> start(
    List<String> fixtureArgs, {
    String id = 'unit-spawn-test',
  }) async {
    final unit = await startFixtureUnit(exe, fixtureArgs, id: id, out: out);
    started.add(unit);
    return unit;
  }

  test('tree fixture descendants carry marker and job', () async {
    final unit = await start(['tree'], id: 'unit-tree');
    final lines = await waitForLines(out, 3);
    final byRole = {for (final l in lines) l.role: l};

    expect(byRole.keys, containsAll(['tree', 'child', 'sleeper']));
    expect(byRole['tree']!.pid, unit.pid);
    for (final line in lines) {
      expect(line.marker, 'unit-tree', reason: '${line.role} marker');
    }

    if (Platform.isWindows) {
      final job = (unit as WindowsUnit).jobHandle;
      for (final line in lines) {
        expect(
          isPidInJob(line.pid, job),
          isTrue,
          reason: '${line.role} in job',
        );
      }
      expect(jobActiveProcesses(job), greaterThanOrEqualTo(3));
    } else {
      final table = PosixProcessTable();
      for (final line in lines) {
        expect(
          table.environment(line.pid),
          contains('KUMIKO_UNIT=unit-tree'),
          reason: '${line.role} environment as the OS reports it',
        );
      }
      // The unit leads its own session; the child shares it; the grandchild
      // started a session of its own.
      expect(byRole['tree']!.sid, unit.pid);
      expect(byRole['child']!.sid, unit.pid);
      expect(byRole['sleeper']!.sid, isNot(unit.pid));
    }
  });

  test('start time identifies the unit process', () async {
    final unit = await start(['sleeper']);
    await waitForLines(out, 1);

    expect(processStartTime(unit.pid), unit.startTime);
    expect(isProcessAlive(unit.pid, unit.startTime), isTrue);
    expect(isProcessAlive(unit.pid, unit.startTime + 1), isFalse);

    final watch = Stopwatch()..start();
    final result = await unit.terminate();
    print('measured: unit termination ${watch.elapsedMilliseconds} ms');

    expect(result.terminated, isTrue, reason: '${result.reason}');
    expect(isProcessAlive(unit.pid, unit.startTime), isFalse);
  });

  test('exit code of the unit reaches exitCode', () async {
    final unit = await start(['exit', '5']);

    expect(await unit.exitCode.timeout(const Duration(seconds: 20)), 5);
  });

  group('POSIX', () {
    final skipOnWindows = Platform.isWindows ? 'POSIX sessions only' : null;

    test('termination ends the session; the marker scan ends an escaped '
        'descendant', () async {
      final created = DateTime.now();
      final unit = await start(['tree'], id: 'unit-escape');
      final lines = await waitForLines(out, 3);
      final escaped = lines.singleWhere((l) => l.role == 'sleeper');
      final escapedStart = processStartTime(escaped.pid)!;

      final result = await unit.terminate();

      expect(result.terminated, isTrue, reason: '${result.reason}');
      expect(
        isProcessAlive(escaped.pid, escapedStart),
        isTrue,
        reason: 'killpg does not reach another session',
      );

      final scan = await runMarkerScan(
        table: PosixProcessTable(),
        markers: {'unit-escape'},
        oldestCreatedAt: created,
      );

      expect(scan.clean, isTrue, reason: '${scan.failure}');
      expect(scan.killed.map((m) => m.pid), contains(escaped.pid));
      expect(isProcessAlive(escaped.pid, escapedStart), isFalse);
    }, skip: skipOnWindows);

    test(
      'a unit that ignores SIGTERM is killed after the grace period',
      () async {
        final unit = await start(['stubborn']);
        await waitForLines(out, 1);
        final watch = Stopwatch()..start();

        final result = await unit.terminate();
        print(
          'measured: termination of a unit ignoring SIGTERM '
          '${watch.elapsedMilliseconds} ms',
        );

        expect(result.terminated, isTrue, reason: '${result.reason}');
        expect(watch.elapsed, greaterThanOrEqualTo(const Duration(seconds: 2)));
        expect(watch.elapsed, lessThan(const Duration(seconds: 6)));
        expect(isProcessAlive(unit.pid, unit.startTime), isFalse);
      },
      skip: skipOnWindows,
    );

    test('killpg is guarded by the leader start time', () async {
      final unit = await start(['sleeper']);
      await waitForLines(out, 1);

      final stale = killProcessGroup(
        unit.pid,
        unit.startTime + 1,
        posixSigkill,
      );

      expect(stale, KillOutcome.startTimeMismatch);
      expect(isProcessAlive(unit.pid, unit.startTime), isTrue);

      final real = killProcessGroup(unit.pid, unit.startTime, posixSigkill);

      expect(real, KillOutcome.signalled);
      await unit.exitCode.timeout(const Duration(seconds: 5));
      expect(
        killProcessGroup(unit.pid, unit.startTime, posixSigkill),
        KillOutcome.leaderGone,
      );
    }, skip: skipOnWindows);
  });

  // Issue #18: what the spawn does when the start time cannot be read. Each
  // outcome is forced through the spawn's test-only parameters, so no test
  // depends on winning or losing the race with the unit's exit.
  group('POSIX start time read', () {
    final skipOnWindows = Platform.isWindows ? 'POSIX sessions only' : null;
    const esrchErrno = 3;
    const hangGuard = Duration(minutes: 2);
    final processes = <Process>[];

    // Every spawned process is registered by the hook before the spawn can
    // fail, so it is ended even when no unit was returned.
    tearDown(() async {
      for (final process in processes) {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(hangGuard);
      }
      processes.clear();
    });

    Future<PosixUnit> spawn(
      List<String> fixtureArgs, {
      required String id,
      Future<void> Function(Process)? before,
      ProcessSnapshot? Function(int pid)? snapshot,
      int Function(int pid)? probe,
    }) => spawnPosixUnit(
      shimExecutable: exe,
      containmentId: id,
      argv: [exe, '--fixture', ...fixtureArgs],
      environment: {'PC_FIXTURE_OUT': out.path},
      beforeStartTimeReadForTesting: (process) async {
        processes.add(process);
        await before?.call(process);
      },
      snapshotForTesting: snapshot,
      probeForTesting: probe,
    );

    Future<void> reaped(Process process) => process.exitCode.timeout(hangGuard);

    bool runs(int pid) {
      final s = PosixProcessTable().snapshot(pid);
      return s != null && !s.zombie;
    }

    test('a plain unit reaped before its start time is read spawns and '
        'reports its exit code', () async {
      final probes = <int>[];
      final unit = await spawn(
        ['exit', '5'],
        id: 'unit-reaped',
        before: reaped,
        probe: (pid) {
          final answer = posixKill(pid, 0);
          probes.add(answer);
          return answer;
        },
      );
      started.add(unit);

      // A pid reused before the read would give a real start time here.
      expect(unit.startTime, startTimeNotRead);
      expect(probes, [esrchErrno], reason: 'absence was proved by the probe');
      expect(await unit.exitCode.timeout(hangGuard), 5);
    }, skip: skipOnWindows);

    test("a reaped unit's terminate returns terminated", () async {
      final unit = await spawn(
        ['exit', '0'],
        id: 'unit-reaped-end',
        before: reaped,
      );

      final result = await unit.terminate();

      expect(result.terminated, isTrue, reason: '${result.reason}');
    }, skip: skipOnWindows);

    test(
      'refused start time read fails the spawn and kills the process',
      () async {
        await expectLater(
          spawn(
            ['sleeper'],
            id: 'unit-refused',
            snapshot: (_) => throw const ProcessReadDenied(),
          ),
          throwsA(isA<StateError>()),
        );

        expect(
          await processes.single.exitCode.timeout(hangGuard),
          -ProcessSignal.sigkill.signalNumber,
        );
      },
      skip: skipOnWindows,
    );

    test('an unconfirmed start time read fails without a signal', () async {
      await expectLater(
        spawn(['sleeper'], id: 'unit-unconfirmed', snapshot: (_) => null),
        throwsA(isA<SpawnIdentityUnconfirmed>()),
      );
      final process = processes.single;

      expect(runs(process.pid), isTrue, reason: 'not signalled');
    }, skip: skipOnWindows);

    test('the unconfirmed error carries the pid', () async {
      Object? error;
      try {
        await spawn(
          ['sleeper'],
          id: 'unit-unconfirmed-pid',
          snapshot: (_) => null,
        );
      } on SpawnIdentityUnconfirmed catch (e) {
        error = e;
      }

      expect(
        error,
        isA<SpawnIdentityUnconfirmed>()
            .having((e) => e.pid, 'pid', processes.single.pid)
            .having((e) => e.containmentId, 'id', 'unit-unconfirmed-pid'),
      );
    }, skip: skipOnWindows);

    test('a unit taken as gone whose exit is not observed in time is not '
        'signalled and its termination times out', () async {
      final unit = await spawn(
        ['sleeper'],
        id: 'unit-forced-gone',
        snapshot: (_) => null,
        probe: (_) => esrchErrno,
      );
      expect(unit.startTime, startTimeNotRead);

      // Nothing ends the sleeper here, so its exit cannot be observed.
      final result = await unit.terminate(killWait: Duration.zero);

      expect(result.terminated, isFalse);
      expect(result.reason, 'termination-timeout');
      expect(runs(unit.pid), isTrue, reason: 'not signalled');
    }, skip: skipOnWindows);

    test(
      'the leader guards act on startTimeNotRead without reading the pid',
      () async {
        final unit = await start(['sleeper']);
        await waitForLines(out, 1);
        var reads = 0;
        ProcessSnapshot? counting(int pid) {
          reads++;
          return PosixProcessTable().snapshot(pid);
        }

        // Signal 0 only checks; nothing is delivered even if a guard failed.
        expect(
          killProcessGroup(
            unit.pid,
            startTimeNotRead,
            0,
            snapshotForTesting: counting,
          ),
          KillOutcome.leaderGone,
        );
        expect(
          posixIsProcessAlive(
            unit.pid,
            startTimeNotRead,
            snapshotForTesting: counting,
          ),
          isFalse,
        );
        expect(reads, 0);

        expect(
          killProcessGroup(
            unit.pid,
            unit.startTime,
            0,
            snapshotForTesting: counting,
          ),
          KillOutcome.signalled,
        );
        expect(
          posixIsProcessAlive(
            unit.pid,
            unit.startTime,
            snapshotForTesting: counting,
          ),
          isTrue,
        );
        expect(reads, 2);
      },
      skip: skipOnWindows,
    );
  });
}
