import 'dart:io';

import 'package:host/host.dart';
import 'package:host/src/test_hooks/omp_agent_fixture.dart';
import 'package:host/src/test_hooks/test_hooks.dart';

/// Test entry point of the Kumiko execution host (design D10): the same host
/// as `bin/kumiko_host.dart`, plus the test capabilities, the `test/*`
/// methods and the `--test-fixture` modes. Built with
/// `dart build cli -t tool/kumiko_host_test.dart -o build/host-test`; never
/// shipped.
Future<void> main(List<String> args) async {
  // The fixture can exercise the release argument checks with a real
  // --mode rpc profile, instead of giving Continue a test-only argv exception.
  final ompScript = Platform.environment['KUMIKO_TEST_OMP_ROOT_SCRIPT'];
  if (ompScript != null && args.firstOrNull == '--mode') {
    exit(await runOmpFixture([...args, '--script', ompScript]));
  }
  final extension = TestHostExtension.fromEnvironment(Platform.environment);
  exit(
    await extension.runWithStartupHold(
      () => hostMain(args, extension: extension),
    ),
  );
}
