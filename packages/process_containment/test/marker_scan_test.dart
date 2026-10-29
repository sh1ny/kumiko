import 'dart:io';

import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/fake_process_table.dart';

final _epoch = DateTime.utc(2026, 1, 1, 12);

ProcessSnapshot _snap(int start, {int uid = 1000, DateTime? at}) =>
    ProcessSnapshot(startTime: start, startedAt: at ?? _epoch, uid: uid);

void main() {
  const marker = 'unit-a';
  final created = _epoch.subtract(const Duration(minutes: 1));

  Future<MarkerScanResult> scan(
    FakeProcessTable table, {
    Duration passTimeout = const Duration(seconds: 10),
  }) => runMarkerScan(
    table: table,
    markers: {marker},
    oldestCreatedAt: created,
    passTimeout: passTimeout,
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
