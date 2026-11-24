@Timeout(Duration(minutes: 2))
library;

import 'package:process_containment/process_containment.dart';
import 'package:process_containment/src/kill_guard.dart';
import 'package:process_containment/src/libc.dart' show eperm, esrch;
import 'package:test/test.dart';

/// The guarded kill decision (design D1, D3) with every process read and
/// signal scripted, so the leader exiting or its pid being reused between
/// the calls is exercised on every platform, with no real processes.
void main() {
  const pid = 4242;
  const recorded = 777;
  const term = 15;

  ProcessSnapshot running(int startTime) => ProcessSnapshot(
    startTime: startTime,
    startedAt: DateTime.fromMicrosecondsSinceEpoch(0),
    uid: 1000,
  );
  ProcessSnapshot zombie(int startTime) => ProcessSnapshot(
    startTime: startTime,
    startedAt: DateTime.fromMicrosecondsSinceEpoch(0),
    uid: 1000,
    zombie: true,
  );
  final denied = Object();

  group('refused killpg', () {
    test(
      'refused killpg: probe ESRCH is leaderGone, with no snapshot read',
      () {
        final s = _Script(
          snapshots: [running(recorded)],
          killpg: [eperm],
          kill: [esrch],
        );
        expect(s.run(pid, recorded, term), KillOutcome.leaderGone);
        expect(s.calls, ['snapshot', 'killpg $term', 'kill 0']);
      },
    );

    test('a zombie at the pid is leaderGone', () {
      final s = _Script(
        snapshots: [running(recorded), zombie(recorded)],
        killpg: [eperm],
        kill: [0],
      );
      expect(s.run(pid, recorded, term), KillOutcome.leaderGone);
      expect(s.calls, ['snapshot', 'killpg $term', 'kill 0', 'snapshot']);
    });

    test('another nonzero start time is startTimeMismatch', () {
      final s = _Script(
        snapshots: [running(recorded), running(recorded + 1)],
        killpg: [eperm],
        kill: [0],
      );
      expect(s.run(pid, recorded, term), KillOutcome.startTimeMismatch);
      expect(s.sentSignals, [term]);
    });

    test('refused killpg: an inconclusive recheck is failed', () {
      for (final recheck in <Object?>[
        running(recorded), // the same leader: a real refusal
        running(0), // the macOS placeholder of another user's process
        null, // not found, but the probe did not confirm absence
        denied, // the read is refused
      ]) {
        final s = _Script(
          snapshots: [running(recorded), recheck],
          killpg: [eperm],
          kill: [0],
          denied: denied,
        );
        expect(
          s.run(pid, recorded, term),
          KillOutcome.failed,
          reason: '$recheck',
        );
        expect(s.sentSignals, [term], reason: '$recheck');
      }
    });

    test('a recorded start time of 0 never confirms a replacement', () {
      final s = _Script(
        snapshots: [running(0), running(recorded)],
        killpg: [eperm],
        kill: [0],
      );
      expect(s.run(pid, 0, term), KillOutcome.failed);
      expect(s.sentSignals, [term]);
    });
  });

  group('killpg ESRCH, fallback allowed (a unit of this run)', () {
    test('a confirmed leader is signalled directly', () {
      final s = _Script(
        snapshots: [running(recorded), running(recorded)],
        killpg: [esrch],
        kill: [0, 0],
      );
      expect(s.run(pid, recorded, term, fallback: true), KillOutcome.signalled);
      expect(s.calls, [
        'snapshot',
        'killpg $term',
        'kill 0',
        'snapshot',
        'kill $term',
      ]);
    });

    test('a direct signal that finds no process is leaderGone', () {
      final s = _Script(
        snapshots: [running(recorded), running(recorded)],
        killpg: [esrch],
        kill: [0, esrch],
      );
      expect(
        s.run(pid, recorded, term, fallback: true),
        KillOutcome.leaderGone,
      );
    });

    test('a refused direct signal with an inconclusive recheck is failed', () {
      for (final recheck in <Object?>[
        running(recorded), // the same leader: a real refusal
        running(0), // the macOS placeholder of another user's process
        null, // not found, but the probe did not confirm absence
        denied, // the read is refused
      ]) {
        final s = _Script(
          snapshots: [running(recorded), running(recorded), recheck],
          killpg: [esrch],
          kill: [0, eperm, 0],
          denied: denied,
        );
        expect(
          s.run(pid, recorded, term, fallback: true),
          KillOutcome.failed,
          reason: '$recheck',
        );
        expect(s.sentSignals, [term, term], reason: '$recheck');
      }
    });

    test('a refused direct signal whose leader then exits is leaderGone', () {
      final s = _Script(
        snapshots: [running(recorded), running(recorded)],
        killpg: [esrch],
        kill: [0, eperm, esrch],
      );
      expect(
        s.run(pid, recorded, term, fallback: true),
        KillOutcome.leaderGone,
      );
    });

    test('a refused direct signal is resolved by the recheck snapshot', () {
      final exited = _Script(
        snapshots: [running(recorded), running(recorded), zombie(recorded)],
        killpg: [esrch],
        kill: [0, eperm, 0],
      );
      expect(
        exited.run(pid, recorded, term, fallback: true),
        KillOutcome.leaderGone,
      );
      expect(exited.sentSignals, [term, term]);

      final reused = _Script(
        snapshots: [
          running(recorded),
          running(recorded),
          running(recorded + 1),
        ],
        killpg: [esrch],
        kill: [0, eperm, 0],
      );
      expect(
        reused.run(pid, recorded, term, fallback: true),
        KillOutcome.startTimeMismatch,
      );
      expect(reused.sentSignals, [term, term]);
    });

    test('killpg ESRCH: an unconfirmed leader gets no direct signal', () {
      for (final recheck in <Object?>[running(0), null, denied]) {
        final s = _Script(
          snapshots: [running(recorded), recheck],
          killpg: [esrch],
          kill: [0],
          denied: denied,
        );
        expect(
          s.run(pid, recorded, term, fallback: true),
          KillOutcome.failed,
          reason: '$recheck',
        );
        expect(s.sentSignals, [term], reason: '$recheck');
      }
    });

    test('killpg ESRCH: matching zero start times confirm nothing', () {
      // A recorded 0 and a live 0 are both the macOS placeholder: equal, but
      // no evidence that the pid is still the leader.
      final s = _Script(
        snapshots: [running(0), running(0)],
        killpg: [esrch],
        kill: [0],
      );
      expect(s.run(pid, 0, term, fallback: true), KillOutcome.failed);
      expect(s.sentSignals, [term]);
    });

    test('killpg ESRCH: a gone or replaced leader gets no direct signal', () {
      final gone = _Script(
        snapshots: [running(recorded)],
        killpg: [esrch],
        kill: [esrch],
      );
      expect(
        gone.run(pid, recorded, term, fallback: true),
        KillOutcome.leaderGone,
      );
      expect(gone.calls, ['snapshot', 'killpg $term', 'kill 0']);

      final reused = _Script(
        snapshots: [running(recorded), running(recorded + 1)],
        killpg: [esrch],
        kill: [0],
      );
      expect(
        reused.run(pid, recorded, term, fallback: true),
        KillOutcome.startTimeMismatch,
      );
      expect(reused.sentSignals, [term]);
    });
  });

  group('killpg ESRCH, fallback disallowed (a recorded unit)', () {
    test('fallback disallowed: killpg ESRCH with the recorded start time is '
        'failed, with no direct signal', () {
      final s = _Script(
        snapshots: [running(recorded), running(recorded)],
        killpg: [esrch],
        kill: [0],
      );
      expect(s.run(pid, recorded, term), KillOutcome.failed);
      expect(s.sentSignals, [term]);
    });

    test('a confirmed exit is still leaderGone', () {
      final s = _Script(
        snapshots: [running(recorded)],
        killpg: [esrch],
        kill: [esrch],
      );
      expect(s.run(pid, recorded, term), KillOutcome.leaderGone);
    });
  });

  group('first check (unchanged mapping)', () {
    test('a refused first read is failed, with no signal', () {
      final s = _Script(snapshots: [denied], denied: denied);
      expect(s.run(pid, recorded, term), KillOutcome.failed);
      expect(s.sentSignals, isEmpty);
    });

    test('a group signal that lands is signalled', () {
      final s = _Script(snapshots: [running(recorded)], killpg: [0]);
      expect(s.run(pid, recorded, term), KillOutcome.signalled);
      expect(s.calls, ['snapshot', 'killpg $term']);
    });
  });
}

