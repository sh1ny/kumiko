import 'dart:async';
import 'dart:io';

import 'package:host/src/agent/draft_store.dart';
import 'package:host/src/host_faults.dart';
import 'package:host/src/host_options.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:test/test.dart';

/// The draft worker (change `app-exit-and-reopen` design D4, ADR 0014
/// decisions 12-16): one isolate owning `drafts.sqlite`, opened under a
/// rollback journal with `synchronous=EXTRA` and `secure_delete=ON`, with a
/// pending bound and a deadline per operation.
void main() {
  late Directory dir;
  late File file;
  late HostFaults faults;
  late List<DraftStore> stores;
  late int available;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('kumiko_drafts_');
    file = File('${dir.path}${Platform.pathSeparator}drafts.sqlite');
    faults = HostFaults();
    stores = [];
    available = 0;
  });
  tearDown(() async {
    for (final s in stores) {
      s.dispose();
    }
    // Windows may hold a killed isolate's file a moment longer.
    for (var i = 0; i < 40; i++) {
      try {
        dir.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  DraftStore open({
    File? at,
    Duration deadline = const Duration(seconds: 5),
    Duration openHold = Duration.zero,
    bool autostart = true,
  }) {
    final store = DraftStore(
      file: at ?? file,
      faults: faults,
      deadline: deadline,
      openHold: openHold,
      onAvailable: () => available++,
    );
    faults.onDraftRelease = store.releaseHeld;
    stores.add(store);
    if (autostart) store.start();
    return store;
  }

  Future<void> ready(DraftStore s) => eventually(
    () => s.phase != DraftPhase.starting,
    reason: 'the worker never finished opening',
  );

  Future<RpcException> failure(Future<Object?> call) async {
    try {
      await call;
    } on RpcException catch (e) {
      return e;
    }
    fail('the call succeeded');
  }

  Map<String, Object?> row(String session, {File? at}) {
    final db = sql.sqlite3.open((at ?? file).path, mode: sql.OpenMode.readOnly);
    try {
      final rows = db.select('SELECT * FROM draft WHERE session_id = ?', [
        session,
      ]);
      return rows.isEmpty ? {} : Map.of(rows.single);
    } finally {
      db.close();
    }
  }

  test(
    'nothing is opened before start; the file appears when started',
    () async {
      final s = open(autostart: false);
      expect(s.phase, DraftPhase.starting);
      expect(s.workersSpawned, 0);
      expect(file.existsSync(), isFalse);
      s.start();
      await ready(s);
      expect(s.phase, DraftPhase.available);
      expect(s.workersSpawned, 1);
      expect(file.existsSync(), isTrue);
    },
  );

  test('draft schema v1 and the three settings are read back', () async {
    final s = open();
    await ready(s);
    expect(s.pragmas, {
      'journal_mode': 'delete',
      'synchronous': 3, // EXTRA
      'secure_delete': 1, // ON
      'user_version': 1,
    });
    final db = sql.sqlite3.open(file.path, mode: sql.OpenMode.readOnly);
    try {
      expect(db.select('PRAGMA user_version').single.values.single, 1);
      final columns = {
        for (final r in db.select('PRAGMA table_info(draft)'))
          r['name']: (r['type'], r['notnull'], r['pk']),
      };
      expect(columns, {
        'session_id': ('TEXT', 0, 1),
        'text': ('TEXT', 0, 0),
        'bytes': ('INTEGER', 1, 0),
        'revision': ('INTEGER', 1, 0),
        'updated_at': ('TEXT', 1, 0),
      });
    } finally {
      db.close();
    }
    // Rollback journal: no write-ahead log appears beside the file.
    await s.save('a', 'x', 1);
    expect(File('${file.path}-wal').existsSync(), isFalse);
    expect(File('${file.path}-shm').existsSync(), isFalse);
    expect(File('${file.path}-journal').existsSync(), isFalse);
  });

  test(
    'a newer draft schema disables drafts without touching the file',
    () async {
      final db = sql.sqlite3.open(file.path)
        ..execute('PRAGMA user_version = 9');
      db.close();
      final before = file.readAsBytesSync();
      final s = open();
      await ready(s);
      expect(s.phase, DraftPhase.disabled);
      expect(s.disabledReason, contains('newer'));
      expect(file.readAsBytesSync(), before);
    },
  );

  test('a hot journal is rolled back on open', () async {
    // A transaction that spills its cache journals the old pages, changes the
    // file and is cut off: the files of that moment are copied while it is
    // still open, which is what a crash leaves.
    final big = 'old-' * 25000; // 100 KB, overflow pages
    final src = sql.sqlite3.open(file.path);
    src.execute('PRAGMA journal_mode = DELETE');
    src.execute(
      'CREATE TABLE draft(session_id TEXT PRIMARY KEY, text TEXT NULL, '
      'bytes INTEGER NOT NULL, revision INTEGER NOT NULL, '
      'updated_at TEXT NOT NULL)',
    );
    src.execute('PRAGMA user_version = 1');
    for (var i = 0; i < 6; i++) {
      src.execute('INSERT INTO draft VALUES (?, ?, ?, 1, ?)', [
        's$i',
        big,
        big.length,
        't',
      ]);
    }
    src.execute('PRAGMA cache_size = 2');
    src.execute('BEGIN IMMEDIATE');
    src.execute("UPDATE draft SET text = replace(text, 'old-', 'new-')");
    final crash = File('${dir.path}${Platform.pathSeparator}crash.sqlite');
    file.copySync(crash.path);
    File('${file.path}-journal').copySync('${crash.path}-journal');
    src.execute('ROLLBACK');
    src.close();
    expect(File('${crash.path}-journal').existsSync(), isTrue);
    expect(
      File('${crash.path}-journal').lengthSync(),
      greaterThan(512),
      reason: 'the journal must hold page images to be hot',
    );

    final s = open(at: crash);
    await ready(s);
    expect(s.phase, DraftPhase.available);
    final loaded = await s.load('s3');
    expect(loaded.text, big, reason: 'the cut-off update was rolled back');
    expect(File('${crash.path}-journal').existsSync(), isFalse);
  });

  group('operations', () {
    test('save returns the stored revision; stale carries it', () async {
      final s = open();
      expect(await s.save('a', 'first', 3), 3);
      final e = await failure(s.save('a', 'older', 3));
      expect(e.reason, ErrorCode.staleRevision);
      expect(storedRevisionOf(e), 3);
      expect(storedRevisionOf(await failure(s.save('a', 'older', 1))), 3);
      expect((await s.load('a')).text, 'first');
      expect(await s.save('a', 'second', 500), 500);
      expect(storedRevisionOf(await failure(s.save('a', 'x', 3))), 500);
      final loaded = await s.load('a');
      expect((loaded.text, loaded.revision), ('second', 500));
      final none = await s.load('never');
      expect((none.text, none.revision), (null, 0));
    });

    test('an empty save keeps a tombstone at its revision', () async {
      final s = open();
      await s.save('a', 'text', 1);
      expect(await s.save('a', '', 2), 2);
      final loaded = await s.load('a');
      expect((loaded.text, loaded.revision), (null, 2));
      expect(storedRevisionOf(await failure(s.save('a', 'late', 2))), 2);
      expect(row('a')['text'], isNull);
      expect(row('a')['bytes'], 0);
    });

    test('send removes unless a synced link holds newer text', () async {
      final s = open();
      await s.save('a', 'P', 5);
      expect(await s.commitSend('a', 5, synced: true), 5);
      expect((await s.load('a')).text, isNull);
      // A late save at or below the floor is refused.
      expect(storedRevisionOf(await failure(s.save('a', 'P', 5))), 5);

      await s.save('b', 'R', 6);
      expect(await s.commitSend('b', 5, synced: true), 6);
      expect((await s.load('b')).text, 'R', reason: 'newer text stays');

      // Unsynced: the stored revision is not comparable, so it is removed
      // and the floor is the larger of the two.
      await s.save('c', 'P', 500);
      expect(await s.commitSend('c', 1, synced: false), 500);
      final c = await s.load('c');
      expect((c.text, c.revision), (null, 500));

      // Nothing stored: the floor is still raised to r.
      expect(await s.commitSend('d', 4, synced: true), 4);
      expect(storedRevisionOf(await failure(s.save('d', 'x', 4))), 4);
    });

    test(
      'total bytes are capped; replacing a draft does not count twice',
      () async {
        final s = open();
        final full = 'a' * maxDraftBytes;
        final perDraft = maxStoredDraftBytes ~/ maxDraftBytes;
        for (var i = 0; i < perDraft; i++) {
          await s.save('s$i', full, 1);
        }
        expect(
          (await failure(s.save('extra', 'a', 1))).reason,
          ErrorCode.draftCap,
        );
        expect((await s.load('extra')).text, isNull);
        // Same size over an existing draft is not an increase.
        expect(await s.save('s0', full, 2), 2);
        // A smaller draft frees room for a small new one.
        await s.save('s1', 'tiny', 2);
        expect(await s.save('extra', 'a', 1), 1);
        expect((await s.load('s2')).text, full, reason: 'others are unchanged');
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('pending bound, deadline and not responding', () {
    test('at most 16 operations are pending; the 17th fails at once', () async {
      final s = open(deadline: const Duration(seconds: 30));
      await ready(s);
      faults.set(TestFault.draftCommitHangs, enabled: true);
      final held = [for (var i = 0; i < 16; i++) s.save('s$i', 'x', 1)];
      final outcomes = held.map<Future<Object?>>(
        (f) => f.then<Object?>((v) => v, onError: (Object e) => e),
      );
      expect(s.pending, 16);
      final watch = Stopwatch()..start();
      final e = await failure(s.save('s16', 'x', 1));
      expect(e.reason, ErrorCode.draftUnavailable);
      expect(watch.elapsedMilliseconds, lessThan(200));
      expect(s.pending, 16);

      faults.set(TestFault.draftCommitHangs, enabled: false);
      expect(await Future.wait(outcomes), everyElement(1));
      expect(s.pending, 0);
      expect(await s.save('s16', 'x', 1), 1);
    });

    test('the default deadline is 5 s', () {
      expect(HostOptions.defaultDraftDeadline, const Duration(seconds: 5));
      expect(
        DraftStore(file: file, faults: faults).deadline,
        const Duration(seconds: 5),
      );
      expect(DraftStore.maxPending, 16);
    });

    test(
      'a commit past the deadline fails and the store is not responding',
      () async {
        final s = open(deadline: const Duration(milliseconds: 400));
        await ready(s);
        final before = available;
        faults.set(TestFault.draftCommitHangs, enabled: true);
        final watch = Stopwatch()..start();
        final e = await failure(s.save('a', 'held', 1));
        expect(e.reason, ErrorCode.draftUnavailable);
        expect(watch.elapsedMilliseconds, inInclusiveRange(380, 1500));
        expect(s.notResponding, isTrue);

        // Not queued: the next operation fails at once.
        watch.reset();
        final again = await failure(s.save('b', 'x', 1));
        expect(again.reason, ErrorCode.draftUnavailable);
        expect(watch.elapsedMilliseconds, lessThan(100));
        expect(s.pending, 1, reason: 'only the stuck operation is pending');
        expect(available, before, reason: 'not announced while stuck');

        // The stuck operation returns: cleared, announced once, usable.
        faults.set(TestFault.draftCommitHangs, enabled: false);
        await eventually(() => !s.notResponding, reason: 'never cleared');
        expect(available, before + 1);
        expect(await s.save('b', 'x', 1), 1);
        // The held save did commit late.
        expect((await s.load('a')).text, 'held');
      },
    );

    test(
      'an injected commit failure rolls back and is a store error',
      () async {
        final s = open();
        await s.save('a', 'kept', 1);
        faults.set(TestFault.draftCommitFails, enabled: true);
        expect(
          (await failure(s.save('a', 'lost', 2))).reason,
          ErrorCode.storeError,
        );
        expect(
          (await failure(s.commitSend('a', 1, synced: true))).reason,
          ErrorCode.storeError,
        );
        faults.set(TestFault.draftCommitFails, enabled: false);
        final loaded = await s.load('a');
        expect((loaded.text, loaded.revision), ('kept', 1));
      },
    );
  });

  group('open and draftStoreReady', () {
    test(
      'operations wait for the open and succeed within the deadline',
      () async {
        final s = open(openHold: const Duration(milliseconds: 500));
        final watch = Stopwatch()..start();
        expect(await s.save('a', 'x', 1), 1);
        expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(450));
        expect(available, 1, reason: 'announced once the open finished');
      },
    );

    test(
      'a held open past the deadline fails operations; ready follows',
      () async {
        final s = open(
          deadline: const Duration(milliseconds: 300),
          openHold: const Duration(milliseconds: 1500),
        );
        final e = await failure(s.load('a'));
        expect(e.reason, ErrorCode.draftUnavailable);
        expect(s.notResponding, isTrue);
        expect(available, 0);
        await eventually(
          () => s.phase == DraftPhase.available && !s.notResponding,
          reason: 'the store never answered again',
        );
        expect(available, 1);
        expect(await s.save('a', 'x', 1), 1);
      },
    );

    test(
      'an unopenable file disables drafts; reset replaces it once',
      () async {
        file.writeAsStringSync('this is not a database ' * 40);
        final s = open();
        await ready(s);
        expect(s.phase, DraftPhase.disabled);
        expect(s.disabledReason, isNotNull);
        expect(available, 0);
        final watch = Stopwatch()..start();
        expect(
          (await failure(s.save('a', 'x', 1))).reason,
          ErrorCode.draftUnavailable,
        );
        expect(watch.elapsedMilliseconds, lessThan(100));

        await s.reset();
        expect(s.phase, DraftPhase.available);
        expect(s.workersSpawned, 2);
        expect(available, 1);
        expect(await s.save('a', 'after', 1), 1);
        expect((await s.load('a')).text, 'after');
        // Working now: a reset would discard it.
        expect((await failure(s.reset())).reason, ErrorCode.draftStoreInUse);
        expect((await s.load('a')).text, 'after');
      },
    );

    test('only one reset runs at a time', () async {
      file.writeAsStringSync('this is not a database ' * 40);
      final s = open();
      await ready(s);
      faults.set(TestFault.draftResetHangs, enabled: true);
      final first = s.reset();
      final second = await failure(s.reset());
      expect(second.reason, ErrorCode.draftStoreInUse);
      expect(
        (await failure(s.load('a'))).reason,
        ErrorCode.draftUnavailable,
        reason: 'operations fail while the reset holds its reservation',
      );
      faults.set(TestFault.draftResetHangs, enabled: false);
      await first;
      expect(s.workersSpawned, 2, reason: 'exactly one successor');
      expect(available, 1);
      expect(await s.save('a', 'x', 1), 1);
    });
  });

  test('measured: draft save and removal latency', () async {
    final s = open();
    await ready(s);
    const rounds = 30;
    final saves = <int>[];
    final removals = <int>[];
    final text = 'x' * 4096;
    for (var i = 1; i <= rounds; i++) {
      var watch = Stopwatch()..start();
      await s.save('m', '$text$i', i * 2);
      saves.add(watch.elapsedMicroseconds);
      watch = Stopwatch()..start();
      await s.commitSend('m', i * 2, synced: true);
      removals.add(watch.elapsedMicroseconds);
    }
    String summary(List<int> us) {
      final sorted = [...us]..sort();
      String ms(int v) => (v / 1000).toStringAsFixed(2);
      return 'median ${ms(sorted[sorted.length ~/ 2])} ms, '
          'p95 ${ms(sorted[(sorted.length * 0.95).floor()])} ms, '
          'max ${ms(sorted.last)} ms';
    }

    // ignore: avoid_print
    print(
      'measured: draft save $rounds x 4 KiB ${summary(saves)}; '
      'removal ${summary(removals)} on ${Platform.operatingSystem}',
    );
    final sortedSaves = [...saves]..sort();
    expect(
      sortedSaves[sortedSaves.length ~/ 2],
      lessThan(100000),
      reason: 'a median save above 100 ms reopens design D4',
    );
  });
}

Future<void> eventually(
  FutureOr<bool> Function() check, {
  Duration within = const Duration(seconds: 20),
  String reason = 'condition not reached',
}) async {
  final deadline = DateTime.now().add(within);
  while (!await check()) {
    if (DateTime.now().isAfter(deadline)) fail(reason);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
