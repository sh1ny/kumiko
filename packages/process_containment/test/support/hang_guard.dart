import 'dart:async';

/// The real-time limit on a wait in this package's PTY test support.
///
/// It only stops a hung test. A wait under it waits for its event (the text,
/// the console closer, the end of output, the state a poll looks for), never
/// for a short budget that also has to cover a process start or other I/O on
/// a slow runner. Its expiry is never an outcome: a wait that reaches it fails
/// and names what it was waiting for.
///
/// Two minutes is below each test file's own `@Timeout`, the outer hang
/// guard. A hung wait reports itself first unless the test's earlier steps
/// already used most of that timeout; then the runner's timeout, which names
/// the test, ends it instead. Neither expiry is an expected outcome.
const hangGuard = Duration(minutes: 2);

/// Waits for [future] under [hangGuard]. If the guard expires first, throws a
/// [StateError] naming [what] and, when given, the [state] seen so far.
///
/// [expiry] replaces the real [hangGuard] timer: the guard expires when it
/// completes. Only tests of the waits themselves pass it, to fire the guard
/// at the stage they test without a clock.
Future<T> guarded<T>(
  Future<T> future,
  String what, {
  String Function()? state,
  Future<void>? expiry,
}) {
  final expired = Completer<void>();
  void expire() {
    if (!expired.isCompleted) expired.complete();
  }

  final timer = expiry == null ? Timer(hangGuard, expire) : null;
  expiry?.then((_) => expire());
  return Future.any<T>([
    future,
    expired.future.then<T>(
      (_) => throw StateError(
        'hang guard expired waiting for $what'
        '${state == null ? '' : ': ${state()}'}',
      ),
    ),
  ]).whenComplete(() => timer?.cancel());
}
