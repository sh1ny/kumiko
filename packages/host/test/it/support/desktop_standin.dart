// A desktop stand-in as a separate process: `desktop_standin
// <host-exe> <profile> <target>`. It starts the host through the 4.4 launcher,
// launches a `tree` and an `escaper` unit in <target>, prints
// `READY <host pid>` and then waits until it is killed.
//
// `desktop_standin <host-exe> <profile> <target> --draft <script> <text>`
// starts one agent session, saves <text> as its draft at revision 1, prints
// `SESSION <id>` and `READY <host pid>`, and waits until it is killed.
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
      Capability.agent,
      Capability.workbench,
    },
  );
  final session = await launcher.start();
  final draft = args.length > 5 && args[3] == '--draft';
  if (args.length > 4 && (args[3] == '--agent' || draft)) {
    final c = session.connection;
    final a = await _agent(session, args);
    if (draft) {
      await c.request(
        Method.agentDraftSave,
        AgentDraftSaveParams(
          sessionId: a.sessionId,
          text: args[5],
          revision: 1,
        ).toJson(),
      );
      stdout.writeln('SESSION ${a.sessionId}');
    } else {
      await c.request(
        Method.agentPrompt,
        AgentPromptParams(sessionId: a.sessionId, text: 'spawn tree'),
      );
    }
    stdout.writeln('READY ${session.pid}');
    await stdout.flush();
    await Completer<void>().future;
  }
  if (args.length > 4 && args[3] == '--terminal') {
    await _terminal(session, fixture: args[4], target: args[2]);
    stdout.writeln('READY ${session.pid}');
    await stdout.flush();
    await Completer<void>().future;
  }
  // `--terminal-and-agent <fixture-exe> <script>`: both of the above in one
  // desktop, the agent's turn held running.
  if (args.length > 5 && args[3] == '--terminal-and-agent') {
    await _terminal(session, fixture: args[4], target: args[2]);
    final a = await _agent(session, [...args.take(4), args[5]]);
    await session.connection.request(
      Method.agentPrompt,
      AgentPromptParams(sessionId: a.sessionId, text: 'spawn tree'),
    );
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

/// Starts one agent session of the script `args[4]` in `args[2]` and attaches
/// its event channel.
Future<AgentStartResult> _agent(HostSession session, List<String> args) async {
  final c = session.connection;
  final reconciled = Completer<void>();
  session.notifications.listen((n) {
    if (n.method == Method.cleanupState &&
        n.params['reconciling'] == false &&
        !reconciled.isCompleted) {
      reconciled.complete();
    }
  });
  await reconciled.future;
  final w = WorkspaceOpenResult.fromJson(
    (await c.request(Method.workspaceOpen, WorkspaceOpenParams(args[2])))
        as Json,
  );
  await c.request(
    Method.runtimeSave,
    RuntimeSaveParams(
      RuntimeProfile(
        id: 'standin-agent',
        name: 'Stand-in agent',
        runtimeKind: 'claude-code',
        executable: args[0],
        args: ['--test-fixture', 'acp-agent', '--script', args[4]],
      ),
    ),
  );
  final a = AgentStartResult.fromJson(
    (await c.request(
      Method.agentStart,
      AgentStartParams(
        workspaceId: w.workspace.id,
        runtimeProfileId: 'standin-agent',
      ),
    )) as Json,
  );
  c.attachInbound(a.eventChannel, grantInitial: false).listen((_) {});
  await c.request(Method.agentAttach, AgentSessionParams(a.sessionId));
  c.grantInitial(a.eventChannel);
  return a;
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
