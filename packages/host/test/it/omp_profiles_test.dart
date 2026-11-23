import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/harness.dart';
import 'support/omp_support.dart' show OmpFixture;
import 'support/terminal_support.dart';

void main() {
  setUpAll(buildTestHost);
  late Directory profile;
  late Directory bin;
  setUp(() {
    profile = tempDir('omp_profiles');
    bin = tempDir('omp_bin');
    addTearDown(() => deleteTree(profile));
    addTearDown(() => deleteTree(bin));
  });

  String executable(String dir, String name) {
    final file = File(p.join(dir, Platform.isWindows ? '$name.exe' : name))
      ..createSync(recursive: true);
    if (!Platform.isWindows) chmodPath(file.path, 0x1c0);
    return file.path;
  }

  Future<Desktop> start() async {
    final desktop = await Desktop.start(
      profile,
      capabilities: {...testCapabilities, Capability.agent, Capability.omp},
      environment: {
        'KUMIKO_TEST_RUNTIME_PATH': bin.path,
        'KUMIKO_TEST_SHELL_PATH': '',
        'LOCALAPPDATA': bin.path,
      },
    );
    addTearDown(desktop.dispose);
    await desktop.waitState();
    return desktop;
  }

  Future<RuntimeListResult> list(Desktop desktop) async =>
      RuntimeListResult.fromJson(
        await desktop.connection.request(
          Method.runtimeList,
          const EmptyParams(),
        ) as Json,
      );

  test('OMP: OMP is the only detected runtime', () async {
    final omp = executable(bin.path, 'omp');
    final desktop = await start();
    final first = await list(desktop);
    final builtin = first.profiles.single;
    expect(builtin.id, 'builtin:omp');
    expect(builtin.isBuiltin, isTrue);
    expect(builtin.runtimeKind, 'omp');
    expect(builtin.executable, omp);
    expect(builtin.args, ['--mode', 'rpc']);
    expect(first.defaultId, builtin.id);
    expect(first.defaultAvailable, isTrue);

    executable(bin.path, 'codex');
    await desktop.session.quit();
    await desktop.restart();
    await desktop.waitState();
    final next = await list(desktop);
    expect(next.profiles.map((profile) => profile.runtimeKind), [
      'codex',
      'omp',
    ]);
    expect(next.defaultId, builtin.id);
    expect(LedgerView(profile).units(), isEmpty);
  });

  test('OMP: Only a shim exists', () async {
    File(p.join(bin.path, 'omp.cmd')).createSync();
    File(p.join(bin.path, 'omp.ps1')).createSync();
    final result = await list(await start());
    expect(result.profiles, isEmpty);
    expect(result.defaultReason, contains('add a runtime profile'));
    expect(LedgerView(profile).units(), isEmpty);
  });

  test('OMP: Only a private copy exists', () async {
    final private = Directory(p.join(bin.path, 'Tern', 'private'));
    final privateBin = Directory(p.join(private.path, 'bin'))
      ..createSync(recursive: true);
    final source = File(testHostExecutable());
    final copy = source.copySync(
      p.join(privateBin.path, Platform.isWindows ? 'omp.exe' : 'omp'),
    );
    if (!Platform.isWindows) chmodPath(copy.path, 0x1c0);
    final sourceLib = Directory(p.join(source.parent.parent.path, 'lib'));
    final targetLib = Directory(p.join(private.path, 'lib'))..createSync();
    for (final asset in sourceLib.listSync().whereType<File>()) {
      asset.copySync(p.join(targetLib.path, p.basename(asset.path)));
    }
    final fixture = OmpFixture(profile, bin);
    await fixture.open(
      environment: {'KUMIKO_TEST_RUNTIME_PATH': bin.path},
      executable: copy.path,
    );
    final result = await list(fixture.desktop);
    expect(result.profiles.map((profile) => profile.id), ['scripted-omp']);
    final peer = await fixture.start();
    expect(peer.started.adapter.name, 'omp-rpc');
    await peer.close();
    expect(LedgerView(profile).units(), isEmpty);
  });

  test('OMP: OMP argv profile', () async {
    final fixture = OmpFixture(profile, bin);
    await fixture.open();
    await fixture.start();
    expect(
      fixture.reports.singleWhere((r) => r['launch'] == 'root')['argv'],
      fixture.argv,
    );
  });

  test('OMP: Profile override does not leak', () async {
    final fixture = OmpFixture(profile, bin);
    await fixture.open(
      profileEnvironment: {'OMP_PROFILE_CANARY': 'first-profile-only'},
    );
    await fixture.start();
    await fixture.desktop.connection.request(
      Method.runtimeSave,
      RuntimeSaveParams(
        RuntimeProfile(
          id: 'second-omp',
          name: 'Second OMP',
          runtimeKind: 'omp',
          executable: testHostExecutable(),
          args: fixture.argv,
        ),
      ),
    );
    await fixture.desktop.connection.request(
      Method.agentStart,
      AgentStartParams(
        workspaceId: fixture.workspace,
        runtimeProfileId: 'second-omp',
      ),
    );
    final reports = fixture.reports.where((r) => r['launch'] == 'root');
    expect(reports.map((r) => r['profileCanary']), [
      'first-profile-only',
      null,
    ]);
    const key = 'OMP_PROFILE_CANARY';
    final desktop = fixture.desktop;
    await desktop.saveFixtureProfile(cwd: bin.path);
    final terminal = await desktop.openTerminal('fixture');
    await terminal.waitForText('READY;');
    await terminal.send('env $key');
    final response = RegExp('ENV:$key=([^;]*);');
    await eventually(() => response.hasMatch(terminal.text));
    final value = response.firstMatch(terminal.text)!.group(1)!;
    expect(utf8.decode(base64.decode(value)), '-');
    await terminal.close();
    await terminal.waitExited();
  });
}
