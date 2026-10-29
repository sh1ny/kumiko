import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

/// Reports from [root] and every directory directly under it.
List<FixtureProcess> readReportsDeep(Directory root) => [
  ...readReports(root),
  for (final e in root.listSync(followLinks: false))
    if (e is Directory) ...readReports(e),
];

void main() {
  setUpAll(buildTestHost);

  late Directory profile;
  late Directory root;
  late Directory target;
  late Desktop desktop;
  final junctions = <String>[];

  setUp(() async {
    profile = tempDir('gate_');
    root = tempDir('gate_root_');
    target = Directory(joinPath(root.path, 'Workspace'))..createSync();
    desktop = await Desktop.start(profile);
    await desktop.waitState();
  });

  tearDown(() async {
    await desktop.dispose();
    for (final p in readReportsDeep(root)) {
      if (p.alive) Process.killPid(p.pid, ProcessSignal.sigkill);
    }
    for (final j in junctions) {
      Process.runSync('cmd', ['/c', 'rmdir', j]);
    }
    junctions.clear();
    await deleteTree(root);
    await deleteTree(profile);
  });

  /// Launches a unit in [dir] whose kill fails, then ends it: the workspace
  /// is cleanup unresolved.
  Future<void> makeUnresolved(Directory dir) async {
    await desktop.setFault(TestFault.killFails);
    final id = await desktop.launch(dir, TestFixture.sleeper);
    await waitReports(dir, 1);
    expect((await desktop.end(id)).cleaned, isFalse);
    await desktop.setFault(TestFault.killFails, enabled: false);
  }

  test('launch against unresolved workspace refused', () async {
    await makeUnresolved(target);
    final before = LedgerView(profile).units().length;
    final reports = readReports(target).length;

    expect(
      await desktop.launchRefusal(target, TestFixture.sleeper),
      ErrorCode.cleanupUnresolved,
    );

    expect(LedgerView(profile).units(), hasLength(before));
    expect(readReports(target), hasLength(reports), reason: 'nothing started');
  });

  test('ending a unit unresolved sends the new cleanup state', () async {
    final before = await desktop.waitState();
    expect(before.unresolvedUnits, 0);

    await makeUnresolved(target);

    final after = await desktop.waitState(where: (s) => s.unresolvedUnits == 1);
    expect(after.unresolvedWorkspaces, 1);
    expect(after.revision, isNot(before.revision));
  });

  test('other workspace launches normally', () async {
    await makeUnresolved(target);
    final other = Directory(joinPath(root.path, 'Other'))..createSync();

    final id = await desktop.launch(other, TestFixture.sleeper);

    await waitReports(other, 1);
    expect(LedgerView(profile).unit(id)!['state'], 'running');
  });

  test('symlink, junction and case alias are gated', () async {
    await makeUnresolved(target);
    var tried = 0;

    final link = joinPath(root.path, 'link');
    try {
      Link(link).createSync(target.path);
      tried++;
      expect(
        await desktop.launchRefusal(Directory(link), TestFixture.sleeper),
        ErrorCode.cleanupUnresolved,
        reason: 'symbolic link',
      );
    } on FileSystemException {
      // Creating symlinks needs a privilege on some Windows setups.
    }

    if (Platform.isWindows) {
      final junction = joinPath(root.path, 'junction');
      final r = Process.runSync('cmd', [
        '/c',
        'mklink',
        '/J',
        junction,
        target.path,
      ]);
      if (r.exitCode == 0) {
        junctions.add(junction);
        tried++;
        expect(
          await desktop.launchRefusal(Directory(junction), TestFixture.sleeper),
          ErrorCode.cleanupUnresolved,
          reason: 'junction',
        );
      }
    }

    final upper = Directory(joinPath(root.path, 'WORKSPACE'));
    if (upper.existsSync()) {
      tried++;
      expect(
        await desktop.launchRefusal(upper, TestFixture.sleeper),
        ErrorCode.cleanupUnresolved,
        reason: 'letter case on a case-insensitive volume',
      );
    }
    expect(tried, greaterThan(0), reason: 'no alias could be created');
  });

  test('case-distinct directory on case-sensitive volume not gated', () async {
    // `workspace` and `Workspace` are different directories only on a
    // case-sensitive volume; the same one otherwise.
    if (Directory(joinPath(root.path, 'WORKSPACE')).existsSync()) {
      markTestSkipped('the volume is case-insensitive');
      return;
    }
    final lower = Directory(joinPath(root.path, 'workspace'));
    if (Directory(lower.path).existsSync()) {
      markTestSkipped('the volume is case-insensitive');
      return;
    }
    lower.createSync();
    await makeUnresolved(target);

    final id = await desktop.launch(lower, TestFixture.sleeper);

    await waitReports(lower, 1);
    expect(LedgerView(profile).unit(id)!['state'], 'running');
  });

  test(
    'missing target refused with target-unavailable, no ledger row',
    () async {
      final missing = Directory(joinPath(root.path, 'missing'));

      expect(
        await desktop.launchRefusal(missing, TestFixture.sleeper),
        ErrorCode.targetUnavailable,
      );

      expect(LedgerView(profile).units(), isEmpty);
      expect(missing.existsSync(), isFalse);
    },
  );
}
