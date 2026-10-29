import 'dart:io';

import 'package:host/host.dart';
import 'package:host/src/test_hooks/test_hooks.dart';

/// Test entry point of the Kumiko execution host (design D10): the same host
/// as `bin/kumiko_host.dart`, plus the test capabilities, the `test/*`
/// methods and the `--test-fixture` modes. Built with
/// `dart build cli -t tool/kumiko_host_test.dart -o build/host-test`; never
/// shipped.
Future<void> main(List<String> args) async {
  exit(
    await hostMain(
      args,
      extension: TestHostExtension.fromEnvironment(Platform.environment),
    ),
  );
}
