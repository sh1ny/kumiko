import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../it/support/harness.dart';

void main() {
  setUpAll(buildTestHost);

  Future<String> probe(Json script) async {
    final profile = tempDir('omp_version');
    addTearDown(() => deleteTree(profile));
    final fixture = File(p.join(profile.path, 'probe.json'));
    fixture.writeAsStringSync(
      jsonEncode({
        'reportFile': p.join(profile.path, 'probe.jsonl'),
        ...script,
      }),
    );
    final desktop = await Desktop.start(
      profile,
      environment: {
        'KUMIKO_TEST_OMP_PROBE_ARGS': jsonEncode([
          '--test-fixture',
          'codex-agent',
          '--probe',
          '--script',
          fixture.path,
        ]),
      },
    );
    addTearDown(desktop.dispose);
    try {
      final result = await desktop.connection.request('test/omp.probe', {});
      return (result as Json)['version']! as String;
    } finally {
      expect(LedgerView(profile).units(), isEmpty);
    }
  }

  test('OMP: Supported version', () async {
    expect(await probe({'version': 'omp/18.20.1'}), '18.20.1');
  });

  test('OMP: Version too old', () async {
    await expectLater(
      probe({'version': 'omp/18.20.0'}),
      throwsA(
        isA<RpcException>().having(
          (error) => error.message,
          'message',
          allOf(contains('18.20.0'), contains('18.20.1')),
        ),
      ),
    );
  });

  for (final (name, script, reason) in <(String, Json, String)>[
    ('empty', {'version': ''}, 'invalid native OMP version'),
    (
      'multiple',
      {'version': 'omp/18.20.1\nomp/19.0.0'},
      'invalid native OMP version',
    ),
    (
      'oversize',
      {'version': 'omp/18.20.1', 'probeStderr': 'x' * 4096},
      'exceeds 4 KiB',
    ),
    ('exit', {'version': 'omp/18.20.1', 'probeExit': 7}, 'exited 7'),
    ('timeout', {'probeDelayMs': 20000}, 'timed out'),
  ]) {
    test('OMP: Probe fails: $name', () async {
      await expectLater(
        probe(script),
        throwsA(
          isA<RpcException>()
              .having(
                (error) => error.reason,
                'reason',
                ErrorCode.adapterProtocol,
              )
              .having((error) => error.message, 'message', contains(reason)),
        ),
      );
    });
  }
}
