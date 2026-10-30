import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/harness.dart';
import 'support/terminal_support.dart';

/// Qualification of the terminal relay under load (design D3-D5, Resource
/// Bounds): control stays responsive beside saturated and stalled terminals,
/// a slow consumer holds the host's memory down without losing a byte, and a
/// shell that stops reading input bounds what the host queues for it.
void main() {
  setUpAll(buildTestHost);

  late Directory profile;
  late Directory work;
  late Directory home;
  setUp(() {
    profile = tempDir('qual_profile_');
    work = tempDir('qual_work_');
    home = tempDir('qual_home_');
  });
  tearDown(() async {
    killReported(work);
    await deleteTree(work);
    await deleteTree(home);
    await deleteTree(profile);
  });

  Future<Desktop> start() async {
    final desktop = await Desktop.start(
      profile,
      environment: {'USERPROFILE': home.path, 'HOME': home.path},
    );
    addTearDown(desktop.dispose);
    await desktop.waitState();
    await desktop.saveFixtureProfile(cwd: work.path);
    return desktop;
  }

  const ackBound = Duration(milliseconds: 250);
  const mib = 1024 * 1024;

  /// A terminal whose output is only counted, checked line by line against
  /// the flood's numbering, never kept.
  Future<OpenTerminal> countingTerminal(
    Desktop desktop,
    _FloodCheck check, {
    String profileId = 'fixture',
  }) async {
    final ready = StringBuffer();
    var seenReady = false;
    final t = await desktop.openTerminal(
      profileId,
      onData: (data) {
        if (!seenReady) {
          ready.write(latin1.decode(data));
          seenReady = ready.toString().contains('READY;');
          return;
        }
        check.add(data);
      },
    );
    await eventually(() => seenReady, reason: 'the shell never got ready');
    return t;
  }

  test('saturating A and stalled B: control terminal C resize and close ack '
      'worst <= 250 ms, C output flows; closing stalled B acks <= 250 ms and '
      'ends within the deadline', () async {
    final desktop = await start();
    final a = _FloodCheck();
    final ta = await countingTerminal(desktop, a);
    final tb = await desktop.openTerminal('fixture');
    await tb.waitForText('READY;');
    final bShell = int.parse(tokenOf(tb.text, 'PID')!);
    tb.pause();
    await tb.send('flood ${200 * mib}');
    await ta.send('flood ${200 * mib}');
    await eventually(
      () => a.bytes > 8 * mib,
      within: const Duration(seconds: 60),
      reason: 'A is not saturating: ${a.bytes} bytes',
    );
    final tc = await desktop.openTerminal('fixture');
    await tc.waitForText('READY;');

    var worst = Duration.zero;
    Future<void> timed(Future<void> call) async {
      final clock = Stopwatch()..start();
      await call;
      if (clock.elapsed > worst) worst = clock.elapsed;
    }

    for (var i = 0; i < 40; i++) {
      await timed(desktop.resizeTerminal(tc.id, 60 + i, 20 + i % 10));
      await tc.send('echo c$i');
      await tc.waitForText('ECHO:c$i;', within: const Duration(seconds: 20));
    }
    expect(
      a.bytes,
      greaterThan(8 * mib),
      reason: 'A keeps flowing while C is used',
    );
    print(
      'measured: worst resize ack ${worst.inMilliseconds} ms beside a '
      'saturating and a stalled terminal on ${Platform.operatingSystem}',
    );

    final closeB = Stopwatch()..start();
    await timed(desktop.closeTerminal(tb.id));
    final ackB = closeB.elapsed;
    final exitedB = await tb.waitExited(within: const Duration(seconds: 35));
    await timed(desktop.closeTerminal(tc.id));
    await tc.waitExited();

    expect(worst, lessThanOrEqualTo(ackBound));
    expect(ackB, lessThanOrEqualTo(ackBound));
    expect(exitedB.reason, TerminalExitReason.closed);
    await eventually(
      () => readReports(work).any((p) => p.pid == bShell && !p.alive),
      reason: 'the stalled terminal left its shell running',
    );
    await desktop.closeTerminal(ta.id);
    await ta.waitExited(within: const Duration(seconds: 35));
    expect(LedgerView(profile).units(), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('100 MB with a slow consumer: the host stops reading, its memory stays '
      'within the bound and no byte is lost', () async {
    final desktop = await start();
    final hostPid = desktop.session.pid;
    final check = _FloodCheck();
    Timer? pacer;
    late OpenTerminal t;
    var sinceBreak = 0;
    var paused = false;
    // The consumer takes ~512 KiB, then rests 50 ms: about 10 MiB/s.
    final ready = StringBuffer();
    var seenReady = false;
    t = await desktop.openTerminal(
      'fixture',
      onData: (data) {
        if (!seenReady) {
          ready.write(latin1.decode(data));
          seenReady = ready.toString().contains('READY;');
          return;
        }
        check.add(data);
        sinceBreak += data.length;
        if (sinceBreak >= 512 * 1024 && !paused) {
          paused = true;
          sinceBreak = 0;
          t.pause();
          pacer = Timer(const Duration(milliseconds: 50), () {
            paused = false;
            t.resume();
          });
        }
      },
    );
    await eventually(() => seenReady, reason: 'the shell never got ready');
    addTearDown(() => pacer?.cancel());
    const total = 100 * mib;
    // Hold the consumer fully back first, so the host is stalled with a
    // flood behind it, then let it drain slowly.
    paused = true;
    t.pause();
    final baseline = hostRssKiB(hostPid);
    await t.send('flood $total');
    await Future<void>.delayed(const Duration(seconds: 3));
    var peak = hostRssKiB(hostPid);
    expect(
      check.bytes,
      0,
      reason: 'nothing reaches a consumer that is not reading',
    );
    paused = false;
    t.resume();

    final clock = Stopwatch()..start();
    while (check.sequence < total ~/ 64 &&
        clock.elapsed < const Duration(minutes: 3)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final rss = hostRssKiB(hostPid);
      if (rss > peak) peak = rss;
    }

    final growth = (peak - baseline) / 1024;
    print(
      'measured: host RSS ${baseline ~/ 1024} MiB at rest, peak '
      '${peak ~/ 1024} MiB (+${growth.toStringAsFixed(1)} MiB) while '
      '100 MB moved on ${Platform.operatingSystem}',
    );
    expect(check.sequence, total ~/ 64, reason: 'lines received');
    expect(check.gaps, 0, reason: 'a line was lost or out of order');
    expect(
      growth,
      lessThan(48),
      reason: 'host memory grew with the unread output',
    );
    await desktop.closeTerminal(t.id);
    await t.waitExited();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a shell that stops reading input bounds what the host queues: '
      'accepted input <= 576 KiB plus the OS buffer, and all of it arrives '
      'in order once the shell reads', () async {
    final desktop = await start();
    await desktop.saveFixtureProfile(
      id: 'deaf',
      fixtureArgs: ['deaf'],
      cwd: work.path,
    );
    final t = await desktop.openTerminal('deaf');
    await t.waitForText('READY;');
    const piece = 16 * 1024;
    var next = 0;
    Uint8List chunk() {
      final bytes = Uint8List.fromList([
        for (var i = 0; i < piece; i++) 0x61 + (next + i) % 26,
      ]);
      next += piece;
      return bytes;
    }

    // Write until a write stays pending. A write waits for room as a whole,
    // so what completed is what the host accepted.
    var accepted = 0;
    Future<void>? pending;
    const attemptLimit = 8 * mib;
    while (accepted < attemptLimit) {
      final write = t.input.write(chunk());
      final done = await Future.any([
        write.then((_) => true),
        Future<bool>.delayed(const Duration(milliseconds: 1500), () => false),
      ]);
      if (!done) {
        pending = write;
        break;
      }
      accepted += piece;
    }
    final blocked = pending != null;
    print(
      'measured: accepted ${accepted ~/ 1024} KiB of input before a write '
      'blocked (blocked=$blocked) on ${Platform.operatingSystem}',
    );

    File(joinPath(work.path, 'go')).writeAsStringSync('go');
    if (pending != null) await pending;
    await t.input.write(utf8.encode('!'));
    await t.waitForText('GOT:', within: const Duration(seconds: 60));

    final delivered = int.parse(tokenOf(t.text, 'GOT')!.split(':').first);
    final correct = tokenOf(t.text, 'GOT')!.split(':').last;
    expect(correct, '1', reason: 'every byte arrived, in order');
    expect(delivered, next, reason: 'every accepted byte arrived');
    if (!blocked) {
      // The OS took all of it: ConPTY's input queue is not bounded by
      // the host, so the host-side bound cannot be observed here.
      expect(
        Platform.isWindows,
        isTrue,
        reason: 'writes never blocked on a platform with a bounded PTY',
      );
      markTestSkipped(
        'the OS input queue absorbed ${accepted ~/ 1024} KiB; the host-side '
        'bound is not observable',
      );
      return;
    }
    // 576 KiB of host buffers (design, Resource Bounds) plus what a PTY
    // holds (64 KiB on Linux, less elsewhere) and one write in flight.
    expect(accepted, lessThanOrEqualTo(576 * 1024 + 128 * 1024));
  });
}

/// Checks the flood's numbered lines (`L<8 digits>` and 53 `x`) as they
/// stream in, whatever escape sequences the terminal put around them.
class _FloodCheck {
  static final RegExp _line = RegExp(r'L(\d{8})x{53}');
  static final RegExp _escapes = RegExp(
    r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)|\x1B\[[0-?]*[ -/]*[@-~]|'
    r'\x1B[()][A-Za-z0-9]|\x1B[=>78MNOPXZc]',
  );

  int bytes = 0;

  /// Lines seen in order so far; the next expected number.
  int sequence = 0;
  int gaps = 0;
  String _rest = '';

  void add(Uint8List data) {
    bytes += data.length;
    final text = (_rest + latin1.decode(data)).replaceAll(_escapes, '');
    var consumed = 0;
    for (final m in _line.allMatches(text)) {
      final number = int.parse(m.group(1)!);
      if (number != sequence) gaps++;
      sequence = number + 1;
      consumed = m.end;
    }
    _rest = text.substring(consumed);
    if (_rest.length > 4096) _rest = _rest.substring(_rest.length - 4096);
  }
}
