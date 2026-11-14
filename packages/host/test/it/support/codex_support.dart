import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'agent_support.dart';
import 'harness.dart';

export 'agent_support.dart';
export 'harness.dart';

const codexCaps = {
  Capability.agent,
  Capability.codex,
  Capability.agentExtensionsV1,
};

class NativeFixture {
  NativeFixture(this.profile, this.work, {this.script = const {}});
  final Directory profile;
  final Directory work;
  final Json script;
  late Desktop desktop;
  late String workspace;
  late File report;
  late File scriptFile;
  Future<void> open({
    Set<String> caps = codexCaps,
    Map<String, String> env = const {},
  }) async {
    report = File(joinPath(work.path, 'native.report.jsonl'));
    scriptFile = File(joinPath(work.path, 'native.script.json'));
    scriptFile.writeAsStringSync(
      jsonEncode({'reportFile': report.path, ...script}),
    );
    desktop = await Desktop.start(
      profile,
      capabilities: {...testCapabilities, ...caps},
      environment: {
        'KUMIKO_TEST_RUNTIME_PATH': '',
        'KUMIKO_TEST_RUNTIME_DIRS': '',
        'KUMIKO_TEST_SHELL_PATH': '',
        'CODEX_PARENT_CANARY': 'controlled',
        'KUMIKO_TEST_CODEX_PROBE_ARGS': jsonEncode([
          '--test-fixture',
          'codex-agent',
          '--script',
          scriptFile.path,
          '--probe',
        ]),
        ...env,
      },
    );
    addTearDown(desktop.dispose);
    await desktop.waitState();
    workspace = (await desktop.openWorkspace(work.path)).workspace.id;
    await desktop.connection.request(
      Method.runtimeSave,
      RuntimeSaveParams(
        RuntimeProfile(
          id: 'native',
          name: 'Scripted native',
          runtimeKind: 'codex',
          executable: testHostExecutable(),
          args: ['--test-fixture', 'codex-agent', '--script', scriptFile.path],
          env: const {'CODEX_PROFILE_CANARY': 'explicit'},
        ),
      ),
    );
  }

  Future<AgentPeer> start() async {
    final peer = AgentPeer(desktop);
    await peer.start(workspace, runtime: 'native');
    await peer.attach();
    return peer;
  }

  List<Json> get reports => fixtureReports(report);
  List<Json> get requests => [
    for (final row in reports)
      if (row['received'] case final Json m) m,
  ];
}

Json nativeEvent(String method, Json params) => {
  'send': {'method': method, 'params': params},
};
Json terminalEvent(String status) => nativeEvent('turn/completed', {
  'threadId': r'$thread',
  'turn': {
    'id': r'$turn',
    'status': status,
    'items': <Object?>[],
    'error': status == 'failed' ? {'message': 'native failed'} : null,
  },
});
Json deltaEvent(String text, {String thread = r'$thread'}) => nativeEvent(
  'item/agentMessage/delta',
  {'threadId': thread, 'turnId': r'$turn', 'itemId': 'message', 'delta': text},
);
