import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

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
    executable(p.join(bin.path, 'Tern', 'private'), 'omp');
    final result = await list(await start());
    expect(result.profiles, isEmpty);
    expect(LedgerView(profile).units(), isEmpty);
  });
}
