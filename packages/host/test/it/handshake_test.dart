import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

void main() {
  setUpAll(buildTestHost);

  late Directory profile;
  setUp(() => profile = tempDir('hs_'));
  tearDown(() => deleteTree(profile));

  test('test host negotiates test caps', () async {
    final desktop = await Desktop.start(profile);
    addTearDown(desktop.dispose);

    expect(desktop.session.hello.capabilities, testCapabilities);
    expect(desktop.session.hello.version, 1);
    expect(desktop.session.hello.hostVersion, isNotEmpty);
    // Their methods are served.
    await desktop.setFault(TestFault.killFails, enabled: false);
    final channel = TestChannelOpenResult.fromJson(
      await desktop.connection.request(
        Method.testChannelOpen,
        const TestChannelOpenParams(1024).toJson(),
      ) as Json,
    );
    expect(channel.channel, greaterThan(0));
    await desktop.connection.closeChannel(channel.channel);
  });

  test('an unusable log directory does not stop the host', () async {
    // `logs` is a file, so the diagnostic log cannot be created.
    File('${profile.path}${Platform.pathSeparator}logs').writeAsStringSync('');
    final desktop = await Desktop.start(profile);
    addTearDown(desktop.dispose);

    final state = await desktop.waitState();
    expect(state.unresolvedWorkspaces, 0);
    expect(desktop.session.hello.capabilities, testCapabilities);
  });

  test(
    'test methods are refused when the desktop requests no test caps',
    () async {
      final desktop = await Desktop.start(profile, capabilities: const {});
      addTearDown(desktop.dispose);

      expect(desktop.session.hello.capabilities, isEmpty);
      final target = tempDir('hs_target_');
      addTearDown(() => deleteTree(target));
      expect(
        await desktop.launchRefusal(target, TestFixture.sleeper),
        ErrorCode.methodNotAvailable,
      );
      expect(readReports(target), isEmpty);
      expect(LedgerView(profile).units(), isEmpty);
    },
  );

  test('oversize frame closes connection with protocol-violation', () async {
    final host = await RawHost.start(profile);
    addTearDown(host.dispose);
    await host.hello();

    host.writeRaw(oversizeHeader());

    final code = await host.exitCode.timeout(const Duration(seconds: 20));
    expect(code, 65);
    expect(host.stderrText.toString(), contains('protocol-violation'));
  });
}
