import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'agent_support.dart';
import 'harness.dart';

export 'agent_support.dart';
export 'harness.dart';

const ompCaps = {Capability.agent, Capability.omp};

class OmpFixture {
  OmpFixture(this.profile, this.work, {this.script = const {}});

  final Directory profile;
  final Directory work;
  final Json script;
  late Desktop desktop;
  late String workspace;
  late File report;
  late File scriptFile;

  void writeScript() {
    report = File(p.join(profile.path, 'omp-report.jsonl'));
    scriptFile = File(p.join(profile.path, 'omp-script.json'));
    scriptFile.writeAsStringSync(
      jsonEncode({...script, 'reportFile': report.path}),
    );
  }

  List<String> get argv => [
    '--test-fixture',
    'omp-agent',
    '--script',
    scriptFile.path,
    '--mode',
    'rpc',
  ];

  Future<void> open({
    Set<String> caps = ompCaps,
    Map<String, String> environment = const {},
    Map<String, String> profileEnvironment = const {},
    List<String>? profileArgs,
    String? executable,
    Duration? quitTimeout,
  }) async {
    writeScript();
    desktop = await Desktop.start(
      profile,
      capabilities: {...testCapabilities, ...caps},
      quitTimeout: quitTimeout ?? defaultQuitTimeout,
      environment: {
        'KUMIKO_TEST_RUNTIME_PATH': '',
        'KUMIKO_TEST_SHELL_PATH': '',
        'KUMIKO_TEST_OMP_PROBE_ARGS': jsonEncode([...argv, '--version']),
        ...environment,
      },
    );
    addTearDown(desktop.dispose);
    await desktop.waitState();
    workspace = (await desktop.openWorkspace(work.path)).workspace.id;
    await desktop.connection.request(
      Method.runtimeSave,
      RuntimeSaveParams(
        RuntimeProfile(
          id: 'scripted-omp',
          name: 'Scripted OMP',
          runtimeKind: 'omp',
          executable: executable ?? testHostExecutable(),
          args: profileArgs ?? argv,
          env: {
            ...profileEnvironment,
            if (profileArgs != null)
              'KUMIKO_TEST_OMP_ROOT_SCRIPT': scriptFile.path,
          },
        ),
      ),
    );
  }

  Future<AgentPeer> start() async {
    final peer = AgentPeer(desktop);
    await peer.start(workspace, runtime: 'scripted-omp');
    await peer.attach();
    return peer;
  }

  List<Json> get reports => script['isolateReports'] != true
      ? fixtureReports(report)
      : [
          for (final file in report.parent.listSync().whereType<File>())
            if (file.path.startsWith('${report.path}.'))
              ...fixtureReports(file),
        ];

  List<Json> get commands => [
    for (final row in reports)
      if (row['received'] case final Json command) command,
  ];
}
