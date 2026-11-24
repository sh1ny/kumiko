import 'package:process_containment/process_containment.dart';
import 'package:process_containment/src/posix_process_table.dart';
import 'package:test/test.dart';

/// The macOS short read (`PROC_PIDT_SHORTBSDINFO`) answers when the full read
/// is refused. A refused full read of one of our own processes means a
/// zombie, which has no credentials left: it must read as a zombie, not as
/// unreadable, or a marker scan that passes it reports `scan-unreadable` (#30).
void main() {
  const me = 501;

  test('our own zombie reads as a zombie', () {
    final snapshot = macShortInfoSnapshot(
      uid: me,
      zombie: true,
      currentUid: me,
    );
    expect(snapshot.zombie, isTrue);
    expect(snapshot.uid, me);
  });

  test('another user\'s zombie reads as a zombie', () {
    final snapshot = macShortInfoSnapshot(uid: 0, zombie: true, currentUid: me);
    expect(snapshot.zombie, isTrue);
  });

  test('one of our own live processes stays unreadable', () {
    expect(
      () => macShortInfoSnapshot(uid: me, zombie: false, currentUid: me),
      throwsA(isA<ProcessReadDenied>()),
    );
  });

  test('another user\'s live process reads with start time 0', () {
    final snapshot = macShortInfoSnapshot(
      uid: 0,
      zombie: false,
      currentUid: me,
    );
    expect(snapshot.zombie, isFalse);
    expect(snapshot.startTime, 0);
    expect(snapshot.uid, 0);
  });
}
