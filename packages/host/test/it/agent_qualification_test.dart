import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/agent_support.dart';
import 'support/harness.dart';
import 'support/terminal_support.dart';
import 'support/tool_support.dart';

const _mib = 1024 * 1024;
const _ackBound = Duration(milliseconds: 250);

/// Native process/credit qualification only. State-machine combinations,
/// escaping arithmetic and permit cancellation are covered by the pure tests.
/// All adapters run as ordinary profiles through the actual AgentService.
void main() {
  setUpAll(buildTestHost);
  late Directory profile;
  late Directory work;
  setUp(() {
    profile = tempDir('agent_qualification_profile_');
    work = tempDir('agent_qualification_work_');
  });
  tearDown(() async {
    killReported(work);
    await deleteTree(work);
    await deleteTree(profile);
  });

  Future<(Desktop, String)> desktop() async {
    final d = await Desktop.start(
      profile,
      capabilities: {...testCapabilities, Capability.agent},
      environment: {
        'KUMIKO_TEST_RUNTIME_PATH': '',
        'KUMIKO_TEST_SHELL_PATH': '',
      },
    );
    addTearDown(d.dispose);
    await d.waitState();
    final workspace = await d.openWorkspace(work.path);
    return (d, workspace.workspace.id);
  }

  Future<(_Consumer, File)> agent(
    Desktop d,
    String workspace, {
    required String runtime,
    required Json script,
    bool credit = true,
    void Function(AgentEvent)? onEvent,
  }) async {
    final report = await saveAgentFixture(d, work, id: runtime, script: script);
    final peer = AgentPeer(d);
    await peer.start(workspace, runtime: runtime);
    final consumer = _Consumer(peer, onEvent: onEvent);
    await consumer.attach(credit: credit);
    return (consumer, report);
  }

  test('saturating terminal A, stalled session B: Stop and permissionReply '
      'in C ack worst of 100 each <= 250 ms and C events keep flowing', () async {
    final (d, workspace) = await desktop();
    await d.saveFixtureProfile(cwd: work.path);
    var ready = false;
    var terminalBytes = 0;
    var floodFinished = false;
    var terminalTail = '';
    final terminal = await d.openTerminal(
      'fixture',
      onData: (bytes) {
        terminalTail += latin1.decode(bytes);
        if (!ready) {
          ready = terminalTail.contains('READY;');
        } else {
          terminalBytes += bytes.length;
        }
        floodFinished |= terminalTail.contains('FLOODED:');
        // Count output, retaining only enough to recognize split sentinels.
        if (terminalTail.length > 128) {
          terminalTail = terminalTail.substring(terminalTail.length - 128);
        }
      },
    );
    await eventually(() => ready, reason: 'terminal A did not initialize');
    final (b, bReport) = await agent(
      d,
      workspace,
      runtime: 'stalled',
      credit: false,
      script: {
        'blockedWriteAfterMs': 100,
        'prompt': [
          {
            'flood': {'count': 4096, 'update': textUpdate('b' * 16384)},
          },
        ],
      },
    );
    await b.peer.prompt();
    await waitFixture(bReport, (p) => p['blockedWrite'] == true);
    _expectQueueBound(await _paused(b.peer));
    expect(b.receivedBytes, 0);

    var cChunks = 0;
    final (c, cReport) = await agent(
      d,
      workspace,
      runtime: 'active',
      onEvent: (event) {
        if (event.kind == AgentEventKind.agentText) {
          expect(event.text, 'C event before Stop');
          cChunks++;
        }
      },
      script: {
        'prompt': [
          permissionAction,
          {'update': textUpdate('C event before Stop')},
          {'waitCancel': true},
        ],
      },
    );
    // Deliberately much more than this measurement can drain. Explicit byte
    // progress across EVERY sample and the absent end sentinel prove A stays
    // active; this is not a finite flood that ended before the latency loop.
    await terminal.send('flood ${1 << 40}');
    await eventually(
      () => terminalBytes >= 8 * _mib,
      within: const Duration(seconds: 60),
      reason: 'A did not saturate',
    );
    var worstStop = Duration.zero;
    var worstPermission = Duration.zero;
    final startBytes = terminalBytes;
    for (var i = 0; i < 100; i++) {
      final beforeBytes = terminalBytes;
      await c.peer.prompt('qualification turn $i');
      await eventually(
        () => c.peer.of(Method.agentPermissionRequested).length == i + 1,
      );
      final request = c.peer.of(Method.agentPermissionRequested).last;
      expect(
        request['options'],
        (permissionAction['permission'] as Json)['options'],
      );
      final permissionClock = Stopwatch()..start();
      await c.peer.call(Method.agentPermissionReply, {
        'sessionId': c.peer.id,
        'requestId': request['requestId'],
        'optionId': 'yes',
      });
      final permissionAck = permissionClock.elapsed;
      if (permissionAck > worstPermission) worstPermission = permissionAck;
      await eventually(
        () => cChunks == i + 1,
        reason: 'C actual event channel stopped flowing in turn $i',
      );
      await eventually(
        () =>
            fixtureReports(cReport)
                .where((p) => p.containsKey('permissionOutcome'))
                .length ==
            i + 1,
        reason: 'permission reply $i did not reach the actual fixture',
      );
      final stopClock = Stopwatch()..start();
      await c.peer.call(Method.agentStop);
      final stopAck = stopClock.elapsed;
      if (stopAck > worstStop) worstStop = stopAck;
      await eventually(() => c.peer.of(Method.agentStopResult).length == i + 1);
      expect(c.peer.of(Method.agentStopResult).last['outcome'], 'stopped');
      await eventually(
        () => c.peer.of(Method.agentState).last['state'] == 'idle',
      );
      await eventually(
        () => c.turns == i + 1,
        reason: 'C turn event $i did not traverse its data channel',
      );
      await eventually(
        () => terminalBytes > beforeBytes,
        reason: 'terminal A stopped flowing during sample $i',
      );
      expect(floodFinished, isFalse);
      expect(terminal.exited, isNull);
    }
    final answers = fixtureReports(cReport)
        .where((p) => p.containsKey('permissionOutcome'))
        .toList();
    expect(answers, hasLength(100));
    for (final answer in answers) {
      expect(answer['permissionOutcome'], {
        'outcome': 'selected',
        'optionId': 'yes',
      });
    }
    expect(cChunks, 100);
    expect(terminalBytes, greaterThan(startBytes));
    print(
      'measured: Stop worst of 100 ${worstStop.inMicroseconds / 1000} ms; '
      'permissionReply worst of 100 ${worstPermission.inMicroseconds / 1000} ms; '
      'terminal A ${terminalBytes - startBytes} bytes during samples; '
      'C $cChunks text events on ${Platform.operatingSystem}',
    );
    expect(worstStop, lessThanOrEqualTo(_ackBound));
    expect(worstPermission, lessThanOrEqualTo(_ackBound));
    await c.closeAndRelease();
    await b.closeAndRelease();
    await d.closeTerminal(terminal.id);
    await terminal.waitExited(within: const Duration(seconds: 35));
    await terminal.subscription.cancel();
    expect(LedgerView(profile).units(), isEmpty);
    await expectAllGone(readReports(work));
  }, timeout: const Timeout(Duration(minutes: 5)));

  String secretOf(File report) {
    final launch = fixtureReports(
      report,
    ).firstWhere((p) => p.containsKey('newCwd'));
    final entry = (launch['mcpServers'] as List).single as Json;
    return [
      for (final e in entry['env'] as List)
        if ((e as Json)['name'] == 'KUMIKO_TOOL_SECRET') e['value'] as String,
    ].single;
  }

  Map<String, Object?> sessionInfoCall(int id) => {
    'jsonrpc': '2.0',
    'id': id,
    'method': 'tools/call',
    'params': {
      'name': 'kumiko_session_info',
      'arguments': <String, Object?>{},
    },
  };

  test('tool call answered within the control-latency bound under '
      'saturation', () async {
    final (d, workspace) = await desktop();
    await d.saveFixtureProfile(cwd: work.path);
    var ready = false;
    var terminalBytes = 0;
    var terminalTail = '';
    final terminal = await d.openTerminal(
      'fixture',
      onData: (bytes) {
        terminalTail += latin1.decode(bytes);
        if (!ready) {
          ready = terminalTail.contains('READY;');
        } else {
          terminalBytes += bytes.length;
        }
        if (terminalTail.length > 128) {
          terminalTail = terminalTail.substring(terminalTail.length - 128);
        }
      },
    );
    await eventually(() => ready, reason: 'terminal A did not initialize');
    final (b, bReport) = await agent(
      d,
      workspace,
      runtime: 'stalled',
      credit: false,
      script: {
        'blockedWriteAfterMs': 100,
        'prompt': [
          {
            'flood': {'count': 4096, 'update': textUpdate('b' * 16384)},
          },
        ],
      },
    );
    await b.peer.prompt();
    await waitFixture(bReport, (p) => p['blockedWrite'] == true);
    _expectQueueBound(await _paused(b.peer));
    final (c, cReport) = await agent(
      d,
      workspace,
      runtime: 'tooled',
      script: {'reportLaunch': true},
    );
    await terminal.send('flood ${1 << 40}');
    await eventually(
      () => terminalBytes >= 8 * _mib,
      within: const Duration(seconds: 60),
      reason: 'A did not saturate',
    );
    final client = await ToolClient.connect(await endpointOf(d));
    addTearDown(client.close);
    client.authenticate(secretOf(cReport));
    expect(await client.readJson(), {'ok': true});
    var worst = Duration.zero;
    final startBytes = terminalBytes;
    for (var i = 0; i < 50; i++) {
      final before = terminalBytes;
      final clock = Stopwatch()..start();
      client.send(sessionInfoCall(i + 1));
      final answer = (await client.readJson())!;
      final elapsed = clock.elapsed;
      expect(answer['id'], i + 1);
      expect(
        ((answer['result'] as Json)['structuredContent'] as Json)['sessionId'],
        c.peer.id,
      );
      if (elapsed > worst) worst = elapsed;
      await eventually(
        () => terminalBytes > before,
        reason: 'terminal A stopped flowing during sample $i',
      );
    }
    expect(terminalBytes, greaterThan(startBytes));
    expect(b.receivedBytes, 0, reason: 'B still has no credit');
    print(
      'measured: tool call worst of 50 ${worst.inMicroseconds / 1000} ms '
      'on ${Platform.operatingSystem}',
    );
    expect(worst, lessThanOrEqualTo(_ackBound));
    await c.closeAndRelease();
    await b.closeAndRelease();
    await d.closeTerminal(terminal.id);
    await terminal.waitExited(within: const Duration(seconds: 35));
    await terminal.subscription.cancel();
    expect(LedgerView(profile).units(), isEmpty);
    await expectAllGone(readReports(work));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('Stop acknowledged within bound while a client holds max in-flight '
      'calls', () async {
    final (d, workspace) = await desktop();
    // Session P stays in session/new, so its grant is unbound: every call
    // from its bridge client waits on the binding future and stays in flight.
    final release = File(joinPath(work.path, 'release-pending'));
    final pendingReport = await saveAgentFixture(
      d,
      work,
      id: 'pending',
      script: {
        'reportLaunch': true,
        'new': [
          {'waitFile': release.path},
        ],
      },
    );
    final pendingPeer = AgentPeer(d);
    final starting = pendingPeer.start(workspace, runtime: 'pending');
    await waitFixture(pendingReport, (p) => p.containsKey('newCwd'));
    final client = await ToolClient.connect(await endpointOf(d));
    addTearDown(client.close);
    client.authenticate(secretOf(pendingReport));
    expect(await client.readJson(), {'ok': true});
    for (var id = 1; id <= 8; id++) {
      client.send(sessionInfoCall(id));
    }
    // Nothing answers while the slot is unbound.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(client.ended, isFalse);

    final (c, cReport) = await agent(
      d,
      workspace,
      runtime: 'active',
      script: {
        'prompt': [
          {'waitCancel': true},
        ],
      },
    );
    var worst = Duration.zero;
    for (var i = 0; i < 50; i++) {
      await c.peer.prompt('turn $i');
      await eventually(
        () => c.peer.of(Method.agentState).last['state'] == 'running',
      );
      final clock = Stopwatch()..start();
      await c.peer.call(Method.agentStop);
      final ack = clock.elapsed;
      if (ack > worst) worst = ack;
      await eventually(() => c.peer.of(Method.agentStopResult).length == i + 1);
      await eventually(
        () => c.peer.of(Method.agentState).last['state'] == 'idle',
      );
    }
    expect(fixtureReports(cReport), isNotNull);
    print(
      'measured: Stop worst of 50 with 8 calls in flight '
      '${worst.inMicroseconds / 1000} ms on ${Platform.operatingSystem}',
    );
    expect(worst, lessThanOrEqualTo(_ackBound));

    // The eight calls were really pending: they are answered only now.
    release.writeAsStringSync('go');
    await starting;
    final ids = <Object?>{};
    for (var i = 0; i < 8; i++) {
      final answer = (await client.readJson())!;
      expect(answer['result'], isNotNull);
      ids.add(answer['id']);
    }
    expect(ids, {1, 2, 3, 4, 5, 6, 7, 8});
    await pendingPeer.attach();
    await pendingPeer.close();
    await c.closeAndRelease();
    expect(LedgerView(profile).units(), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('with no credit the host stops reading at the queue bound (fixture '
      'reports blocked writes); on resume every event arrives in order', () async {
    final (d, workspace) = await desktop();
    const count = 1024;
    final padding = 'x' * 16384;
    var next = 0;
    final (a, report) = await agent(
      d,
      workspace,
      runtime: 'ordered',
      onEvent: (event) {
        if (event.kind != AgentEventKind.agentText) return;
        expect(next, lessThan(count), reason: 'duplicate/extra event');
        expect(
          event.text,
          'row-$next:$padding',
          reason: 'event $next was missing, changed or reordered',
        );
        expect(event.truncated, isFalse);
        next++;
      },
      script: {
        'blockedWriteAfterMs': 100,
        'prompt': [
          {
            'flood': {
              'count': count,
              'indexPrefix': 'row-',
              'update': textUpdate(padding),
            },
          },
        ],
      },
    );
    // Pause the REAL inbound subscription before the first prompt. Its one
    // granted window fills, but the consumer returns no replenishing credit.
    a.pause();
    await a.peer.prompt();
    await waitFixture(report, (p) => p['blockedWrite'] == true);
    final full = await _paused(a.peer);
    _expectQueueBound(full);
    expect(full['channelSentBytes'], channelWindow);
    expect(a.receivedBytes, 0);
    expect(next, 0);
    expect(a.peer.of(Method.agentTurnEnded), isEmpty);
    final written =
        fixtureReports(report)
                .where((p) => p.containsKey('writtenUpdates'))
                .last['writtenUpdates']
            as int;
    expect(
      written,
      lessThan(count),
      reason: 'the native producer must actually block',
    );

    Timer? pacer;
    addTearDown(() => pacer?.cancel());
    var sincePause = 0;
    a.onBytes = (bytes) {
      sincePause += bytes;
      if (sincePause < 128 * 1024) return;
      sincePause = 0;
      a.pause();
      // Intentional slow-consumer pacing, not a correctness synchronization.
      pacer = Timer(const Duration(milliseconds: 20), a.resume);
    };
    a.resume();
    await eventually(
      () => a.turns == 1,
      within: const Duration(minutes: 2),
      reason: 'ordered flood did not drain',
    );
    await a.peer.wait(Method.agentTurnEnded);
    expect(
      next,
      count,
      reason: 'every distinguishable event arrives exactly once',
    );
    expect(
      (await waitFixture(
        report,
        (p) => p['writtenUpdates'] == count,
      ))['writtenUpdates'],
      count,
    );
    expect(a.peer.of(Method.agentExited), isEmpty);
    pacer?.cancel();
    a.onBytes = null;
    a.resume();
    print(
      'measured: ordered slow consumer received $next events; '
      'native producer blocked after $written updates; '
      'relay ${full['queuedBytes']} bytes and channel '
      '${full['channelQueuedBytes']} queued bytes on ${Platform.operatingSystem}',
    );
    await a.closeAndRelease();
    expect(LedgerView(profile).units(), isEmpty);
    await expectAllGone(readReports(work));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('channel without credit but queue below the bound: permissionRequested '
      'arrives and the reply reaches the fixture', () async {
    final (d, workspace) = await desktop();
    final (a, report) = await agent(
      d,
      workspace,
      runtime: 'below-bound',
      credit: false,
      script: {
        'prompt': [
          {'update': textUpdate('unread event')},
          permissionAction,
        ],
      },
    );
    await a.peer.prompt();
    final request = await a.peer.wait(Method.agentPermissionRequested);
    expect(
      a.receivedBytes,
      0,
      reason: 'this channel never received initial credit',
    );
    final stats = await _stats(a.peer);
    expect(stats['paused'], isFalse);
    expect(stats['queuedBytes'] as int, lessThan(_mib));
    expect(stats['channelSentBytes'], 0);
    expect(
      request['options'],
      (permissionAction['permission'] as Json)['options'],
    );
    await a.peer.call(Method.agentPermissionReply, {
      'sessionId': a.peer.id,
      'requestId': request['requestId'],
      'optionId': 'no',
    });
    expect(
      (await waitFixture(
        report,
        (p) => p.containsKey('permissionOutcome'),
      ))['permissionOutcome'],
      {'outcome': 'selected', 'optionId': 'no'},
    );
    await a.peer.wait(Method.agentTurnEnded);
    a.grant();
    await eventually(() => a.turns == 1);
    await a.closeAndRelease();
    expect(LedgerView(profile).units(), isEmpty);
  });

  test('queue at its bound: permission appears only after credit and works; '
      'refilled queue Stop is notConfirmed after 10 s, close ack <= 250 ms', () async {
    final (d, workspace) = await desktop();
    var secondText = 0;
    final (a, report) = await agent(
      d,
      workspace,
      runtime: 'queued-permission',
      credit: false,
      onEvent: (event) {
        if (event.kind != AgentEventKind.agentText) return;
        final text = event.text!;
        expect(event.truncated, isFalse);
        if (text.codeUnitAt(0) == 1) {
          expect(
            secondText,
            0,
            reason: 'first line was reordered after second',
          );
          expect(text.runes.every((r) => r == 1), isTrue);
        } else {
          expect(text.runes.every((r) => r == 2), isTrue);
          secondText += text.length;
        }
      },
      script: {
        'blockedWriteAfterMs': 100,
        'prompt': [
          // One MiB of source encodes to about SIX MiB, so the normalizer
          // must admit lazily. A raw/source-size queue estimate is unsound.
          {'update': textUpdate('\u0001' * _mib)},
          permissionAction,
          {'update': textUpdate('\u0002' * _mib)},
          {'waitCancel': true},
        ],
      },
    );
    final adapter = LedgerView(profile).units().single;
    final adapterPid = adapter['pid'] as int;
    final adapterStart = processStartTime(adapterPid)!;
    final record = agentRows(profile).single;
    await a.peer.prompt();
    _expectQueueBound(await _paused(a.peer));
    // Unlike merely reaching the script action, the fixture's completed
    // permission-envelope write proves the request is in the native path.
    final permissionBytes = utf8
        .encode(
          '${jsonEncode({
            'jsonrpc': '2.0',
            'id': 'fixture-permission-1',
            'method': 'session/request_permission',
            'params': {'sessionId': 'fixture-native', ...(permissionAction['permission'] as Json)},
          })}\n',
        )
        .length;
    await waitFixture(
      report,
      (p) => p['writeCompleted'] == true && p['bytes'] == permissionBytes,
    );
    expect(a.peer.of(Method.agentPermissionRequested), isEmpty);
    expect(a.receivedBytes, 0);
    a.grant();
    final request = await a.peer.wait(Method.agentPermissionRequested);
    expect(
      request['options'],
      (permissionAction['permission'] as Json)['options'],
    );
    // Stop returning real credit before allowing the second flood to begin.
    a.pause();
    await a.peer.call(Method.agentPermissionReply, {
      'sessionId': a.peer.id,
      'requestId': request['requestId'],
      'optionId': 'yes',
    });
    expect(
      (await waitFixture(
        report,
        (p) => p.containsKey('permissionOutcome'),
      ))['permissionOutcome'],
      {'outcome': 'selected', 'optionId': 'yes'},
    );
    _expectQueueBound(await _paused(a.peer));
    expect(a.peer.of(Method.agentPermissionRequested), hasLength(1));
    final stopClock = Stopwatch()..start();
    await a.peer.call(Method.agentStop);
    final stop = await a.peer.wait(
      Method.agentStopResult,
      within: const Duration(seconds: 15),
    );
    final stopElapsed = stopClock.elapsed;
    expect(stop['outcome'], 'notConfirmed');
    expect(stopElapsed, greaterThanOrEqualTo(const Duration(seconds: 10)));
    expect(a.peer.of(Method.agentState).last['state'], 'stopping');
    expect(a.peer.of(Method.agentExited), isEmpty);
    expect(isProcessAlive(adapterPid, adapterStart), isTrue);
    expect(LedgerView(profile).units(), hasLength(1));
    await waitFixture(report, (p) => p['cancelReceived'] == true);
    // D8: Stop cancels pending approval; do NOT demand a new approval card
    // after cancellation. The real request was answered before this phase.
    expect(a.peer.of(Method.agentPermissionRequested), hasLength(1));
    final closeClock = Stopwatch()..start();
    await a.peer.call(Method.agentClose);
    final closeAck = closeClock.elapsed;
    expect(closeAck, lessThanOrEqualTo(_ackBound));
    await a.peer.wait(
      Method.agentExited,
      where: (p) => p['reason'] == 'closed',
      within: const Duration(seconds: 32),
    );
    final closeElapsed = closeClock.elapsed;
    await eventually(() => !isProcessAlive(adapterPid, adapterStart));
    expect(LedgerView(profile).units(), isEmpty);
    expect(agentRows(profile).single, record);
    print(
      'measured: full-queue Stop notConfirmed after '
      '${stopElapsed.inMicroseconds / 1000} ms; close ack '
      '${closeAck.inMicroseconds / 1000} ms and settlement '
      '${closeElapsed.inMicroseconds / 1000} ms on ${Platform.operatingSystem}',
    );
    await a.releaseAfterExit();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a 17 MiB fixture line fails the session adapter-protocol, terminates '
      'the unit and keeps the record', () async {
    final (d, workspace) = await desktop();
    final (a, report) = await agent(
      d,
      workspace,
      runtime: 'oversized',
      script: {
        'new': [
          {'spawnTree': true},
        ],
        'prompt': [
          {'oversizedBytes': 17 * _mib},
        ],
      },
    );
    final record = agentRows(profile).single;
    final adapter = LedgerView(profile).units().single;
    final adapterPid = adapter['pid'] as int;
    final adapterStart = processStartTime(adapterPid)!;
    await waitFixture(report, (p) => p['spawnedTree'] == true);
    final tree = await waitReports(work, 4);
    await a.peer.prompt();
    final exit = await a.peer.wait(
      Method.agentExited,
      within: const Duration(seconds: 40),
    );
    expect(exit['reason'], 'failed');
    expect(exit['error'], ErrorCode.adapterProtocol);
    expect(exit['message'], contains('message too large'));
    expect(agentRows(profile).single, record);
    await eventually(() => LedgerView(profile).units().isEmpty);
    await eventually(
      () => !isProcessAlive(adapterPid, adapterStart),
      reason: 'oversized-line failure left the adapter alive',
    );
    await expectAllGone(tree);
    await a.releaseAfterExit();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('two concurrent 8 MiB lines share one permit, release it before '
      'desktop delivery and keep measured host RSS <= 350 MiB', () async {
    final (d, workspace) = await desktop();
    final releaseA = File(joinPath(work.path, 'release-large-a'));
    final releaseB = File(joinPath(work.path, 'release-large-b'));
    final updateA = _eightMiBUpdate(1);
    final updateB = _eightMiBUpdate(2);
    var textA = 0;
    var textB = 0;
    void check(AgentEvent event, int code, void Function(int) count) {
      if (event.kind != AgentEventKind.agentText) return;
      expect(event.text!.runes.every((r) => r == code), isTrue);
      expect(event.truncated, isFalse);
      count(event.text!.length);
    }

    final (a, reportA) = await agent(
      d,
      workspace,
      runtime: 'large-a',
      credit: false,
      onEvent: (event) => check(event, 1, (n) => textA += n),
      script: {
        'prompt': [
          {
            'gatedUpdate': {
              'update': updateA,
              'prefixBytes': 2 * _mib,
              'releaseFile': releaseA.path,
            },
          },
        ],
      },
    );
    final (b, reportB) = await agent(
      d,
      workspace,
      runtime: 'large-b',
      credit: false,
      onEvent: (event) => check(event, 2, (n) => textB += n),
      script: {
        'prompt': [
          {
            'gatedUpdate': {
              'update': updateB,
              'prefixBytes': 2 * _mib,
              'releaseFile': releaseB.path,
            },
          },
        ],
      },
    );
    final baseline = await hostRssKiBAsync(d.session.pid);
    var peak = baseline;
    Future<void>? rssQuery;
    late final Timer sampler;
    Future<void> sample() {
      final active = rssQuery;
      if (active != null) {
        return active;
      }
      final query = hostRssKiBAsync(d.session.pid).then<void>((rss) {
        if (rss > peak) {
          peak = rss;
        }
      });
      rssQuery = query;
      unawaited(
        query.then<void>(
          (_) {
            rssQuery = null;
          },
          onError: (Object error, StackTrace stack) {
            // Retain the failed query for the awaited stop/teardown to report.
            sampler.cancel();
          },
        ),
      );
      return query;
    }

    Future<void> stopSampling() async {
      sampler.cancel();
      await rssQuery;
    }

    // Intentional OS RSS measurement sampling, not ordering synchronization.
    // Coalesce ticks while an OS query is active; never block real credit.
    sampler = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => unawaited(sample()),
    );
    addTearDown(stopSampling);
    // Neither prompt waits for its large line to finish before the other
    // starts. The snapshot below, not elapsed time, proves real contention.
    await Future.wait([a.peer.prompt(), b.peer.prompt()]);
    Json simultaneous = {};
    await eventually(
      () async {
        simultaneous = await _allStats(d);
        final sa = simultaneous[a.peer.id] as Json;
        final sb = simultaneous[b.peer.id] as Json;
        return (sa['largeLineOwned'] == true &&
                sb['largeLineWaiting'] == true) ||
            (sb['largeLineOwned'] == true && sa['largeLineWaiting'] == true);
      },
      reason:
          'no native owner/waiter overlap on the host-wide large-line permit',
    );
    final aFirst = (simultaneous[a.peer.id] as Json)['largeLineOwned'] == true;
    final first = aFirst ? a : b;
    final second = aFirst ? b : a;
    final firstReport = aFirst ? reportA : reportB;
    final secondReport = aFirst ? reportB : reportA;
    final firstRelease = aFirst ? releaseA : releaseB;
    final secondRelease = aFirst ? releaseB : releaseA;
    expect(
      simultaneous.values.where((p) => (p as Json)['largeLineOwned'] == true),
      hasLength(1),
    );
    await waitFixture(firstReport, (p) => p['prefixWritten'] == true);
    await sample();
    firstRelease.writeAsStringSync('release');
    await eventually(
      () async => (await _stats(second.peer))['largeLineOwned'] == true,
      reason: 'waiting native session did not acquire the released permit',
    );
    await waitFixture(secondReport, (p) => p['prefixWritten'] == true);
    final firstBlocked = await _paused(first.peer);
    _expectQueueBound(firstBlocked);
    expect(firstBlocked['largeLineOwned'], isFalse);
    expect(firstBlocked['channelSentBytes'], 0);
    expect(
      first.receivedBytes,
      0,
      reason: 'the first desktop must still be stalled when the second owns the permit',
    );
    // The first session is paused INSIDE lazy normalized admission, not just
    // waiting for its next turn. Its 1 MiB control text expands to ~6 MiB.
    secondRelease.writeAsStringSync('release');
    final secondBlocked = await _paused(second.peer);
    _expectQueueBound(secondBlocked);
    expect(secondBlocked['largeLineOwned'], isFalse);
    expect(secondBlocked['largeLineWaiting'], isFalse);
    expect(second.receivedBytes, 0);
    await sample();
    a.grant();
    b.grant();
    try {
      await eventually(
        () => a.turns == 1 && b.turns == 1,
        within: const Duration(minutes: 2),
        reason: 'both native large lines must complete',
      );
    } on Object {
      await stopSampling();
      print(
        'diagnostic: native large-line drain ${jsonEncode({
          'a': {'textBytes': textA, 'receivedBytes': a.receivedBytes, 'turns': a.turns, 'state': a.peer.of(Method.agentState), 'turnEnded': a.peer.of(Method.agentTurnEnded), 'exited': a.peer.of(Method.agentExited), 'fixture': fixtureReports(reportA)},
          'b': {'textBytes': textB, 'receivedBytes': b.receivedBytes, 'turns': b.turns, 'state': b.peer.of(Method.agentState), 'turnEnded': b.peer.of(Method.agentTurnEnded), 'exited': b.peer.of(Method.agentExited), 'fixture': fixtureReports(reportB)},
          'rssBaselineKiB': baseline,
          'rssObservedPeakKiB': peak,
        })}',
      );
      try {
        print(
          'diagnostic: native large-line snapshot '
          '${jsonEncode(await _allStats(d))}',
        );
        print(
          'diagnostic: after sampler cancellation ${jsonEncode({
            'a': {'textBytes': textA, 'receivedBytes': a.receivedBytes, 'turns': a.turns},
            'b': {'textBytes': textB, 'receivedBytes': b.receivedBytes, 'turns': b.turns},
          })}',
        );
      } on Object catch (error) {
        print('diagnostic: native large-line snapshot unavailable: $error');
      }
      rethrow;
    }
    await a.peer.wait(Method.agentTurnEnded);
    await b.peer.wait(Method.agentTurnEnded);
    expect(textA, _mib);
    expect(textB, _mib);
    expect(a.peer.of(Method.agentExited), isEmpty);
    expect(b.peer.of(Method.agentExited), isEmpty);
    await sample();
    await stopSampling();
    final growth = peak - baseline;
    print(
      'measured: two concurrent native lines ${_updateLineBytes(updateA)} and '
      '${_updateLineBytes(updateB)} bytes; host RSS baseline '
      '${(baseline / 1024).toStringAsFixed(1)} MiB, observed peak '
      '${(peak / 1024).toStringAsFixed(1)} MiB, growth '
      '${(growth / 1024).toStringAsFixed(1)} MiB on ${Platform.operatingSystem}',
    );
    expect(
      peak,
      lessThanOrEqualTo(350 * 1024),
      reason: 'observed host RSS exceeds the stated host worst-case envelope',
    );
    await a.closeAndRelease();
    await b.closeAndRelease();
    expect(LedgerView(profile).units(), isEmpty);
    await expectAllGone(readReports(work));
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<Json> _allStats(Desktop desktop) async {
  final response = await desktop.connection.request('test/agent.stats', {});
  return (response as Json)['sessions'] as Json;
}

Future<Json> _stats(AgentPeer peer) async =>
    (await _allStats(peer.desktop))[peer.id] as Json;

Future<Json> _paused(AgentPeer peer) async {
  Json stats = {};
  await eventually(() async {
    stats = await _stats(peer);
    return stats['paused'] == true;
  }, reason: 'actual agent relay never reached its credit backpressure bound');
  return stats;
}

void _expectQueueBound(Json stats) {
  expect(stats['paused'], isTrue);
  expect(stats['queuedBytes'] as int, greaterThanOrEqualTo(_mib));
  expect(
    stats['queuedBytes'] as int,
    lessThanOrEqualTo(2 * _mib),
    reason: 'at most 1 MiB queue plus 1 MiB normalized-line overshoot',
  );
  expect(
    stats['channelQueuedBytes'] as int,
    lessThanOrEqualTo(channelWindow),
    reason: 'the channel has a separate 256 KiB window, not an unbounded queue',
  );
}

int _updateLineBytes(Json update) => utf8
    .encode(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': {'sessionId': 'fixture-native', 'update': update},
      }),
    )
    .length;

/// Exactly 8 MiB of encoded ACP JSON, excluding LF. The ignored field pads the
/// real envelope without increasing normalized source text above its 1 MiB
/// cap; escaping expands that legitimate source into ~6 MiB of event output.
Json _eightMiBUpdate(int code) {
  final update = <String, Object?>{
    ...textUpdate(String.fromCharCode(code) * _mib),
    'fixturePadding': '',
  };
  final padding = 8 * _mib - _updateLineBytes(update);
  expect(padding, greaterThan(0));
  update['fixturePadding'] = 'x' * padding;
  expect(_updateLineBytes(update), 8 * _mib);
  return update;
}

/// Uses the actual inbound channel and its credit accounting. Pausing the RAW
/// subscription (not a spare broadcast or transformed stream) stops credit.
/// Events are validated/count-checked in callbacks and are never accumulated.
class _Consumer {
  _Consumer(this.peer, {this.onEvent});
  final AgentPeer peer;
  final void Function(AgentEvent)? onEvent;
  void Function(int bytes)? onBytes;
  final _decoder = AgentEventDecoder();
  StreamSubscription<Uint8List>? _subscription;
  bool _granted = false;
  int receivedBytes = 0;
  int turns = 0;

  Future<void> attach({required bool credit}) async {
    _subscription = peer.desktop.connection
        .attachInbound(peer.started.eventChannel, grantInitial: false)
        .listen((bytes) {
          receivedBytes += bytes.length;
          for (final event in _decoder.add(bytes)) {
            if (event.kind == AgentEventKind.turn) turns++;
            onEvent?.call(event);
          }
          onBytes?.call(bytes.length);
        });
    addTearDown(() async {
      await _subscription?.cancel();
    });
    await peer.call(Method.agentAttach);
    if (credit) grant();
  }

  void grant() {
    if (_granted) throw StateError('initial credit already granted');
    _granted = true;
    peer.desktop.connection.grantInitial(peer.started.eventChannel);
  }

  void pause() => _subscription!.pause();
  void resume() => _subscription!.resume();
  Future<void> closeAndRelease() async {
    await peer.call(Method.agentClose);
    await peer.wait(
      Method.agentExited,
      where: (p) => p['reason'] == 'closed',
      within: const Duration(seconds: 35),
    );
    await releaseAfterExit();
  }

  Future<void> releaseAfterExit() async {
    await peer.call(Method.agentRelease);
    await _subscription?.cancel();
    _subscription = null;
  }
}
