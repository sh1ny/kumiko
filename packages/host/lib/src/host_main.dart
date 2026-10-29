import 'dart:async';
import 'dart:io';

import 'package:process_containment/process_containment.dart';

import 'host.dart';
import 'host_extension.dart';

const String _usage = 'usage: kumiko_host --profile <dir>';

/// The host's entry, shared by the release and the test executable (design
/// D10). [extension] is passed only by the test entry point.
///
/// `--unit-exec` is dispatched here, so both executables have it (D2).
/// `--test-fixture` is dispatched only with an [extension]: in the release
/// host it is a usage error that starts nothing and touches nothing.
Future<int> hostMain(List<String> args, {HostExtension? extension}) async {
  if (args.isNotEmpty && args.first == '--unit-exec') {
    runUnitExec(args.sublist(1));
  }
  if (args.isNotEmpty && args.first == '--test-fixture') {
    if (extension == null) {
      stderr.writeln('kumiko_host: unknown option --test-fixture\n$_usage');
      return HostExit.usage;
    }
    return extension.runFixture(args.sublist(1));
  }

  String? profile;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--profile' && i + 1 < args.length) profile = args[++i];
  }
  if (profile == null || profile.isEmpty) {
    stderr.writeln(_usage);
    return HostExit.usage;
  }

  final host = Host(profile: Directory(profile), extension: extension);
  final done = Completer<int>();
  runZonedGuarded(() => host.run().then(done.complete), (error, stack) {
    stderr.writeln('kumiko_host: unexpected error: $error\n$stack');
    if (!done.isCompleted) done.complete(70);
  });
  return done.future;
}
