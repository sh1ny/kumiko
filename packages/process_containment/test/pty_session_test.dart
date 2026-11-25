import 'dart:async';

import 'package:process_containment/process_containment.dart';
import 'package:test/fake.dart';
import 'package:test/test.dart';

import 'support/hang_guard.dart';
import 'support/pty_session.dart';

/// The PTY test support's own waits and teardown (change
/// `fix-pty-wait-hang-guard` D1, D2). The hang guard is fired through its
/// expiry future, never a clock: a fake unit, a reader whose output never
/// ends, and the real `guarded` wait inside `dispose`.
void main() {
  group('guarded', () {
    test('fails naming what it waited for and the state once the guard '
        'expires', () async {
      final expiry = Completer<void>();
      final wait = guarded(
        Completer<int>().future,
        'the marker',
        state: () => 'output so far',
        expiry: expiry.future,
      );
      expiry.complete();
      await expectLater(
        wait,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('the marker'), contains('output so far')),
          ),
        ),
      );
    });

    test('completes with the value when it arrives first, and a later expiry '
        'changes nothing', () async {
      final expiry = Completer<void>();
      final wait = guarded(Future.value(7), 'seven', expiry: expiry.future);
      expect(await wait, 7);
      expiry.complete();
      await expectLater(wait, completion(7));
    });
  });

  group('PtySession.dispose', () {
    const handles = PtyHandles(readHandle: 11, writeHandle: 12);

    test('without end of output closes the write handle, keeps the read '
        'handle and fails naming the unit', () async {
      final unit = _Unit();
      final closed = <int>[];
      final expiry = Completer<void>();
      final session = PtySession(
        unit,
        handles,
        reader: PtyReader.detached(),
        drainExpiry: expiry.future,
        closeHandle: closed.add,
      );

      // Output never ends, so the real end-of-output wait in dispose can only
      // finish through its guard, fired here.
      expiry.complete();
      await expectLater(
        session.dispose(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('unit pid 4242'),
              contains('end of output after dispose'),
            ),
          ),
        ),
      );
      expect(unit.terminations, 1);
      expect(closed, [12]);
    });

    test('closes both handles once output ended', () async {
      final unit = _Unit();
      final closed = <int>[];
      final session = PtySession(
        unit,
        handles,
        reader: PtyReader.detached(ended: true),
        // Never fired: the output has ended, so the wait does not need it.
        drainExpiry: Completer<void>().future,
        closeHandle: closed.add,
      );

      await session.dispose();
      expect(unit.terminations, 1);
      expect(closed, [11, 12]);
    });

    test('a failed termination still closes the safe handles and fails with '
        'its reason', () async {
      final unit = _Unit(failure: 'kill-failed:1');
      final closed = <int>[];
      final session = PtySession(
        unit,
        handles,
        reader: PtyReader.detached(ended: true),
        drainExpiry: Completer<void>().future,
        closeHandle: closed.add,
      );

      await expectLater(
        session.dispose(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('unit pid 4242'), contains('kill-failed:1')),
          ),
        ),
      );
      expect(closed, [11, 12]);
    });
  });
}

/// A unit whose termination succeeds, or reports [failure] the way the native
/// units do: a failed result, not a throw.
class _Unit extends Fake implements ContainedUnit {
  _Unit({this.failure});

  final String? failure;
  var terminations = 0;

  @override
  int get pid => 4242;

  @override
  Future<TerminationResult> terminate() async {
    terminations++;
    final reason = failure;
    return reason == null
        ? const TerminationResult.terminated()
        : TerminationResult.failed(reason);
  }
}
