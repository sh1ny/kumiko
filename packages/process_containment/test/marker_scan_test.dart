import 'dart:io';

import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/fake_process_table.dart';

final _epoch = DateTime.utc(2026, 1, 1, 12);

ProcessSnapshot _snap(
  int start, {
  int uid = 1000,
  DateTime? at,
  bool zombie = false,
}) => ProcessSnapshot(
  startTime: start,
  startedAt: at ?? _epoch,
  uid: uid,
  zombie: zombie,
);

void main() {
  const marker = 'unit-a';
  final created = _epoch.subtract(const Duration(minutes: 1));

  Future<MarkerScanResult> scan(
    FakeProcessTable table, {
    Duration passTimeout = const Duration(seconds: 10),
    bool Function()? passExpired,
  }) => runMarkerScan(
    table: table,
    markers: {marker},
    oldestCreatedAt: created,
    passTimeout: passTimeout,
    passExpiredForTesting: passExpired,
  );

  test(
    'process gone or pid reused between list and read counts as gone',
    () async {
      final calls = <int, int>{};
      final table = FakeProcessTable(
        pids: [10, 11, 12],
        onSnapshot: (pid) {
          final n = calls[pid] = (calls[pid] ?? 0) + 1;
          return switch (pid) {
            // Listed, then exited before the re-check.
            10 => n == 1 ? _snap(100) : null,
            // Listed as start 100; the pid now belongs to another process.
            11 => _snap(n == 1 ? 100 : 200),
            _ => _snap(300),
          };
        },
        onEnvironment: (pid) => switch (pid) {
          10 => throw const ProcessGone(),
          11 => throw const ProcessReadDenied(),
          _ => ['PATH=/bin'],
        },
        // The kernel confirms both: 10 is gone, 11's pid was reused.
        onConfirmedExits: (pid, _) => pid == 10 || pid == 11,
      );

      final result = await scan(table);

      expect(result.failure, isNull);
      expect(result.clean, isTrue);
      expect(result.killed, isEmpty);
      expect(table.kills, isEmpty);
    },
  );

  test('live unreadable process yields scan-unreadable', () async {
    final table = FakeProcessTable(
      pids: [20],
      onSnapshot: (_) => _snap(100),
      onEnvironment: (_) => throw const ProcessReadDenied(),
    );

    final result = await scan(table);

    expect(result.failure, 'scan-unreadable:20');
    expect(result.clean, isFalse);
    expect(result.unreadablePid, 20);
  });

  test('marked process is killed, then the rescan finds nothing', () async {
    var alive = true;
    final table = FakeProcessTable(
      pids: [30, 31],
      onSnapshot: (pid) => pid == 30 && !alive ? null : _snap(100 + pid),
      onEnvironment: (pid) => pid == 30
          ? ['A=b', '$unitMarkerVariable=$marker']
          : ['$unitMarkerVariable=other-unit'],
      onKill: (pid, _) {
        alive = false;
        return true;
      },
      // Still listed with a null snapshot: cleared only by exit evidence.
      onConfirmedExits: (pid, _) => pid == 30 && !alive,
    );

    final result = await scan(table);

    expect(result.clean, isTrue);
    expect(result.killed.map((p) => (p.pid, p.marker, p.startTime)), [
      (30, marker, 130),
    ]);
    expect(table.kills, [(30, 130)], reason: 'only the marked pid is killed');
  });

  test(
    'marked process that survives SIGKILL leaves the unit unresolved',
    () async {
      final table = FakeProcessTable(
        pids: [40],
        onSnapshot: (_) => _snap(100),
        onEnvironment: (_) => ['$unitMarkerVariable=$marker'],
        onKill: (_, _) => false,
      );

      final result = await scan(table);

      expect(result.clean, isFalse);
      expect(result.failure, 'marked-survivor:40');
      expect(result.remaining.single.pid, 40);
    },
  );

  test('unlistable process table makes every unit unresolved', () async {
    final table = FakeProcessTable(
      pids: [],
      listFails: true,
      onSnapshot: (_) => null,
      onEnvironment: (_) => const [],
    );

    final result = await scan(table);

    expect(result.failure, 'scan-unlistable');
    expect(result.clean, isFalse);
  });

  test('a pass that exceeds its timeout yields scan-timeout', () async {
    final table = FakeProcessTable(
      pids: [50, 51],
      onSnapshot: (_) => _snap(100),
      onEnvironment: (_) => const [],
    );

    final result = await scan(table, passTimeout: Duration.zero);

    expect(result.failure, 'scan-timeout');
  });

  test('population is current-user processes inside the time window', () async {
    final oldest = created.subtract(const Duration(seconds: 1));
    final table = FakeProcessTable(
      pids: [60, 61, 62, 63],
      onSnapshot: (pid) => switch (pid) {
        60 => _snap(1, uid: 0), // another user
        61 => _snap(2, at: oldest.subtract(const Duration(milliseconds: 1))),
        62 => _snap(3, at: oldest), // exactly on the margin: read
        _ => _snap(4),
      },
      onEnvironment: (pid) {
        expect(
          pid,
          anyOf(62, 63),
          reason: 'pid $pid is outside the population',
        );
        return const [];
      },
    );

    final result = await scan(table);

    expect(result.clean, isTrue);
  });

  // Issue #40, design D1: a process the first pass cannot read is cleared
  // only by kernel evidence of its full exit seen before the second
  // listing. Every answer below changes on a call count, never on time
  // (AGENTS.md rules 2 and 3).
  group('a process that exits during the scan', () {
    test('a recheck-confirmed exit still gets a second listing after the '
        'confirmation', () async {
      final table = FakeProcessTable(
        pids: [10],
        onList: (n) => n == 1 ? [10] : [],
        onSnapshot: (_) => _snap(100),
        onEnvironment: (_) => throw const ProcessGone(),
        onConfirmedExits: (_, _) => true,
      );

      final result = await scan(table);

      expect(result.failure, isNull, reason: '$result');
      expect(table.calls, ['list', 'confirm:10', 'list']);
    });

    test(
      'a pending process confirmed during the settle contributes no failure',
      () async {
        late final FakeProcessTable table;
        table = FakeProcessTable(
          pids: [20],
          onList: (n) => n == 1 ? [20] : [],
          onSnapshot: (_) => _snap(100),
          onEnvironment: (_) => throw const ProcessReadDenied(),
          onConfirmedExits: (pid, _) => table.confirmCalls[pid]! >= 2,
        );

        final result = await scan(table);

        expect(result.failure, isNull, reason: '$result');
        expect(table.calls, ['list', 'confirm:20', 'confirm:20', 'list']);
      },
    );

    test('a pending process never confirmed yields scan-unreadable', () async {
      final table = FakeProcessTable(
        pids: [20],
        onSnapshot: (_) => _snap(100),
        onEnvironment: (_) => throw const ProcessReadDenied(),
      );

      final result = await scan(table);

      expect(result.failure, 'scan-unreadable:20');
      expect(table.listCount, 2);
    });

    test(
      'a pending process gone only in the second pass stays scan-unreadable',
      () async {
        late final FakeProcessTable table;
        table = FakeProcessTable(
          pids: [20],
          // Gone from the second listing, and confirmed only after it.
          onList: (n) => n == 1 ? [20] : [],
          onSnapshot: (_) => _snap(100),
          onEnvironment: (_) => throw const ProcessReadDenied(),
          onConfirmedExits: (_, _) => table.listCount >= 2,
        );

        final result = await scan(table);

        expect(result.failure, 'scan-unreadable:20');
        expect(result.clean, isFalse);
      },
    );

    test('null or zombie snapshot without confirmed exit is pending', () async {
      final table = FakeProcessTable(
        pids: [30, 31],
        onList: (n) => n == 1 ? [30, 31] : [],
        onSnapshot: (pid) => pid == 30 ? null : _snap(100, zombie: true),
        onEnvironment: (pid) => fail('pid $pid was not readable'),
      );

      final result = await scan(table);

      expect(result.failure, 'scan-unreadable:30');
      expect(table.confirmCalls.keys, containsAll([30, 31]));
    });

    test('a zombie without confirmed exit stays pending when it leaves the '
        'listing', () async {
      // On its own, so the zombie alone must keep the scan unresolved
      // (pre-ship review round 2, F2).
      final table = FakeProcessTable(
        pids: [31],
        onList: (n) => n == 1 ? [31] : [],
        onSnapshot: (_) => _snap(100, zombie: true),
        onEnvironment: (pid) => fail('pid $pid was not readable'),
      );

      final result = await scan(table);

      expect(result.failure, 'scan-unreadable:31');
      expect(table.listCount, 2);
    });

    test('out-of-population zombie is skipped without an exit check', () async {
      final before = created.subtract(const Duration(seconds: 2));
      final table = FakeProcessTable(
        pids: [40, 41],
        onSnapshot: (pid) => pid == 40
            ? _snap(100, uid: 0, zombie: true) // another user
            : _snap(101, at: before, zombie: true), // before the window
        onEnvironment: (pid) => fail('pid $pid is outside the population'),
      );

      final result = await scan(table);

      expect(result.failure, isNull, reason: '$result');
      expect(table.calls, ['list'], reason: 'no exit check, no second pass');
    });

    test(
      'a short-info placeholder start time does not exclude a zombie',
      () async {
        final starts = <int?>[];
        final table = FakeProcessTable(
          pids: [42],
          onList: (n) => n == 1 ? [42] : [],
          // The macOS short read: start time 0 at the epoch, a placeholder.
          onSnapshot: (_) => ProcessSnapshot(
            startTime: 0,
            startedAt: DateTime.fromMicrosecondsSinceEpoch(0),
            uid: 1000,
            zombie: true,
          ),
          onEnvironment: (pid) => fail('pid $pid was not readable'),
          onConfirmedExits: (_, start) {
            starts.add(start);
            return false;
          },
        );

        final result = await scan(table);

        expect(result.failure, 'scan-unreadable:42');
        expect(starts, everyElement(isNull), reason: 'start time unknown');
      },
    );

    test("a null snapshot of another user's pid is skipped", () async {
      final table = FakeProcessTable(
        pids: [43],
        onSnapshot: (_) => null,
        onEnvironment: (pid) => fail('pid $pid was not readable'),
        onForeignPids: (pid) => pid == 43,
      );

      final result = await scan(table);

      expect(result.failure, isNull, reason: '$result');
      // Asked only after its exit is not confirmed; still not read, so the
      // second listing runs (pre-ship review F1).
      expect(table.calls, [
        'list',
        'confirm:43',
        'foreign:43',
        'list',
        'confirm:43',
        'foreign:43',
      ]);
    });

    test(
      'a null-snapshot pid named foreign still gets a second listing',
      () async {
        // Reaped between the listings, the pid is absent from our user's
        // listing too: naming it is no evidence it never was ours (F1).
        final table = FakeProcessTable(
          pids: [44],
          onList: (n) => n == 1 ? [44] : [45],
          onSnapshot: (pid) => pid == 44 ? null : _snap(145),
          onEnvironment: (pid) => pid == 45
              ? ['$unitMarkerVariable=$marker']
              : fail('pid $pid was not readable'),
          onForeignPids: (pid) => pid == 44,
        );

        final result = await scan(table);

        expect(result.failure, 'marked-survivor:45');
      },
    );

    test('a process that exits after its failed read on the final pass is '
        'unreadable', () async {
      // Pass 2 refuses 52, which exits only once 53 has been read: a
      // check deferred to the end of the pass would clear it (F2).
      var killed = false;
      var exited = false;
      var secondPass = false;
      final table = FakeProcessTable(
        pids: [50, 52, 53],
        onSnapshot: (pid) {
          if (pid == 50) return killed ? null : _snap(150);
          if (pid == 53 && secondPass) exited = true;
          return _snap(100 + pid);
        },
        onEnvironment: (pid) {
          if (pid == 50) return ['$unitMarkerVariable=$marker'];
          if (pid == 52 && secondPass) throw const ProcessReadDenied();
          return ['PATH=/bin'];
        },
        onKill: (_, _) => killed = true,
        onList: (n) {
          secondPass = n == 2;
          return [50, 52, 53];
        },
        onConfirmedExits: (pid, _) => pid == 50 || (pid == 52 && exited),
      );

      final result = await scan(table);

      expect(result.failure, 'scan-unreadable:52');
    });

    test('each exit check runs inside its own pid iteration', () async {
      // The pass clock covers every exit check (F3).
      late final FakeProcessTable table;
      table = FakeProcessTable(
        pids: [90, 91],
        onList: (n) => n == 1 ? [90, 91] : [],
        onSnapshot: (pid) => _snap(100 + pid),
        onEnvironment: (_) => throw const ProcessReadDenied(),
        onConfirmedExits: (_, _) => true,
      );

      final result = await scan(
        table,
        passExpired: () {
          table.calls.add('check');
          return false;
        },
      );

      expect(result.failure, isNull, reason: '$result');
      expect(table.calls, [
        'list',
        'check',
        'confirm:90',
        'check',
        'confirm:91',
        'list',
      ]);
    });

    test(
      'refusal first seen on the second pass yields scan-unreadable',
      () async {
        {
          var killed = false;
          var refusals = 0;
          final table = FakeProcessTable(
            pids: [50, 51],
            onSnapshot: (pid) {
              if (pid == 50) return killed ? null : _snap(150);
              // 51 is read on the first pass, refused on the second.
              if (refusals++ > 0) throw const ProcessReadDenied();
              return _snap(151);
            },
            onEnvironment: (pid) =>
                pid == 50 ? ['$unitMarkerVariable=$marker'] : ['PATH=/bin'],
            onKill: (_, _) => killed = true,
            onConfirmedExits: (pid, _) => pid == 50, // the killed one is gone
          );

          final result = await scan(table);

          expect(result.failure, 'scan-unreadable:51');
          expect(table.kills, [(50, 150)]);
        }
      },
    );

    test('child of a confirmed exit is found by the second pass', () async {
      late final FakeProcessTable table;
      table = FakeProcessTable(
        pids: [60],
        onList: (n) => n == 1 ? [60] : [61],
        onSnapshot: (pid) => _snap(100 + pid),
        onEnvironment: (pid) => pid == 60
            ? throw const ProcessReadDenied()
            : ['$unitMarkerVariable=$marker'],
        onConfirmedExits: (pid, _) => table.confirmCalls[pid]! >= 2,
      );

      final result = await scan(table);

      expect(result.failure, 'marked-survivor:61');
      expect(table.kills, isEmpty, reason: 'the second pass kills nothing');
    });

    test(
      'child of a recheck-confirmed exit is found by the second pass',
      () async {
        final table = FakeProcessTable(
          pids: [62],
          onList: (n) => n == 1 ? [62] : [63],
          onSnapshot: (pid) => _snap(100 + pid),
          onEnvironment: (pid) => pid == 62
              ? throw const ProcessGone()
              : ['$unitMarkerVariable=$marker'],
          onConfirmedExits: (_, _) => true,
        );

        final result = await scan(table);

        expect(result.failure, 'marked-survivor:63');
        expect(table.kills, isEmpty);
      },
    );

    test(
      'one confirmed and one unconfirmed pending pid name the unconfirmed one',
      () async {
        late final FakeProcessTable table;
        table = FakeProcessTable(
          pids: [70, 71],
          onList: (n) => n == 1 ? [70, 71] : [],
          onSnapshot: (pid) => _snap(100 + pid),
          onEnvironment: (_) => throw const ProcessReadDenied(),
          onConfirmedExits: (pid, _) =>
              pid == 70 && table.confirmCalls[pid]! >= 2,
        );

        final result = await scan(table);

        expect(result.failure, 'scan-unreadable:71');
      },
    );

    test(
      'unconfirmed pid then an unlistable second pass yields scan-unlistable',
      () async {
        final table = FakeProcessTable(
          pids: [72],
          onList: (n) =>
              n == 1 ? [72] : throw const ProcessTableUnlistable('scripted'),
          onSnapshot: (_) => _snap(100),
          onEnvironment: (_) => throw const ProcessReadDenied(),
        );

        final result = await scan(table);

        expect(result.failure, 'scan-unlistable');
        expect(result.clean, isFalse);
      },
    );

    test(
      'a timed-out first pass kills its matches and drops pending pids',
      () async {
        var checks = 0;
        final table = FakeProcessTable(
          pids: [80, 81, 82],
          onSnapshot: (pid) => _snap(100 + pid),
          onEnvironment: (pid) => switch (pid) {
            80 => ['$unitMarkerVariable=$marker'],
            81 => throw const ProcessReadDenied(),
            _ => fail('pid $pid is past the timeout'),
          },
        );

        // The pass expires before its third pid: driven by a count, not time.
        final result = await scan(table, passExpired: () => checks++ >= 2);

        expect(result.failure, 'scan-timeout');
        expect(table.kills, [(80, 180)]);
        expect(table.calls, [
          'list',
          'confirm:81',
        ], reason: 'no exit check past the expiry, no settle, no second pass');
      },
    );
  });

  test('real process table finds and kills a marked process', () async {
    final id = 'scan-smoke-${pid}_${DateTime.now().microsecondsSinceEpoch}';
    final before = DateTime.now();
    final sleeper = await Process.start(
      'sleep',
      ['60'],
      environment: {unitMarkerVariable: id},
    );
    addTearDown(() => sleeper.kill(ProcessSignal.sigkill));

    final result = await runMarkerScan(
      table: PosixProcessTable(),
      markers: {id},
      oldestCreatedAt: before,
    );

    expect(result.failure, isNull, reason: '$result');
    expect(result.killed.map((p) => p.pid), [sleeper.pid]);
    expect(await sleeper.exitCode, -9);
  }, skip: Platform.isWindows ? 'the marker scan is POSIX only' : false);
}
