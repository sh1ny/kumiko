import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/agent_support.dart';
import 'support/harness.dart';
import 'support/terminal_support.dart' show rpcFailure;

const _codexCaps = {
  Capability.agent,
  Capability.codex,
  Capability.agentExtensionsV1,
};

void main() {
  setUpAll(buildTestHost);
  late Directory profile;
  late Directory work;
  setUp(() {
    profile = tempDir('codex_protocol_profile_');
    work = tempDir('codex_protocol_work_');
  });
  tearDown(() async {
    killReported(work);
    await deleteTree(work);
    await deleteTree(profile);
  });
  Future<Desktop> desktop(Set<String> caps) async {
    final d = await Desktop.start(
      profile,
      capabilities: {...testCapabilities, ...caps},
      environment: {
        'KUMIKO_TEST_RUNTIME_PATH': '',
        'KUMIKO_TEST_RUNTIME_DIRS': '',
        'KUMIKO_TEST_SHELL_PATH': '',
      },
    );
    addTearDown(d.dispose);
    await d.waitState();
    return d;
  }

  Future<(String, File)> seed({bool saved = false}) async {
    final d = await desktop(_codexCaps);
    final w = await d.openWorkspace(work.path);
    final report = await saveAgentFixture(
      d,
      work,
      id: 'scripted',
      script: {'reportLaunch': true},
    );
    if (saved) {
      final a = AgentPeer(d);
      await a.start(w.workspace.id, runtime: 'scripted');
      await a.attach();
      await a.close();
    }
    await d.connection.request(
      Method.runtimeSave,
      RuntimeSaveParams(
        RuntimeProfile(
          id: 'codex',
          name: 'Scripted native candidate',
          runtimeKind: 'codex',
          executable: testHostExecutable(),
          args: [
            '--test-fixture',
            'acp-agent',
            '--script',
            File(joinPath(work.path, 'scripted.script.json')).path,
          ],
          env: const {},
        ),
      ).toJson(),
    );
    await d.dispose();
    if (saved) {
      final db = sqlite3.open(joinPath(profile.path, 'kumiko.db'));
      try {
        db.execute(
          "UPDATE agent_session SET runtime_kind = 'codex', runtime_profile_id = 'codex'",
        );
      } finally {
        db.close();
      }
    }
    if (report.existsSync()) report.deleteSync();
    return (w.workspace.id, report);
  }

  for (final missing in _codexCaps) {
    test(
      'Codex: Older desktop missing $missing refuses before any spawn',
      () async {
        final (workspace, report) = await seed();
        final d = await desktop(_codexCaps.difference({missing}));
        for (var i = 0; i <= maxChannels; i++) {
          final error = await rpcFailure(
            d.connection.request(Method.agentStart, {
              'workspaceId': workspace,
              'runtimeProfileId': 'codex',
            }),
          );
          expect(error.reason, ErrorCode.methodNotAvailable);
          if (missing != Capability.agent) {
            expect(error.message, contains(missing));
          }
        }
        expect(report.existsSync(), isFalse);
        expect(LedgerView(profile).units(), isEmpty);
        expect(agentRows(profile), isEmpty);
      },
    );
  }
  test(
    'Codex: Compatible peers refuse native-unavailable without ACP fallback',
    () async {
      final (workspace, report) = await seed();
      final d = await desktop(_codexCaps);
      final error = await rpcFailure(
        d.connection.request(Method.agentStart, {
          'workspaceId': workspace,
          'runtimeProfileId': 'codex',
        }),
      );
      expect(error.reason, ErrorCode.methodNotAvailable);
      expect(error.message, contains('native'));
      expect(report.existsSync(), isFalse);
      expect(LedgerView(profile).units(), isEmpty);
    },
  );
  test(
    'Codex: Older desktop cannot Continue a saved Codex through an ACP default',
    () async {
      final (_, report) = await seed(saved: true);
      final id = agentRows(profile).single['id'];
      final d = await desktop({Capability.agent, Capability.codex});
      final error = await rpcFailure(
        d.connection.request(Method.agentContinue, {'sessionId': id}),
      );
      expect(error.reason, ErrorCode.methodNotAvailable);
      expect(error.message, contains(Capability.agentExtensionsV1));
      expect(report.existsSync(), isFalse);
      expect(LedgerView(profile).units(), isEmpty);
      expect(agentRows(profile).single['id'], id);
    },
  );
  test(
    'Codex: Prior run sends a late answer and steer without native writes',
    () async {
      final d = await desktop(_codexCaps);
      final w = await d.openWorkspace(work.path);
      final report = await saveAgentFixture(
        d,
        work,
        id: 'claude',
        script: {'reportLaunch': true},
      );
      final a = AgentPeer(d);
      await a.start(w.workspace.id, runtime: 'claude');
      await a.attach();
      final before = fixtureReports(report).length;
      for (final method in [Method.agentSteer, Method.agentQuestionAnswer]) {
        final error = await rpcFailure(
          d.connection.request(method, {
            'sessionId': a.id,
            'runId': 'previous-run',
            'expectedTurnId': 'previous-turn',
            'turnId': 'previous-turn',
            'requestId': 'retired',
            'text': 'do not send',
            'answers': const <Json>[],
          }),
        );
        expect(error.reason, 'stale-run');
      }
      expect(fixtureReports(report).length, before);
      await a.prompt('Claude still works');
      await a.wait(Method.agentTurnEnded);
      await a.close();
    },
  );
}
