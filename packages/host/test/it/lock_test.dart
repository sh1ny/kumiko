import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

/// Every file under [dir] with its bytes (or, for a file the OS will not let
/// us read because another process locks it, its size and mtime).
Map<String, String> snapshot(Directory dir) {
  final out = <String, String>{};
  for (final e in dir.listSync(recursive: true, followLinks: false)) {
    final rel = e.path.substring(dir.path.length);
    if (e is File) {
      try {
        out[rel] = base64.encode(e.readAsBytesSync());
      } on FileSystemException {
        final stat = e.statSync();
        out[rel] = 'locked:${stat.size}:${stat.modified.toIso8601String()}';
      }
    } else {
      out[rel] = 'dir';
    }
  }
  return out;
}

/// A quiescent lock holder: the test host in `--test-fixture lock-holder`
/// mode, which only holds the profile lock.
Future<Process> startLockHolder(Directory profile) async {
  final process = await Process.start(testHostExecutable(), [
    '--test-fixture',
    'lock-holder',
    profile.path,
  ]);
  final line = await process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first
      .timeout(const Duration(seconds: 30));
  expect(line, 'held');
  process.stderr.drain<void>();
  return process;
}

Future<void> stopLockHolder(Process holder) async {
  await holder.stdin.close();
  holder.kill();
  await holder.exitCode;
}

void main() {
  setUpAll(buildTestHost);

  late Directory profile;
  setUp(() => profile = tempDir('lock_'));
  tearDown(() => deleteTree(profile));

  test('two simultaneous launches yield one host', () async {
    final a = Desktop.newLauncher(profile);
    final b = Desktop.newLauncher(profile);

    final results = await Future.wait([
      a.start().then<Object>((s) => s, onError: (Object e) => e),
      b.start().then<Object>((s) => s, onError: (Object e) => e),
    ]);

    final sessions = results.whereType<HostSession>().toList();
    final failures = results.whereType<HostStartException>().toList();
    addTearDown(() => Future.wait(sessions.map((s) => s.quit())));
    expect(sessions, hasLength(1));
    expect(failures, hasLength(1));
    expect(failures.single.kind, HostStartFailure.helloRejected);
    expect(failures.single.reason, ErrorCode.profileLocked);
    expect(
      sessions.single.hello.state,
      anyOf(HostState.ready, HostState.reconciling),
    );
  });

  test('the profile directory is owner-only, new or already there', () async {
    int bits(String path) => FileStat.statSync(path).mode & 0x1ff;
    // An existing directory others can read.
    await Process.run('chmod', ['755', profile.path]);
    expect(bits(profile.path), 0x1ed);
    final desktop = await Desktop.start(profile);
    addTearDown(desktop.dispose);
    expect(bits(profile.path), 0x1c0, reason: 'rwx------');

    // One the host creates.
    final fresh = Directory(joinPath(profile.path, 'nested'));
    final second = await Desktop.start(fresh);
    addTearDown(second.dispose);
    expect(bits(fresh.path), 0x1c0);
  }, skip: Platform.isWindows ? 'POSIX permissions' : false);

  test('killed owner releases lock to next launch', () async {
    final desktop = await Desktop.start(profile);
    addTearDown(desktop.dispose);
    Process.killPid(desktop.session.pid, ProcessSignal.sigkill);
    await desktop.session.lost.timeout(hostLossBound);

    // No manual removal of the lock file between the two.
    expect(File(joinPath(profile.path, 'kumiko.lock')).existsSync(), isTrue);
    await desktop.restart();

    expect(desktop.session.hello.instanceId, isNotEmpty);
    expect(desktop.session.isLost, isFalse);
  });

  test('locked host replies profile-locked and exits', () async {
    final holder = await startLockHolder(profile);
    addTearDown(() => stopLockHolder(holder));
    final host = await RawHost.start(profile);
    addTearDown(host.dispose);

    final error = await host.hello().then<RpcException?>(
      (_) => null,
      onError: (Object e) => e as RpcException,
    );

    expect(error?.reason, ErrorCode.profileLocked);
    expect(error?.message, contains(profile.path));
    final code = await host.exitCode.timeout(const Duration(seconds: 20));
    expect(code, 0);
  });

  test(
    'refused launch leaves profile byte-identical (lock-holder fixture)',
    () async {
      final holder = await startLockHolder(profile);
      addTearDown(() => stopLockHolder(holder));
      final before = snapshot(profile);

      final failure = await Desktop.newLauncher(profile)
          .start()
          .then<Object?>((s) {
            unawaited(s.quit());
            return null;
          }, onError: (Object e) => e);

      expect((failure! as HostStartException).reason, ErrorCode.profileLocked);
      expect(snapshot(profile), before);
    },
  );

  test('locked host creates no store or journal files', () async {
    final holder = await startLockHolder(profile);
    addTearDown(() => stopLockHolder(holder));

    final failure = await Desktop.newLauncher(profile)
        .start()
        .then<Object?>((s) {
          unawaited(s.quit());
          return null;
        }, onError: (Object e) => e);

    expect(failure, isA<HostStartException>());
    final names = profile
        .listSync()
        .map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last)
        .toSet();
    expect(names, {'kumiko.lock'});
  });
}
