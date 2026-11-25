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
Future<T> guarded<T>(
  Future<T> future,
  String what, {
  String Function()? state,
}) => future.timeout(
  hangGuard,
  onTimeout: () => throw StateError(
    'hang guard: no $what within $hangGuard'
    '${state == null ? '' : ': ${state()}'}',
  ),
);
