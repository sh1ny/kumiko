import 'dart:convert';
import 'dart:io';

import 'package:desktop/src/host_location.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:integration_test/integration_test.dart';

import '../bar/bar_host.dart';
import '../bar/probe.dart';

/// The throughput bar items (change `host-terminals`, tasks 6.2 and 6.4), run
/// in a profile build with `flutter drive --profile`, since frame times of a
/// debug build are not what a user sees. Prints one `BAR throughput:` and one
/// `BAR interrupt:` line for `spike-results.md`.
///
/// Frame times are judged only on real hardware, with
/// `--dart-define=KUMIKO_GATE_FRAMES=true` (user decision 2026-10-30): CI VMs
/// render in software, so there they are printed but not judged.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // The engine applies output on post-frame callbacks, so frames must run
  // while the test awaits real I/O.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  final host = BarHost()..install();
  const gateFrames = bool.fromEnvironment('KUMIKO_GATE_FRAMES');

  testWidgets('throughput: 100 MB cat completes; Ctrl+C ends it in 1 s', (
    tester,
  ) async {
    final file = File('${host.profileDir.path}/hundred.txt');
    final sink = file.openWrite();
    final line = utf8.encode('${'The quick brown fox 0123456789 ' * 2}xyz\n');
    final chunk = Uint8List.fromList([
      for (var i = 0; i < (1 << 20) ~/ line.length; i++) ...line,
    ]);
    while (await sink.flush().then((_) => file.lengthSync()) < 100 << 20) {
      sink.add(chunk);
    }
    await sink.close();
    final size = file.lengthSync();
    // Windows has no `cat`: the Dart VM of the Flutter SDK runs one that
    // writes in 1 MiB blocks (`block_cat.dart`). The interrupt run needs a
    // program still writing at Ctrl+C, so it loops there and runs `yes`
    // elsewhere.
    final blockCat = File('integration_test/bar/block_cat.dart').absolute.path;
    final dart =
        '${Platform.environment['FLUTTER_ROOT']}/bin/cache/dart-sdk/bin/dart.exe';
    final (exe, args) = host.os == HostOs.windows
        ? (dart, [blockCat, file.path])
        : ('/bin/cat', [file.path]);
    final (endless, endlessArgs) = host.os == HostOs.windows
        ? (dart, [blockCat, file.path, 'loop'])
        : ('/usr/bin/yes', <String>[]);

    // Whether the program was still running when the interrupt run sent
    // Ctrl+C; a program that already ended proves nothing.
    var runningAtInterrupt = false;

    Future<(Duration, List<Duration>, TerminalExited?, int, String)> run(
      String exe,
      List<String> args, {
      Duration? interruptAfter,
    }) async {
      final probe = BarProbe.create();
      final surface = probe.surface;
      // A MaterialApp, as the app gives the view.
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(width: 960, height: 600, child: surface.view),
          ),
        ),
      );
      final (cols, rows) = await surface.size.first.timeout(
        const Duration(seconds: 30),
      );
      final frames = <Duration>[];
      void onTimings(List<FrameTiming> timings) =>
          frames.addAll(timings.map((t) => t.totalSpan));
      final opened = await host.open(
        surface,
        exe,
        args,
        cols: cols,
        rows: rows,
      );
      await until(() => opened.received > 0);
      SchedulerBinding.instance.addTimingsCallback(onTimings);
      final clock = Stopwatch()..start();
      if (interruptAfter != null) {
        await Future<void>.delayed(interruptAfter);
        runningAtInterrupt = !opened.exited.isCompleted;
        clock.reset();
        probe.ctrlC();
      }
      // Null when the program is still running; a CI VM can be slow.
      final exited = await opened.exited.future
          .then<TerminalExited?>((e) => e)
          .timeout(const Duration(minutes: 10), onTimeout: () => null);
      clock.stop();
      // Frame timings arrive in batches; let the last batch in.
      await tester.pump(const Duration(seconds: 1));
      SchedulerBinding.instance.removeTimingsCallback(onTimings);
      final screen = screenText(probe);
      await opened.close(host.link);
      await tester.pumpWidget(const SizedBox());
      surface.dispose();
      return (clock.elapsed, frames, exited, opened.received, screen);
    }

    expect(
      host.os != HostOs.windows || File(dart).existsSync(),
      isTrue,
      reason: 'FLUTTER_ROOT locates the Dart VM: $dart',
    );
    final (took, frames, exited, bytes, screen) = await run(exe, args);
    final worst = frames.fold(Duration.zero, (a, b) => a > b ? a : b);
    final slow = frames.where((f) => f >= const Duration(milliseconds: 100));
    final complete = exited?.status == 0 && bytes >= size && frames.isNotEmpty;
    debugPrint(
      'BAR throughput${gateFrames ? '' : ' (frames not judged)'}: '
      '${complete && (slow.isEmpty || !gateFrames) ? 'pass' : 'fail'}; '
      '$bytes of $size bytes in '
      '${took.inMilliseconds} ms, ${frames.length} frames, worst '
      '${worst.inMilliseconds} ms, ${slow.length} at or over 100 ms; '
      '${exited == null ? 'still running' : 'ended ${exited.reason.wire} ${exited.status}'}'
      '${complete ? '' : '; screen:\n$screen'}',
    );

    final (stopped, _, interrupted, _, _) = await run(
      endless,
      endlessArgs,
      interruptAfter: const Duration(seconds: 2),
    );
    debugPrint(
      'BAR interrupt: '
      '${runningAtInterrupt && stopped < const Duration(seconds: 1) ? 'pass' : 'fail'}; '
      '${runningAtInterrupt ? '' : 'already ended at Ctrl+C; '}ended '
      '${stopped.inMilliseconds} ms after Ctrl+C, '
      '${interrupted == null ? 'still running' : '${interrupted.reason.wire} ${interrupted.status}'}',
    );
    expect(exited?.status, 0, reason: 'the program ran to the end:\n$screen');
    expect(bytes, greaterThanOrEqualTo(size), reason: 'every byte arrived');
    expect(frames, isNotEmpty, reason: 'frames were drawn');
    if (gateFrames) expect(slow, isEmpty, reason: 'frames at or over 100 ms');
    expect(runningAtInterrupt, isTrue, reason: 'still running at Ctrl+C');
    expect(stopped, lessThan(const Duration(seconds: 1)));
  }, timeout: const Timeout(Duration(minutes: 25)));
}
