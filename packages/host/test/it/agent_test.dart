import 'dart:convert';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

void main() {
  setUpAll(buildTestHost);
  test('ACP fixture profile initializes through real RuntimeProfileService UnitManager and UnitPipes', () async {
    final profile = tempDir('acp_profile_');
    final target = tempDir('acp_target_');
    addTearDown(() => deleteTree(profile));
    addTearDown(() => deleteTree(target));
    final desktop = await Desktop.start(
      profile,
      capabilities: {...testCapabilities, Capability.agent},
      environment: {
        'KUMIKO_TEST_RUNTIME_PATH': '',
        'KUMIKO_TEST_SHELL_PATH': '',
      },
    );
    addTearDown(desktop.dispose);
    await desktop.waitState();
    final runtime = RuntimeProfile(
      id: 'scripted-acp',
      name: 'Scripted ACP',
      runtimeKind: 'claude-code',
      executable: testHostExecutable(),
      args: ['--test-fixture', 'acp-agent'],
      env: {
        'KUMIKO_TEST_ACP_SCRIPT': jsonEncode({
          'agentInfo': {'name': 'contained-fixture', 'version': 'test-only'},
          'agentCapabilities': {
            'loadSession': true,
            'sessionCapabilities': <String, Object?>{
              'resume': <String, Object?>{},
            },
          },
        }),
      },
    );
    await desktop.connection.request(
      Method.runtimeSave,
      RuntimeSaveParams(runtime),
    );
    // Test-only harness operation, not an agent/start substitute. It resolves
    // the saved profile with the actual service and uses real contained pipes.
    final result = await desktop.connection.request(Method.testUnitLaunch, {
      'target': target.path,
      'acpProfileInitialize': runtime.id,
    }) as Json;
    expect(result['protocolVersion'], 1);
    expect(result['agentInfo'], {
      'name': 'contained-fixture',
      'version': 'test-only',
    });
    expect(result['kind'], 'agent');
    expect(result['ledgerRecorded'], isTrue);
    expect(result['cleaned'], isTrue);
    expect(LedgerView(profile).units(), isEmpty);
  });
}
