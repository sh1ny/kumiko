import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/agent_support.dart';
import 'support/harness.dart';
import 'support/terminal_support.dart' show rpcFailure;

const candidateEnvironment = {
  'KUMIKO_TEST_QUALIFIED_ADAPTERS':
      '[["scripted-acp","test-only",["load","resume"]]]',
};
const advertisedHistory = <String, Object?>{
  'loadSession': true,
  'sessionCapabilities': {'resume': <String, Object?>{}},
};

Future<AgentContinueResult> continuePeer(AgentPeer peer, String id) async {
  final result = AgentContinueResult.fromJson(
    await peer.call(Method.agentContinue, {'sessionId': id}),
  );
  peer.started = AgentStartResult(
    sessionId: id,
    eventChannel: result.eventChannel,
    adapter: result.adapter,
    capabilities: result.capabilities,
  );
  return result;
}

void main() {
  setUpAll(buildTestHost);
  late Directory profile;
  late Directory work;
  setUp(() {
    profile = tempDir('continue_profile_');
    work = tempDir('continue_work_');
  });
  tearDown(() async {
    killReported(work);
    await deleteTree(work);
    await deleteTree(profile);
  });
  Future<Desktop> desktop({
    bool qualified = true,
    Map<String, String> env = const {},
  }) async {
    final d = await Desktop.start(
      profile,
      capabilities: {...testCapabilities, Capability.agent},
      environment: {
        'KUMIKO_TEST_RUNTIME_PATH': '',
        'KUMIKO_TEST_SHELL_PATH': '',
        if (qualified) ...candidateEnvironment,
        ...env,
      },
    );
    addTearDown(d.dispose);
    await d.waitState();
    return d;
  }

  Future<(AgentPeer, File, Json)> saved(
    Desktop d, {
    Json script = const {},
  }) async {
    final w = await d.openWorkspace(work.path);
    final report = await saveAgentFixture(
      d,
      work,
      script: {'agentCapabilities': advertisedHistory, ...script},
    );
    final a = AgentPeer(d);
    await a.start(w.workspace.id);
    await a.attach();
    final row = agentRows(profile).single;
    await a.close();
    await a.call(Method.agentRelease);
    report.writeAsStringSync('');
    return (a, report, row);
  }

  Future<void> refuse(AgentPeer a, String id, String reason) async {
    final before = agentRows(profile);
    final e = await rpcFailure(a.call(Method.agentContinue, {'sessionId': id}));
    expect(e.reason, ErrorCode.resumeUnavailable);
    expect(e.data['resumeReason'], reason);
    expect(agentRows(profile), before);
  }

  Future<AgentRecordsResult> records(Desktop d, List<String> ids) async =>
      AgentRecordsResult.fromJson(
        await d.connection.request(Method.agentRecords, AgentRecordsParams(ids))
            as Json,
      );

  test('admitted prompt stdin failure settles a live adapter and permits Continue', () async {
    final d = await desktop();
    final workspace = await d.openWorkspace(work.path);
    final report = await saveAgentFixture(
      d,
      work,
      script: {'closeStdinAfterNew': true},
    );
    final a = AgentPeer(d);
    await a.start(workspace.workspace.id);
    await a.attach();
    await a.wait(Method.agentState, where: (p) => p['state'] == 'idle');
    final row = agentRows(profile).single;
    final tree = await waitReports(work, 1);
    await waitFixture(report, (p) => p['stdinClosed'] == true);
    expect(isProcessAlive(tree.single.pid, tree.single.startTime), isTrue);
    a.notifications.clear();
    await a.prompt('the native stdin read end is already closed');
    await a.wait(Method.agentState, where: (p) => p['state'] == 'running');
    await eventually(() {
      final state = a.of(Method.agentState).last['state'];
      return state == 'failed' || state == 'idle';
    });
    expect(a.of(Method.agentState).last['state'], 'failed');
    final exited = await a.wait(Method.agentExited);
    expect(exited['reason'], 'failed');
    expect(exited['error'], 'adapter-exited');
    expect(a.of(Method.agentTurnEnded), isEmpty);
    await expectAllGone(tree);
    expect(LedgerView(profile).units(), isEmpty);
    expect(agentRows(profile).single, row);
    await a.call(Method.agentRelease);
    a.notifications.clear();

    await saveAgentFixture(d, work, script: {
      'agentCapabilities': advertisedHistory,
    });
    expect((await continuePeer(a, a.id)).mode, AgentContinueMode.load);
    await a.attach();
    await a.wait(Method.agentState, where: (p) => p['state'] == 'idle');
    await a.prompt('the saved native reference can be used again');
    await a.wait(Method.agentTurnEnded);
    expect(agentRows(profile).single, row);
    await a.close();
  });

  for (final identity in {
    'multi-MiB name': {'name': 'n' * (2 * 1024 * 1024), 'version': 'test-only'},
    'multi-MiB version': {'name': 'scripted-acp', 'version': 'v' * (2 * 1024 * 1024)},
    'escaped version': {'name': 'scripted-acp', 'version': '\u0001' * 683},
  }.entries) {
    test('Continue rejects ${identity.key} without losing the host or saved record', () async {
      final d = await desktop();
      final (a, _, row) = await saved(d);
      await saveAgentFixture(d, work, script: {
        'agentInfo': identity.value,
        'agentCapabilities': advertisedHistory,
      });
      final error = await rpcFailure(continuePeer(a, a.id));
      expect(error.reason, ErrorCode.adapterProtocol);
      expect(error.data['stage'], 'initialize');
      expect(error.message, contains('adapter identity'));
      expect(utf8.encode(jsonEncode(error.message)).length, lessThan(8192));
      expect(agentRows(profile), [row]);
      final inspected = (await records(d, [a.id])).records[a.id]!;
      expect(inspected.known, isTrue);
      expect(inspected.adapterVersion, 'test-only');
      expect(inspected.workspaceAvailable, isTrue);
      expect(LedgerView(profile).units(), isEmpty);
      await expectAllGone(readReports(work));
    });
  }

  test('concurrent load and resume failures preserve inexact diagnostics after held cleanup', () async {
    final d = await desktop();
    final w = await d.openWorkspace(work.path);
    final originals = <AgentPeer>[];
    final nativeMessage = 'Authentication required${'界' * 2000}';
    for (final mode in ['load', 'resume']) {
      await saveAgentFixture(
        d,
        work,
        id: '$mode-error',
        script: {
          'agentCapabilities': {
            if (mode == 'load') 'loadSession': true,
            'sessionCapabilities': {'resume': <String, Object?>{}},
          },
          'errors': {
            'session/$mode': {
              'code': -32000,
              'message': nativeMessage,
              'data': {'private': 'x' * (1024 * 1024 + 64)},
            },
          },
        },
      );
      final a = AgentPeer(d);
      await a.start(w.workspace.id, runtime: '$mode-error');
      await a.attach();
      await a.close();
      await a.call(Method.agentRelease);
      originals.add(a);
    }
    final rows = agentRows(profile);
    final restored = <AgentPeer>[];
    await d.setFault(TestFault.terminateHangs);
    try {
      for (final original in originals) {
        final a = AgentPeer(d);
        restored.add(a);
        await continuePeer(a, original.id);
        await a.attach();
        await a.wait(Method.agentState, where: (p) => p['state'] == 'failed');
      }
      await eventually(
        () async {
          final stats =
              await d.connection.request('test/agent.stats', {}) as Json;
          final sessions = stats['sessions'] as Json;
          return restored.every(
            (a) => (sessions[a.id] as Json)['ending'] == true,
          );
        },
        reason: 'both restoration failures must await held containment cleanup',
      );
      expect(LedgerView(profile).units(), hasLength(2));
      for (final a in restored) {
        expect(a.of(Method.agentExited), isEmpty);
      }
    } finally {
      await d.setFault(TestFault.terminateHangs, enabled: false);
    }
    for (final a in restored) {
      final exit = await a.wait(Method.agentExited);
      expect(exit['reason'], 'failed');
      expect(exit['error'], ErrorCode.resumeUnavailable);
      expect(exit['resumeReason'], 'adapter-error');
      expect(exit['message'], contains('[truncated]'));
      expect(
        utf8.encode(exit['message'] as String).length,
        lessThanOrEqualTo(4096),
      );
      expect(jsonEncode(exit), isNot(contains('"private"')));
      await a.call(Method.agentRelease);
    }
    expect(agentRows(profile), rows);
    expect(LedgerView(profile).units(), isEmpty);
    await expectAllGone(readReports(work));
  });

  test('Continue with load: replay start, replayed user agent tool events, replay end then idle; no prompt sent', () async {
    final d = await desktop();
    final (_, report, row) = await saved(
      d,
      script: {
        'load': [
          {
            'update': {
              'sessionUpdate': 'user_message_chunk',
              'content': {'type': 'text', 'text': 'earlier user'},
            },
          },
          {'update': textUpdate('earlier agent')},
          {
            'update': {
              'sessionUpdate': 'tool_call',
              'toolCallId': 't',
              'title': 'Read',
              'status': 'pending',
            },
          },
          {
            'update': {
              'sessionUpdate': 'tool_call_update',
              'toolCallId': 't',
              'status': 'completed',
            },
          },
        ],
      },
    );
    await d.session.quit();
    await d.restart();
    await d.waitState();
    final inspected = (await records(d, [
      row['id'] as String,
      'unknown',
    ])).records;
    expect(inspected[row['id']]!.known, isTrue);
    expect(inspected[row['id']]!.targetPath, row['target_path']);
    expect(inspected[row['id']]!.adapterVersion, 'test-only');
    expect(inspected[row['id']]!.workspaceAvailable, isTrue);
    expect(inspected['unknown']!.known, isFalse);
    expect(inspected['unknown']!.workspaceAvailable, isFalse);
    expect(LedgerView(profile).units(), isEmpty);
    expect(fixtureReports(report), isEmpty);
    final a = AgentPeer(d);
    final answer = await continuePeer(a, row['id'] as String);
    expect(answer.mode, AgentContinueMode.load);
    expect(answer.capabilities, containsAll(['load', 'resume']));
    expect(
      fixtureReports(report).where((p) => p['method'] == 'session/load'),
      isEmpty,
    );
    await a.attach();
    await a.wait(Method.agentState, where: (p) => p['state'] == 'idle');
    await eventually(() => a.events.length == 6);
    expect(a.events.map((p) => p['kind']), [
      'replay',
      'user',
      'agentText',
      'tool',
      'toolUpdate',
      'replay',
    ]);
    expect(a.events.first['phase'], 'start');
    expect(a.events.last['phase'], 'end');
    final load = fixtureReports(report)
        .singleWhere((p) => p['method'] == 'session/load');
    expect(load['sessionId'], row['native_session_id']);
    expect(load['cwd'], row['target_path']);
    expect(load['mcpServers'], isEmpty);
    expect(
      fixtureReports(report)
          .where((p) => p.containsKey('newCwd') || p.containsKey('prompt')),
      isEmpty,
    );
    expect(agentRows(profile).single, row);
    await a.prompt('next turn');
    await a.wait(Method.agentTurnEnded);
    expect(
      (await waitFixture(report, (p) => p.containsKey('prompt')))['sessionId'],
      row['native_session_id'],
    );
    await a.close();
    expect(agentRows(profile).single, row);
  });
  test('Continue load replay uses bounded ordinary relay and delivers every event after credit resumes', () async {
    final d = await desktop();
    final text = 'x' * (32 * 1024);
    final (_, report, row) = await saved(
      d,
      script: {
        'blockedWriteAfterMs': 100,
        'load': [
          {
            'flood': {'count': 256, 'update': textUpdate(text)},
          },
        ],
      },
    );
    final a = AgentPeer(d);
    await continuePeer(a, row['id'] as String);
    await a.attach(credit: false);
    await waitFixture(report, (p) => p['blockedWrite'] == true);
    expect(a.events, isEmpty);
    expect(a.of(Method.agentState).any((p) => p['state'] == 'idle'), isFalse);
    d.connection.grantInitial(a.started.eventChannel);
    await a.wait(Method.agentState, where: (p) => p['state'] == 'idle');
    await eventually(() => a.events.length == 258);
    expect(a.events.first, containsPair('phase', 'start'));
    expect(a.events.last, containsPair('phase', 'end'));
    expect(
      a.events
          .skip(1)
          .take(256)
          .every((p) => p['kind'] == 'agentText' && p['text'] == text),
      isTrue,
    );
    expect(agentRows(profile).single, row);
    expect(
      fixtureReports(report)
          .where((p) => p.containsKey('prompt') || p.containsKey('newCwd')),
      isEmpty,
    );
    await a.close();
  });

  test('Continue with resume only: notice earlier messages not shown then idle; next prompt reaches same native session', () async {
    final d = await desktop();
    final (_, report, row) = await saved(
      d,
      script: {
        'agentCapabilities': {
          'sessionCapabilities': {'resume': <String, Object?>{}},
        },
      },
    );
    final a = AgentPeer(d);
    expect(
      (await continuePeer(a, row['id'] as String)).mode,
      AgentContinueMode.resume,
    );
    await a.attach();
    await a.wait(Method.agentState, where: (p) => p['state'] == 'idle');
    await eventually(() => a.events.isNotEmpty);
    expect(a.events.single, containsPair('kind', 'notice'));
    expect(a.events.single['text'], 'earlier messages not shown');
    expect(
      fixtureReports(report)
          .where((p) => p.containsKey('prompt') || p.containsKey('newCwd')),
      isEmpty,
    );
    expect(fixtureReports(report).single['method'], 'session/resume');
    await a.prompt();
    await a.wait(Method.agentTurnEnded);
    expect(
      (await waitFixture(report, (p) => p.containsKey('prompt')))['sessionId'],
      row['native_session_id'],
    );
    expect(agentRows(profile).single, row);
    await a.close();
  });
  test('same exact unlisted fixture without override is not-qualified; records remain known and read-only', () async {
    final d = await desktop(qualified: false);
    final (a, report, row) = await saved(d);
    final inspected = (await records(d, [a.id])).records[a.id]!;
    expect(inspected.known, isTrue);
    expect(inspected.workspaceAvailable, isTrue);
    final e = await rpcFailure(a.call(Method.agentContinue));
    expect(e.reason, ErrorCode.resumeUnavailable);
    expect(e.data['resumeReason'], 'not-qualified');
    expect(e.message, contains('test-only'));
    expect(agentRows(profile).single, row);
    expect(LedgerView(profile).units(), isEmpty);
    expect(
      fixtureReports(report)
          .where((p) => p.containsKey('newCwd') || p.containsKey('method')),
      isEmpty,
    );
  });
  test('Continue uses current initialize version not the immutable creating version', () async {
    final d = await desktop();
    final (a, _, row) = await saved(d);
    await saveAgentFixture(
      d,
      work,
      script: {
        'agentInfo': {'name': 'scripted-acp', 'version': 'new-unlisted'},
        'agentCapabilities': advertisedHistory,
      },
    );
    final e = await rpcFailure(a.call(Method.agentContinue));
    expect(e.data['resumeReason'], 'not-qualified');
    expect(e.message, contains('new-unlisted'));
    expect(agentRows(profile).single, row);
    expect(LedgerView(profile).units(), isEmpty);
  });
  test('qualified fixture version advertising neither load nor resume answers not-advertised', () async {
    final d = await desktop();
    final (a, _, row) = await saved(
      d,
      script: {'agentCapabilities': <String, Object?>{}},
    );
    await refuse(a, a.id, 'not-advertised');
    expect(agentRows(profile).single, row);
    expect(LedgerView(profile).units(), isEmpty);
  });
  test('unknown record is refused before target profile or launch', () async {
    final d = await desktop();
    await refuse(AgentPeer(d), 'unknown', 'unknown-record');
    expect(LedgerView(profile).units(), isEmpty);
  });
  for (final replaced in [false, true]) {
    test(
      'Continue target ${replaced ? 'changed' : 'missing'} refuses before spawn and records reports unavailable',
      () async {
        final d = await desktop();
        final (a, _, row) = await saved(d);
        final moved = Directory('${work.path}-original');
        work.renameSync(moved.path);
        addTearDown(() => deleteTree(moved));
        if (replaced) work.createSync();
        if (replaced) {
          expect(
            (directoryIdentity(work.path) as ResolvedDirectory).id,
            isNot(row['target_identity']),
          );
        }
        expect(
          (await records(d, [a.id])).records[a.id]!.workspaceAvailable,
          isFalse,
        );
        await refuse(a, a.id, replaced ? 'target-changed' : 'target-missing');
        expect(LedgerView(profile).units(), isEmpty);
      },
    );
  }
  test('Continue cleanup-unresolved refuses before profile resolution or any spawn', () async {
    final d = await desktop(env: {'KUMIKO_TEST_SETTLE_DEADLINE_MS': '250'});
    final w = await d.openWorkspace(work.path);
    final report = await saveAgentFixture(d, work);
    final a = AgentPeer(d);
    await a.start(w.workspace.id);
    await a.attach();
    await d.setFault(TestFault.terminateHangs);
    await a.call(Method.agentClose);
    await a.wait(Method.agentCloseFailed);
    final units = LedgerView(profile).units();
    await d.connection.request(
      Method.runtimeRemove,
      const RuntimeRemoveParams('acp'),
    );
    report.writeAsStringSync('');
    await refuse(a, a.id, 'cleanup-unresolved');
    expect(LedgerView(profile).units(), units);
    expect(fixtureReports(report), isEmpty);
    await d.setFault(TestFault.terminateHangs, enabled: false);
  });
  for (final mode in ['load', 'resume']) {
    test(
      'session/$mode error emits failed resume-unavailable adapter-error; settles without session/new',
      () async {
        final d = await desktop();
        final (_, report, row) = await saved(
          d,
          script: {
            if (mode == 'resume')
              'agentCapabilities': {
                'sessionCapabilities': {'resume': <String, Object?>{}},
              },
            'errors': {
              'session/$mode': {
                'code': -32007,
                'message': 'native history is missing',
              },
            },
          },
        );
        final a = AgentPeer(d);
        await continuePeer(a, row['id'] as String);
        await a.attach();
        final exit = await a.wait(Method.agentExited);
        expect(exit['reason'], 'failed');
        expect(exit['error'], ErrorCode.resumeUnavailable);
        expect(exit['resumeReason'], 'adapter-error');
        expect(exit['message'], 'native history is missing');
        expect(agentRows(profile).single, row);
        expect(LedgerView(profile).units(), isEmpty);
        expect(
          fixtureReports(report)
              .where((p) => p.containsKey('newCwd') || p.containsKey('prompt')),
          isEmpty,
        );
        await a.call(Method.agentRelease);
      },
    );
  }
  test('second Continue of a live start or open Continue record is refused without another spawn', () async {
    final d = await desktop();
    final w = await d.openWorkspace(work.path);
    await saveAgentFixture(
      d,
      work,
      script: {'agentCapabilities': advertisedHistory},
    );
    final a = AgentPeer(d);
    await a.start(w.workspace.id);
    await a.attach();
    await expectLater(
      a.call(Method.agentContinue),
      rpcCode(ErrorCode.turnRunning),
    );
    expect(LedgerView(profile).units(), hasLength(1));
    await a.close();
    await a.call(Method.agentRelease);
    final b = AgentPeer(d);
    await continuePeer(b, a.id);
    await expectLater(
      a.call(Method.agentContinue),
      rpcCode(ErrorCode.turnRunning),
    );
    expect(LedgerView(profile).units(), hasLength(1));
    await b.attach();
    await b.wait(Method.agentState, where: (p) => p['state'] == 'idle');
    await b.close();
  });
  test('duplicate pending Continue is synchronously reserved before initialize completes', () async {
    final d = await desktop();
    final (a, report, row) = await saved(d);
    await saveAgentFixture(
      d,
      work,
      script: {
        'agentCapabilities': advertisedHistory,
        'initialize': [
          {'stallStdin': true},
        ],
      },
    );
    final pending = a.call(Method.agentContinue);
    final failure = expectLater(pending, throwsA(isA<Exception>()));
    await waitFixture(report, (p) => p['stdinStalled'] == true);
    await expectLater(
      a.call(Method.agentContinue),
      rpcCode(ErrorCode.turnRunning),
    );
    expect(LedgerView(profile).units(), hasLength(1));
    expect(agentRows(profile).single, row);
    await d.session.quit();
    await failure;
  });
  test("removing a running session's profile keeps it running and its record; a later Continue uses the default profile", () async {
    final d = await desktop();
    final w = await d.openWorkspace(work.path);
    await saveAgentFixture(d, work, id: 'original');
    final a = AgentPeer(d);
    await a.start(w.workspace.id, runtime: 'original');
    await a.attach();
    final row = agentRows(profile).single;
    final fallback = await saveAgentFixture(
      d,
      work,
      id: 'fallback',
      script: {'agentCapabilities': advertisedHistory},
    );
    await d.connection.request(
      Method.runtimeSetDefault,
      const RuntimeSetDefaultParams('fallback'),
    );
    await d.connection.request(
      Method.runtimeRemove,
      const RuntimeRemoveParams('original'),
    );
    await a.prompt('still running');
    await a.wait(Method.agentTurnEnded);
    expect(agentRows(profile).single, row);
    await a.close();
    await a.call(Method.agentRelease);
    final b = AgentPeer(d);
    await continuePeer(b, a.id);
    await b.attach();
    await b.wait(Method.agentState, where: (p) => p['state'] == 'idle');
    expect(
      (await waitFixture(
        fallback,
        (p) => p['method'] == 'session/load',
      ))['sessionId'],
      row['native_session_id'],
    );
    expect(agentRows(profile).single, row);
    await b.close();
  });
  test(
    'records rejects over 128 ids without spawning and accepts 128 unknown ids',
    () async {
      final d = await desktop();
      await expectLater(
        records(d, List.generate(129, (i) => '$i')),
        rpcCode(ErrorCode.invalidParams),
      );
      final result = await records(d, List.generate(128, (i) => '$i'));
      expect(result.records, hasLength(128));
      expect(
        result.records.values.every((r) => !r.known && !r.workspaceAvailable),
        isTrue,
      );
      expect(LedgerView(profile).units(), isEmpty);
    },
  );
}
