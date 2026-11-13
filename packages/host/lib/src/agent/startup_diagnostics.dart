import 'dart:async';

Future<int?> drainStartupDiagnostics({
  required Future<void> stderrDone,
  required Future<int> exitCode,
  required Duration budget,
  int? knownStatus,
}) async {
  var observedStatus = knownStatus;
  try {
    // Containment is settled by the caller. These independent observations
    // share its existing post-exit read budget, rather than serial deadlines.
    await Future.wait<void>([
      stderrDone,
      exitCode.then<void>((status) {
        observedStatus = status;
      }),
    ]).timeout(budget);
  } on Object {
    // Diagnostic drains must not replace the primary failure. Preserve any
    // status actually observed before an error or deadline; never invent one.
  }
  return observedStatus;
}
