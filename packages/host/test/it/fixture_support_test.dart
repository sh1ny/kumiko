import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/agent_support.dart';
import 'support/draft_support.dart';
import 'support/harness.dart';
import 'support/terminal_support.dart';

/// The test fixtures and helpers the draft rows stand on: the terminal
/// fixture's gated `flood`, the marker latch, the ACP fixture's
/// `promptReceived` report and `promptTexts`.
void main() {
  setUpAll(buildTestHost);

  group('MarkerLatch', () {
    List<int> b(String s) => utf8.encode(s);

    test('the marker split across three chunks sets the latch', () {
      final latch = MarkerLatch('GATED;');
      latch.add(b('xxGA'));
      expect(latch.seen, isFalse);
      latch.add(b('T'));
      expect(latch.seen, isFalse);
      latch.add(b('ED;yy'));
      expect(latch.seen, isTrue);
    });

    test('the marker split across two chunks sets the latch', () {
      final latch = MarkerLatch('GATED;');
      latch.add(b('...GAT'));
      expect(latch.seen, isFalse);
      latch.add(b('ED;'));
      expect(latch.seen, isTrue);
    });

    test('the marker within one chunk sets the latch', () {
      final latch = MarkerLatch('GATED;');
      latch.add(b('a GATED; b'));
      expect(latch.seen, isTrue);
    });

    test('a near miss does not set it, and it stays set', () {
      final latch = MarkerLatch('GATED;');
      latch.add(b('GATE'));
      latch.add(b('X;GATED'));
      expect(latch.seen, isFalse);
      latch.add(b(';'));
      expect(latch.seen, isTrue);
      latch.add(b('nothing more'));
      expect(latch.seen, isTrue);
    });

    test('one byte per chunk finds it', () {
      final latch = MarkerLatch('GATED;');
      for (final byte in b('..GATED;')) {
        latch.add([byte]);
      }
      expect(latch.seen, isTrue);
    });
  });

  group('promptTexts', () {
    late Directory dir;
    setUp(() => dir = tempDir('prompt_texts_'));
    tearDown(() => deleteTree(dir));

    File reportOf(List<Object?> lines) {
      final file = File(joinPath(dir.path, 'r.jsonl'));
      file.writeAsStringSync(
        [for (final l in lines) '${jsonEncode(l)}\n'].join(),
      );
      return file;
    }

    test('reads the one text block of each promptReceived, in order', () {
      final report = reportOf([
        {'newCwd': '/x'},
        {
          'promptReceived': [
            {'type': 'text', 'text': 'first'},
          ],
        },
        {
          'prompt': [
            {'type': 'text', 'text': 'first'},
          ],
        },
        {
          'promptReceived': [
            {'type': 'text', 'text': 'second'},
          ],
        },
      ]);
      expect(promptTexts(report), ['first', 'second']);
    });

    test('no report file reads as no prompts', () {
      expect(promptTexts(File(joinPath(dir.path, 'none.jsonl'))), isEmpty);
    });

    final malformed = <String, Object?>{
      'two blocks': [
        {'type': 'text', 'text': 'a'},
        {'type': 'text', 'text': 'b'},
      ],
      'no blocks': <Object?>[],
      'a non-text block': [
        {'type': 'image', 'data': 'x'},
      ],
      'a text block without text': [
        {'type': 'text'},
      ],
      'not a list': 'plain',
    };
    for (final entry in malformed.entries) {
      test('a malformed payload (${entry.key}) fails the test', () {
        final report = reportOf([
          {'promptReceived': entry.value},
        ]);
        expect(() => promptTexts(report), throwsA(isA<TestFailure>()));
      });
    }
  });

  group('acp fixture promptReceived', () {
    late Directory work;
    setUp(() => work = tempDir('acp_fixture_'));
    tearDown(() => deleteTree(work));

    /// Runs the fixture adapter directly, feeds it [requests] and returns the
    /// report once [until] holds.
    Future<File> run(
      Json script,
      List<Json> requests,
      bool Function(File report) until,
    ) async {
      final report = File(joinPath(work.path, 'r.jsonl'));
      final scriptFile = File(joinPath(work.path, 's.json'))
        ..writeAsStringSync(jsonEncode({'reportFile': report.path, ...script}));
      final process = await Process.start(testHostExecutable(), [
        '--test-fixture',
        'acp-agent',
        '--script',
        scriptFile.path,
      ], workingDirectory: work.path);
      process.stdout.drain<void>().ignore();
      process.stderr.drain<void>().ignore();
      try {
        for (final r in requests) {
          process.stdin.writeln(jsonEncode({'jsonrpc': '2.0', ...r}));
        }
        await process.stdin.flush();
        await eventually(
          () => until(report),
          within: const Duration(minutes: 2),
          reason: 'the fixture never reported the prompts',
        );
      } finally {
        process.kill();
        await process.exitCode;
      }
      return report;
    }

    Json prompt(int id, String text) => {
      'id': id,
      'method': 'session/prompt',
      'params': {
        'sessionId': 'native-1',
        'prompt': [
          {'type': 'text', 'text': text},
        ],
      },
    };

    test('a prompt refused as busy is still reported', () async {
      final report = await run(
        {'holdPrompt': true},
        [prompt(1, 'running'), prompt(2, 'while busy')],
        (f) => promptTexts(f).length >= 2,
      );
      expect(promptTexts(report), ['running', 'while busy']);
    });

    test('a prompt answered with a scripted error is still reported', () async {
      final report = await run(
        {
          'errors': {
            'session/prompt': {'code': -32000, 'message': 'scripted'},
          },
        },
        [prompt(1, 'refused')],
        (f) => promptTexts(f).isNotEmpty,
      );
      expect(promptTexts(report), ['refused']);
    });
  });

  group('term_fixture flood gate', () {
    late Directory profile;
    late Directory work;
    setUp(() {
      profile = tempDir('flood_profile_');
      work = tempDir('flood_work_');
    });
    tearDown(() async {
      killReported(work);
      await deleteTree(work);
      await deleteTree(profile);
    });

    const total = 2 * 1024 * 1024;

    int markers(OpenTerminal t) => 'GATED;'.allMatches(t.text).length;

    Future<(OpenTerminal, File)> flooding({
      void Function(Uint8List data)? onData,
    }) async {
      final d = await Desktop.start(
        profile,
        helloTimeout: const Duration(minutes: 2),
        environment: {
          'TERM_FIXTURE_HOST': testHostExecutable(),
          'KUMIKO_TEST_RESOLVE_TIMEOUT_MS': '120000',
          'KUMIKO_TEST_ATTACH_TIMEOUT_MS': '120000',
        },
      );
      addTearDown(d.dispose);
      await d.waitState(within: const Duration(minutes: 2));
      await d.saveFixtureProfile(cwd: work.path);
      if (onData == null) {
        final t = await d.openTerminal('fixture');
        await t.waitForText('READY;', within: const Duration(minutes: 2));
        return (t, File(joinPath(work.path, 'gate')));
      }
      final ready = MarkerLatch('READY;');
      final t = await d.openTerminal(
        'fixture',
        onData: (data) {
          ready.add(data);
          onData(data);
        },
      );
      addTearDown(() async {
        try {
          await d.closeTerminal(t.id).timeout(const Duration(seconds: 30));
        } on Object {
          // not under test
        }
        await t.subscription.cancel();
      });
      await eventually(
        () => ready.seen,
        within: const Duration(minutes: 2),
        reason: 'the fixture never printed READY;',
      );
      return (t, File(joinPath(work.path, 'gate')));
    }

    test(
      'a gate created mid-flood makes it write GATED; exactly once',
      () async {
        // Output is counted as it arrives, never kept: the flood runs until
        // teardown. A batch is 16 KiB and the gate is checked after each one,
        // so 1 MiB of output before the file exists means many checks ran
        // without it, and 1 MiB after the marker means many ran after it.
        const window = 1024 * 1024;
        var counting = false;
        var received = 0;
        var count = 0;
        int? markedAt;
        var carry = '';
        final (t, gate) = await flooding(
          onData: (data) {
            if (!counting) return;
            received += data.length;
            final joined = carry + latin1.decode(data);
            final found = 'GATED;'.allMatches(joined).length;
            if (found > 0 && markedAt == null) markedAt = received;
            count += found;
            carry = joined.length < 5
                ? joined
                : joined.substring(joined.length - 5);
          },
        );
        counting = true;
        await t.send('flood ${1 << 40} gate');
        await eventually(
          () => received >= window,
          within: const Duration(minutes: 2),
          reason: 'the flood never started',
        );
        expect(count, 0, reason: 'GATED; came before the gate file existed');
        gate.writeAsStringSync('go');
        await eventually(
          () => markedAt != null && received - markedAt! >= window,
          within: const Duration(minutes: 2),
          reason: 'no GATED; and further output after the gate file',
        );
        expect(count, 1);
      },
    );

    test('without the gate file it never writes GATED;', () async {
      final (t, _) = await flooding();
      await t.send('flood ${total ~/ 8} gate');
      await t.waitForText('FLOODED:', within: const Duration(minutes: 2));
      expect(markers(t), 0);
    });
  });
}
