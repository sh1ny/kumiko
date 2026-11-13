import 'dart:async';

import 'package:host/src/agent/startup_diagnostics.dart';
import 'package:test/test.dart';

class _Deadline implements Timer {
  _Deadline(this.duration, this.callback);
  final Duration duration;
  final void Function() callback;
  @override
  bool isActive = true;
  @override
  int get tick => 0;
  @override
  void cancel() => isActive = false;
  void fire() {
    if (!isActive) return;
    isActive = false;
    callback();
  }
}

void main() {
  const budget = Duration(seconds: 1);
  late List<_Deadline> deadlines;
  Future<int?> drain(Future<void> stderr, Future<int> exit, {int? known}) =>
      runZoned(
        () => drainStartupDiagnostics(
          stderrDone: stderr,
          exitCode: exit,
          budget: budget,
          knownStatus: known,
        ),
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            final deadline = _Deadline(duration, callback);
            deadlines.add(deadline);
            return deadline;
          },
        ),
      );
  setUp(() => deadlines = []);

  test(
    'stderr EOF before delayed exit publication retains actual status',
    () async {
      final stderr = Completer<void>();
      final exit = Completer<int>();
      var finished = false;
      final result = drain(stderr.future, exit.future)
        ..then((_) => finished = true);
      stderr.complete();
      await Future<void>(() {});
      final finishedBeforeExit = finished;
      exit.complete(37);
      final status = await result;
      expect(finishedBeforeExit, false);
      expect(status, 37);
    },
  );

  test('hanging exit remains unknown at the existing read deadline', () async {
    final exit = Completer<int>();
    var finished = false;
    final result = drain(Future<void>.value(), exit.future)
      ..then((_) => finished = true);
    await Future<void>(() {});
    expect(finished, false);
    expect(deadlines.single.duration, budget);
    deadlines.single.fire();
    expect(await result, isNull);
    exit.complete(37);
  });

  test('stderr delay shares one budget with exit publication', () async {
    final stderr = Completer<void>();
    final exit = Completer<int>();
    final result = drain(stderr.future, exit.future);
    exit.complete(37);
    await Future<void>(() {});
    expect(deadlines, hasLength(1));
    expect(deadlines.single.duration, budget);
    deadlines.single.fire();
    expect(await result, 37);
    stderr.complete();
    expect(deadlines, hasLength(1));
  });

  test('already known status survives stderr timeout', () async {
    final stderr = Completer<void>();
    final result = drain(stderr.future, Future<int>.value(42), known: 42);
    await Future<void>(() {});
    deadlines.single.fire();
    expect(await result, 42);
    stderr.complete();
  });

  test('already known status survives stderr error', () async {
    final stderr = Completer<void>();
    final result = drain(stderr.future, Future<int>.value(42), known: 42);
    final assertion = expectLater(result, completion(42));
    stderr.completeError(StateError('synthetic stderr failure'));
    await assertion;
  });

  test(
    'exit observation error preserves unknown status without replacing failure',
    () async {
      final exit = Completer<int>();
      final result = drain(Future<void>.value(), exit.future);
      final assertion = expectLater(result, completion(isNull));
      exit.completeError(StateError('synthetic exit observation failure'));
      await assertion;
    },
  );
}
