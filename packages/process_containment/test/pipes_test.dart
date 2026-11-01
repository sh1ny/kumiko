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
import 'support/fixture_lines.dart';

void main() {
  late Directory tmp;
  late String exe;
  late File out;
  var sequence = 0;
  final units = <ContainedUnit>[];

  setUpAll(() async {
    (tmp, exe) = await compileFixtureHost();
  });
  tearDownAll(() => deleteTempDir(tmp));
  setUp(() => out = File(p.join(tmp.path, 'pipes-${sequence++}.txt')));
  tearDown(() async {
    for (final unit in units) {
      await unit.terminate();
      await unit.pipes!.close();
      if (unit is WindowsUnit) unit.close();
    }
    units.clear();
  });

  Future<ContainedUnit> start(
    List<String> args, {
    String? workingDirectory,
  }) async {
    final environment = {'PC_FIXTURE_OUT': out.path};
    final ContainedUnit unit;
    if (Platform.isWindows) {
      unit = spawnWindowsUnit(
        executable: exe,
        args: ['--fixture', ...args],
        containmentId: 'pipes-$sequence',
        environment: environment,
        workingDirectory: workingDirectory ?? tmp.path,
        pipes: true,
      );
    } else {
      unit = await spawnPosixUnit(
        shimExecutable: exe,
        argv: [exe, '--fixture', ...args],
        containmentId: 'pipes-$sequence',
        environment: environment,
        workingDirectory: workingDirectory ?? tmp.path,
        pipes: true,
      );
    }
    units.add(unit);
    return unit;
  }

  test('pipes echo stdin to stdout and keep stderr separate', () async {
    final unit = await start(['pipes-echo']);
    final output = utf8.decoder.bind(unit.pipes!.stdout).join();
    final errors = utf8.decoder.bind(unit.pipes!.stderr).join();
    await unit.pipes!.stdin.write(utf8.encode('hello pipes\n'));
    await unit.pipes!.stdin.close();
    expect(await output, 'hello pipes\n');
    expect(await errors, 'separate stderr\n');
    expect(await unit.exitCode, 0);
  });

  test('pipes preserve exact argv spaces quotes and empty arguments', () async {
    final argv = ['a b', 'say "hi"', r'back\slash\', '', "it's", 'tab\there'];
    final unit = await start(['pipes-argv', ...argv]);
    final output = utf8.decoder.bind(unit.pipes!.stdout).join();
    final errors = unit.pipes!.stderr.drain<void>();
    expect(jsonDecode(await output), argv);
    await errors;
    expect(await unit.exitCode, 0);
  });

  Future<void> expectWorkingDirectory(
    String reported,
    String requested,
    String other,
  ) async {
    final expected = directoryIdentity(requested);
    final actual = directoryIdentity(reported);
    final different = directoryIdentity(other);
    final evidence =
        'requested=$requested; reported=$reported; other=$other; '
        'requested identity=$expected; reported identity=$actual; '
        'other identity=$different';
    expect(expected, isA<ResolvedDirectory>(), reason: evidence);
    expect(actual, isA<ResolvedDirectory>(), reason: evidence);
    expect(different, isA<ResolvedDirectory>(), reason: evidence);
    expect(
      (actual as ResolvedDirectory).id,
      (expected as ResolvedDirectory).id,
      reason: evidence,
    );
    expect(
      actual.id,
      isNot((different as ResolvedDirectory).id),
      reason: evidence,
    );
  }

  test('pipes pass environment and working directory unchanged', () async {
    final unit = await start(['pipes-options']);
    final output = utf8.decoder.bind(unit.pipes!.stdout).join();
    final errors = unit.pipes!.stderr.drain<void>();
    final values = jsonDecode(await output) as Map<String, dynamic>;
    expect(values['out'], out.path);
    final other = Directory(p.join(tmp.path, 'not-cwd'))..createSync();
    await expectWorkingDirectory(values['cwd'] as String, tmp.path, other.path);
    await errors;
    expect(await unit.exitCode, 0);
  });

  test(
    'Windows piped cwd preserves directory identity through a junction alias',
    () async {
      final target = Directory(p.join(tmp.path, 'cwd-target'))..createSync();
      final other = Directory(p.join(tmp.path, 'cwd-other'))..createSync();
      final junction = p.join(tmp.path, 'cwd-junction');
      final created = await Process.run('cmd', [
        '/c',
        'mklink',
        '/J',
        junction,
        target.path,
      ]);
      expect(created.exitCode, 0, reason: '${created.stdout}${created.stderr}');
      addTearDown(() async {
        final removed = await Process.run('cmd', ['/c', 'rmdir', junction]);
        expect(
          removed.exitCode,
          0,
          reason: '${removed.stdout}${removed.stderr}',
        );
      });

      final unit = await start(['pipes-options'], workingDirectory: junction);
      final output = utf8.decoder.bind(unit.pipes!.stdout).join();
      final errors = unit.pipes!.stderr.drain<void>();
      final values = jsonDecode(await output) as Map<String, dynamic>;
      final reported = values['cwd'] as String;
      expect(values['out'], out.path);
      // GetCurrentDirectoryW preserves the junction spelling, whereas link
      // resolution returns its target. Lexical equality is not cwd identity.
      expect(
        p.equals(reported, target.resolveSymbolicLinksSync()),
        isFalse,
        reason: 'junction=$junction; reported=$reported; target=${target.path}',
      );
      await expectWorkingDirectory(reported, target.path, other.path);
      await errors;
      expect(await unit.exitCode, 0);
    },
    skip: !Platform.isWindows ? 'Windows junction cwd spelling' : false,
  );

  test(
    'pipes reach EOF after child exit without explicit pipe close',
    () async {
      final unit = await start(['exit', '7']);
      final output = unit.pipes!.stdout.drain<void>();
      final errors = unit.pipes!.stderr.drain<void>();
      expect(await unit.exitCode, 7);
      await Future.wait([output, errors]).timeout(const Duration(seconds: 10));
    },
  );

  test(
    '4 MiB blocked output resumes without loss or unbounded read ahead',
    () async {
      final unit = await start(['pipes-output']);
      final errors = StreamIterator(
        utf8.decoder.bind(unit.pipes!.stderr).transform(const LineSplitter()),
      );
      expect(await errors.moveNext(), isTrue);
      expect(errors.current, 'output-started');
      // No stdout listener exists yet. The child must stay blocked, rather
      // than buffering all 4 MiB in the host or failing its write and exiting.
      await expectLater(
        unit.exitCode.timeout(const Duration(milliseconds: 200)),
        throwsA(isA<TimeoutException>()),
      );
      expect(out.existsSync(), isFalse);
      final paused = Completer<void>();
      final done = Completer<void>();
      var bytes = 0;
      var largest = 0;
      late StreamSubscription<List<int>> subscription;
      subscription = unit.pipes!.stdout.listen(
        (chunk) {
          bytes += chunk.length;
          if (chunk.length > largest) largest = chunk.length;
          expect(chunk.every((byte) => byte == 120), isTrue);
          if (!paused.isCompleted) {
            subscription.pause();
            paused.complete();
          }
        },
        onDone: done.complete,
        onError: done.completeError,
      );
      await paused.future;
      // The fixture cannot finish its 4 MiB write while the OS pipe and the
      // single in-flight read chunk are full. No timing delay is needed.
      expect(out.existsSync(), isFalse);
      subscription.resume();
      await done.future.timeout(const Duration(seconds: 20));
      expect(bytes, 4 * 1024 * 1024);
      expect(largest, lessThanOrEqualTo(64 * 1024));
      expect(await errors.moveNext(), isTrue);
      expect(errors.current, 'output-finished');
      expect(await errors.moveNext(), isFalse);
      expect((await waitForLines(out, 1)).single.role, 'output-finished');
      expect(await unit.exitCode, 0);
    },
  );

  test('nonreading stdin stalls only writer and kill releases pending write', () async {
    final unit = await start(['pipes-no-read']);
    final output = StreamIterator(
      utf8.decoder.bind(unit.pipes!.stdout).transform(const LineSplitter()),
    );
    expect(await output.moveNext(), isTrue);
    expect(output.current, 'ready');
    final errors = unit.pipes!.stderr.drain<void>();
    final chunk = Uint8List(64 * 1024);
    var finished = false;
    final writing = (() async {
      for (var i = 0; i < 64; i++) {
        await unit.pipes!.stdin.write(chunk);
      }
    })();
    final outcome = writing.then<Object?>((_) {
      finished = true;
      return null;
    }, onError: (Object error) => error);
    // This deadline asserts the blocked operation itself, rather than sleeping
    // to let another operation finish. The timer and output read must remain
    // responsive while a native writer waits for a child that never reads.
    await expectLater(
      writing.timeout(const Duration(milliseconds: 200)),
      throwsA(isA<TimeoutException>()),
    );
    // Output remains independently readable while the input write is pending.
    expect(await output.moveNext(), isTrue);
    expect(output.current, 'responsive');
    expect(finished, isFalse);
    expect((await unit.terminate()).terminated, isTrue);
    expect(await outcome.timeout(const Duration(seconds: 10)), isNotNull);
    await output.cancel();
    await errors;
  });

  test('stdin caller queue is bounded at 1 MiB', () async {
    final unit = await start(['pipes-no-read']);
    final output = unit.pipes!.stdout.drain<void>();
    final errors = unit.pipes!.stderr.drain<void>();
    await expectLater(
      unit.pipes!.stdin.write(Uint8List(1024 * 1024 + 1)),
      throwsA(isA<StateError>()),
    );
    final queued = <Future<Object?>>[];
    final chunk = Uint8List(64 * 1024);
    for (var i = 0; i < 16; i++) {
      queued.add(
        unit.pipes!.stdin
            .write(chunk)
            .then<Object?>((_) => null, onError: (Object error) => error),
      );
    }
    await expectLater(
      unit.pipes!.stdin.write(chunk),
      throwsA(isA<StateError>()),
    );
    await unit.terminate();
    await Future.wait(queued).timeout(const Duration(seconds: 10));
    await Future.wait([output, errors]);
  });

  test('terminating piped containment kills child and grandchild', () async {
    final unit = await start(['pipes-tree']);
    final output = unit.pipes!.stdout.drain<void>();
    final errors = unit.pipes!.stderr.drain<void>();
    final lines = await waitForLines(out, 3);
    final starts = {
      for (final line in lines) line.pid: processStartTime(line.pid)!,
    };
    expect((await unit.terminate()).terminated, isTrue);
    await Future.wait([output, errors]).timeout(const Duration(seconds: 10));
    final clock = Stopwatch()..start();
    while (starts.entries.any(
          (entry) => isProcessAlive(entry.key, entry.value),
        ) &&
        clock.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    for (final entry in starts.entries) {
      expect(
        isProcessAlive(entry.key, entry.value),
        isFalse,
        reason: 'pid ${entry.key}',
      );
    }
  });
}
