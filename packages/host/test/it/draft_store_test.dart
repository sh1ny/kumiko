import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/agent_support.dart';
import 'support/draft_support.dart';
import 'support/harness.dart';
import 'support/terminal_support.dart';

/// The hang guard of every real-time wait in this file. It is never an
/// expected outcome (ADR 0017, rules 2 and 4 of #28): a wait that reaches it
/// fails the test, a slow runner alone does not.
const _guard = Duration(minutes: 2);

/// Waits until a report of the fixture adapter of [report] matches [test].
Future<void> _waitReport(
  File report,
  bool Function(Json) test,
  String reason,
) => eventually(
  () => fixtureReports(report).any(test),
  within: _guard,
  reason: reason,
);

/// Waits until the fixture adapter of [report] received a prompt of [text].
Future<void> _waitPrompt(File report, String text) => eventually(
  () => promptTexts(report).contains(text),
  within: _guard,
  reason: 'the prompt "$text" never reached the adapter',
);

/// Waits until [count] fixture processes reported in [target].
Future<List<FixtureProcess>> _waitProcesses(Directory target, int count) async {
  await eventually(
    () => readReports(target).length >= count,
    within: _guard,
    reason: 'fixtures did not report $count processes in ${target.path}',
  );
  return readReports(target);
}

Future<void> _expectGone(Iterable<FixtureProcess> processes) => eventually(
  () => processes.every((p) => !p.alive),
  within: _guard,
  reason: 'still alive: ${processes.where((p) => p.alive).toList()}',
);

/// A test hook of the host that takes no parameters.
Future<Json> _hook(Desktop d, String method) async =>
    (await d.connection.request(method, <String, Object?>{}))! as Json;

/// Waits until a commit of the draft store is admitted and has reached its
/// hold in the worker (`heldCommit`), the proof that a test may expire it.
Future<void> _waitHeld(Desktop d) => eventually(
  () async {
    final stats = await Drafts(d).stats();
    return stats['heldCommit'] != null && (stats['pending']! as int) >= 1;
  },
  within: _guard,
  reason: 'the commit never reached its hold',
);

/// Fires the pending deadlines now, after the stage was acknowledged and
/// before any release (design D3), and expects exactly one op to expire.
Future<void> _expireOne(Desktop d) async =>
    expect(await _hook(d, 'test/draft.expire'), {'expired': 1});

/// Ends the agent session of [a] and ignores how that goes: teardown, not an
/// assertion.
Future<void> _closeQuietly(AgentPeer a) async {
  try {
    await a.call(Method.agentClose).timeout(const Duration(seconds: 30));
  } on Object {
    // not under test
  }
}

