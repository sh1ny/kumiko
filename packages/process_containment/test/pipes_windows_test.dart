@TestOn('windows')
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/fixture_harness.dart';

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
    'piped process uses CREATE_NO_WINDOW without a console window',
    () async {
      final result = await inspect();
      expect(result['consoleWindow'], 0);
    },
  );
}