/// Scripted answers, consumed in order; every call is logged, and every
/// call must target the leader's pid (a `kill(0, 0)` probe would test the
/// caller's own group). A snapshot
/// answer equal to [denied] throws [ProcessReadDenied].
class _Script {
  _Script({
    required List<Object?> snapshots,
    List<int> killpg = const [],
    List<int> kill = const [],
    this.denied,
  }) : _snapshots = [...snapshots],
       _killpg = [...killpg],
       _kill = [...kill];

  final List<Object?> _snapshots;
  final List<int> _killpg;
  final List<int> _kill;
  final Object? denied;
  final calls = <String>[];

  /// The signals actually sent (signal 0 probes excluded).
  List<int> get sentSignals => [
    for (final c in calls)
      if (c.startsWith('kill') && !c.endsWith(' 0')) int.parse(c.split(' ')[1]),
  ];

  KillOutcome run(
    int pid,
    int startTime,
    int signal, {
    bool fallback = false,
  }) => guardedKill(
    pid: pid,
    startTime: startTime,
    signal: signal,
    directFallback: fallback,
    snapshot: (p) {
      calls.add('snapshot');
      expect(p, pid, reason: 'snapshot of another pid');
      expect(_snapshots, isNotEmpty, reason: 'unscripted snapshot');
      final answer = _snapshots.removeAt(0);
      if (answer != null && identical(answer, denied)) {
        throw const ProcessReadDenied();
      }
      return answer as ProcessSnapshot?;
    },
    killpg: (p, s) {
      calls.add('killpg $s');
      expect(p, pid, reason: 'killpg of another group');
      expect(_killpg, isNotEmpty, reason: 'unscripted killpg');
      return _killpg.removeAt(0);
    },
    kill: (p, s) {
      calls.add('kill $s');
      expect(p, pid, reason: 'kill of another pid');
      expect(_kill, isNotEmpty, reason: 'unscripted kill');
      return _kill.removeAt(0);
    },
  );
}
