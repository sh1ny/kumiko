@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/fixture_harness.dart';
import 'support/hang_guard.dart';
import 'support/pty_session.dart';

const _posixOnly = 'POSIX only';

/// PTY spawn on both OSes (design D2, D3, Risks): the child sees a terminal on
/// 0/1/2, argv arrives unchanged, the size is applied and follows resizes, the
/// output ends when the child exits, and on POSIX the shim reports setup and
/// exec failures instead of an exit status that looks like a result.
void main() {
  late Directory tmp;
  late String exe;
  late File out;
  var counter = 0;
  final sessions = <PtySession>[];
  final units = <PosixUnit>[];

  setUpAll(() async {
    (tmp, exe) = await compileFixtureHost();
  });

  tearDownAll(() => deleteTempDir(tmp));

  setUp(() {
    out = File(p.join(tmp.path, 'out${counter++}.txt'));
  });

  // Every session and unit is released even when one dispose fails, and
  // none stays registered for the next test; the first failure is rethrown.
  tearDown(() async {
    final toDispose = List.of(sessions);
    final toEnd = List.of(units);
    sessions.clear();
    units.clear();
    Object? failure;
    StackTrace? failureStack;
    for (final s in toDispose) {
      try {
        await s.dispose();
      } catch (e, st) {
        failure ??= e;
        failureStack ??= st;
      }
    }
    for (final u in toEnd) {
      try {
        final result = await u.terminate(killWait: hangGuard);
        if (!result.terminated) {
          throw StateError('unit ${u.pid} not terminated: ${result.reason}');
        }
      } catch (e, st) {
        failure ??= e;
        failureStack ??= st;
      } finally {
        final pty = u.pty;
        if (pty != null) {
          closePtyHandle(pty.readHandle);
          closePtyHandle(pty.writeHandle);
        }
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
  });

  Future<PtySession> start(
    List<String> fixtureArgs, {
    PtySize size = const PtySize(100, 30),
  }) async {
    final s = await startPtyFixture(
      exe,
      fixtureArgs,
      id: 'pty-$counter',
      out: out,
      size: size,
    );
    sessions.add(s);
    return s;
  }

  Future<PosixUnit> startPosix(List<String> argv, {PtyOptions? options}) async {
    final unit = await spawnPosixUnit(
      shimExecutable: exe,
      containmentId: 'pty-posix-$counter',
      argv: argv,
      pty: options ?? const PtyOptions(size: PtySize(80, 24)),
    );
    units.add(unit);
    return unit;
  }

  test('the child sees a terminal on stdin, stdout and stderr', () async {
    final s = await start(['tty']);
    await s.reader.waitForText('TTY:1:1:1;');
  });

  test('arguments with spaces and quotes arrive unchanged', () async {
    final argv = ['a b', 'say "hi"', r'back\slash\', '', "it's", 'tab\there'];
    final s = await start(['tty', ...argv]);
    final marker = RegExp(r'ARGS:([A-Za-z0-9+/=\s]+);');
    final text = await s.reader.waitFor(
      (t) => marker.hasMatch(t),
      what: 'ARGS marker',
    );
    final b64 = marker
        .firstMatch(text)!
        .group(1)!
        .replaceAll(RegExp(r'\s'), '');
    final received = (jsonDecode(utf8.decode(base64.decode(b64))) as List)
        .cast<String>();
    expect(received, argv);
  });

  test('the initial size is applied', () async {
    final s = await start(['tty'], size: const PtySize(100, 30));
    await s.reader.waitForText('SIZE:100x30;');
  });

  test('a resize is seen by the child', () async {
    final s = await start(['tty']);
    await s.reader.waitForText('SIZE:100x30;');
    ptyResize(s.pty, const PtySize(120, 40));
    await s.reader.waitForText('SIZE:120x40;');
  });

  test('output ends after the child exits', () async {
    final s = await start(['exit', '3']);
    expect(await s.unit.exitCode, 3);
    // ConPTY keeps its output pipe open until the console is closed.
    await s.closeConsole();
    await guarded(
      s.reader.done,
      'end of output after the console closed',
      state: s.reader.excerpt,
    );
    expect(s.reader.error, isNull);
  });

  test('bash job control: Ctrl+Z stops a job and fg resumes it', () async {
    final unit = await startPosix(['/bin/bash', '--norc', '--noprofile', '-i']);
    final reader = PtyReader(unit.pty!.readHandle);
    void send(String s) =>
        ptyWrite(unit.pty!.writeHandle, Uint8List.fromList(utf8.encode(s)));

    send('echo ready-\$((20+1))\n');
    await reader.waitForText('ready-21');
    // The quotes keep the typed (echoed) command line from matching the
    // marker, so `started` proves the job is in the foreground group before
    // Ctrl+Z, which bash itself would ignore.
    send('sh -c \'echo star""ted; exec sleep 30\'\n');
    await reader.waitForText('started');
    send('\x1a'); // Ctrl+Z
    await reader.waitForText('Stopped');
    send('fg\n');
    await reader.waitFor(
      // typed line, the Stopped listing, and fg printing the job again
      (t) => t.split('exec sleep 30').length > 3,
      what: 'fg echoing the job',
    );
    send('\x03'); // Ctrl+C ends the resumed sleep
    send('echo after-\$((40+2))\n');
    await reader.waitForText('after-42');
    send('exit\n');
    expect(await unit.exitCode, 0);
    await guarded(
      reader.done,
      'end of output after bash exited',
      state: reader.excerpt,
    );
  }, skip: Platform.isWindows ? _posixOnly : null);

  group('POSIX shim status pipe', () {
    test('a non-executable file raises SpawnFailed at exec', () async {
      final file = File(p.join(tmp.path, 'not-executable'))
        ..writeAsStringSync('#!/bin/sh\nexit 0\n');
      await Process.run('chmod', ['644', file.path]);
      await expectLater(
        startPosix([file.path]),
        throwsA(
          isA<SpawnFailed>()
              .having((e) => e.stage, 'stage', 'exec')
              .having((e) => e.errno, 'errno', 13),
        ),
      );
    });

    test('a bare name is not looked up in a relative PATH entry, so a '
        'program in the working directory does not run', () async {
      final local = File(p.join(tmp.path, 'kumiko-local-program'))
        ..writeAsStringSync('#!/bin/sh\nexit 0\n');
      await Process.run('chmod', ['755', local.path]);
      final unit = spawnPosixUnit(
        shimExecutable: exe,
        containmentId: 'pty-posix-relative',
        argv: ['kumiko-local-program'],
        environment: {'PATH': '.:'},
        workingDirectory: tmp.path,
        pty: const PtyOptions(size: PtySize(80, 24)),
      );
      await expectLater(
        unit,
        throwsA(
          isA<SpawnFailed>()
              .having((e) => e.stage, 'stage', 'exec')
              .having((e) => e.errno, 'errno', 2),
        ),
      );
    });

    test('a missing program raises SpawnFailed at exec', () async {
      await expectLater(
        startPosix([p.join(tmp.path, 'does-not-exist')]),
        throwsA(
          isA<SpawnFailed>()
              .having((e) => e.stage, 'stage', 'exec')
              .having((e) => e.errno, 'errno', 2),
        ),
      );
    });

    test('an injected slave-open failure raises SpawnFailed', () async {
      await expectLater(
        startPosix(
          ['/bin/sh', '-c', 'exit 0'],
          options: PtyOptions(
            size: const PtySize(80, 24),
            slavePathForTesting: p.join(tmp.path, 'no-such-slave'),
          ),
        ),
        throwsA(
          isA<SpawnFailed>()
              .having((e) => e.stage, 'stage', 'open-slave')
              .having((e) => e.errno, 'errno', 2),
        ),
      );
    });

    for (final status in [126, 127]) {
      test('a program that exits $status spawns and reports $status', () async {
        final unit = await startPosix(['/bin/sh', '-c', 'exit $status']);
        expect(await unit.exitCode, status);
      });
    }
  }, skip: Platform.isWindows ? _posixOnly : null);

  // Issue #18 on the PTY path: the status pipe still decides first, and the
  // start-time outcome is forced through the spawn's test-only parameters.
  group('POSIX PTY start time read', () {
    const esrchErrno = 3;
    final processes = <Process>[];

    // Every spawned process is registered by the hook before the spawn can
    // fail, so it is ended even when no unit was returned.
    tearDown(() async {
      for (final process in processes) {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(hangGuard);
      }
      processes.clear();
    });

    Future<PosixUnit> spawn(
      List<String> argv, {
      Future<void> Function(Process)? before,
      ProcessSnapshot? Function(int pid)? snapshot,
      int Function(int pid)? probe,
      Stream<List<int>> Function(Stream<List<int>>)? status,
    }) async {
      final unit = await spawnPosixUnit(
        shimExecutable: exe,
        containmentId: 'pty-read-$counter',
        argv: argv,
        pty: const PtyOptions(size: PtySize(80, 24)),
        beforeStartTimeReadForTesting: (process) async {
          processes.add(process);
          await before?.call(process);
        },
        snapshotForTesting: snapshot,
        probeForTesting: probe,
        statusStreamForTesting: status,
      );
      units.add(unit);
      return unit;
    }

    Future<void> reaped(Process process) => process.exitCode.timeout(hangGuard);

    /// A status read error followed at once by end of file: a synchronous
    /// controller delivers both while `listen` runs, before the spawn can
    /// cancel, so its done handler must tolerate a completed read.
    Stream<List<int>> readError(Stream<List<int>> _) {
      final c = StreamController<List<int>>(sync: true);
      c.onListen = () {
        c.addError(const OSError('injected status read error', 5));
        unawaited(c.close());
      };
      return c.stream;
    }

    /// A unit that ignores SIGHUP (kept across `exec`) and then writes
    /// [ready]: once that file exists it runs its program on the PTY, and
    /// closing the master cannot end it.
    List<String> hangupProof(File ready) => [
      '/bin/sh',
      '-c',
      'trap "" HUP; : > "\$1"; exec sleep 600',
      'sh',
      ready.path,
    ];

    /// The status read error, raised only after [ready] exists. A poll for
    /// the file the unit writes, failing loudly at the hang guard.
    Stream<List<int>> Function(Stream<List<int>>) readErrorAfter(File ready) =>
        (_) async* {
          final deadline = DateTime.now().add(hangGuard);
          while (!ready.existsSync()) {
            if (DateTime.now().isAfter(deadline)) {
              fail('the unit never wrote ${ready.path}');
            }
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          throw const OSError('injected status read error', 5);
        };

    bool runs(int pid) {
      final s = PosixProcessTable().snapshot(pid);
      return s != null && !s.zombie;
    }

    test('a PTY unit reaped before its start time is read spawns and reports '
        'its exit code', () async {
      final probes = <int>[];
      final unit = await spawn(
        ['/bin/sh', '-c', 'exit 7'],
        before: reaped,
        probe: (pid) {
          final answer = posixKill(pid, 0);
          probes.add(answer);
          return answer;
        },
      );

      expect(unit.startTime, startTimeNotRead);
      expect(probes, [esrchErrno], reason: 'absence was proved by the probe');
      expect(await unit.exitCode.timeout(hangGuard), 7);
    });

    // macOS drains a terminal's output when its last slave descriptor
    // closes, so a unit with unread output cannot exit until the master is
    // read: it cannot be reaped before the spawn returns its master.
    test(
      'a PTY unit reaped before its start time is read keeps its output on '
      'the PTY',
      () async {
        final unit = await spawn([
          '/bin/sh',
          '-c',
          'echo reaped-output; exit 7',
        ], before: reaped);

        expect(unit.startTime, startTimeNotRead);
        expect(await unit.exitCode.timeout(hangGuard), 7);
        final reader = PtyReader(unit.pty!.readHandle);
        await reader.waitForText('reaped-output');
      },
      skip: Platform.isMacOS
          ? 'macOS holds the exit until the terminal output is read'
          : null,
    );

    test('a missing program reaped before the read still raises SpawnFailed '
        'at exec', () async {
      final snapshots = <ProcessSnapshot?>[];
      final probes = <int>[];
      await expectLater(
        spawn(
          [p.join(tmp.path, 'does-not-exist')],
          before: reaped,
          snapshot: (pid) {
            final s = PosixProcessTable().snapshot(pid);
            snapshots.add(s);
            return s;
          },
          probe: (pid) {
            final answer = posixKill(pid, 0);
            probes.add(answer);
            return answer;
          },
        ),
        throwsA(
          isA<SpawnFailed>()
              .having((e) => e.stage, 'stage', 'exec')
              .having((e) => e.unconfirmedPid, 'unconfirmedPid', isNull),
        ),
      );

      // The proved-gone branch was taken, then overruled by the report.
      expect(snapshots, [isNull]);
      expect(probes, [esrchErrno]);
    });

    test('status pipe read error fails with status-read once', () async {
      await expectLater(
        spawn(['/bin/sh', '-c', 'exec sleep 600'], status: readError),
        throwsA(
          isA<SpawnFailed>()
              .having((e) => e.stage, 'stage', 'status-read')
              .having((e) => e.unconfirmedPid, 'unconfirmedPid', isNull),
        ),
      );

      // The spawn settled its unit before reporting.
      await processes.single.exitCode.timeout(hangGuard);
    });

    test('an unconfirmed read under a status read error carries the pid and '
        'sends no signal', () async {
      final ready = File(p.join(tmp.path, 'ready${counter++}'));
      await expectLater(
        spawn(
          hangupProof(ready),
          snapshot: (_) => null,
          probe: (_) => 0,
          status: readErrorAfter(ready),
        ),
        throwsA(
          isA<SpawnFailed>().having((e) => e.stage, 'stage', 'status-read'),
        ),
      );
      final process = processes.single;

      expect(runs(process.pid), isTrue, reason: 'not signalled');
    });

    test(
      'a throwing injected read is rethrown and nothing is signalled',
      () async {
        final ready = File(p.join(tmp.path, 'ready${counter++}'));
        final readFailure = StateError('injected read failure');
        await expectLater(
          spawn(
            hangupProof(ready),
            // Waits until the unit runs its program and ignores SIGHUP, so
            // only a signal from the spawn could end it.
            before: (_) async {
              final deadline = DateTime.now().add(hangGuard);
              while (!ready.existsSync()) {
                if (DateTime.now().isAfter(deadline)) {
                  fail('the unit never wrote ${ready.path}');
                }
                await Future<void>.delayed(const Duration(milliseconds: 20));
              }
            },
            snapshot: (_) => throw readFailure,
          ),
          throwsA(same(readFailure)),
        );

        expect(runs(processes.single.pid), isTrue, reason: 'not signalled');
      },
    );

    test('a status stream whose cancel throws still reports the unconfirmed '
        'pid', () async {
      Stream<List<int>> cancelThrows(Stream<List<int>> _) {
        late final StreamController<List<int>> c;
        c = StreamController<List<int>>(
          onListen: () =>
              c.addError(const OSError('injected status read error', 5)),
          onCancel: () => throw StateError('injected cancel failure'),
        );
        return c.stream;
      }

      Object? error;
      try {
        await spawn(
          ['/bin/sh', '-c', 'exec sleep 600'],
          snapshot: (_) => null,
          probe: (_) => 0,
          status: cancelThrows,
        );
      } on Object catch (e) {
        error = e;
      }

      expect(
        error,
        isA<SpawnFailed>()
            .having((e) => e.stage, 'stage', 'status-read')
            .having(
              (e) => e.unconfirmedPid,
              'unconfirmedPid',
              processes.single.pid,
            ),
      );
    });

    test('a status stream whose cancel never completes still reports the '
        'unconfirmed pid', () async {
      Stream<List<int>> cancelHangs(Stream<List<int>> _) {
        late final StreamController<List<int>> c;
        c = StreamController<List<int>>(
          onListen: () =>
              c.addError(const OSError('injected status read error', 5)),
          onCancel: () => Completer<void>().future,
        );
        return c.stream;
      }

      Object? error;
      try {
        // The group's hang guard ends the test if the spawn waits on it.
        await spawn(
          ['/bin/sh', '-c', 'exec sleep 600'],
          snapshot: (_) => null,
          probe: (_) => 0,
          status: cancelHangs,
        );
      } on Object catch (e) {
        error = e;
      }

      expect(
        error,
        isA<SpawnFailed>().having(
          (e) => e.unconfirmedPid,
          'unconfirmedPid',
          processes.single.pid,
        ),
      );
    });

    for (final (name, wrapper) in <(String, StatusWrapper)>[
      ('a throwing status wrapper', (_) => throw StateError('injected')),
      ('a status cancel that throws synchronously', (_) => _SyncCancelThrows()),
    ]) {
      test(
        '$name is a status-read failure that keeps the unconfirmed pid',
        () async {
          Object? error;
          try {
            await spawn(
              ['/bin/sh', '-c', 'exec sleep 600'],
              snapshot: (_) => null,
              probe: (_) => 0,
              status: wrapper,
            );
          } on Object catch (e) {
            error = e;
          }

          expect(
            error,
            isA<SpawnFailed>()
                .having((e) => e.stage, 'stage', 'status-read')
                .having(
                  (e) => e.unconfirmedPid,
                  'unconfirmedPid',
                  processes.single.pid,
                ),
          );
        },
      );
    }

    test('the status-read failure names the unconfirmed pid', () async {
      Object? error;
      try {
        await spawn(
          ['/bin/sh', '-c', 'exec sleep 600'],
          snapshot: (_) => null,
          probe: (_) => 0,
          status: readError,
        );
      } on SpawnFailed catch (e) {
        error = e;
      }

      expect(
        error,
        isA<SpawnFailed>().having(
          (e) => e.unconfirmedPid,
          'unconfirmedPid',
          processes.single.pid,
        ),
      );
    });
  }, skip: Platform.isWindows ? _posixOnly : null);
}

typedef StatusWrapper = Stream<List<int>> Function(Stream<List<int>> status);

/// A status stream that reports a read error and whose subscription's
/// `cancel` throws synchronously instead of returning a future.
class _SyncCancelThrows extends Stream<List<int>> {
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _CancelThrows(
    Stream<List<int>>.error(const OSError('injected status read error', 5))
        .listen(
          onData,
          onError: onError,
          onDone: onDone,
          cancelOnError: cancelOnError,
        ),
  );
}

class _CancelThrows implements StreamSubscription<List<int>> {
  _CancelThrows(this._inner);

  final StreamSubscription<List<int>> _inner;

  @override
  Future<void> cancel() {
    unawaited(_inner.cancel());
    throw StateError('injected synchronous cancel failure');
  }

  @override
  void onData(void Function(List<int> data)? handleData) =>
      _inner.onData(handleData);

  @override
  void onError(Function? handleError) => _inner.onError(handleError);

  @override
  void onDone(void Function()? handleDone) => _inner.onDone(handleDone);

  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);

  @override
  void resume() => _inner.resume();

  @override
  bool get isPaused => _inner.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _inner.asFuture(futureValue);
}
