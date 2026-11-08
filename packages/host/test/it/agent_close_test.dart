import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/agent_support.dart';
import 'support/harness.dart';

void main() {
  setUpAll(buildTestHost);
  late Directory profile;
  late Directory work;
  setUp(() {
    profile = tempDir('agent_close_profile_');
    work = tempDir('agent_close_work_');
  });
  tearDown(() async {
    killReported(work);
    await deleteTree(work);
    await deleteTree(profile);
  });
  Future<(Desktop, AgentPeer, File)> open({
    Json script = const {},
    bool attach = true,
    Map<String, String> env = const {},
    Duration quitTimeout = defaultQuitTimeout,
  }) async {
    final d = await Desktop.start(
      profile,
      quitTimeout: quitTimeout,
      capabilities: {...testCapabilities, Capability.agent},
      environment: {
        'KUMIKO_TEST_RUNTIME_PATH': '',
        'KUMIKO_TEST_SHELL_PATH': '',
        ...env,
      },
    );
    addTearDown(d.dispose);
    await d.waitState();
    final w = await d.openWorkspace(work.path);
    final report = await saveAgentFixture(d, work, script: script);
    final a = AgentPeer(d);
    await a.start(w.workspace.id, runtime: 'acp');
    if (attach) await a.attach();
    return (d, a, report);
  }

  test('idle close terminates the unit, retains the record and release frees only its own channel', () async {
    final (d, a, _) = await open();
    final b = AgentPeer(d);
    await b.start(agentRows(profile).single['workspace_id'] as String);
    await b.attach();
    final records = agentRows(profile);
    final clock = Stopwatch()..start();
    await a.call(Method.agentClose);
    expect(clock.elapsed, lessThan(const Duration(milliseconds: 250)));
    await a.wait(Method.agentExited, where: (p) => p['reason'] == 'closed');
    await a.call(Method.agentRelease);
    await expectLater(
      a.call(Method.agentStop),
      rpcCode(ErrorCode.unknownSession),
    );
    expect(agentRows(profile), records);
    await b.prompt();
    await b.wait(Method.agentTurnEnded);
    await b.close();
    expect(LedgerView(profile).units(), isEmpty);
  });
  test('running close cancels permissions before cancel, terminates the tree and retains changed files and record', () async {
    final changed = File(joinPath(work.path, 'changed.txt'));
    final (_, a, report) = await open(
      script: {
        'prompt': [
          {'spawnTree': true},
          {
            'writeFile': {'path': changed.path, 'text': 'keep this change'},
          },
          permissionAction,
        ],
        'holdPrompt': true,
      },
    );
    await a.prompt();
    await a.wait(Method.agentPermissionRequested);
    final tree = await waitReports(work, 4);
    final before = agentRows(profile).single;
    final clock = Stopwatch()..start();
    await a.call(Method.agentClose);
    expect(clock.elapsed, lessThan(const Duration(milliseconds: 250)));
    await a.wait(Method.agentExited, where: (p) => p['reason'] == 'closed');
    final reports = fixtureReports(report);
    expect(
      reports.firstWhere(
        (p) => p.containsKey('permissionOutcome'),
      )['permissionOutcome'],
      {'outcome': 'cancelled'},
    );
    expect(
      reports.indexWhere((p) => p.containsKey('permissionOutcome')),
      lessThan(reports.indexWhere((p) => p['cancelReceived'] == true)),
    );
    await expectAllGone(tree);
    expect(changed.readAsStringSync(), 'keep this change');
    expect(agentRows(profile).single, before);
    expect(LedgerView(profile).units(), isEmpty);
  });
  test('no attach within attach timeout terminates the unit, frees the channel and keeps the record', () async {
    final (d, a, _) = await open(
      attach: false,
      env: {'KUMIKO_TEST_ATTACH_TIMEOUT_MS': '300'},
    );
    await eventually(() => LedgerView(profile).units().isEmpty);
    await expectAllGone(readReports(work));
    expect(agentRows(profile).single['id'], a.id);
    await expectLater(
      a.call(Method.agentAttach),
      rpcCode(ErrorCode.unknownSession),
    );
    // All 160 slots fit: the timed-out reservation did not leak one.
    for (var i = 0; i < maxChannels; i++) {
      await d.connection.request(
        Method.testChannelOpen,
        const TestChannelOpenParams(0),
      );
    }
  });

  test(
    'attach expiry during held failure settlement frees its reservation',
    () async {
      final (d, a, _) = await open(
        attach: false,
        env: {
          'KUMIKO_TEST_ATTACH_TIMEOUT_MS': '500',
          'KUMIKO_TEST_SETTLE_DEADLINE_MS': '5000',
        },
        script: {
          'prompt': [
            {'oversizedBytes': 1},
          ],
        },
      );
      await d.setFault(TestFault.terminateHangs);
      try {
        await a.prompt('fail before attaching');
        await a.wait(Method.agentState, where: (p) => p['state'] == 'failed');
        await eventually(() async {
          final stats =
              await d.connection.request('test/agent.stats', {}) as Json;
          return ((stats['sessions'] as Json)[a.id] as Json)['ending'] == true;
        });
        await Future<void>.delayed(const Duration(milliseconds: 650));
        expect(a.of(Method.agentExited), isEmpty);
      } finally {
        await d.setFault(TestFault.terminateHangs, enabled: false);
      }
      await a.wait(Method.agentExited);
      await eventually(() => LedgerView(profile).units().isEmpty);
      await expectAllGone(readReports(work));
      expect(agentRows(profile).single['id'], a.id);
      await expectLater(
        a.call(Method.agentAttach),
        rpcCode(ErrorCode.unknownSession),
      );
      for (var i = 0; i < maxChannels; i++) {
        await d.connection.request(
          Method.testChannelOpen,
          const TestChannelOpenParams(0),
        );
      }
      expect(d.connection.isClosed, isFalse);
    },
  );
  test('cleanup failure reports closeFailed never false exited and preserves unresolved launch gate', () async {
    final (d, a, _) = await open(
      env: {'KUMIKO_TEST_SETTLE_DEADLINE_MS': '250'},
    );
    await d.setFault(TestFault.terminateHangs);
    await a.call(Method.agentClose);
    await a.wait(Method.agentCloseFailed);
    expect(a.of(Method.agentExited), isEmpty);
    final unit = LedgerView(profile).units().single;
    expect(unit['state'], 'unresolved');
    expect(agentRows(profile).single['id'], a.id);
    final b = AgentPeer(d);
    await expectLater(
      b.start(agentRows(profile).single['workspace_id'] as String),
      rpcCode(ErrorCode.cleanupUnresolved),
    );
    expect(agentRows(profile), hasLength(1));
    // closeFailed ends transport ownership, not cleanup ownership. Recovery
    // stays gated by the durable ledger until the cleanup action resolves it.
    await expectLater(
      a.call(Method.agentClose),
      rpcCode(ErrorCode.unknownSession),
    );
    await expectLater(
      a.call(Method.agentContinue),
      rpcCode(ErrorCode.resumeUnavailable),
    );
    await d.setFault(TestFault.terminateHangs, enabled: false);
    final retried = await d.retry(unit['target_identity'] as String);
    expect(retried.resolvedUnits, 1);
    expect(retried.unresolvedUnits, 0);
    expect(LedgerView(profile).units(), isEmpty);
    expect(
      a.of(Method.agentExited),
      isEmpty,
      reason: 'cleanup retry is not a successful agent close',
    );
    final recovered = AgentPeer(d);
    await recovered.start(
      agentRows(profile).single['workspace_id'] as String,
      runtime: 'acp',
    );
    await recovered.attach();
    await recovered.close();
    expect(agentRows(profile).map((row) => row['id']), contains(a.id));
  });
  test('unexpected exit counts accepted final events under withheld credit before release', () async {
    final text = 'final-${'x' * (384 * 1024)}';
    final prompt = 'question-${'q' * (192 * 1024)}';
    final (d, a, _) = await open(
      attach: false,
      script: {
        'prompt': [
          {'update': textUpdate(text)},
          {'exit': 7},
        ],
      },
    );
    final decoder = AgentEventDecoder();
    final received = <AgentEvent>[];
    final input = d.connection
        .attachInbound(a.started.eventChannel, grantInitial: false)
        .listen((bytes) => received.addAll(decoder.add(bytes)));
    addTearDown(input.cancel);
    await a.call(Method.agentAttach);
    await a.prompt(prompt);
    final exit = await a.wait(
      Method.agentExited,
      where: (p) => p['reason'] == 'failed',
    );
    expect(exit['status'], 7);
    expect(received, isEmpty);
    final expectedCount =
        encodeAgentEvent(AgentEvent.text(AgentEventKind.user, prompt)).length +
        encodeAgentEvent(AgentEvent.text(AgentEventKind.agentText, text))
            .length;
    expect(exit['eventCount'], expectedCount);
    expect(
      LedgerView(profile).units(),
      isEmpty,
      reason: 'below-bound queued output must not prevent native exit',
    );
    d.connection.grantInitial(a.started.eventChannel);
    await eventually(() => received.length == expectedCount);
    expect(
      received
          .where((e) => e.kind == AgentEventKind.agentText)
          .map((e) => e.text)
          .join(),
      text,
    );
    expect(
      received
          .where((e) => e.kind == AgentEventKind.user)
          .map((e) => e.text)
          .join(),
      prompt,
    );
    await a.call(Method.agentRelease);
    decoder.close();
    await expectLater(
      a.call(Method.agentRelease),
      rpcCode(ErrorCode.unknownSession),
    );
    expect(d.connection.isClosed, isFalse);
    expect(agentRows(profile).single['id'], a.id);
  });

  test('native exit retires permissions and drains trailing updates after credit resumes', () async {
    final text = '\u0001' * maxAgentTextChunkBytes;
    const trailing = 'accepted after the expanded final update';
    final (d, a, _) = await open(
      attach: false,
      script: {
        'prompt': [
          {...permissionAction, 'waitPermission': false},
          {'update': textUpdate(text)},
          {
            ...permissionAction,
            'rpcId': 'late-draining-permission',
            'waitPermission': false,
          },
          {'update': textUpdate(trailing)},
          {'exit': 7},
        ],
      },
    );
    final unit = LedgerView(profile).units().single;
    final adapterPid = unit['pid'] as int;
    final adapterStart = processStartTime(adapterPid)!;
    final decoder = AgentEventDecoder();
    final record = agentRows(profile).single;
    final received = <AgentEvent>[];
    final input = d.connection
        .attachInbound(a.started.eventChannel, grantInitial: false)
        .listen((bytes) => received.addAll(decoder.add(bytes)));
    addTearDown(input.cancel);
    await a.call(Method.agentAttach);
    await a.prompt('exit under backpressure');
    final permission = await a.wait(Method.agentPermissionRequested);
    Json stats = {};
    await eventually(() async {
      final snapshot =
          await d.connection.request('test/agent.stats', {}) as Json;
      stats = (snapshot['sessions'] as Json)[a.id] as Json;
      return stats['paused'] == true &&
          !isProcessAlive(adapterPid, adapterStart);
    }, reason: 'adapter did not exit while normalized admission was blocked');
    expect(stats['queuedBytes'] as int, greaterThanOrEqualTo(1024 * 1024));
    expect(
      stats['queuedBytes'] as int,
      lessThan(1024 * 1024 + maxAgentEventBytes + 1),
    );
    expect(
      stats['channelQueuedBytes'] as int,
      lessThanOrEqualTo(channelWindow),
    );
    expect(stats['largeLineOwned'], isFalse);
    expect(received, isEmpty);
    await a.wait(
      Method.agentState,
      where: (p) => p['state'] == 'failed',
      within: const Duration(seconds: 3),
    );
    final resolved = await a.wait(Method.agentPermissionResolved);
    expect(resolved['requestId'], permission['requestId']);
    expect(resolved['outcome'], 'cancelled');
    await expectLater(
      a.call(Method.agentPermissionReply, {
        'sessionId': a.id,
        'requestId': permission['requestId'],
        'optionId': 'yes',
      }),
      rpcCode(ErrorCode.unknownRequest),
    );
    expect(
      a.of(Method.agentExited),
      isEmpty,
      reason: 'a final count cannot be sealed during partial admission',
    );
    d.connection.grantInitial(a.started.eventChannel);
    final exited = await a.wait(
      Method.agentExited,
      where: (p) => p['reason'] == 'failed',
    );
    final expectedCount =
        encodeAgentEvent(
          AgentEvent.text(AgentEventKind.user, 'exit under backpressure'),
        ).length +
        encodeAgentEvent(AgentEvent.text(AgentEventKind.agentText, text))
            .length +
        encodeAgentEvent(AgentEvent.text(AgentEventKind.agentText, trailing))
            .length;
    expect(exited['status'], 7);
    expect(exited['eventCount'], expectedCount);
    await eventually(() => received.length == expectedCount);
    expect(
      received
          .where((event) => event.kind == AgentEventKind.agentText)
          .map((event) => event.text)
          .join(),
      '$text$trailing',
    );
    expect(received.every((event) => !event.truncated), isTrue);
    expect(a.of(Method.agentPermissionRequested), hasLength(1));
    expect(a.of(Method.agentPermissionResolved), [resolved]);
    expect(a.of(Method.agentExited), hasLength(1));
    expect(isProcessAlive(adapterPid, adapterStart), isFalse);
    expect(LedgerView(profile).units(), isEmpty);
    expect(agentRows(profile).single, record);
    await a.call(Method.agentRelease);
    decoder.close();
  });

  for (final fault in [TestFault.killFails, TestFault.terminateHangs]) {
    test(
      'Windows exited leader with inherited pipes retains unresolved ownership '
      'and shuts down within bound (${fault.name})',
      () async {
        final (d, a, report) = await open(
          script: {
            'prompt': [
              {'spawnPipeHolder': true},
              {'exit': 8},
            ],
          },
          env: {
            'KUMIKO_TEST_SETTLE_DEADLINE_MS': '250',
            'KUMIKO_TEST_SHUTDOWN_DEADLINE_MS': '250',
            'KUMIKO_TEST_READ_DEADLINE_MS': '50',
          },
          quitTimeout: const Duration(seconds: 3),
        );
        await d.setFault(fault);
        final unit = LedgerView(profile).units().single;
        final adapterPid = unit['pid'] as int;
        final adapterStart = processStartTime(adapterPid)!;
        await a.prompt();
        await waitFixture(report, (p) => p['spawnedPipeHolder'] == true);
        final tree = await waitReports(work, 2);
        final holder = tree.singleWhere((process) => process.role == 'sleeper');
        await eventually(() => !isProcessAlive(adapterPid, adapterStart));
        expect(holder.alive, isTrue);
        await a.call(Method.agentClose);
        await a.wait(Method.agentCloseFailed);
        expect(a.of(Method.agentExited), isEmpty);
        final unresolved = LedgerView(profile).units().single;
        expect(unresolved['state'], 'unresolved');
        expect(unresolved['containment_id'], unit['containment_id']);
        expect(holder.alive, isTrue);
        final clock = Stopwatch()..start();
        final quit = await d.session.quit();
        expect(
          quit.timedOut,
          isFalse,
          reason: 'host joined a native ReadFile held by a live descendant',
        );
        expect(quit.exitCode, 0);
        expect(clock.elapsed, lessThan(const Duration(seconds: 3)));
        final retained = LedgerView(profile).units().single;
        expect(retained['containment_id'], unit['containment_id']);
        expect(retained['state'], 'unresolved');
        expect(retained['unresolved_reason'], contains('shutdown-deadline'));
        expect(agentRows(profile).single['id'], a.id);
        await expectAllGone(tree);
      },
      skip: !Platform.isWindows,
    );
  }

  test(
    'exit before attach republishes the final count and drains accepted output',
    () async {
      final (d, a, _) = await open(
        attach: false,
        script: {
          'prompt': [
            {'update': textUpdate('before attach')},
            {'exit': 6},
          ],
        },
      );
      await a.prompt();
      final exit = await a.wait(
        Method.agentExited,
        where: (p) => p['reason'] == 'failed',
      );
      expect(exit['eventCount'], 2);
      await a.attach();
      await eventually(() => a.events.length == 2);
      expect(a.events.last['text'], 'before attach');
      await a.call(Method.agentRelease);
      expect(d.connection.isClosed, isFalse);
      expect(agentRows(profile).single['id'], a.id);
    },
  );

  test(
    'consumer cancellation after final bytes flushed forgets exited ownership',
    () async {
      final (d, a, _) = await open(
        script: {
          'prompt': [
            {'update': textUpdate('last output')},
            {'exit': 9},
          ],
        },
      );
      await a.prompt();
      await a.wait(Method.agentExited, where: (p) => p['reason'] == 'failed');
      await eventually(
        () => a.events.any((event) => event['text'] == 'last output'),
      );
      await a.data!.cancel();
      await eventually(
        () async {
          final stats =
              await d.connection.request('test/agent.stats', {}) as Json;
          return !(stats['sessions'] as Json).containsKey(a.id);
        },
        within: const Duration(seconds: 3),
        reason: 'cancelled final stream left a ghost exited owner',
      );
      await expectLater(
        a.call(Method.agentRelease),
        rpcCode(ErrorCode.unknownSession),
      );
      expect(agentRows(profile).single['id'], a.id);
    },
  );

  test(
    'explicit close during held failure settlement preserves dismissal intent',
    () async {
      final (d, a, _) = await open(
        script: {
          'prompt': [
            {'oversizedBytes': 1},
          ],
        },
      );
      final tree = await waitReports(work, 1);
      await d.setFault(TestFault.terminateHangs);
      try {
        await a.prompt('fail before dismissal');
        await a.wait(Method.agentState, where: (p) => p['state'] == 'failed');
        await eventually(() async {
          final stats =
              await d.connection.request('test/agent.stats', {}) as Json;
          return ((stats['sessions'] as Json)[a.id] as Json)['ending'] == true;
        }, reason: 'failure never reached the held containment settlement');
        expect(a.of(Method.agentExited), isEmpty);
        expect(LedgerView(profile).units(), hasLength(1));
        await a.call(Method.agentClose);
        await a.call(Method.agentClose);
        expect(
          a.of(Method.agentExited),
          isEmpty,
          reason: 'acknowledged dismissal must still await real cleanup',
        );
      } finally {
        await d.setFault(TestFault.terminateHangs, enabled: false);
      }
      final exit = await a.wait(Method.agentExited);
      expect(exit['reason'], 'closed');
      expect(a.of(Method.agentExited), hasLength(1));
      expect(a.of(Method.agentCloseFailed), isEmpty);
      await expectAllGone(tree);
      expect(LedgerView(profile).units(), isEmpty);
      await a.call(Method.agentRelease);
      expect(agentRows(profile).single['id'], a.id);
    },
  );

  test(
    'explicit close abandons credit-blocked transcript enqueue after failure',
    () async {
      final prefill = 'p' * (768 * 1024);
      final begin = File(joinPath(work.path, 'begin-prefill'));
      final eof = File(joinPath(work.path, 'fail-after-enqueue-blocks'));
      final (d, a, report) = await open(
        attach: false,
        script: {
          'afterNew': [
            {'waitFile': begin.path},
            {'update': textUpdate(prefill)},
            {'waitFile': eof.path},
            {'closeStdout': true},
          ],
          'holdPrompt': true,
        },
      );
      final tree = await waitReports(work, 1);
      await a.attach(credit: false);
      begin.writeAsStringSync('prefill');
      final prefillBytes = encodeAgentEvent(
        AgentEvent.text(AgentEventKind.agentText, prefill),
      ).fold<int>(0, (sum, line) => sum + line.length);
      await eventually(() async {
        final stats =
            await d.connection.request('test/agent.stats', {}) as Json;
        final session = (stats['sessions'] as Json)[a.id] as Json;
        return session['queuedBytes'] == prefillBytes - channelWindow &&
            session['channelQueuedBytes'] == channelWindow &&
            session['paused'] == false;
      }, reason: 'accepted prefill never reached the relay without credit');
      // The escaped prompt fits control's 1 MiB bound but fills the relay
      // behind the accepted prefill. It is local FIFO work, not an ACP update:
      // the ACP reader can independently observe EOF while enqueue is blocked.
      await a.prompt('\u0001' * (160 * 1024));
      await waitFixture(report, (p) => p.containsKey('prompt'));
      await eventually(() async {
        final stats =
            await d.connection.request('test/agent.stats', {}) as Json;
        return ((stats['sessions'] as Json)[a.id] as Json)['paused'] == true;
      }, reason: 'canonical user enqueue never blocked on withheld credit');
      eof.writeAsStringSync('fail');
      await a.wait(Method.agentState, where: (p) => p['state'] == 'failed');
      await eventually(
        () => LedgerView(profile).units().isEmpty,
        reason: 'native cleanup did not finish independently of transcript',
      );
      expect(a.of(Method.agentExited), isEmpty);
      expect(a.events, isEmpty);
      await a.call(Method.agentClose);
      final exit = await a.wait(
        Method.agentExited,
        within: const Duration(seconds: 3),
      );
      expect(exit['reason'], 'closed');
      expect(a.of(Method.agentExited), hasLength(1));
      expect(a.of(Method.agentCloseFailed), isEmpty);
      expect(
        a.events,
        isEmpty,
        reason: 'dismissal must not require data credit',
      );
      await expectAllGone(tree);
      expect(LedgerView(profile).units(), isEmpty);
      await a.call(Method.agentRelease);
      expect(agentRows(profile).single['id'], a.id);
      expect(d.connection.isClosed, isFalse);
    },
  );

  test('initial attach during held failure settlement preserves final output and native diagnostic', () async {
    final (d, a, _) = await open(
      attach: false,
      script: {
        'prompt': [
          {'update': textUpdate('accepted before failure')},
          {'oversizedBytes': 1},
        ],
      },
    );
    await d.setFault(TestFault.terminateHangs);
    try {
      await a.prompt('before first attach');
      await a.wait(Method.agentState, where: (p) => p['state'] == 'failed');
      await eventually(() async {
        final stats =
            await d.connection.request('test/agent.stats', {}) as Json;
        return ((stats['sessions'] as Json)[a.id] as Json)['ending'] == true;
      }, reason: 'failure never reached the held containment settlement');
      expect(a.of(Method.agentExited), isEmpty);
      expect(LedgerView(profile).units(), hasLength(1));
      await a.attach();
      await eventually(() => a.events.length == 2);
      expect(a.events.last['text'], 'accepted before failure');
      expect(a.of(Method.agentExited), isEmpty);
    } finally {
      await d.setFault(TestFault.terminateHangs, enabled: false);
    }
    final exit = await a.wait(
      Method.agentExited,
      where: (p) => p['reason'] == 'failed',
    );
    expect(exit['error'], ErrorCode.adapterProtocol);
    expect(exit['message'], contains('FormatException'));
    expect(exit['eventCount'], 2);
    expect(a.events.first['text'], 'before first attach');
    expect(LedgerView(profile).units(), isEmpty);
    await a.call(Method.agentRelease);
    expect(agentRows(profile).single['id'], a.id);
  });

  test(
    'explicit close still refuses initial attach during held settlement',
    () async {
      final (d, a, _) = await open(attach: false);
      await d.setFault(TestFault.terminateHangs);
      try {
        await a.call(Method.agentClose);
        await eventually(() async {
          final stats =
              await d.connection.request('test/agent.stats', {}) as Json;
          return ((stats['sessions'] as Json)[a.id] as Json)['ending'] == true;
        });
        await expectLater(
          a.call(Method.agentAttach),
          rpcCode(ErrorCode.unknownSession),
        );
      } finally {
        await d.setFault(TestFault.terminateHangs, enabled: false);
      }
      await a.wait(Method.agentExited, where: (p) => p['reason'] == 'closed');
      await a.call(Method.agentRelease);
    },
  );

  for (final pending in [false, true]) {
    test(
      'stdout EOF settles a still-live adapter ${pending ? 'during prompt' : 'while idle'}',
      () async {
        final release = File(joinPath(work.path, 'close-stdout'));
        final actions = [
          if (!pending) {'waitFile': release.path},
          if (pending) {'update': textUpdate('accepted before EOF')},
          {'closeStdout': true},
        ];
        final (d, a, _) = await open(
          script: {if (pending) 'prompt': actions else 'afterNew': actions},
        );
        final tree = await waitReports(work, 1);
        if (pending) {
          await a.prompt('pending at EOF');
        } else {
          release.writeAsStringSync('close');
        }
        await a.wait(Method.agentState, where: (p) => p['state'] == 'failed');
        final exited = await a.wait(
          Method.agentExited,
          where: (p) => p['reason'] == 'failed',
        );
        expect(exited['error'], 'adapter-exited');
        expect(exited['eventCount'], pending ? 2 : 0);
        if (pending) {
          await eventually(() => a.events.length == 2);
          expect(a.events.last['text'], 'accepted before EOF');
          expect(a.of(Method.agentTurnEnded), isEmpty);
        }
        await expectAllGone(tree);
        expect(LedgerView(profile).units(), isEmpty);
        await a.call(Method.agentRelease);
        expect(agentRows(profile).single['id'], a.id);
        expect(d.connection.isClosed, isFalse);
      },
    );
  }

  test('release before exit is refused and double close while closing acknowledges without a second exit', () async {
    final (_, a, report) = await open(script: {'holdPrompt': true});
    await expectLater(
      a.call(Method.agentRelease),
      rpcCode(ErrorCode.invalidParams),
    );
    await a.prompt();
    await waitFixture(report, (p) => p.containsKey('prompt'));
    await a.call(Method.agentClose);
    await a.call(Method.agentClose);
    await a.wait(Method.agentExited);
    expect(a.of(Method.agentExited), hasLength(1));
  });
  test(
    'desktop quit settles the owned unit while retaining the successful record',
    () async {
      final (d, a, _) = await open();
      final tree = await waitReports(work, 1);
      await d.session.quit();
      await expectAllGone(tree);
      expect(LedgerView(profile).units(), isEmpty);
      expect(agentRows(profile).single['id'], a.id);
    },
  );
  test('killing the stand-in desktop during a turn leaves no adapter child or grandchild process', () async {
    final script = File(joinPath(work.path, 'standin-script.json'))
      ..writeAsStringSync(
        jsonEncode({
          'prompt': [
            {'spawnTree': true},
          ],
          'holdPrompt': true,
        }),
      );
    final standin = await Process.start(desktopStandinExecutable(), [
      testHostExecutable(),
      profile.path,
      work.path,
      '--agent',
      script.path,
    ]);
    addTearDown(() async {
      standin.kill();
      await standin.exitCode;
    });
    final errors = StringBuffer();
    standin.stderr.transform(utf8.decoder).listen(errors.write);
    final ready = await standin.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((line) => line.startsWith('READY '))
        .timeout(const Duration(seconds: 90));
    final host = int.parse(ready.split(' ')[1]);
    final started = processStartTime(host)!;
    final tree = await waitReports(work, 4);
    expect(tree.every((p) => p.alive), isTrue, reason: '$errors');
    standin.kill(ProcessSignal.sigkill);
    await standin.exitCode;
    await eventually(
      () => !isProcessAlive(host, started),
      within: const Duration(seconds: 40),
    );
    await expectAllGone(tree);
  });
  test('killed host: next host settles the agent unit or gates unresolved cleanup and refuses start', () async {
    final (d, a, report) = await open(
      script: {
        'prompt': [
          {'spawnTree': true},
        ],
        'holdPrompt': true,
      },
    );
    await a.prompt();
    await waitFixture(report, (p) => p['spawnedTree'] == true);
    final tree = await waitReports(work, 4);
    final workspace = agentRows(profile).single['workspace_id'] as String;
    Process.killPid(d.session.pid, ProcessSignal.sigkill);
    await d.session.lost;
    await d.restart();
    await d.waitState();
    final units = LedgerView(profile).units();
    if (units.isEmpty) {
      await expectAllGone(tree);
      final b = AgentPeer(d);
      await b.start(workspace);
      await b.close();
    } else {
      expect(
        units.every((u) => u['kind'] == 'agent' && u['state'] == 'unresolved'),
        isTrue,
      );
      await expectLater(
        AgentPeer(d).start(workspace),
        rpcCode(ErrorCode.cleanupUnresolved),
      );
    }
    expect(agentRows(profile).first['id'], a.id);
  });
}
