@TestOn('windows')
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/fixture_harness.dart';
import 'support/fixture_lines.dart';

void main() {
  late Directory tmp;
  late String exe;
  final units = <WindowsUnit>[];
  setUpAll(() async {
    (tmp, exe) = await compileFixtureHost();
  });
  tearDownAll(() => deleteTempDir(tmp));
  tearDown(() async {
    for (final unit in units) {
      await unit.terminate();
      await unit.pipes!.close();
      unit.close();
    }
    units.clear();
  });

  Future<Map<String, dynamic>> inspect() async {
    final unit = spawnWindowsUnit(
      executable: exe,
      args: ['--fixture', 'pipes-windows-handles'],
      containmentId: 'pipes-windows-handles',
      pipes: true,
    );
    units.add(unit);
    final output = utf8.decoder.bind(unit.pipes!.stdout).join();
    final errors = unit.pipes!.stderr.drain<void>();
    final result = jsonDecode(await output) as Map<String, dynamic>;
    await errors;
    expect(await unit.exitCode, 0);
    return result;
  }

  test(
    'all inherited handles are exactly the three child stdpipe handles',
    () async {
      final kernel = DynamicLibrary.open('kernel32.dll');
      final createEvent = kernel
          .lookupFunction<
            IntPtr Function(Pointer<Void>, Int32, Int32, Pointer<Utf16>),
            int Function(Pointer<Void>, int, int, Pointer<Utf16>)
          >('CreateEventW');
      final security = calloc<Uint8>(24);
      security.cast<Uint32>().value = 24;
      (security + 16).cast<Int32>().value = 1;
      final sentinel = createEvent(security.cast<Void>(), 1, 0, nullptr);
      calloc.free(security);
      expect(sentinel, isNot(0));
      addTearDown(() => closeHandle(sentinel));

      final result = await inspect();
      final inherited = (result['inherited'] as List).cast<int>();
      final std = (result['std'] as List).cast<int>();
      expect(std.toSet(), hasLength(3));
      // This is a complete native process-handle inventory filtered by the
      // inheritance bit, not merely a negative probe of the sentinel.
      expect(inherited, unorderedEquals(std));
      expect(inherited, isNot(contains(sentinel)));
      expect(result['stdTypes'], [3, 3, 3], reason: 'FILE_TYPE_PIPE');
      expect(result['stdInheritable'], [true, true, true]);
    },
  );

  test(
    'leader exit settles stdin writes and close while a descendant holds stdin',
    () async {
      final out = File('${tmp.path}/inherited-stdin.txt');
      final unit = spawnWindowsUnit(
        executable: exe,
        args: ['--fixture', 'pipes-inherited-stdin'],
        containmentId: 'pipes-inherited-stdin',
        environment: {'PC_FIXTURE_OUT': out.path},
        pipes: true,
      );
      units.add(unit);
      final output = StreamIterator(
        utf8.decoder.bind(unit.pipes!.stdout).transform(const LineSplitter()),
      );
      final errors = unit.pipes!.stderr.drain<void>();
      expect(await output.moveNext(), isTrue);
      final handles = jsonDecode(output.current) as Map<String, dynamic>;
      expect(
        (handles['stdTypes'] as List).first,
        3,
        reason: 'inherited stdin is a pipe',
      );
      final child = (await waitForLines(
        out,
        2,
      )).singleWhere((line) => line.role == 'inherited-stdin');
      final childStart = processStartTime(child.pid)!;
      final queued = <Future<Object?>>[];
      for (var i = 0; i < 16; i++) {
        queued.add(
          unit.pipes!.stdin
              .write(Uint8List(unitPipeChunkSize))
              .then<Object?>((_) => null, onError: (Object error) => error),
        );
      }
      final outcomes = Future.wait(queued);
      await expectLater(
        outcomes.timeout(const Duration(milliseconds: 200)),
        throwsA(isA<TimeoutException>()),
      );
      final closing = unit.pipes!.stdin.close();
      expect(Process.killPid(unit.pid), isTrue);
      await unit.exitCode.timeout(const Duration(seconds: 5));
      expect(isProcessAlive(child.pid, childStart), isTrue);

      expect(
        await outcomes.timeout(const Duration(seconds: 1)),
        everyElement(isA<StateError>()),
      );
      await closing.timeout(const Duration(seconds: 1));
      await expectLater(
        unit.pipes!.stdin.write([1]),
        throwsA(isA<StateError>()),
      );
      expect(isProcessAlive(child.pid, childStart), isTrue);

      expect((await unit.terminate()).terminated, isTrue);
      await unit.pipes!.close().timeout(const Duration(seconds: 10));
      await output.cancel();
      await errors;
      expect(isProcessAlive(child.pid, childStart), isFalse);
    },
  );

  test(
    'piped process uses CREATE_NO_WINDOW without a console window',
    () async {
      final result = await inspect();
      expect(result['consoleWindow'], 0);
    },
  );
}
