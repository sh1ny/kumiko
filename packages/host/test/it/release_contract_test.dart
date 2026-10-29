import 'dart:convert';
import 'dart:io';

import 'package:host/src/host.dart' show HostExit;
import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

/// Every file under [dir] with its bytes, so any write is visible.
Map<String, String> snapshot(Directory dir) {
  final out = <String, String>{};
  for (final e in dir.listSync(recursive: true, followLinks: false)) {
    final rel = e.path.substring(dir.path.length);
    out[rel] = e is File ? base64.encode(e.readAsBytesSync()) : 'dir';
  }
  return out;
}

/// The release contract (design D10): the release executable carries no test
/// capability, no `test/*` method and no `--test-fixture` mode, and still
/// serves `--unit-exec`.
void main() {
  setUpAll(buildReleaseHost);

  late Directory profile;
  late Directory cwd;

  setUp(() {
    profile = tempDir('release_profile_');
    cwd = tempDir('release_cwd_');
  });

  tearDown(() async {
    await deleteTree(profile);
    await deleteTree(cwd);
  });

  test('release host advertises no test caps; every test method and fixture '
      'refused', () async {
    // The desktop asks for every test capability.
    final launcher = HostLauncher(
      executable: releaseHostExecutable(),
      profileDir: profile.path,
      capabilities: testCapabilities,
    );
    final session = await launcher.start();
    try {
      expect(
        session.hello.capabilities.where((c) => c.startsWith('test.')),
        isEmpty,
        reason: 'hello advertised ${session.hello.capabilities}',
      );

      final calls = <String, Object>{
        Method.testUnitLaunch: TestUnitLaunchParams(
          target: cwd.path,
          fixture: TestFixture.sleeper,
        ).toJson(),
        Method.testUnitEnd: TestUnitEndParams('no-such-unit').toJson(),
        Method.testChannelOpen: const TestChannelOpenParams(0).toJson(),
        Method.testChannelStats: const TestChannelStatsParams(1).toJson(),
        Method.testFaultSet: TestFaultSetParams(
          TestFault.killFails,
          enabled: true,
        ).toJson(),
      };
      for (final entry in calls.entries) {
        expect(
          await failureReason(
            () => session.connection.request(entry.key, entry.value),
          ),
          ErrorCode.methodNotAvailable,
          reason: entry.key,
        );
      }

      // Nothing started: no ledger row, no process in the target.
      expect(LedgerView(profile).units(), isEmpty);
      expect(readReports(cwd), isEmpty);
    } finally {
      await session.quit();
    }

    // Every fixture variant is a usage error that starts and touches nothing,
    // against a profile a release host has used.
    final before = snapshot(profile);
    for (final variant in [
      ['tree'],
      ['escaper'],
      ['sleeper'],
      ['stubborn'],
      ['lock-holder', profile.path],
    ]) {
      final result = await Process.run(releaseHostExecutable(), [
        '--test-fixture',
        ...variant,
      ], workingDirectory: cwd.path).timeout(const Duration(seconds: 20));

      expect(result.exitCode, HostExit.usage, reason: variant.join(' '));
      expect(
        result.stderr as String,
        contains('usage'),
        reason: variant.join(' '),
      );
      expect(result.stdout, isEmpty, reason: variant.join(' '));
      expect(
        cwd.listSync(),
        isEmpty,
        reason: '${variant.join(' ')} wrote or started something',
      );
      expect(
        snapshot(profile),
        before,
        reason: '${variant.join(' ')} changed the profile',
      );
    }

    // No fixture took the lock either: the profile is still free.
    await withStore(profile, (store) {});
  });

  group('unit-exec', () {
    final skip = Platform.isWindows ? 'unit-exec is POSIX only' : null;

    test(
      'release host runs a benign helper: pid, session, exit code, marker',
      () async {
        const unit = 'contract-unit-1';
        final process = await Process.start(releaseHostExecutable(), [
          '--unit-exec',
          unit,
          '--',
          '/bin/sh',
          '-c',
          r'echo "$$ $KUMIKO_UNIT"; read answer; exit 7',
        ]);
        addTearDown(process.kill);
        process.stderr.drain<void>();
        final line = await process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 20));

        final fields = line.split(' ');
        expect(int.parse(fields[0]), process.pid, reason: 'pid preserved');
        expect(fields[1], unit, reason: 'KUMIKO_UNIT set');
        expect(
          sessionIdOf(process.pid),
          process.pid,
          reason: 'session id equals pid',
        );

        process.stdin.writeln('go');
        await process.stdin.close();
        expect(
          await process.exitCode.timeout(const Duration(seconds: 20)),
          7,
          reason: 'exit code propagates',
        );
      },
      skip: skip,
    );
  });
}
