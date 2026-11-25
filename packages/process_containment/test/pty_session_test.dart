import 'package:process_containment/process_containment.dart';
import 'package:test/fake.dart';
import 'package:test/test.dart';

import 'support/pty_session.dart';

/// The PTY test support's own teardown (change `fix-pty-wait-hang-guard`
/// D2): when output does not end, `dispose` closes what is safe, keeps the
/// read handle the reader may still use, and fails naming the unit. A fake
/// unit, a reader whose output never ends and an end-of-output wait that
/// fires its guard as soon as `dispose` reaches it keep this off the clock.
void main() {
  const handles = PtyHandles(readHandle: 11, writeHandle: 12);

  test('dispose without end of output closes the write handle, keeps the '
      'read handle and fails naming the unit', () async {
    final unit = _Unit();
    final closed = <int>[];
    final session = PtySession(
      unit,
      handles,
      reader: PtyReader.detached(),
      closeHandle: closed.add,
      drain: (done, what, {state}) async =>
          throw StateError('hang guard: no $what'),
    );

    await expectLater(
      session.dispose(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('unit pid 4242'), contains('end of output')),
        ),
      ),
    );
    expect(unit.terminations, 1);
    expect(closed, [12]);
  });

  test('dispose closes both handles once output ended', () async {
    final unit = _Unit();
    final closed = <int>[];
    final session = PtySession(
      unit,
      handles,
      reader: PtyReader.detached(ended: true),
      closeHandle: closed.add,
    );

    await session.dispose();
    expect(unit.terminations, 1);
    expect(closed, [11, 12]);
  });

  test('a failed terminate still closes the safe handles and fails', () async {
    final unit = _Unit(fail: true);
    final closed = <int>[];
    final session = PtySession(
      unit,
      handles,
      reader: PtyReader.detached(ended: true),
      closeHandle: closed.add,
    );

    await expectLater(
      session.dispose(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('unit pid 4242'), contains('terminate failed')),
        ),
      ),
    );
    expect(closed, [11, 12]);
  });
}

class _Unit extends Fake implements ContainedUnit {
  _Unit({this.fail = false});

  final bool fail;
  var terminations = 0;

  @override
  int get pid => 4242;

  @override
  Future<TerminationResult> terminate() async {
    terminations++;
    if (fail) throw StateError('terminate failed');
    return const TerminationResult.terminated();
  }
}
