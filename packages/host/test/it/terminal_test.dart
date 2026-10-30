import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:host/src/host_faults.dart' show scriptedPtyOutput;
import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'fixtures/term_fixture.dart' show blob;
import 'support/harness.dart';
import 'support/terminal_support.dart';

/// Terminal open, attach, relay, resize and exit against the real host and a
/// fixture shell (host-terminals design D2-D5). Output is checked through
/// the fixture's `NAME:value;` tokens, because ConPTY adds escape sequences
/// around what a program writes.
void main() {
  setUpAll(buildTestHost);

  late Directory profile;
  late Directory work;
  late Directory home;
  setUp(() {
    profile = tempDir('term_profile_');
    work = tempDir('term_work_');
    home = tempDir('term_home_');
  });
  tearDown(() async {
    killReported(work);
    killReported(home);
    await deleteTree(work);
    await deleteTree(home);
    await deleteTree(profile);
  });

  Future<Desktop> start({
    Map<String, String> environment = const {},
    Set<String> capabilities = testCapabilities,
  }) async {
    final desktop = await Desktop.start(
      profile,
      environment: {
        'USERPROFILE': home.path,
        'HOME': home.path,
        'TERM_FIXTURE_HOST': testHostExecutable(),
        'EDITOR': 'nano',
        ...environment,
      },
      capabilities: capabilities,
    );
    addTearDown(desktop.dispose);
    await desktop.waitState();
    return desktop;
  }

  String real(String path) {
    final resolved = Directory(path).resolveSymbolicLinksSync();
    return Platform.isWindows ? resolved.toLowerCase() : resolved;
  }

  /// Opens the default fixture shell and waits until it is ready.
  Future<OpenTerminal> shell(
    Desktop desktop, {
    String profileId = 'fixture',
    String? workspaceId,
    int cols = 80,
    int rows = 24,
  }) async {
    final t = await desktop.openTerminal(
      profileId,
      workspaceId: workspaceId,
      cols: cols,
      rows: rows,
    );
    await t.waitForText('READY;');
    return t;
  }

  group('open', () {
    test('terminal runs the profile executable under a PTY (isatty true, '
        'fixture shell prints its argv and cwd)', () async {
      final desktop = await start();
      const args = ['a b', 'say "hi"', "x'y", r'back\slash'];
      await desktop.saveFixtureProfile(
        fixtureArgs: ['shell', ...args],
        cwd: work.path,
      );

      final t = await shell(desktop);

      expect(tokenOf(t.text, 'TTY'), '1:1:1', reason: 'a terminal on 0/1/2');
      expect(jsonDecode(decodedToken(t.text, 'ARGS')!), args);
      expect(real(decodedToken(t.text, 'CWD')!), real(work.path));
      final unit = LedgerView(profile).units().single;
      expect(unit['kind'], 'terminal');
      expect(unit['state'], 'running');
    });

    test('missing executable returns executable-not-found with the path and '
        'starts nothing', () async {
      final desktop = await start();
      final missing = joinPath(
        work.path,
        Platform.isWindows ? 'no-such-shell.exe' : 'no-such-shell',
      );
      await desktop.saveFixtureProfile(executable: missing, cwd: work.path);

      final e = await rpcFailure(desktop.openTerminalRaw('fixture'));

      expect(e.reason, ErrorCode.executableNotFound);
      expect(e.data['executable'], missing);
      expect(e.message, contains(missing));
      expect(LedgerView(profile).units(), isEmpty);
      expect(readReports(work), isEmpty);
    });

    test('(Executable path is wrong) no substitute shell starts', () async {
      // A detected shell exists, and the user's profile points at a wrong
      // path: the host reports it and starts nothing in its place.
      final bin = tempDir('term_bin_');
      addTearDown(() => deleteTree(bin));
      final name = Platform.isWindows ? 'pwsh.exe' : 'bash';
      File(joinPath(bin.path, name)).writeAsStringSync('');
      if (!Platform.isWindows) {
        Process.runSync('chmod', ['+x', joinPath(bin.path, name)]);
      }
      final desktop = await start(
        environment: {'KUMIKO_TEST_SHELL_PATH': bin.path},
      );
      expect((await desktop.listProfiles()).profiles.first.isBuiltin, isTrue);
      await desktop.saveFixtureProfile(
        executable: joinPath(work.path, 'wrong-path'),
        cwd: work.path,
      );

      final e = await rpcFailure(desktop.openTerminalRaw('fixture'));

      expect(e.reason, ErrorCode.executableNotFound);
      expect(LedgerView(profile).units(), isEmpty);
      expect(readReports(work), isEmpty);
    });

    test('non-executable file returns spawn-failed{stage exec, osError} '
        'before any open result; a program exiting 126 opens and reports '
        'exit 126', () async {
      final desktop = await start();
      final file = File(joinPath(work.path, 'plain.txt'))
        ..writeAsStringSync('not a program');
      await desktop.saveFixtureProfile(
        id: 'plain',
        executable: file.path,
        cwd: work.path,
      );

      final e = await rpcFailure(desktop.openTerminalRaw('plain'));

      expect(e.reason, ErrorCode.spawnFailed);
      // POSIX: the shim's execve (EACCES); Windows: CreateProcessW
      // (ERROR_BAD_EXE_FORMAT).
      expect(e.data['stage'], Platform.isWindows ? 'CreateProcessW' : 'exec');
      expect(e.data['osError'], Platform.isWindows ? 193 : 13);
      expect(LedgerView(profile).units(), isEmpty);

      await desktop.saveFixtureProfile(
        id: 'exits126',
        fixtureArgs: ['exit', '126'],
        cwd: work.path,
      );
      final t = await desktop.openTerminal('exits126');
      final exited = await t.waitExited();
      expect(exited.status, 126);
      expect(exited.reason, TerminalExitReason.exited);
    });

    test(
      'open result has terminal id and two distinct new channel ids',
      () async {
        final desktop = await start();
        await desktop.saveFixtureProfile(cwd: work.path);

        final a = await desktop.openTerminalRaw('fixture');
        final b = await desktop.openTerminalRaw('fixture');

        expect(a.terminalId, isNotEmpty);
        final ids = [
          a.outputChannel,
          a.inputChannel,
          b.outputChannel,
          b.inputChannel,
        ];
        expect(ids.toSet(), hasLength(4), reason: 'every channel id is unique');
        expect(ids.every((id) => id > 0), isTrue);
        expect(a.terminalId, isNot(b.terminalId));
      },
    );

    test('concurrent opens get unique ids; each terminal receives only its '
        'own bytes', () async {
      final desktop = await start();
      await desktop.saveFixtureProfile(cwd: work.path);

      final terminals = await Future.wait([
        for (var i = 0; i < 4; i++) desktop.openTerminal('fixture'),
      ]);
      for (final t in terminals) {
        await t.waitForText('READY;');
      }
      for (var i = 0; i < terminals.length; i++) {
        await terminals[i].send('echo mine-$i');
      }
      for (var i = 0; i < terminals.length; i++) {
        await terminals[i].waitForText('ECHO:mine-$i;');
      }

      final ids = {
        for (final t in terminals) ...[t.outputChannel, t.inputChannel],
        for (final t in terminals) t.id,
      };
      expect(ids, hasLength(12));
      for (var i = 0; i < terminals.length; i++) {
        for (var j = 0; j < terminals.length; j++) {
          if (i != j) {
            expect(terminals[i].text, isNot(contains('mine-$j')));
          }
        }
      }
    });

    test('open at the limit starts no shell', () async {
      final desktop = await start();
      await desktop.saveFixtureProfile(cwd: work.path);
      // Leave one slot of the connection's channels: a terminal needs two.
      for (var i = 0; i < maxChannels - 1; i++) {
        await desktop.connection.request(
          Method.testChannelOpen,
          const TestChannelOpenParams(1, writeBytes: 1).toJson(),
        );
      }

      final e = await rpcFailure(desktop.openTerminalRaw('fixture'));

      expect(e.reason, ErrorCode.channelLimit);
      expect(LedgerView(profile).units(), isEmpty);
      expect(readReports(work), isEmpty, reason: 'no shell was started');
    });

    test('open at the unit cap returns unit-cap', () async {
      final desktop = await start(environment: {'KUMIKO_TEST_UNIT_CAP': '1'});
      await desktop.saveFixtureProfile(cwd: work.path);
      await shell(desktop);

      final e = await rpcFailure(desktop.openTerminalRaw('fixture'));

      expect(e.reason, ErrorCode.unitCap);
      expect(LedgerView(profile).units(), hasLength(1));
      await eventually(
        () => readReports(work).length == 1,
        reason: 'only the first shell ran',
      );
    });

    test('no terminal start leaves a reserved channel behind', () async {
      // A refused open frees its two slots: after many refusals the channels
      // are still all available.
      final desktop = await start();
      await desktop.saveFixtureProfile(
        executable: joinPath(work.path, 'absent'),
        cwd: work.path,
      );
      for (var i = 0; i < 100; i++) {
        final e = await rpcFailure(desktop.openTerminalRaw('fixture'));
        expect(
          e.reason,
          ErrorCode.executableNotFound,
          reason: 'attempt $i; ledger: ${LedgerView(profile).units()}',
        );
      }
      await desktop.saveFixtureProfile(id: 'ok', cwd: work.path);

      await shell(desktop, profileId: 'ok');
    });
  });

  group('directory and environment', () {
    test(
      'terminal without profile cwd starts in the workspace directory',
      () async {
        final desktop = await start();
        final workspace = (await desktop.openWorkspace(work.path)).workspace;
        await desktop.saveFixtureProfile();

        final t = await shell(desktop, workspaceId: workspace.id);

        expect(real(decodedToken(t.text, 'CWD')!), real(work.path));
        expect(
          LedgerView(profile).units().single['target_path'],
          isNotNull,
          reason: 'the unit is attributed to the workspace',
        );
      },
    );

    test('terminal without workspace starts in home', () async {
      final desktop = await start();
      await desktop.saveFixtureProfile();

      final t = await shell(desktop);

      expect(real(decodedToken(t.text, 'CWD')!), real(home.path));
    });

    test('a profile cwd wins over the workspace directory', () async {
      final desktop = await start();
      final other = Directory(joinPath(work.path, 'sub'))..createSync();
      final workspace = (await desktop.openWorkspace(work.path)).workspace;
      await desktop.saveFixtureProfile(cwd: other.path);

      final t = await shell(desktop, workspaceId: workspace.id);

      expect(real(decodedToken(t.text, 'CWD')!), real(other.path));
    });

    test('open for an unavailable workspace is refused with '
        'workspace-unavailable', () async {
      final desktop = await start();
      final gone = Directory(joinPath(work.path, 'gone'))..createSync();
      final workspace = (await desktop.openWorkspace(gone.path)).workspace;
      await desktop.saveFixtureProfile();
      gone.deleteSync();

      final e = await rpcFailure(
        desktop.openTerminalRaw('fixture', workspaceId: workspace.id),
      );

      expect(e.reason, ErrorCode.workspaceUnavailable);
      expect(LedgerView(profile).units(), isEmpty);
      expect(readReports(work), isEmpty);
    });

    test('open in a cleanup-unresolved workspace is refused and leaves its '
        'state unchanged', () async {
      final desktop = await start();
      final workspace = (await desktop.openWorkspace(work.path)).workspace;
      await desktop.saveFixtureProfile();
      await desktop.setFault(TestFault.killFails);
      final unit = await desktop.launch(work, TestFixture.sleeper);
      await waitReports(work, 1);
      expect((await desktop.end(unit)).cleaned, isFalse);
      final before = await desktop.allWorkspaces();
      final rows = LedgerView(profile).units();
      expect(before, hasLength(1));

      final e = await rpcFailure(
        desktop.openTerminalRaw('fixture', workspaceId: workspace.id),
      );

      expect(e.reason, ErrorCode.cleanupUnresolved);
      expect(
        [for (final w in await desktop.allWorkspaces()) w.toJson()],
        [for (final w in before) w.toJson()],
      );
      expect(LedgerView(profile).units(), rows);
    });

    test('EDITOR=hx visible only in the terminal from that profile', () async {
      final desktop = await start();
      await desktop.saveFixtureProfile(
        id: 'with-editor',
        cwd: work.path,
        env: {'EDITOR': 'hx'},
      );
      await desktop.saveFixtureProfile(id: 'plain', cwd: work.path);

      final a = await shell(desktop, profileId: 'with-editor');
      final b = await shell(desktop, profileId: 'plain');
      await a.send('env EDITOR');
      await b.send('env EDITOR');
      await a.waitForText('ENV:EDITOR=');
      await b.waitForText('ENV:EDITOR=');

      expect(decodedToken(a.text, 'ENV:EDITOR'), isNull);
      String? editor(OpenTerminal t) {
        final m = RegExp('ENV:EDITOR=([^;]*);').firstMatch(t.text);
        return m == null ? null : utf8.decode(base64.decode(m.group(1)!));
      }

      expect(editor(a), 'hx');
      expect(editor(b), 'nano', reason: "the host's own value, not hx");
    });
  });

  group('relay', () {
    test('escape sequences, invalid UTF-8 and NUL bytes arrive byte-exact and '
        'in order', () async {
      final desktop = await start();
      await desktop.saveFixtureProfile(cwd: work.path);
      final t = await shell(desktop);

      await t.send('bytes');
      await t.waitForText('END;');

      final all = t.bytes;
      final begin = _indexOf(all, utf8.encode('BEGIN;'));
      final end = _indexOf(all, utf8.encode('END;'), begin);
      expect(begin, greaterThanOrEqualTo(0));
      expect(end, greaterThan(begin));
      final received = all.sublist(begin + 'BEGIN;'.length, end);
      if (Platform.isWindows) {
        // ConPTY renders what a program writes into a screen and re-emits it:
        // NUL, invalid UTF-8 and bare control bytes are not kept. The relay
        // itself is byte-exact; here the bytes and the order of the markers
        // are what the host can be held to.
        expect(received, isNotEmpty);
      } else {
        // The default output processing writes each LF as CR LF; every other
        // byte is the program's own.
        expect(
          received,
          orderedEquals([
            for (final b in blob()) ...(b == 0x0A ? [0x0D, 0x0A] : [b]),
          ]),
        );
      }
    });

    test('a scripted PTY-reader byte sequence equals the complete sequence '
        'the desktop receives', () async {
      // The reader yields known chunks (escape sequences, NUL, malformed
      // UTF-8, split across chunk boundaries) before the PTY's own output, so
      // the relay is held to byte equality on every OS, ConPTY included.
      final desktop = await start();
      await desktop.saveFixtureProfile(cwd: work.path);
      await desktop.setFault(TestFault.ptyScriptedOutput);
      final t = await shell(desktop);

      final expected = [for (final chunk in scriptedPtyOutput) ...chunk];
      await eventually(
        () => t.bytes.length >= expected.length,
        reason: 'the scripted bytes did not all arrive',
      );
      expect(t.bytes.sublist(0, expected.length), orderedEquals(expected));
    });

    test('resize is seen by the child (fixture reports its window size after '
        'SIGWINCH / console resize)', () async {
      final desktop = await start();
      await desktop.saveFixtureProfile(cwd: work.path);
      final t = await shell(desktop, cols: 80, rows: 24);
      await t.send('size');
      await t.waitForText('SIZE:80x24;');

      await desktop.resizeTerminal(t.id, 120, 40);
      await t.send('size');

      await t.waitForText('SIZE:120x40;');
    });

    test('100 resizes in 1 s are coalesced and the last size wins; PTY ends '
        'at the final size', () async {
      final desktop = await start();
      await desktop.saveFixtureProfile(cwd: work.path);
      final t = await shell(desktop);
      final clock = Stopwatch()..start();

      for (var i = 1; i <= 100; i++) {
        await desktop.resizeTerminal(t.id, 60 + i, 20 + i % 30);
      }
      await desktop.resizeTerminal(t.id, 133, 37);
      final took = clock.elapsed;
      await t.send('size');

      await eventually(
        () => RegExp('SIZE:133x37;').hasMatch(t.text),
        reason: 'final size not seen: ${t.text}',
      );
      expect(took, lessThan(const Duration(seconds: 20)));
      // The shell stays responsive.
      await t.send('echo alive');
      await t.waitForText('ECHO:alive;');
    });

    test('resize applies to the named terminal only', () async {
      final desktop = await start();
      await desktop.saveFixtureProfile(cwd: work.path);
      final a = await shell(desktop);
      final b = await shell(desktop);

      await desktop.resizeTerminal(a.id, 100, 30);
      await a.send('size');
      await b.send('size');

      await a.waitForText('SIZE:100x30;');
      await b.waitForText('SIZE:80x24;');
      expect(b.text, isNot(contains('SIZE:100x30;')));
    });

    test('0 cols or rows over 500 rejected as invalid-size; PTY keeps its '
        'size', () async {
      final desktop = await start();
      await desktop.saveFixtureProfile(cwd: work.path);
      final t = await shell(desktop, cols: 80, rows: 24);

      for (final (cols, rows) in [(0, 24), (80, 0), (80, 501), (1001, 24)]) {
        final e = await rpcFailure(desktop.resizeTerminal(t.id, cols, rows));
        expect(e.reason, ErrorCode.invalidSize, reason: '${cols}x$rows');
      }
      await t.send('size');

      await t.waitForText('SIZE:80x24;');
      expect(t.text, isNot(contains('SIZE:0x')));
    });

    test('interactive fixture CLI reads input and writes output in a Personal '
        'terminal with no workspace', () async {
      final desktop = await start();
      await desktop.saveFixtureProfile();
      final t = await shell(desktop);

      await t.send('echo hello from the cli');

      await t.waitForText('ECHO:hello from the cli;');
      expect(LedgerView(profile).units().single['kind'], 'terminal');
      expect(LedgerView(profile).workspaces(), isEmpty);
    });

    test("unknown command prints the shell's not-found error and the "
        'terminal stays live', () async {
      final desktop = await start();
      await desktop.saveFixtureProfile();
      final t = await shell(desktop);

      await t.send('claude-not-installed');
      await t.waitForText('command not found');
      await t.send('echo still-here');

      await t.waitForText('ECHO:still-here;');
      expect(t.exited, isNull);
    });

    test(
      'terminal opens on a host with no agent capability or session',
      () async {
        final desktop = await start(
          capabilities: {Capability.workbench, Capability.terminal},
        );
        await desktop.saveFixtureProfile(cwd: work.path);

        final t = await shell(desktop);
        await t.send('echo works');

        await t.waitForText('ECHO:works;');
        expect(desktop.session.hello.capabilities, {
          Capability.workbench,
          Capability.terminal,
        });
      },
    );
  });

  group('exit', () {
    test('externally killed shell reports its status', () async {
      final desktop = await start();
      await desktop.saveFixtureProfile(cwd: work.path);
      final t = await shell(desktop);
      final shellPid = int.parse(tokenOf(t.text, 'PID')!);

      Process.killPid(shellPid, ProcessSignal.sigkill);
      final exited = await t.waitExited();

      expect(exited.reason, TerminalExitReason.exited);
      // POSIX: Dart reports a signal as its negative number. Windows:
      // the raw exit code TerminateProcess set, which Dart's killPid makes
      // -1 (0xFFFFFFFF as the unsigned DWORD the host passes on).
      if (Platform.isWindows) {
        expect(exited.status, anyOf(1, 0xFFFFFFFF));
      } else {
        expect(exited.status, -9);
      }
      expect(t.text, contains('READY;'), reason: 'earlier output stays');
    });

    test('last line printed before exit arrives before exited', () async {
      final desktop = await start();
      await desktop.saveFixtureProfile(cwd: work.path);
      final t = await shell(desktop);

      await t.send('bye 0');
      final exited = await t.waitExited();

      final atExit = t.bytes.sublist(0, t.events.outputAtExit[t.id]);
      expect(plainText(atExit), contains('LASTLINE;'));
      expect(exited.outputComplete, isTrue);
    });

    test('final line precedes exited{status 3, outputComplete true}; channels '
        'open until release', () async {
      final desktop = await start();
      await desktop.saveFixtureProfile(cwd: work.path);
      final t = await shell(desktop);

      await t.send('bye 3');
      final exited = await t.waitExited();

      expect(exited.status, 3);
      expect(exited.outputComplete, isTrue);
      expect(exited.reason, TerminalExitReason.exited);
      expect(
        plainText(t.bytes.sublist(0, t.events.outputAtExit[t.id])),
        contains('LASTLINE;'),
      );
      // Channels stay open: input is still accepted by the channel.
      await t.input.write(utf8.encode('late'));
      expect(LedgerView(profile).units(), isEmpty, reason: 'unit cleaned');

      await t.release();

      await eventually(() async {
        try {
          await t.input.write(utf8.encode('x'));
          return false;
        } on ChannelClosedException {
          return true;
        }
      }, reason: 'the channels were not closed by the release');
    });

    test('close after release returns unknown-terminal', () async {
      final desktop = await start();
      await desktop.saveFixtureProfile(cwd: work.path);
      final t = await shell(desktop);
      await t.send('bye 0');
      await t.waitExited();
      await t.release();

      final close = await rpcFailure(desktop.closeTerminal(t.id));
      final resize = await rpcFailure(desktop.resizeTerminal(t.id, 80, 24));
      final release = await rpcFailure(desktop.releaseTerminal(t.id));

      expect(close.reason, ErrorCode.unknownTerminal);
      expect(resize.reason, ErrorCode.unknownTerminal);
      expect(release.reason, ErrorCode.unknownTerminal);
      // A terminal that never existed is no different.
      final never = await rpcFailure(desktop.closeTerminal('term-none'));
      expect(never.reason, ErrorCode.unknownTerminal);
    });

    test('injected no-EOF PTY after exit: bytes read are delivered, then '
        'exited{outputComplete false}', () async {
      final desktop = await start(
        environment: {'KUMIKO_TEST_READ_DEADLINE_MS': '400'},
      );
      await desktop.saveFixtureProfile(cwd: work.path);
      await desktop.setFault(TestFault.ptyNoEof);
      final t = await shell(desktop);

      await t.send('bye 3');
      final exited = await t.waitExited();

      expect(exited.outputComplete, isFalse);
      expect(exited.status, 3);
      expect(
        plainText(t.bytes.sublist(0, t.events.outputAtExit[t.id])),
        contains('LASTLINE;'),
        reason: 'the bytes read were delivered before the notification',
      );
    });

    test('reader parked over 1 s with unread final bytes; credit resumes; '
        'byte-exact delivery before exited{outputComplete true}', () async {
      // A short read deadline: if time parked for credit counted toward it,
      // the stall below would end the output early.
      final desktop = await start(
        environment: {'KUMIKO_TEST_READ_DEADLINE_MS': '300'},
      );
      await desktop.saveFixtureProfile(cwd: work.path);
      final received = BytesBuilder(copy: false);
      final t = await desktop.openTerminal('fixture', onData: received.add);
      await eventually(
        () => received.length > 0,
        reason: 'the shell printed nothing',
      );
      const total = 256 * 1024 + 64 * 1024 + 8 * 1024;
      final lines = total ~/ 64;
      t.pause();

      await t.send('floodexit ${lines * 64} 0');
      // The shell writes until the terminal's buffers are full and the host
      // is parked without credit; it may or may not have exited yet.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(t.exited, isNull, reason: 'nothing is reported while parked');
      t.resume();
      final exited = await t.waitExited();

      expect(exited.outputComplete, isTrue);
      expect(exited.status, 0);
      final seen = plainText(received.toBytes());
      final sequence = [
        for (final m in RegExp(r'L(\d{8})x+').allMatches(seen))
          int.parse(m.group(1)!),
      ];
      expect(sequence, [for (var i = 0; i < lines; i++) i]);
      if (!Platform.isWindows) {
        // Exactly what the program wrote, plus its start-up report.
        final report = utf8.encode(
          seen.substring(0, seen.indexOf('L00000000')),
        );
        expect(received.length - report.length, greaterThanOrEqualTo(total));
      }
    });
  });
}

int _indexOf(Uint8List haystack, List<int> needle, [int from = 0]) {
  for (var i = from; i <= haystack.length - needle.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  return -1;
}
