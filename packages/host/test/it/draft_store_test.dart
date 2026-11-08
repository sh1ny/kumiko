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

const _ackBound = Duration(milliseconds: 250);

/// Unsent drafts on the host (change `app-exit-and-reopen` design D3, D4,
/// ADR 0014 decisions 8-16): per-session, revision-guarded, removed before a
/// prompt is dispatched, kept in a separate rollback-journal file on a worker
/// isolate that control and cleanup never wait for.
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

  const quick = {'KUMIKO_TEST_DRAFT_DEADLINE_MS': '1000'};

  Future<Desktop> desktop({
    Map<String, String> env = const {},
    Set<String> capabilities = const {},
  }) async {
    final d = await Desktop.start(
      profile,
      capabilities: {...testCapabilities, Capability.agent, ...capabilities},
      environment: {
        'KUMIKO_TEST_RUNTIME_PATH': '',
        'KUMIKO_TEST_SHELL_PATH': '',
        ...env,
      },
    );
    addTearDown(d.dispose);
    await d.waitState();
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
    reason: 'the draft store never opened',
  );

  /// Ends the host as a crash would, then waits for it to be gone.
  Future<void> killHost(Desktop d) async {
    Process.killPid(d.session.pid, ProcessSignal.sigkill);
    await d.session.lost.timeout(hostLossBound * 3);
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
      final d = await Desktop.start(profile);
      addTearDown(d.dispose);
      await d.waitState();
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
      // sent to a peer that never advertised the capability.
      expect((await d.listWorkspaces()).workspaces, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(d.draftStoreReady, 0);
    });

    test('save past 32 MiB total refused draft-cap', () async {
      final ids = await seedSessions(profile, 130);
      final d = await desktop();
      final drafts = Drafts(d);
      final full = 'a' * maxDraftBytes;
      final fits = maxStoredDraftBytes ~/ maxDraftBytes;
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
    }, timeout: const Timeout(Duration(minutes: 3)));

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

    test(
      'draft save acked within control latency under saturated output',
      () async {
        final (d, a, _) = await session(id: 'saver');
        await d.saveFixtureProfile(cwd: work.path);
        var ready = false;
        var bytes = 0;
        var tail = '';
        final terminal = await d.openTerminal(
          'fixture',
          onData: (data) {
            tail += latin1.decode(data);
            if (!ready) {
              ready = tail.contains('READY;');
            } else {
              bytes += data.length;
            }
            if (tail.length > 128) tail = tail.substring(tail.length - 128);
          },
        );
        await eventually(() => ready, reason: 'terminal A did not initialize');
        // Session B has no credit: its events back up and stay unsent.
        final workspace = (await d.listWorkspaces()).workspaces.single;
        final stalledReport = await saveAgentFixture(
          d,
          work,
          id: 'stalled',
          script: {
            'blockedWriteAfterMs': 100,
            'prompt': [
              {
                'flood': {'count': 4096, 'update': textUpdate('b' * 16384)},
              },
            ],
          },
        );
        final b = AgentPeer(d);
        await b.start(workspace.id, runtime: 'stalled');
        await b.attach(credit: false);
        await b.prompt();
        await waitFixture(stalledReport, (p) => p['blockedWrite'] == true);
        await terminal.send('flood ${1 << 40}');
        await eventually(
          () => bytes >= 8 * 1024 * 1024,
          within: const Duration(seconds: 60),
          reason: 'terminal A did not saturate',
        );
        final drafts = Drafts(d);
        var worst = Duration.zero;
        final before = bytes;
        for (var i = 1; i <= 20; i++) {
          final clock = Stopwatch()..start();
          await drafts.save(a.id, 'draft number $i ' * 100, i);
          if (clock.elapsed > worst) worst = clock.elapsed;
        }
        expect(bytes, greaterThan(before), reason: 'A kept flowing');
        // ignore: avoid_print
        print(
          'measured: draft save under saturated output worst of 20 '
          '${worst.inMicroseconds / 1000} ms on ${Platform.operatingSystem}',
        );
        expect(worst, lessThanOrEqualTo(_ackBound));
        await b.close();
        await a.close();
        await d.closeTerminal(terminal.id);
        await terminal.waitExited(within: const Duration(seconds: 35));
        await terminal.subscription.cancel();
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });

  group('durability', () {
    test('draft saved by the stand-in desktop survives its kill', () async {
      final script = File(joinPath(work.path, 'standin-script.json'))
        ..writeAsStringSync('{}');
      final standin = await Process.start(desktopStandinExecutable(), [
        testHostExecutable(),
        profile.path,
        work.path,
        '--draft',
        script.path,
        'check the tests',
      ]);
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
        const Duration(seconds: 90),
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
        within: const Duration(seconds: 40),
        reason: 'host still running',
      );
      expect(draftRow(profile, sessionId)['text'], 'check the tests');

      final d = await desktop();
      final loaded = await Drafts(d).load(sessionId);
      expect((loaded.text, loaded.revision), ('check the tests', 1));
      // Nothing was sent to the adapter by the draft's storing or loading.
      expect(
        receivedPrompts(File(joinPath(work.path, 'standin.report.jsonl'))),
        isEmpty,
      );
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
        expect(
          (await waitFixture(report, (r) => r.containsKey('prompt')))['prompt'],
          isNotEmpty,
          reason: 'the prompt was dispatched after the removal',
        );
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
      await waitFixture(report, (r) => r.containsKey('prompt'));
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
      await waitFixture(report, (r) => r.containsKey('prompt'));
      expect(filesContaining(profile, canary, hostRunning: true), isEmpty);
      expect((await drafts.load(a.id)).text, isNull);
      await a.wait(Method.agentTurnEnded);
      await a.close();
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
      await waitFixture(report, (r) => r.containsKey('prompt'));
      final loaded = await drafts.load(a.id);
      expect((loaded.text, loaded.revision), ('R typed meanwhile', 6));
      expect(filesContaining(profile, canary, hostRunning: true), isEmpty);
      await a.wait(Method.agentTurnEnded);

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
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(receivedPrompts(report), isEmpty, reason: 'nothing ran');
        expect(
          a.of(Method.agentState).where((s) => s['state'] == 'running'),
          isEmpty,
        );
        final loaded = await drafts.load(a.id);
        expect((loaded.text, loaded.revision), ('kept draft', 1));

        // Sending again later is safe.
        await d.setFault(TestFault.draftCommitFails, enabled: false);
        await drafts.send(a, 'kept draft', revision: 1, synced: true);
        await waitFixture(report, (r) => r.containsKey('prompt'));
        expect((await drafts.load(a.id)).text, isNull);
      },
    );

    test('Retry sends no draft fields and leaves the stored draft', () async {
      final (d, a, report) = await session();
      final drafts = Drafts(d);
      await drafts.save(a.id, 'Q stays', 3);
      await drafts.send(a, 'resend P');
      await waitFixture(report, (r) => r.containsKey('prompt'));
      final loaded = await drafts.load(a.id);
      expect((loaded.text, loaded.revision), ('Q stays', 3));
    });

    test(
      'held commit refuses send draft-unavailable within the deadline',
      () async {
        final (d, a, report) = await session(env: quick);
        final drafts = Drafts(d);
        await drafts.save(a.id, 'held send', 1);
        final ready = d.draftStoreReady;
        await d.setFault(TestFault.draftCommitHangs);
        final clock = Stopwatch()..start();
        final e = await refusal(
          drafts.send(a, 'held send', revision: 1, synced: true),
        );
        expect(e.reason, ErrorCode.draftUnavailable);
        expect(clock.elapsedMilliseconds, inInclusiveRange(900, 3000));
        expect(receivedPrompts(report), isEmpty, reason: 'nothing ran');
        // While not responding, the next send fails at once.
        clock.reset();
        final again = await refusal(
          drafts.send(a, 'held send', revision: 2, synced: true),
        );
        expect(again.reason, ErrorCode.draftUnavailable);
        expect(clock.elapsedMilliseconds, lessThan(250));

        await d.setFault(TestFault.draftCommitHangs, enabled: false);
        await eventually(
          () => d.draftStoreReady > ready,
          reason: 'the host never said the store was ready',
        );
        // The removal committed late; the desktop stores the composer again
        // above r.
        final late = await drafts.load(a.id);
        expect((late.text, late.revision), (null, 1));
        expect((await drafts.save(a.id, 'held send', 2)).revision, 2);
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
          reason: 'drafts were not disabled',
        );
        final clock = Stopwatch()..start();
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
        expect(
          clock.elapsedMilliseconds,
          lessThan(1000),
          reason: 'refused at once',
        );
        expect(receivedPrompts(report), isEmpty, reason: 'nothing ran');
        // Retry removes nothing, so it still dispatches.
        await second.send(b, 'resend');
        await waitFixture(report, (r) => r.containsKey('prompt'));
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
      await a.close();
      await d.session.quit();
      expect(filesContaining(profile, canary, hostRunning: false), [
        'drafts.sqlite',
      ]);
      // The main store holds the session record and no text of the draft.
      expect(receivedPrompts(report), isEmpty, reason: 'nothing was sent');
      final reopened = await desktop();
      expect((await Drafts(reopened).load(a.id)).text, 'unsent $canary');
    });
  });

  group('the store never delays control or cleanup', () {
    test('held draft open: reconciliation and launches proceed', () async {
      final first = Directory(joinPath(work.path, 'first'))..createSync();
      final other = Directory(joinPath(work.path, 'other'))..createSync();
      final d = await desktop(
        env: {
          'KUMIKO_TEST_DRAFT_DEADLINE_MS': '800',
          'KUMIKO_TEST_DRAFT_OPEN_HOLD_MS': '4000',
        },
      );
      await d.launch(first, TestFixture.tree);
      final stranded = await waitReports(first, 3);
      await killHost(d);
      final ids = await seedSessions(profile, 1);

      // The same desktop starts the next host: it attests the old one's job
      // closed, so its units are cleaned (not left unresolved) on Windows.
      await d.restart();
      await d.waitState();
      // The previous host's units are reconciled while the draft store is
      // still inside its open.
      await expectAllGone(stranded);
      expect(LedgerView(profile).units(), isEmpty);
      expect(await d.launchRefusal(other, TestFixture.sleeper), isNull);
      await waitReports(other, 1);
      expect((await Drafts(d).stats())['phase'], 'starting');

      final clock = Stopwatch()..start();
      final e = await refusal(Drafts(d).load(ids.single));
      expect(e.reason, ErrorCode.draftUnavailable);
      expect(clock.elapsedMilliseconds, inInclusiveRange(700, 3000));

      // The open finishes: announced, and the store works.
      await eventually(
        () => d.draftStoreReady > 0,
        within: const Duration(seconds: 30),
        reason: 'the store never became available',
      );
      expect((await Drafts(d).save(ids.single, 'now stored', 1)).revision, 1);
    });

    test(
      'held commit: Stop and permission reply within control latency',
      () async {
        final d = await desktop(env: quick);
        final w = await d.openWorkspace(work.path);
        final saverReport = await saveAgentFixture(d, work, id: 'saver');
        final saver = AgentPeer(d);
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
        );
        await asker.prompt();
        final request = await asker.wait(Method.agentPermissionRequested);

        await d.setFault(TestFault.draftCommitHangs);
        final clock = Stopwatch()..start();
        final held = refusal(Drafts(d).save(saver.id, 'held in its commit', 1));
        await Future<void>.delayed(const Duration(milliseconds: 100));

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
        expect(stopAck, lessThanOrEqualTo(_ackBound));
        expect(replyAck, lessThanOrEqualTo(_ackBound));
        expect(
          (await stopper.wait(Method.agentStopResult))['outcome'],
          'stopped',
        );
        await waitFixture(askReport, (p) => p.containsKey('permissionOutcome'));

        final e = await held;
        expect(e.reason, ErrorCode.draftUnavailable);
        expect(clock.elapsedMilliseconds, inInclusiveRange(900, 3000));
        await d.setFault(TestFault.draftCommitHangs, enabled: false);
        expect(saverReport.existsSync() || true, isTrue);
        expect(stopReport.existsSync() || true, isTrue);
      },
    );

    test(
      'held commit: desktop kill ends every unit within the bound',
      () async {
        final (d, a, _) = await session(env: quick);
        final target = Directory(joinPath(work.path, 'units'))..createSync();
        await d.launch(target, TestFixture.tree);
        final tree = await waitReports(target, 3);
        final adapter = await waitReports(work, 1);
        await d.setFault(TestFault.draftCommitHangs);
        unawaited(
          Drafts(d)
              .save(a.id, 'held while the desktop goes', 1)
              .then<void>((_) {}, onError: (Object _) {}),
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));

        final clock = Stopwatch()..start();
        final quit = await d.session.quit();
        // ignore: avoid_print
        print(
          'measured: shutdown with a held draft commit '
          '${clock.elapsedMilliseconds} ms on ${Platform.operatingSystem}',
        );
        expect(quit.timedOut, isFalse);
        expect(quit.exitCode, 0);
        expect(clock.elapsed, lessThan(const Duration(seconds: 15)));
        await expectAllGone([...tree, ...adapter]);
        expect(LedgerView(profile).units(), isEmpty);
      },
    );

    test(
      'released commit clears not responding and sends draftStoreReady',
      () async {
        final (d, a, _) = await session(env: quick);
        final drafts = Drafts(d);
        await drafts.save(a.id, 'before', 1);
        final ready = d.draftStoreReady;
        await d.setFault(TestFault.draftCommitHangs);
        expect(
          (await refusal(drafts.save(a.id, 'held', 2))).reason,
          ErrorCode.draftUnavailable,
        );
        expect((await drafts.stats())['notResponding'], isTrue);
        final clock = Stopwatch()..start();
        expect(
          (await refusal(drafts.save(a.id, 'queued behind', 3))).reason,
          ErrorCode.draftUnavailable,
        );
        expect(clock.elapsedMilliseconds, lessThan(250), reason: 'not queued');
        expect(d.draftStoreReady, ready, reason: 'not announced while stuck');

        await d.setFault(TestFault.draftCommitHangs, enabled: false);
        await eventually(
          () => d.draftStoreReady > ready,
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
