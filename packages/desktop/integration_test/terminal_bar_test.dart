import 'dart:convert';
import 'dart:io';

import 'package:desktop/src/host_location.dart';
import 'package:desktop/src/terminal/terminal_surface.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'bar/bar_fixture.dart' show trueColours;
import 'bar/bar_host.dart';
import 'bar/probe.dart';
import 'bar/vttest.dart';

/// The agent-scripted daily-driver bar items (change `host-terminals`, task
/// 6.2) through the engine behind [BarProbe.create], with the real bundled
/// host, apart from throughput (`profile/terminal_throughput_test.dart`).
/// Each test prints one `BAR <item>:` line for `spike-results.md`.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // The engine applies output on post-frame callbacks, so frames must run
  // while the test awaits real I/O.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  final host = BarHost()..install();
  final barDir = Directory('integration_test/bar');

  setUpAll(() {
    expect(
      barDir.existsSync(),
      isTrue,
      reason: 'run from packages/desktop (cwd ${Directory.current.path})',
    );
  });

  /// The fixture program, run by the Dart VM of the Flutter SDK.
  Future<Opened> openFixture(TerminalSurface surface, String mode) {
    final root = Platform.environment['FLUTTER_ROOT'];
    expect(root, isNotNull, reason: 'FLUTTER_ROOT locates the Dart VM');
    final dart =
        '$root/bin/cache/dart-sdk/bin/dart'
        '${host.os == HostOs.windows ? '.exe' : ''}';
    final fixture = File('${barDir.path}/bar_fixture.dart').absolute.path;
    return host.open(surface, File(dart).absolute.path, [fixture, mode]);
  }

  BarProbe headless({int cols = 80, int rows = 24}) =>
      BarProbe.create()..resizeHeadless(cols, rows);

  testWidgets('colour: 256 indexed and 24-bit colours', (tester) async {
    final grid = headless();
    final opened = await openFixture(grid.surface, 'colour');
    await until(
      () => gridRows(grid)[9].startsWith('READY'),
      reason: () => screenText(grid),
    );

    final wrong = <String>[];
    for (var n = 0; n < 256; n++) {
      final fg = grid.fgAt(n ~/ 80, n % 80);
      if (fg != _xterm256(grid, n)) wrong.add('index $n: ${_hex(fg)}');
    }
    for (final (i, (r, g, b)) in trueColours().indexed) {
      final fg = grid.fgAt(5, i);
      if (fg != r << 16 | g << 8 | b) wrong.add('true colour $i: ${_hex(fg)}');
    }
    debugPrint('BAR colour: ${wrong.isEmpty ? 'pass' : 'fail $wrong'}');
    expect(wrong, isEmpty);
    await opened.close(host.link);
    grid.surface.dispose();
  });

  testWidgets('unicode: wide characters and emoji widths', (tester) async {
    final grid = headless();
    final opened = await openFixture(grid.surface, 'wide');
    await until(
      () => gridRows(grid)[9].startsWith('READY'),
      reason: () => screenText(grid),
    );

    // (code point, wide, spacer); a spacer's code point is not checked.
    final got = [
      for (var x = 0; x < 7; x++)
        (
          grid.isSpacer(0, x) ? 0 : grid.codepointAt(0, x),
          grid.isWide(0, x),
          grid.isSpacer(0, x),
        ),
    ];
    final want = [
      (0x4E2D, true, false),
      (0, false, true),
      (0x6587, true, false),
      (0, false, true),
      (0x1F600, true, false),
      (0, false, true),
      (0x61, false, false),
    ];
    debugPrint('BAR wide: ${_same(got, want) ? 'pass' : 'fail $got'}');
    expect(got, want);
    await opened.close(host.link);
    grid.surface.dispose();
  });

  testWidgets('input: bracketed paste arrives wrapped once', (tester) async {
    final grid = headless();
    final opened = await openFixture(grid.surface, 'paste');
    await until(
      () => gridRows(grid)[9].startsWith('READY'),
      reason: () => screenText(grid),
    );
    await until(() => grid.bracketedPaste);

    const text = 'echo one\necho two';
    // What the view's paste action sends once it has read the clipboard;
    // the system clipboard itself is left alone.
    grid.paste(text);
    await until(
      () => gridRows(grid)[11].startsWith('GOT '),
      reason: () => screenText(grid),
    );

    final hex = gridRows(grid)[11].substring(4).trim();
    // A terminal may send a pasted line break as CR; either reads as one.
    final got = latin1.encode(
      latin1
          .decode([
            for (var i = 0; i + 1 < hex.length; i += 2)
              int.parse(hex.substring(i, i + 2), radix: 16),
          ])
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n'),
    );
    final want = [
      ...'\x1b[200~'.codeUnits,
      ...utf8.encode(text),
      ...'\x1b[201~'.codeUnits,
    ];
    debugPrint(
      'BAR paste: ${_same(got, want) ? 'pass' : 'fail ${latin1.decode(got)}'}',
    );
    expect(got, want);
    await opened.close(host.link);
    grid.surface.dispose();
  });

  testWidgets('conformance: vttest subset, replayed transcripts', (
    tester,
  ) async {
    final grid = headless();
    final failures = await _vttest(grid, (step) async {
      grid.surface.feed(
        File('${barDir.path}/vttest/${step.id}.bin').readAsBytesSync(),
      );
    }, Directory('${barDir.path}/vttest'));
    debugPrint('BAR vttest (replayed): ${failures.isEmpty ? 'pass' : 'fail'}');
    expect(failures, isEmpty, reason: failures.join('\n'));
    grid.surface.dispose();
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets(
    'conformance: vttest subset, live through the host',
    (tester) async {
      final which = Process.runSync('which', ['vttest']);
      final vttest = '${which.stdout}'.trim();
      expect(vttest, isNotEmpty, reason: 'vttest is installed');
      final version = Process.runSync(vttest, ['-V']);
      final grid = headless();
      final opened = await host.open(grid.surface, vttest, const []);
      final failures = await _vttest(grid, (step) async {
        if (step.key != null) {
          opened.received = 0;
          opened.lastOutput = DateTime.now();
          await opened.channels.write(Uint8List.fromList(step.key!.codeUnits));
        }
        // A screen is complete once vttest has been quiet for two seconds.
        await until(
          () =>
              DateTime.now().difference(opened.lastOutput) >
              const Duration(seconds: 2),
          timeout: const Duration(minutes: 1),
        );
      }, Directory('${barDir.path}/vttest'));
      debugPrint(
        'BAR vttest (live, ${'${version.stdout}'.trim()}): '
        '${failures.isEmpty ? 'pass' : 'fail'}',
      );
      expect(failures, isEmpty, reason: failures.join('\n'));
      await opened.close(host.link);
      grid.surface.dispose();
    },
    skip: host.os == HostOs.windows,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

/// Walks [vttestSteps], each brought to the engine by [step], and compares
/// every judged screen with its expected grid in [dir]. Returns the
/// failures; a menu step that does not show the main menu is one, since the
/// walk is then out of step.
Future<List<String>> _vttest(
  BarProbe grid,
  Future<void> Function(VttestStep) step,
  Directory dir,
) async {
  final failures = <String>[];
  for (final s in vttestSteps) {
    await step(s);
    await _settled(grid);
    if (s.id.startsWith('menu.')) {
      if (!gridRows(grid).any((r) => r.contains('Enter choice number'))) {
        failures.add('${s.id}: the main menu is not shown');
        break;
      }
      continue;
    }
    final expected = ExpectedScreen.load(dir, s.id);
    final mismatches = expected?.mismatches(grid) ?? const [];
    debugPrint(
      'vttest ${s.id}: '
      '${expected == null
          ? 'ran, not judged'
          : mismatches.isEmpty
          ? 'pass'
          : 'FAIL'}',
    );
    if (mismatches.isNotEmpty) {
      failures.add('${s.id} (${expected!.title}):\n${mismatches.join('\n')}');
    }
  }
  return failures;
}

/// Waits until [grid] has not changed for 300 ms.
Future<void> _settled(BarProbe grid) async {
  var generation = grid.generation;
  var quiet = 0;
  while (quiet < 6) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (grid.generation == generation) {
      quiet++;
    } else {
      generation = grid.generation;
      quiet = 0;
    }
  }
}

/// The xterm 256-colour palette; 0-15 are the engine's configured colours.
int _xterm256(BarProbe grid, int n) {
  if (n < 16) return grid.configuredColour(n);
  if (n >= 232) {
    final v = 8 + 10 * (n - 232);
    return v << 16 | v << 8 | v;
  }
  const levels = [0, 95, 135, 175, 215, 255];
  final i = n - 16;
  return levels[i ~/ 36] << 16 | levels[i ~/ 6 % 6] << 8 | levels[i % 6];
}

String _hex(int rgb) => '#${rgb.toRadixString(16).padLeft(6, '0')}';

bool _same<T>(List<T> a, List<T> b) =>
    a.length == b.length &&
    [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((e) => e);
