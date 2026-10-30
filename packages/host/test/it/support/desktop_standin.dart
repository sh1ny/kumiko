// A desktop stand-in as a separate process: `desktop_standin
// <host-exe> <profile> <target>`. It starts the host through the 4.4 launcher,
// launches a `tree` and an `escaper` unit in <target>, prints
// `READY <host pid>` and then waits until it is killed.
//
// `desktop_standin <host-exe> <profile> <target> --terminal <fixture-exe>`
// instead opens one terminal running the fixture shell in <target>, makes
// the shell start a child, and prints `READY <host pid>` once both run.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';

Future<void> main(List<String> args) async {
  final launcher = HostLauncher(
    executable: args[0],
    profileDir: args[1],
    capabilities: {
      Capability.testUnits,
      Capability.testFaults,
      Capability.terminal,
    },
  );
  final session = await launcher.start();
  if (args.length > 4 && args[3] == '--terminal') {
    await _terminal(session, fixture: args[4], target: args[2]);
    stdout.writeln('READY ${session.pid}');
    await stdout.flush();
    await Completer<void>().future;
  }
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

Future<void> _terminal(
  HostSession session, {
  required String fixture,
  required String target,
}) async {
  final connection = session.connection;
  await connection.request(
    Method.profileSave,
    ProfileSaveParams(
      ShellProfile(
        id: 'standin',
        name: 'Stand-in',
        executable: fixture,
        args: const ['shell'],
        cwd: target,
      ),
    ).toJson(),
  );
  final opened = TerminalOpenResult.fromJson(
    (await connection.request(
          Method.terminalOpen,
          const TerminalOpenParams(
            profileId: 'standin',
            cols: 80,
            rows: 24,
          ).toJson(),
        ))!
        as Json,
  );
  final text = StringBuffer();
  final output = connection.attachInbound(
    opened.outputChannel,
    grantInitial: false,
  );
  output.listen((data) => text.write(utf8.decode(data, allowMalformed: true)));
  final input = connection.attachOutbound(opened.inputChannel);
  await connection.request(
    Method.terminalAttach,
    TerminalAttachParams(opened.terminalId).toJson(),
  );
  connection.grantInitial(opened.outputChannel);
  Future<void> waitFor(String needle) async {
    final stop = DateTime.now().add(const Duration(seconds: 60));
    while (!text.toString().contains(needle)) {
      if (DateTime.now().isAfter(stop)) {
        throw StateError('no "$needle" in the terminal output: $text');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  await waitFor('READY;');
  await input.write(utf8.encode('child\r'));
  await waitFor('CHILD:');
}
