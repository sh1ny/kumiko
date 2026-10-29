import 'dart:io';

import 'package:host/host.dart';

/// Release entry point of the Kumiko execution host (design D10). It never
/// imports the test hooks: the release executable carries no test code.
Future<void> main(List<String> args) async {
  exit(await hostMain(args));
}
