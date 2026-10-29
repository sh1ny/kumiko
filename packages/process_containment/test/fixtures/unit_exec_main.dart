import 'dart:io';

import 'package:process_containment/process_containment.dart';

/// Minimal executable for the `--unit-exec` shim spike (task 5.1).
///
/// `--unit-exec <id> -- <argv...>` runs the shim; `--report <exit>` prints
/// `pid=.. sid=.. unit=..` and exits with `<exit>`.
void main(List<String> args) {
  if (args.isNotEmpty && args.first == '--unit-exec') {
    runUnitExec(args.sublist(1));
  }
  if (args.length == 2 && args.first == '--report') {
    stdout.writeln(
      'pid=$pid sid=${sessionIdOf(pid)} '
      'unit=${Platform.environment['KUMIKO_UNIT']}',
    );
    exit(int.parse(args[1]));
  }
  stderr.writeln('usage: --unit-exec <id> -- <argv...> | --report <exit>');
  exit(64);
}
