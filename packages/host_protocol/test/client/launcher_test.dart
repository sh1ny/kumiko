import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

/// The stub host, compiled once per run: started from source, the VM can
/// take longer than the short hello timeouts below just to compile it.
late String _stub;

late Directory _profile;

HostLauncher _launcher(
  String mode, {
  Duration helloTimeout = defaultHelloTimeout,
  Duration quitTimeout = defaultQuitTimeout,
}) => HostLauncher(
  executable: _stub,
  executableArguments: ['--mode', mode],
  profileDir: _profile.path,
  helloTimeout: helloTimeout,
  quitTimeout: quitTimeout,
);

Future<HostStartException?> _startFailure(HostLauncher launcher) =>
    launcher.start().then<HostStartException?>((session) {
      unawaited(session.quit());
      return null;
    }, onError: (Object e) => e as HostStartException);

/// Waits until [check] holds, up to [within].
Future<void> _eventually(
  bool Function() check, {
  Duration within = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(within);
  while (!check()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not reached');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  late Directory bin;
  setUpAll(() async {
    bin = Directory.systemTemp.createTempSync('kumiko-stub-');
    _stub =
        '${bin.path}${Platform.pathSeparator}stub_host'
        '${Platform.isWindows ? '.exe' : ''}';
    final r = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'test/fixtures/stub_host.dart',
      '-o',
      _stub,
    ]);
    if (r.exitCode != 0) fail('compiling the stub host: ${r.stderr}');
  });
  tearDownAll(() => bin.deleteSync(recursive: true));

  setUp(() => _profile = Directory.systemTemp.createTempSync('kumiko-launch-'));
  tearDown(() => _profile.deleteSync(recursive: true));

  test('documented defaults', () {
    expect(defaultHelloTimeout, const Duration(seconds: 30));
    expect(hostLossBound, const Duration(seconds: 2));
    expect(defaultQuitTimeout, const Duration(seconds: 35));
    expect(stderrRingCapacity, 64 * 1024);
  });

  test('starts the host with --profile and completes hello', () async {
    final session = await _launcher('serve').start();
    addTearDown(session.quit);

    expect(session.hello.instanceId, 'stub-1');
    expect(session.hello.state, HostState.ready);
    final args = (jsonDecode(session.hello.hostVersion) as List<Object?>)
        .cast<String>();
    expect(args.sublist(args.length - 2), ['--profile', _profile.path]);
  });

  test('hello timeout kills host and reports timeout', () async {
    final launcher = _launcher(
      'silent',
      helloTimeout: const Duration(milliseconds: 500),
    );

    final failure = await _startFailure(launcher);

    expect(failure, isNotNull);
    expect(failure!.kind, HostStartFailure.helloTimeout);
    expect(failure.hostExitCode, isNotNull, reason: 'the host was killed');
    expect(failure.stderr, contains('stub: silent'));
  });

  test('a missing executable is reported as a spawn failure', () async {
    final launcher = HostLauncher(
      executable: '${_profile.path}/no-such-host',
      profileDir: _profile.path,
    );

    final failure = await _startFailure(launcher);

    expect(failure?.kind, HostStartFailure.spawnFailed);
  });

  test('an error answer to hello is reported with its reason', () async {
    final failure = await _startFailure(_launcher('locked'));

    expect(failure?.kind, HostStartFailure.helloRejected);
    expect(failure?.reason, ErrorCode.profileLocked);
  });

  test('host kill detected within 2 s', () async {
    final session = await _launcher('serve').start();
    addTearDown(session.quit);

    final watch = Stopwatch()..start();
    Process.killPid(session.pid, ProcessSignal.sigkill);
    final loss = await session.lost.timeout(hostLossBound);
    watch.stop();

    expect(watch.elapsed, lessThan(hostLossBound));
    expect(loss.exitCode, isNotNull);
    expect(session.connection.isClosed, isTrue);
  });

  test('stderr ring keeps the last 64 KiB', () async {
    final session = await _launcher('flood').start();
    addTearDown(session.quit);

    await _eventually(() => session.stderrTail.endsWith('END\n'));

    expect(session.stderrBytes.length, stderrRingCapacity);
    expect(session.stderrTail, endsWith('line-09999 END\n'));
  });

  test('ring drops the oldest bytes first', () {
    final ring = StderrRing(8)
      ..add([1, 2, 3, 4, 5])
      ..add([6, 7, 8, 9, 10, 11]);
    expect(ring.bytes, [4, 5, 6, 7, 8, 9, 10, 11]);
    ring.add(List.filled(20, 7));
    expect(ring.bytes, List.filled(8, 7));
  });

  test('quit closes stdin and waits for a clean exit', () async {
    final session = await _launcher('serve').start();

    final result = await session.quit();

    expect(result.timedOut, isFalse);
    expect(result.exitCode, 0);
    // A requested quit is not a host loss.
    expect(session.isLost, isFalse);
  });

  test('quit kills a host that outlives the deadline', () async {
    final session = await _launcher(
      'no-exit',
      quitTimeout: const Duration(seconds: 1),
    ).start();

    final result = await session.quit();

    expect(result.timedOut, isTrue);
    expect(result.exitCode, isNotNull);
  });

  group('Windows outer job', () {
    final windows = Platform.isWindows;

    test('holds the host in the job', () async {
      final session = await _launcher('serve').start();
      addTearDown(session.quit);

      expect(session.outerJob, isNotNull);
      expect(isPidInJob(session.pid, session.outerJob!), isTrue);
    }, skip: !windows);

    test(
      'host loss terminates the job and attests it in the next hello',
      () async {
        final launcher = _launcher('echo-prior');
        final first = await launcher.start();
        expect(first.hello.hostVersion, 'null');
        Process.killPid(first.pid, ProcessSignal.sigkill);
        await first.lost;

        final second = await launcher.start();
        addTearDown(second.quit);

        expect(jsonDecode(second.hello.hostVersion), {
          'instanceId': 'stub-1',
          'jobTerminated': true,
        });
      },
      skip: !windows,
    );

    test('the attestation is sent once', () async {
      final launcher = _launcher('echo-prior');
      final first = await launcher.start();
      Process.killPid(first.pid, ProcessSignal.sigkill);
      await first.lost;
      final second = await launcher.start();
      await second.quit();

      final third = await launcher.start();
      addTearDown(third.quit);

      expect(third.hello.hostVersion, 'null');
    }, skip: !windows);

    test('quit closes the job so nothing survives', () async {
      final session = await _launcher('serve').start();
      await session.quit();

      expect(session.outerJob, isNull);
    }, skip: !windows);
  });

  test('POSIX sends no attestation', () async {
    final launcher = _launcher('echo-prior');
    final first = await launcher.start();
    Process.killPid(first.pid, ProcessSignal.sigkill);
    await first.lost;

    final second = await launcher.start();
    addTearDown(second.quit);

    expect(second.hello.hostVersion, 'null');
  }, skip: Platform.isWindows);
}