/// Unsent drafts on the host (change `app-exit-and-reopen` design D3, D4,
/// ADR 0014 decisions 8-16): per-session, revision-guarded, removed before a
/// prompt is dispatched, kept in a separate rollback-journal file on a worker
/// isolate that control and cleanup never wait for.
///
/// No row here fails on elapsed time (ADR 0017). A row that needs a draft
/// deadline to fire expires it with `test/draft.expire`, after the worker
/// acknowledged the stage and before it releases it; every real-time wait is a
/// hang guard.
void main() {
  setUpAll(buildTestHost);

  late Directory profile;
  late Directory work;
  setUp(() {
    profile = tempDir('draft_profile_');
    work = tempDir('draft_work_');
  });
  tearDown(() async {
    killReported(work);
    await deleteTree(work);
    await deleteTree(profile);
  });

  // Every host this suite starts, through `desktop()`, a direct
  // `Desktop.start` (the capability-refusal row, which still omits
  // `Capability.agent`) or the stand-in, gets `draftSuiteEnv`. It turns the
  // prerequisite deadlines the rows only need as setup into hang guards: path
  // resolution and attach, which a slow runner would otherwise miss at the
  // production 5 s and 10 s and fail for reasons unrelated to drafts. A new
  // entry point that bypasses it reintroduces the production prerequisite
  // deadlines.
  const draftSuiteEnv = {
    'KUMIKO_TEST_RESOLVE_TIMEOUT_MS': '120000',
    'KUMIKO_TEST_ATTACH_TIMEOUT_MS': '120000',
  };

  Future<Desktop> desktop({
    Map<String, String> env = const {},
    Set<String> capabilities = const {},
    Duration quitTimeout = defaultQuitTimeout,
    Duration jobDrainTimeout = defaultJobDrainTimeout,
  }) async {
    final d = await Desktop.start(
      profile,
      capabilities: {...testCapabilities, Capability.agent, ...capabilities},
      quitTimeout: quitTimeout,
      jobDrainTimeout: jobDrainTimeout,
      environment: {
        'KUMIKO_TEST_RUNTIME_PATH': '',
        'KUMIKO_TEST_SHELL_PATH': '',
        ...draftSuiteEnv,
        ...env,
      },
    );
    addTearDown(d.dispose);
    await d.waitState(within: _guard);
    return d;
  }

  Future<(Desktop, AgentPeer, File)> session({
    Map<String, String> env = const {},
    Json script = const {},
    String id = 'acp',
    Desktop? on,
  }) async {
    final d = on ?? await desktop(env: env);
    final workspace = await d.openWorkspace(work.path);
    final report = await saveAgentFixture(d, work, id: id, script: script);
    final a = AgentPeer(d);
    await a.start(workspace.workspace.id, runtime: id);
    await a.attach();
    return (d, a, report);
  }

  /// Waits until the draft store of [d] has opened and answers.
  Future<void> storeReady(Desktop d) => eventually(
    () async => (await Drafts(d).stats())['phase'] == 'available',
    within: _guard,
    reason: 'the draft store never opened',
  );

  /// Ends [a] and waits for the host to say so, under the hang guard.
  Future<void> closePeer(AgentPeer a) async {
    await a.call(Method.agentClose);
    await a.wait(
      Method.agentExited,
      where: (p) => p['reason'] == 'closed',
      within: _guard,
    );
  }

  group('bounds and refusals', () {
    test('draftSave for unknown session refused unknown-session', () async {
      final d = await desktop();
      final e = await refusal(Drafts(d).save('no-such-session', 'x', 1));
      expect(e.reason, ErrorCode.unknownSession);
      expect(draftRow(profile, 'no-such-session'), isEmpty);
      expect(
        (await refusal(Drafts(d).load('no-such-session'))).reason,
        ErrorCode.unknownSession,
      );
    });

    test('draft methods need the agent capability on both sides', () async {
      final d = await Desktop.start(profile, environment: draftSuiteEnv);
      addTearDown(d.dispose);
      await d.waitState(within: _guard);
      final drafts = Drafts(d);
      expect(
        (await refusal(drafts.save('s', 'x', 1))).reason,
        ErrorCode.methodNotAvailable,
      );
      expect(
        (await refusal(drafts.load('s'))).reason,
        ErrorCode.methodNotAvailable,
      );
      expect(
        (await refusal(drafts.reset())).reason,
        ErrorCode.methodNotAvailable,
      );
      // The rest of the session keeps working, and the notification is not
      // sent to a peer that never advertised the capability. The store opens
      // and calls its `onAvailable` inline, which would send the notification
      // at once to a peer with the capability; the server awaits each handler
      // before it queues the reply, and control frames reach the desktop in
      // order. So after `available`, one more control round trip, anything
      // the host sent before it has arrived.
      await storeReady(d);
      expect((await d.listWorkspaces()).workspaces, isEmpty);
      expect(d.draftStoreReady, 0);
    });

    test('save past 32 MiB total refused draft-cap', () async {
      final ids = await seedSessions(profile, 130);
      final d = await desktop();
      final drafts = Drafts(d);
      final full = 'a' * maxDraftBytes;
      final fits = maxStoredDraftBytes ~/ maxDraftBytes;
      await storeReady(d);
      for (var i = 0; i < fits; i++) {
        expect((await drafts.save(ids[i], full, 1)).revision, 1);
      }
      final e = await refusal(drafts.save(ids[fits], 'a', 1));
      expect(e.reason, ErrorCode.draftCap);
      expect((await drafts.load(ids[fits])).text, isNull);
      expect(
        (await drafts.load(ids[0])).text,
        full,
        reason: 'others unchanged',
      );
      // Replacing a draft with one of the same size is not an increase.
      expect((await drafts.save(ids[0], full, 2)).revision, 2);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('stale-revision reply carries the stored revision', () async {
      final (d, a, _) = await session();
      final drafts = Drafts(d);
      expect((await drafts.save(a.id, 'stored text', 500)).revision, 500);
      final e = await refusal(drafts.save(a.id, 'older text', 3));
      expect(e.reason, ErrorCode.staleRevision);
      expect(storedRevisionOf(e), 500);
      final loaded = await drafts.load(a.id);
      expect((loaded.text, loaded.revision), ('stored text', 500));
      expect(draftRow(profile, a.id)['text'], 'stored text');
    });

    // The saturated-output row proves that a commit held open does not stop
    // terminal A's output, and that saves around it are acknowledged. Fresh
    // output after the hold is proven by the gate marker: the fixture writes
    // `GATED;` once, only after this test created the gate file, so what the
    // latch sees was produced after the hold began. B's stall is proven by the
    // relay's `paused` flag, which is backpressure that actually happened. A
    // byte count after the hold, or the fixture's timed `blockedWrite` report,
    // must not come back as proof: the relay holds a chunk beyond the window
    // and the channel window does not bound the upstream pipes, so no volume
    // the code guarantees shows freshness, and a timed report proves nothing
    // about what the host holds (design D6, C6). The save latency is printed,
    // never asserted (ADR 0017).
    test('draft save acknowledged under saturated output; a held commit does '
        'not stop A', () async {
      final (d, a, _) = await session(id: 'saver');
      await d.saveFixtureProfile(cwd: work.path);
      final gate = File(joinPath(work.path, 'flood.gate'));
      final marker = MarkerLatch('GATED;');
      var ready = false;
      var bytes = 0;
      var tail = '';
      final terminal = await d.openTerminal(
        'fixture',
        onData: (data) {
          marker.add(data);
          tail += latin1.decode(data);
          if (!ready) {
            ready = tail.contains('READY;');
          } else {
            bytes += data.length;
          }
          if (tail.length > 128) tail = tail.substring(tail.length - 128);
        },
      );
      // Closing the sessions and the terminal is not under test here: the host
      // settles explicit closes on its own production budget. The dedicated
      // close tests assert them.
      final workspace = (await d.listWorkspaces()).workspaces.single;
      AgentPeer? b;
      addTearDown(() async {
        final stalled = b;
        if (stalled != null) await _closeQuietly(stalled);
        await _closeQuietly(a);
        try {
          await d
              .closeTerminal(terminal.id)
              .timeout(const Duration(seconds: 30));
        } on Object {
          // not under test
        }
        await terminal.subscription.cancel();
      });
      await eventually(
        () => ready,
        within: _guard,
        reason: 'terminal A did not initialize',
      );
      // Session B has no credit: its events back up and stay unsent.
      await saveAgentFixture(
        d,
        work,
        id: 'stalled',
        script: {
          'prompt': [
            {
              'flood': {'count': 4096, 'update': textUpdate('b' * 16384)},
            },
          ],
        },
      );
      final stalledPeer = AgentPeer(d);
      b = stalledPeer;
      await stalledPeer.start(workspace.id, runtime: 'stalled');
      await stalledPeer.attach(credit: false);
      await stalledPeer.prompt();
      await eventually(
        () async {
          final stats = await _hook(d, 'test/agent.stats');
          final sessions = stats['sessions']! as Json;
          return (sessions[stalledPeer.id] as Json?)?['paused'] == true;
        },
        within: _guard,
        reason: 'session B never paused for want of credit',
      );
      await terminal.send('flood ${1 << 40} flood.gate');
      await eventually(
        () => bytes >= 8 * 1024 * 1024,
        within: _guard,
        reason: 'terminal A did not saturate',
      );
      final drafts = Drafts(d);
      var worst = Duration.zero;
      for (var i = 1; i <= 20; i++) {
        final clock = Stopwatch()..start();
        expect(
          (await drafts.save(a.id, 'draft number $i ' * 100, i)).revision,
          i,
        );
        if (clock.elapsed > worst) worst = clock.elapsed;
      }
      final stored = await drafts.load(a.id);
      expect((stored.text, stored.revision), ('draft number 20 ' * 100, 20));
      // ignore: avoid_print
      print(
        'measured: draft save under saturated output worst of 20 '
        '${worst.inMicroseconds / 1000} ms on ${Platform.operatingSystem}',
      );
      // Hold one commit open: A's output must keep arriving while it waits,
      // not only between commits.
      await d.setFault(TestFault.draftCommitHangs);
      var settled = false;
      final held = drafts
          .save(a.id, 'held under output', 21)
          .whenComplete(() => settled = true);
      unawaited(held.then<void>((_) {}, onError: (Object _) {}));
      await _waitHeld(d);
      gate.writeAsStringSync('go');
      await eventually(
        () => marker.seen,
        within: _guard,
        reason: 'A stopped while a commit was held',
      );
      expect(settled, isFalse, reason: 'the commit was not held');
      await d.setFault(TestFault.draftCommitHangs, enabled: false);
      expect((await held).revision, 21);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('durability', () {
    test('draft saved by the stand-in desktop survives its kill', () async {
      final script = File(joinPath(work.path, 'standin-script.json'))
        ..writeAsStringSync('{}');
      // The stand-in builds its launcher without an explicit environment, so
      // its host inherits this one.
      final standin = await Process.start(desktopStandinExecutable(), [
        testHostExecutable(),
        profile.path,
        work.path,
        '--draft',
        script.path,
        'check the tests',
      ], environment: draftSuiteEnv);
      addTearDown(() async {
        standin.kill();
        await standin.exitCode;
      });
      final errors = StringBuffer();
      standin.stderr.transform(utf8.decoder).listen(errors.write);
      final lines = <String>[];
      final ready = Completer<void>();
      standin.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            lines.add(line);
            if (line.startsWith('READY ') && !ready.isCompleted) {
              ready.complete();
            }
          });
      await ready.future.timeout(
        _guard,
        onTimeout: () => throw StateError('stand-in failed: $errors'),
      );
      final sessionId = lines
          .firstWhere((l) => l.startsWith('SESSION '))
          .substring('SESSION '.length);
      final hostPid = int.parse(
        lines.firstWhere((l) => l.startsWith('READY ')).split(' ')[1],
      );
      final hostStart = processStartTime(hostPid)!;
      standin.kill(ProcessSignal.sigkill);
      await standin.exitCode;
      await eventually(
        () => !isProcessAlive(hostPid, hostStart),
        within: _guard,
        reason: 'host still running',
      );
      expect(draftRow(profile, sessionId)['text'], 'check the tests');

      final d = await desktop();
      final loaded = await Drafts(d).load(sessionId);
      expect((loaded.text, loaded.revision), ('check the tests', 1));
    });

    test(
      'failed load then edit at low revision recovers floor via stale reply',
      () async {
        final (d, a, _) = await session();
        final drafts = Drafts(d);
        await drafts.save(a.id, 'P stored earlier', 500);
        // The load failed on the desktop, so its counter starts low and the
        // user types Q: refused with the stored revision.
        final e = await refusal(drafts.save(a.id, 'Q typed after', 1));
        expect(e.reason, ErrorCode.staleRevision);
        final floor = storedRevisionOf(e)!;
        expect(floor, 500);
        // The link raises its revision above the floor and saves its current
        // text once more.
        expect(
          (await drafts.save(a.id, 'Q typed after', floor + 1)).revision,
          501,
        );
        await d.session.quit();

        final d2 = await desktop();
        final loaded = await Drafts(d2).load(a.id);
        expect((loaded.text, loaded.revision), ('Q typed after', 501));
      },
    );
  });

  // "Nothing was dispatched" is proven by an exact later event with distinct
  // text, never by a sleep or by a count over reports that may already exist
  // (design D9, C4). The fixture reports every `session/prompt` it receives,
  // even one it then refuses, and `promptTexts` decodes those reports in the
  // order they arrived. After a retry with its own text arrives, the list
  // being exactly `[retry]` proves the earlier send never reached the adapter.
  group('send order', () {
    const p = 'kumiko-canary-p63a unsent draft';
    const q = 'kumiko-canary-q63b typed after the failed load';

    test(
      'unsynced send removes stored P; kill after ack leaves neither',
      () async {
        final (d, a, report) = await session();
        final drafts = Drafts(d);
        await drafts.save(a.id, p, 500);
        expect(
          filesContaining(profile, 'kumiko-canary-p63a', hostRunning: true),
          ['drafts.sqlite'],
        );
        // The load failed: the link is unsynced at a low local revision.
        await drafts.send(a, q, revision: 1, synced: false);
        await _waitPrompt(report, q);
        final loaded = await drafts.load(a.id);
        expect((loaded.text, loaded.revision), (null, 500));
        await killHost(d);
        for (final canary in ['kumiko-canary-p63a', 'kumiko-canary-q63b']) {
          expect(filesContaining(profile, canary, hostRunning: false), isEmpty);
        }
        final d2 = await desktop();
        final after = await Drafts(d2).load(a.id);
        expect((after.text, after.revision), (null, 500));
      },
    );

    test('send before held load returns removes P', () async {
      final (d, a, report) = await session();
      final drafts = Drafts(d);
      // P was stored by an earlier run at revision 7. The pane's load has not
      // returned, so its link is unsynced at revision 0 when the user types Q
      // and sends it: the host must remove P by the unsynced rule although
      // 1 < 7.
      await drafts.save(a.id, p, 7);
      await drafts.send(a, q, revision: 1, synced: false);
      await _waitPrompt(report, q);
      // The late load then returns no text and the floor, so the pane's
      // next save is above it.
      final late = await drafts.load(a.id);
      expect((late.text, late.revision), (null, 7));
      expect(
        filesContaining(profile, 'kumiko-canary-p63a', hostRunning: true),
        isEmpty,
      );
      expect(draftRow(profile, a.id)['text'], isNull);
      expect(storedRevisionOf(await refusal(drafts.save(a.id, 'x', 1))), 7);
    });

    test('canary d1f9 absent from every profile file after ack', () async {
      const canary = 'kumiko-canary-d1f9';
      final (d, a, report) = await session();
      final drafts = Drafts(d);
      await drafts.save(a.id, 'send me: $canary', 1);
      expect(filesContaining(profile, canary, hostRunning: true), [
        'drafts.sqlite',
      ], reason: 'the draft is stored before the send');
      await drafts.send(a, 'send me: $canary', revision: 1, synced: true);
      await _waitPrompt(report, 'send me: $canary');
      expect(filesContaining(profile, canary, hostRunning: true), isEmpty);
      expect((await drafts.load(a.id)).text, isNull);
      await a.wait(Method.agentTurnEnded, within: _guard);
      await closePeer(a);
      await d.session.quit();
      expect(filesContaining(profile, canary, hostRunning: false), isEmpty);
    });

    test(
      'empty save tombstones and the text is absent from every file',
      () async {
        const canary = 'kumiko-canary-c1ea';
        final (d, a, _) = await session();
        final drafts = Drafts(d);
        await drafts.save(a.id, 'about to be cleared $canary', 1);
        expect(filesContaining(profile, canary, hostRunning: true), [
          'drafts.sqlite',
        ]);
        expect((await drafts.save(a.id, '', 2)).revision, 2);
        expect(filesContaining(profile, canary, hostRunning: true), isEmpty);
        final loaded = await drafts.load(a.id);
        expect((loaded.text, loaded.revision), (null, 2));
        expect(draftRow(profile, a.id)['text'], isNull);
        // The tombstone keeps the floor: a late save of the old text is stale.
        expect(
          storedRevisionOf(await refusal(drafts.save(a.id, 'late', 2))),
          2,
        );
        await d.session.quit();
        expect(filesContaining(profile, canary, hostRunning: false), isEmpty);
      },
    );

    test('R saved above r survives; P absent from every file', () async {
      const canary = 'kumiko-canary-b70e';
      final (d, a, report) = await session();
      final drafts = Drafts(d);
      await drafts.save(a.id, 'P $canary', 5);
      // R is typed while the prompt is in flight: both reach the host in
      // order, the removal first.
      final sending = drafts.send(a, 'P $canary', revision: 5, synced: true);
      final typing = drafts.save(a.id, 'R typed meanwhile', 6);
      await sending;
      expect((await typing).revision, 6);
      await _waitPrompt(report, 'P $canary');
      final loaded = await drafts.load(a.id);
      expect((loaded.text, loaded.revision), ('R typed meanwhile', 6));
      expect(filesContaining(profile, canary, hostRunning: true), isEmpty);
      await a.wait(Method.agentTurnEnded, within: _guard);

      // R saved before the removal commits: newer text stays as it is.
      await drafts.save(a.id, 'S $canary', 8);
      await drafts.save(a.id, 'T newer than the send', 9);
      await drafts.send(a, 'S $canary', revision: 8, synced: true);
      final kept = await drafts.load(a.id);
      expect((kept.text, kept.revision), ('T newer than the send', 9));
      expect(filesContaining(profile, canary, hostRunning: true), isEmpty);
    });

    test(
      'injected commit failure refuses the prompt before dispatch',
      () async {
        final (d, a, report) = await session();
        final drafts = Drafts(d);
        await drafts.save(a.id, 'kept draft', 1);
        await d.setFault(TestFault.draftCommitFails);
        final e = await refusal(
          drafts.send(a, 'kept draft', revision: 1, synced: true),
        );
        expect(e.reason, ErrorCode.storeError);
        final loaded = await drafts.load(a.id);
        expect((loaded.text, loaded.revision), ('kept draft', 1));

        // Sending again later is safe, and the retry's own text is the first
        // and only prompt the adapter receives: the refused send never ran.
        await d.setFault(TestFault.draftCommitFails, enabled: false);
        const retry = 'kept draft, sent again after the failed commit';
        await drafts.send(a, retry, revision: 1, synced: true);
        await _waitPrompt(report, retry);
        expect(promptTexts(report), [retry]);
        expect((await drafts.load(a.id)).text, isNull);
      },
    );

    test('Retry sends no draft fields and leaves the stored draft', () async {
      final (d, a, report) = await session();
      final drafts = Drafts(d);
      await drafts.save(a.id, 'Q stays', 3);
      await drafts.send(a, 'resend P');
      await _waitPrompt(report, 'resend P');
      final loaded = await drafts.load(a.id);
      expect((loaded.text, loaded.revision), ('Q stays', 3));
    });

    test(
      'held commit refuses send draft-unavailable once its deadline fires',
      () async {
        final (d, a, report) = await session();
        final drafts = Drafts(d);
        await storeReady(d);
        await drafts.save(a.id, 'held send', 1);
        final ready = d.draftStoreReady;
        await d.setFault(TestFault.draftCommitHangs);
        // The send is admitted and its removal reaches the hold; only then
        // does its deadline fire, and only then is the commit released.
        final sending = refusal(
          drafts.send(a, 'held send', revision: 1, synced: true),
        );
        await _waitHeld(d);
        await _expireOne(d);
        final e = await sending;
        expect(e.reason, ErrorCode.draftUnavailable);
        // While not responding, the next send is refused before it is admitted.
        final pending = (await drafts.stats())['pending'];
        final again = await refusal(
          drafts.send(a, 'held send', revision: 2, synced: true),
        );
        expect(again.reason, ErrorCode.draftUnavailable);
        expect((await drafts.stats())['pending'], pending);

        await d.setFault(TestFault.draftCommitHangs, enabled: false);
        await eventually(
          () => d.draftStoreReady > ready,
          within: _guard,
          reason: 'the host never said the store was ready',
        );
        // The removal committed late: the draft is gone and the tombstone
        // keeps the floor. The desktop stores the composer again above it.
        final late = await drafts.load(a.id);
        expect((late.text, late.revision), (null, 1));
        expect((await drafts.save(a.id, 'held send', 2)).revision, 2);
        // A later send with its own text: the expired send never dispatched.
        const later = 'sent after the late removal returned';
        await drafts.send(a, later, revision: 2, synced: true);
        await _waitPrompt(report, later);
        expect(promptTexts(report), [later]);
      },
    );

    test(
      'disabled store refuses composer send; P kept for healthy restart',
      () async {
        final (d, a, _) = await session();
        final drafts = Drafts(d);
        await drafts.save(a.id, 'P kept for later', 1);
        final recordId = a.id;
        await d.session.quit();
        final healthy = draftsFile(profile).readAsBytesSync();

        // The next launch cannot open the draft store.
        draftsFile(profile).writeAsStringSync('this is not a database ' * 40);
        final d2 = await desktop();
        final w = await d2.openWorkspace(work.path);
        final report = await saveAgentFixture(d2, work, id: 'second');
        final b = AgentPeer(d2);
        await b.start(w.workspace.id, runtime: 'second');
        await b.attach();
        final second = Drafts(d2);
        await eventually(
          () async => (await second.stats())['phase'] == 'disabled',
          within: _guard,
          reason: 'drafts were not disabled',
        );
        expect(
          (await refusal(second.save(b.id, 'Q', 1))).reason,
          ErrorCode.draftUnavailable,
        );
        expect(
          (await refusal(second.load(recordId))).reason,
          ErrorCode.draftUnavailable,
        );
        final send = await refusal(
          second.send(b, 'Q typed and sent', revision: 1, synced: true),
        );
        expect(send.reason, ErrorCode.draftUnavailable);
        expect((await second.stats())['pending'], 0, reason: 'none admitted');
        // Retry removes nothing, so it still dispatches, and its own text is
        // the only prompt the adapter received.
        const retry = 'resend after the refusals';
        await second.send(b, retry);
        await _waitPrompt(report, retry);
        expect(promptTexts(report), [retry]);
        await d2.session.quit();

        // A launch with working storage: A's draft is P, nothing was sent.
        draftsFile(profile).writeAsBytesSync(healthy);
        final d3 = await desktop();
        final loaded = await Drafts(d3).load(recordId);
        expect((loaded.text, loaded.revision), ('P kept for later', 1));
      },
    );
  });

  group('record', () {
    test('canary 5b2e found only in drafts.sqlite', () async {
      const canary = 'kumiko-canary-5b2e';
      final (d, a, report) = await session();
      await Drafts(d).save(a.id, 'unsent $canary', 1);
      expect(filesContaining(profile, canary, hostRunning: true), [
        'drafts.sqlite',
      ]);
      // Storing a draft dispatches nothing: a plain prompt, with no draft
      // fields, so it neither consumes nor tombstones the draft, is the first
      // and only prompt the adapter receives.
      const barrier = 'barrier prompt without draft fields';
      await a.prompt(barrier);
      await _waitPrompt(report, barrier);
      expect(promptTexts(report), [barrier]);
      await a.wait(Method.agentTurnEnded, within: _guard);
      await closePeer(a);
      await d.session.quit();
      expect(filesContaining(profile, canary, hostRunning: false), [
        'drafts.sqlite',
      ]);
      // The main store holds the session record and no text of the draft.
      final reopened = await desktop();
      expect((await Drafts(reopened).load(a.id)).text, 'unsent $canary');
    });
  });

  // These rows prove that control and cleanup do not wait on a draft commit
  // that is held open: the Stop and permission acknowledgements arrive while
  // `heldCommit` is still set, and the host leaves with a commit still held.
  // They do not prove the elapsed bounds of the spec (the 250 ms control
  // bound, `hostLossBound`, the 35 s quit wait, the host's 30 s cleanup after
  // desktop loss), and they do not run the desktop-kill scenario with its
  // cleanup bound: the shutdown row closes the connection instead. Both go to
  // the later automated qualification slice of #28 (design C5, ADR 0017).
  group('the store never delays control or cleanup', () {
    test('held draft open: reconciliation and launches proceed', () async {
      final first = Directory(joinPath(work.path, 'first'))..createSync();
      final other = Directory(joinPath(work.path, 'other'))..createSync();
      // The restart below waits for the old job to drain: a hang guard, not
      // the launcher's 5 s default (design D13).
      final d = await desktop(
        env: {'KUMIKO_TEST_DRAFT_OPEN_HELD': '1'},
        jobDrainTimeout: _guard,
      );
      await d.launch(first, TestFixture.tree);
      final stranded = await _waitProcesses(first, 3);
      await killHost(d);
      final ids = await seedSessions(profile, 1);

      // The same desktop starts the next host: it attests the old one's job
      // closed, so its units are cleaned (not left unresolved) on Windows.
      await d.restart();
      await d.waitState(within: _guard);
      // The previous host's units are reconciled while the draft store is
      // still held at its open.
      await _expectGone(stranded);
      expect(LedgerView(profile).units(), isEmpty);
      expect(await d.launchRefusal(other, TestFixture.sleeper), isNull);
      await _waitProcesses(other, 1);

      final drafts = Drafts(d);
      await eventually(
        () async => (await drafts.stats())['openHeld'] == true,
        within: _guard,
        reason: 'the worker never reached its open gate',
      );
      expect((await drafts.stats())['phase'], 'starting');
      // The load is admitted during the gate, then its deadline fires while
      // the open is still held; only then is the open released.
      final loading = refusal(drafts.load(ids.single));
      await eventually(
        () async => (await drafts.stats())['pending'] == 1,
        within: _guard,
        reason: 'the load was never admitted',
      );
      await _expireOne(d);
      final e = await loading;
      expect(e.reason, ErrorCode.draftUnavailable);
      expect((await drafts.stats())['openHeld'], isTrue);
      expect(await _hook(d, 'test/draft.releaseOpen'), {'released': true});

      // The open finishes: announced, and the store works.
      await eventually(
        () => d.draftStoreReady > 0,
        within: _guard,
        reason: 'the store never became available',
      );
      expect((await drafts.save(ids.single, 'now stored', 1)).revision, 1);
    });

    test(
      'held commit: Stop and permission acknowledged while it is held',
      () async {
        final d = await desktop();
        final w = await d.openWorkspace(work.path);
        final saver = AgentPeer(d);
        await saveAgentFixture(d, work, id: 'saver');
        await saver.start(w.workspace.id, runtime: 'saver');
        await saver.attach();
        final stopReport = await saveAgentFixture(
          d,
          work,
          id: 'stopper',
          script: {
            'prompt': [
              {'waitCancel': true},
            ],
          },
        );
        final stopper = AgentPeer(d);
        await stopper.start(w.workspace.id, runtime: 'stopper');
        await stopper.attach();
        final askReport = await saveAgentFixture(
          d,
          work,
          id: 'asker',
          script: {
            'prompt': [permissionAction],
          },
        );
        final asker = AgentPeer(d);
        await asker.start(w.workspace.id, runtime: 'asker');
        await asker.attach();
        await stopper.prompt();
        await stopper.wait(
          Method.agentState,
          where: (p) => p['state'] == 'running',
          within: _guard,
        );
        await asker.prompt();
        final request = await asker.wait(
          Method.agentPermissionRequested,
          within: _guard,
        );

        await d.setFault(TestFault.draftCommitHangs);
        final held = refusal(Drafts(d).save(saver.id, 'held in its commit', 1));
        await _waitHeld(d);

        final stopClock = Stopwatch()..start();
        await stopper.call(Method.agentStop);
        final stopAck = stopClock.elapsed;
        final replyClock = Stopwatch()..start();
        await asker.call(Method.agentPermissionReply, {
          'sessionId': asker.id,
          'requestId': request['requestId'],
          'optionId': 'yes',
        });
        final replyAck = replyClock.elapsed;
        // ignore: avoid_print
        print(
          'measured: Stop ${stopAck.inMicroseconds / 1000} ms, permissionReply '
          '${replyAck.inMicroseconds / 1000} ms while a draft commit is held '
          'on ${Platform.operatingSystem}',
        );
        expect(
          (await Drafts(d).stats())['heldCommit'],
          isNotNull,
          reason: 'both acknowledgements arrived while the commit was held',
        );
        // The Stop may publish `notConfirmed` after its own bound and later
        // `stopped` with `late: true`; either `stopped` counts.
        await stopper.wait(
          Method.agentStopResult,
          where: (p) => p['outcome'] == 'stopped',
          within: _guard,
        );
        await _waitReport(
          stopReport,
          (r) => r['cancelReceived'] == true,
          'the adapter never received the cancellation',
        );
        await _waitReport(
          askReport,
          (r) => r.containsKey('permissionOutcome'),
          'the adapter never received the permission outcome',
        );

        // Only now does the held save's deadline fire, then it is released.
        await _expireOne(d);
        expect((await held).reason, ErrorCode.draftUnavailable);
        await d.setFault(TestFault.draftCommitHangs, enabled: false);
      },
    );

    // Connection loss (stdin closed) while a commit is held: the host leaves
    // on its own, exit 0, with every unit gone and the ledger empty. The save
    // is neither expired nor released before the connection closes, and its
    // draft deadline (10 min) is longer than the row's whole 5 min timeout, so
    // the host can leave only if shutdown does not wait on the save. The host's
    // own cleanup runs under a 90 s hang guard and the launcher's quit wait is
    // 2 min, so neither the host's deadline nor the launcher kills it first.
    // The empty-ledger check still depends on settlement budgets inside
    // cleanup that a test cannot yet override: a 5 s wait per Windows
    // termination and a 10 s marker-scan pass on POSIX. A slow enough runner
    // can still fail this row on them until a later slice of #28 adds the
    // overrides (design D10, D12, C10).
    test(
      'held commit: connection loss ends every unit and the host leaves',
      () async {
        final d = await desktop(
          env: {
            'KUMIKO_TEST_SHUTDOWN_DEADLINE_MS': '90000',
            'KUMIKO_TEST_DRAFT_DEADLINE_MS': '600000',
          },
          quitTimeout: const Duration(minutes: 2),
        );
        final workspace = await d.openWorkspace(work.path);
        await saveAgentFixture(d, work);
        final a = AgentPeer(d);
        await a.start(workspace.workspace.id, runtime: 'acp');
        await a.attach();
        final target = Directory(joinPath(work.path, 'units'))..createSync();
        await d.launch(target, TestFixture.tree);
        final tree = await _waitProcesses(target, 3);
        final adapter = await _waitProcesses(work, 1);
        await d.setFault(TestFault.draftCommitHangs);
        unawaited(
          Drafts(d)
              .save(a.id, 'held while the connection is lost', 1)
              .then<void>((_) {}, onError: (Object _) {}),
        );
        await _waitHeld(d);

        final clock = Stopwatch()..start();
        final quit = await d.session.quit();
        // ignore: avoid_print
        print(
          'measured: shutdown with a held draft commit '
          '${clock.elapsedMilliseconds} ms on ${Platform.operatingSystem}',
        );
        expect(quit.timedOut, isFalse);
        expect(quit.exitCode, 0);
        await _expectGone([...tree, ...adapter]);
        expect(LedgerView(profile).units(), isEmpty);
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'released commit clears not responding and sends draftStoreReady',
      () async {
        final (d, a, _) = await session();
        final drafts = Drafts(d);
        await storeReady(d);
        await drafts.save(a.id, 'before', 1);
        final ready = d.draftStoreReady;
        await d.setFault(TestFault.draftCommitHangs);
        final held = refusal(drafts.save(a.id, 'held', 2));
        await _waitHeld(d);
        await _expireOne(d);
        expect((await held).reason, ErrorCode.draftUnavailable);
        expect((await drafts.stats())['notResponding'], isTrue);
        final pending = (await drafts.stats())['pending'];
        expect(
          (await refusal(drafts.save(a.id, 'queued behind', 3))).reason,
          ErrorCode.draftUnavailable,
        );
        expect(
          (await drafts.stats())['pending'],
          pending,
          reason: 'refused before it was admitted, not queued',
        );
        expect(d.draftStoreReady, ready, reason: 'not announced while stuck');

        await d.setFault(TestFault.draftCommitHangs, enabled: false);
        await eventually(
          () => d.draftStoreReady > ready,
          within: _guard,
          reason: 'never announced',
        );
        expect((await drafts.stats())['notResponding'], isFalse);
        // The held save did commit once it returned; the next one is above it.
        expect((await drafts.load(a.id)).text, 'held');
        expect((await drafts.save(a.id, 'after', 3)).revision, 3);
      },
    );
  });

  group('reset', () {
    test('reset on a working store refused draft-store-in-use', () async {
      final (d, a, _) = await session();
      final drafts = Drafts(d);
      await drafts.save(a.id, 'must survive', 1);
      final e = await refusal(drafts.reset());
      expect(e.reason, ErrorCode.draftStoreInUse);
      expect((await drafts.load(a.id)).text, 'must survive');
      expect(draftRow(profile, a.id)['text'], 'must survive');
    });

    test(
      'confirmed reset deletes files, sends draftStoreReady, saves succeed',
      () async {
        draftsFile(profile).writeAsStringSync('this is not a database ' * 40);
        final (d, a, _) = await session();
        final drafts = Drafts(d);
        await eventually(
          () async => (await drafts.stats())['phase'] == 'disabled',
          within: _guard,
          reason: 'drafts were not disabled',
        );
        expect(d.draftStoreReady, 0);
        expect(
          (await refusal(drafts.save(a.id, 'x', 1))).reason,
          ErrorCode.draftUnavailable,
        );
        await drafts.reset();
        await eventually(
          () => d.draftStoreReady > 0,
          within: _guard,
          reason: 'never announced',
        );
        final header = draftsFile(profile).readAsBytesSync().sublist(0, 15);
        expect(latin1.decode(header), 'SQLite format 3');
        expect((await drafts.stats())['phase'], 'available');
        expect((await drafts.save(a.id, 'fresh', 1)).revision, 1);
        expect(draftRow(profile, a.id)['text'], 'fresh');
      },
    );

    test(
      'concurrent reset refused; one successor; acked save survives restart',
      () async {
        draftsFile(profile).writeAsStringSync('this is not a database ' * 40);
        final (d, a, _) = await session();
        final drafts = Drafts(d);
        await eventually(
          () async => (await drafts.stats())['phase'] == 'disabled',
          within: _guard,
          reason: 'drafts were not disabled',
        );
        await d.setFault(TestFault.draftResetHangs);
        final first = drafts.reset();
        // The reservation is made before the reset's first await.
        final second = await refusal(drafts.reset());
        expect(second.reason, ErrorCode.draftStoreInUse);
        expect(
          (await refusal(drafts.save(a.id, 'x', 1))).reason,
          ErrorCode.draftUnavailable,
          reason: 'operations fail while the reset is reserved',
        );
        expect((await drafts.stats())['phase'], 'resetting');
        await d.setFault(TestFault.draftResetHangs, enabled: false);
        await first;
        await eventually(
          () => d.draftStoreReady > 0,
          within: _guard,
          reason: 'never announced',
        );
        final stats = await drafts.stats();
        expect(stats['phase'], 'available');
        expect(stats['workersSpawned'], 2, reason: 'exactly one successor');
        expect((await drafts.save(a.id, 'acked after ready', 1)).revision, 1);
        await d.session.quit();

        final d2 = await desktop();
        final loaded = await Drafts(d2).load(a.id);
        expect((loaded.text, loaded.revision), ('acked after ready', 1));
      },
    );
  });

  test(
    'the draft store opens beside the main store, journal mode DELETE',
    () async {
      final d = await desktop();
      await storeReady(d);
      final stats = await Drafts(d).stats();
      expect(stats['pragmas'], {
        'journal_mode': 'delete',
        'synchronous': 3,
        'secure_delete': 1,
        'user_version': 1,
      });
      expect(File('${draftsFile(profile).path}-wal').existsSync(), isFalse);
      expect(
        Uint8List.fromList(draftsFile(profile).readAsBytesSync().sublist(0, 6)),
        isNotEmpty,
      );
    },
  );
}
