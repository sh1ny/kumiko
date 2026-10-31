import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/harness.dart';
import 'support/terminal_support.dart';

/// Closing terminals, and the processes that must not outlive them (design
/// D5, D8). Every shell and every child it starts reports itself in the
/// working directory, so a test can ask whether it is still there.
void main() {
  setUpAll(buildTestHost);

  late Directory profile;
  late Directory work;
  late Directory home;
  setUp(() {
    profile = tempDir('close_profile_');
    work = tempDir('close_work_');
    home = tempDir('close_home_');
  });
  tearDown(() async {
    killReported(work);
    await deleteTree(work);
    await deleteTree(home);
    await deleteTree(profile);
  });

  Future<Desktop> start({Map<String, String> environment = const {}}) async {
    final desktop = await Desktop.start(
      profile,
      environment: {
        'USERPROFILE': home.path,
        'HOME': home.path,
        'TERM_FIXTURE_HOST': testHostExecutable(),
        ...environment,
      },
    );
    addTearDown(desktop.dispose);
    await desktop.waitState();
    await desktop.saveFixtureProfile(cwd: work.path);
    return desktop;
  }

  Future<OpenTerminal> shell(Desktop desktop) async {
    final t = await desktop.openTerminal('fixture');
    await t.waitForText('READY;');
    return t;
  }

  /// Runs `terminal/close` and returns how long the acknowledgement took.
  Future<Duration> timedClose(Desktop desktop, String id) async {
    final clock = Stopwatch()..start();
    await desktop.closeTerminal(id);
    return clock.elapsed;
  }

  /// Whether the fixture shell [pid] has exited within 3 s.
  Future<bool> shellGone(int pid) => eventually(
    () => readReports(work).any((p) => p.pid == pid && !p.alive),
    within: const Duration(seconds: 3),
  ).then((_) => true, onError: (Object _) => false);

  const ackBound = Duration(milliseconds: 250);

  group('close', () {
    test('close ends the shell and its child tree; the tab can go on '
        'exited{closed}', () async {
      final desktop = await start();
      final t = await shell(desktop);
      await t.send('child');
      await t.waitForText('CHILD:');
      final reports = await waitReports(work, 2);
      expect(reports.every((p) => p.alive), isTrue);

      final ack = await timedClose(desktop, t.id);
      final exited = await t.waitExited();

      expect(ack, lessThan(ackBound));
      expect(exited.reason, TerminalExitReason.closed);
      await expectAllGone(reports);
      expect(LedgerView(profile).units(), isEmpty, reason: 'unit cleaned');
      // The channels are closed by the host with the notification, and the
      // terminal is forgotten.
      await eventually(() async {
        try {
          await t.input.write(utf8.encode('x'));
          return false;
        } on ChannelClosedException {
          return true;
        }
      }, reason: 'the input channel stayed open');
      final again = await rpcFailure(desktop.closeTerminal(t.id));
      expect(again.reason, ErrorCode.unknownTerminal);
    });

    test('closing twice acknowledges both; the end is reported once', () async {
      final desktop = await start();
      final t = await shell(desktop);

      await desktop.closeTerminal(t.id);
      await desktop.closeTerminal(t.id).onError<RpcException>((e, _) {
        // Already ended and forgotten by now: also a clear answer.
        expect(e.reason, ErrorCode.unknownTerminal);
      });
      await t.waitExited();

      expect(
        desktop.terminalEvents.exits.where((e) => e.terminalId == t.id),
        hasLength(1),
      );
    });

    test('program ignoring termination: ack within 250 ms, exited{closed} '
        'after the kill', () async {
      final desktop = await start();
      final t = await shell(desktop);
      await t.send('stubborn');
      await t.waitForText('STUBBORN:');
      final reports = await waitReports(work, 2);

      final ack = await timedClose(desktop, t.id);
      final exited = await t.waitExited();

      expect(ack, lessThan(ackBound));
      expect(exited.reason, TerminalExitReason.closed);
      expect(
        reports.every((p) => !p.alive),
        isTrue,
        reason: 'exited{closed} comes after the processes are gone',
      );
    });

    test('escaped marked descendant: exited{closed} only after the scan '
        'killed it', () async {
      final desktop = await start();
      final t = await shell(desktop);
      await t.send('escapee');
      await t.waitForText('ESCAPEE:');
      final reports = await waitReports(work, 2);

      final ack = await timedClose(desktop, t.id);
      final exited = await t.waitExited();

      expect(ack, lessThan(ackBound));
      expect(exited.reason, TerminalExitReason.closed);
      expect(
        reports.every((p) => !p.alive),
        isTrue,
        reason: 'the escaped process is gone when exited arrives',
      );
      expect(LedgerView(profile).units(), isEmpty);
    });

    test('expired settlement deadline: closeFailed, no exited, the unit '
        'stays unresolved', () async {
      final desktop = await start(
        environment: {'KUMIKO_TEST_SETTLE_DEADLINE_MS': '1500'},
      );
      final t = await shell(desktop);
      await desktop.setFault(TestFault.terminateHangs);

      final ack = await timedClose(desktop, t.id);
      await eventually(
        () => t.closeFailed != null,
        reason: 'no terminal/closeFailed',
      );

      expect(ack, lessThan(ackBound));
      expect(t.closeFailed!.reason, 'settlement-deadline');
      expect(t.exited, isNull, reason: 'exited is never sent after it');
      final row = LedgerView(profile).units().single;
      expect(row['state'], 'unresolved');
      expect(row['unresolved_reason'], 'settlement-deadline');
      final e = await rpcFailure(desktop.closeTerminal(t.id));
      expect(e.reason, ErrorCode.unknownTerminal, reason: 'forgotten');
    });

    test('close before attach: the late open result is closed, not '
        'attached', () async {
      final desktop = await start();
      final opened = await desktop.openTerminalRaw('fixture');
      final reports = await waitReports(work, 1);

      await desktop.closeTerminal(opened.terminalId);
      await eventually(
        () => desktop.terminalEvents.exits.any(
          (e) => e.terminalId == opened.terminalId,
        ),
        reason: 'no terminal/exited for a terminal closed before attach',
      );

      expect(
        desktop.terminalEvents.exits
            .singleWhere((e) => e.terminalId == opened.terminalId)
            .reason,
        TerminalExitReason.closed,
      );
      await expectAllGone(reports);
      expect(LedgerView(profile).units(), isEmpty);
      final attach = await rpcFailure(
        desktop.connection.request(
          Method.terminalAttach,
          TerminalAttachParams(opened.terminalId).toJson(),
        ),
      );
      expect(attach.reason, ErrorCode.unknownTerminal);
    });

    test('close during credit-stalled final drainage: reader discards and '
        'exited{closed} arrives without credit', () async {
      final desktop = await start();
      // The shell exits while its terminal still has output the desktop
      // grants no credit for: the host has seen the shell exit, and its
      // reader is parked with output it cannot send.
      //  - POSIX: a child the shell started fills the window and the PTY,
      //    then the shell exits; the PTY's small buffer makes this
      //    deterministic. The host ends the child with the shell's unit.
      //  - Windows: a child would not outlive the shell (closing the
      //    pseudo-console after the shell exits ends every process attached
      //    to it), and the console blocks a large writer too. The shell
      //    writes a little more than the window and exits; the size at which
      //    the console holds the rest depends on its buffers, so look for one
      //    where the exit stays unsent.
      FixtureProcess? flooder;
      OpenTerminal? stalled;
      if (Platform.isWindows) {
        for (var kib = 257; kib <= 384; kib += 4) {
          final t = await shell(desktop);
          t.pause(); // no credit from here on
          final shellPid = int.parse(tokenOf(t.text, 'PID')!);
          await t.send('floodexit ${kib * 1024} 0');
          final gone = await shellGone(shellPid);
          if (gone) {
            await Future<void>.delayed(const Duration(milliseconds: 1500));
          }
          printOnFailure(
            'drain probe $kib KiB: gone=$gone exited=${t.exited?.reason}',
          );
          if (gone && t.exited == null) {
            stalled = t;
            break;
          }
          await desktop.closeTerminal(t.id);
          await t.waitExited();
          if (!gone) break; // the shell blocks from here on
        }
      } else {
        final t = await shell(desktop);
        t.pause(); // no credit from here on
        final shellPid = int.parse(tokenOf(t.text, 'PID')!);
        await t.send('floodchild ${64 * 1024 * 1024}');
        final reports = await waitReports(work, 2);
        flooder = reports.singleWhere((p) => p.role == 'flooder');
        expect(await shellGone(shellPid), isTrue, reason: 'the shell exited');
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        stalled = t;
      }
      expect(stalled, isNotNull, reason: 'no output size stalls the exit');
      final t = stalled!;
      expect(t.exited, isNull, reason: 'unread output keeps it from exiting');

      final ack = await timedClose(desktop, t.id);
      final exited = await t.waitExited();

      expect(ack, lessThan(ackBound));
      expect(exited.reason, TerminalExitReason.closed);
      if (flooder != null) await expectAllGone([flooder]);
      expect(
        LedgerView(profile).units(),
        isEmpty,
        reason: 'every attempt was settled',
      );
    });
  });

  group('attach', () {
    test('unattached terminal is settled after the attach timeout and its '
        'slots are freed', () async {
      final desktop = await start(
        environment: {'KUMIKO_TEST_ATTACH_TIMEOUT_MS': '1000'},
      );
      // Leave exactly the two slots one terminal needs.
      for (var i = 0; i < maxChannels - 2; i++) {
        await desktop.connection.request(
          Method.testChannelOpen,
          const TestChannelOpenParams(1, writeBytes: 1).toJson(),
        );
      }
      final opened = await desktop.openTerminalRaw('fixture');
      final reports = await waitReports(work, 1);
      final full = await rpcFailure(desktop.openTerminalRaw('fixture'));
      expect(full.reason, ErrorCode.channelLimit);

      await expectAllGone(reports);
      await eventually(
        () => LedgerView(profile).units().isEmpty,
        reason: 'the unit was not settled',
      );

      // The slots are free again. The reservation is released only after
      // the unit is settled (design D4), so it can trail the ledger.
      TerminalOpenResult? next;
      await eventually(() async {
        try {
          next = await desktop.openTerminalRaw('fixture');
          return true;
        } on RpcException catch (e) {
          expect(e.reason, ErrorCode.channelLimit);
          return false;
        }
      }, reason: 'the slots were not freed');
      expect(next!.terminalId, isNot(opened.terminalId));
      expect(
        desktop.terminalEvents.exits,
        isEmpty,
        reason: 'a terminal never attached is not reported',
      );
      final late = await rpcFailure(
        desktop.connection.request(
          Method.terminalAttach,
          TerminalAttachParams(opened.terminalId).toJson(),
        ),
      );
      expect(late.reason, ErrorCode.unknownTerminal);
    });
  });

  group('desktop and host loss', () {
    test('killing the stand-in desktop leaves no terminal process (shell '
        'and child)', () async {
      final standin = await Process.start(
        desktopStandinExecutable(),
        [
          testHostExecutable(),
          profile.path,
          work.path,
          '--terminal',
          terminalFixtureExecutable(),
        ],
        environment: {'USERPROFILE': home.path, 'HOME': home.path},
      );
      addTearDown(() => standin.kill());
      final lines = standin.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      final errors = StringBuffer();
      standin.stderr.transform(utf8.decoder).listen(errors.write);
      final ready = await lines
          .firstWhere(
            (l) => l.startsWith('READY '),
            orElse: () => throw StateError('stand-in failed: $errors'),
          )
          .timeout(const Duration(seconds: 90));
      final hostPid = int.parse(ready.split(' ')[1]);
      final hostStart = processStartTime(hostPid)!;
      final reports = await waitReports(work, 2);
      expect(reports.every((p) => p.alive), isTrue);

      standin.kill(ProcessSignal.sigkill);
      await standin.exitCode;

      await eventually(
        () => !isProcessAlive(hostPid, hostStart),
        within: const Duration(seconds: 40),
        reason: 'host still running',
      );
      await expectAllGone(reports);
    });

    test('killed host: the next host settles terminal units or marks the '
        'workspace cleanup unresolved', () async {
      final desktop = await start();
      final workspace = (await desktop.openWorkspace(work.path)).workspace;
      final t = await desktop.openTerminal(
        'fixture',
        workspaceId: workspace.id,
      );
      await t.waitForText('READY;');
      await t.send('child');
      await t.waitForText('CHILD:');
      final running = await waitReports(work, 2);
      Process.killPid(desktop.session.pid, ProcessSignal.sigkill);
      await desktop.session.lost.timeout(hostLossBound * 3);

      await desktop.restart();
      final state = await desktop.waitState();

      // Every process can be terminated here, so every unit is cleaned.
      await expectAllGone(running);
      final rows = LedgerView(profile).units();
      expect(rows.where((u) => u['state'] != 'unresolved'), isEmpty);
      if (rows.isEmpty) {
        expect(state.unresolvedWorkspaces, 0);
      } else {
        expect(state.unresolvedWorkspaces, greaterThan(0));
      }
    });
  });

  group('console cleanup', () {
    test('repeated injected closer timeouts hold slots; at the cap '
        'open returns console-cleanup-pending', () async {
      final desktop = await start(
        environment: {
          'KUMIKO_TEST_UNIT_CAP': '4',
          'KUMIKO_TEST_CONSOLE_CLOSE_TIMEOUT_MS': '300',
        },
      );
      await desktop.setFault(TestFault.consoleCloseHangs);
      for (var i = 0; i < 4; i++) {
        final t = await shell(desktop);
        await desktop.closeTerminal(t.id);
        final exited = await t.waitExited();
        expect(exited.reason, TerminalExitReason.closed);
      }

      // The four consoles never finished closing: they still hold the
      // admission slots.
      late RpcException refused;
      await eventually(() async {
        try {
          await desktop.openTerminalRaw('fixture');
          return false;
        } on RpcException catch (e) {
          refused = e;
          return true;
        }
      }, reason: 'open was not refused');

      expect(refused.reason, ErrorCode.consoleCleanupPending);
      expect(refused.data['pending'], 4);
    }, skip: Platform.isWindows ? false : 'Windows pseudo-console close only');
  });
}
