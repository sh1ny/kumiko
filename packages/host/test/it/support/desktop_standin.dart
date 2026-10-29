// A desktop stand-in as a separate process: `desktop_standin
// <host-exe> <profile> <target>`. It starts the host through the 4.4 launcher,
// launches a `tree` and an `escaper` unit in <target>, prints
// `READY <host pid>` and then waits until it is killed.
import 'dart:async';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';

Future<void> main(List<String> args) async {
  final launcher = HostLauncher(
    executable: args[0],
    profileDir: args[1],
    capabilities: {Capability.testUnits, Capability.testFaults},
  );
  final session = await launcher.start();
  for (final fixture in [TestFixture.tree, TestFixture.escaper]) {
    await session.connection.request(
      Method.testUnitLaunch,
      TestUnitLaunchParams(target: args[2], fixture: fixture).toJson(),
    );
  }
  stdout.writeln('READY ${session.pid}');
  await stdout.flush();
  await Completer<void>().future;
}
