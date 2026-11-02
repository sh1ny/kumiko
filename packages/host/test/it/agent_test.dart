import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/agent_support.dart';
import 'support/harness.dart';
import 'support/terminal_support.dart' show rpcFailure;

void main() {
  setUpAll(buildTestHost);
  late Directory profile;
  late Directory work;
  setUp(() {
    profile = tempDir('agent_profile_');
    work = tempDir('agent_work_');
  });
  tearDown(() async {
    killReported(work);
    await deleteTree(work);
    await deleteTree(profile);
  });
  Future<Desktop> desktop({Map<String, String> env = const {}}) async {
    final d = await Desktop.start(
      profile,
      capabilities: {...testCapabilities, Capability.agent},
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
    Json script = const {},
    bool attach = true,
  }) async {
    final d = await desktop();
    final workspace = await d.openWorkspace(work.path);
    final report = await saveAgentFixture(d, work, script: script);
    final a = AgentPeer(d);
    await a.start(workspace.workspace.id);
    if (attach) await a.attach();
    return (d, a, report);
  }

  void noResources() {
    expect(LedgerView(profile).units(), isEmpty);
    expect(agentRows(profile), isEmpty);
  }

  test(
    'session/new receives cwd = workspace path (fixture reports it)',
    () async {
      final (d, a, report) = await session(script: {'reportLaunch': true});
      final target = directoryIdentity(work.path) as ResolvedDirectory;
      expect(
        (await waitFixture(report, (p) => p.containsKey('newCwd')))['newCwd'],
        target.realPath,
      );
      expect(
        fixtureReports(report)
            .lastWhere((p) => p.containsKey('newCwd'))['mcpServers'],
        hasLength(1),
      );
      expect(
        a.started.sessionId,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      final row = agentRows(profile).single;
      expect(row, containsPair('native_session_id', 'fixture-native'));
      expect(row, containsPair('role', 'coding'));
      expect(row, containsPair('target_host', 'local'));
      expect(row, containsPair('target_identity', target.id));
      expect(DateTime.parse(row['created_at'] as String).isUtc, isTrue);
      expect(LedgerView(profile).units().single['kind'], 'agent');
      final b = AgentPeer(d);
      await b.start(row['workspace_id'] as String);
      expect(b.started.eventChannel, isNot(a.started.eventChannel));
      expect(b.id, isNot(a.id));
      await b.close();
      await a.close();
    },
  );
  for (final id in {
    'large ASCII': 's' * (2 * 1024 * 1024),
    'ASCII over limit': 's' * 4097,
    'escaped over limit': '\u0001' * 683,
    'UTF-8 over limit': '界' * 1366,
  }.entries) {
    test('native session ID ${id.key} is refused before saved-record creation', () async {
      final d = await desktop();
      final workspace = await d.openWorkspace(work.path);
      await saveAgentFixture(d, work, script: {'nativeSessionId': id.value});
      final error = await rpcFailure(d.connection.request(Method.agentStart, AgentStartParams(workspaceId: workspace.workspace.id)));
      expect(error.reason, ErrorCode.adapterProtocol);
      expect(error.data['stage'], 'session/new');
      expect(error.message, contains('session id'));
      noResources();
      expect(d.connection.isClosed, isFalse);
    });
  }
  for (final id in {
    'ASCII boundary': 's' * 4096,
    'escaped boundary': '${'\u0001' * 682}tail',
    'UTF-8 boundary': '${'界' * 1365}x',
  }.entries) {
    test('native session ID ${id.key} remains exact and usable', () async {
      final (_, a, _) = await session(script: {'nativeSessionId': id.value});
      expect(agentRows(profile).single['native_session_id'], id.value);
      await a.prompt('bounded native identity');
      expect((await a.wait(Method.agentTurnEnded))['stopReason'], 'end_turn');
      await a.close();
    });
  }

  test('coalesced session/new response and initial updates are retained in native order', () async {
    final (_, a, _) = await session(script: {
      'newSessionUpdates': [
        textUpdate('initial message'),
        {'sessionUpdate': 'plan', 'entries': [
          {'content': 'Initial plan', 'priority': 'medium', 'status': 'pending'},
        ]},
        {'sessionUpdate': 'tool_call', 'toolCallId': 'initial-tool', 'title': 'Initial tool', 'status': 'pending'},
        {'sessionUpdate': 'tool_call_update', 'toolCallId': 'initial-tool', 'status': 'completed'},
      ],
      'afterNew': [
        {'update': textUpdate('later message')},
      ],
    });
    await eventually(() => a.events.length == 5, within: const Duration(seconds: 3), reason: 'initial ACP updates were lost before session binding');
    expect(a.events.map((event) => event['kind']), ['agentText', 'plan', 'tool', 'toolUpdate', 'agentText']);
    expect(a.events.first['text'], 'initial message');
    expect((a.events[1]['entries'] as List).single, containsPair('content', 'Initial plan'));
    expect(a.events[2]['toolCallId'], 'initial-tool');
    expect(a.events[3]['status'], 'completed');
    expect(a.events.last['text'], 'later message');
    await a.close();
  });

  test('selecting workspace B then sending a prompt keeps cwd A and the stored target A', () async {
    final (d, a, report) = await session(
      script: {
        'prompt': [
          {'report': true},
        ],
      },
    );
    final other = tempDir('agent_other_');
    addTearDown(() => deleteTree(other));
    await d.openWorkspace(other.path);
    final before = agentRows(profile).single;
    await a.prompt();
    await a.wait(Method.agentTurnEnded);
    expect(
      (await waitFixture(report, (p) => p.containsKey('cwd')))['cwd'],
      before['target_path'],
    );
    expect(agentRows(profile).single, before);
    await a.close();
  });

  test('oversized native permission ID fails visibly without publishing approval and keeps the saved record', () async {
    final (d, a, report) = await session(
      script: {
        'prompt': [
          {...permissionAction, 'rpcId': 'p' * (2 * 1024 * 1024)},
        ],
      },
    );
    final record = agentRows(profile).single;
    await a.prompt('reject an undeliverable native permission');
    final exit = await a.wait(Method.agentExited, within: const Duration(seconds: 3));
    expect(exit['reason'], 'failed');
    expect(exit['error'], ErrorCode.adapterProtocol);
    expect(exit['message'], contains('request id'));
    expect(a.of(Method.agentPermissionRequested), isEmpty);
    expect(a.of(Method.agentPermissionResolved), isEmpty);
    expect(fixtureReports(report).where((entry) => entry.containsKey('permissionOutcome')), isEmpty);
    await eventually(() => LedgerView(profile).units().isEmpty);
    await expectAllGone(readReports(work));
    expect(agentRows(profile).single, record);
    await a.call(Method.agentRelease);
    expect(d.connection.isClosed, isFalse);
  });
  test('agent/start requires workspaceId and refuses unknown workspace before spawn', () async {
    final d = await desktop();
    await expectLater(
      d.connection.request(Method.agentStart, {}),
      rpcCode(ErrorCode.workspaceRequired),
    );
    await expectLater(
      d.connection.request(Method.agentStart, {'workspaceId': 'missing'}),
      rpcCode(ErrorCode.workspaceUnavailable),
    );
    noResources();
  });
  test('agent/start for a deleted workspace folder is refused workspace-unavailable with no unit or record', () async {
    final d = await desktop();
    final w = await d.openWorkspace(work.path);
    await saveAgentFixture(d, work);
    work.deleteSync(recursive: true);
    await expectLater(
      AgentPeer(d).start(w.workspace.id),
      rpcCode(ErrorCode.workspaceUnavailable),
    );
    noResources();
  });
  test(
    'missing explicit or removed default profile is never silently substituted',
    () async {
      final d = await desktop();
      final w = await d.openWorkspace(work.path);
      final a = AgentPeer(d);
      await expectLater(
        a.start(w.workspace.id),
        rpcCode(ErrorCode.noRuntimeProfile),
      );
      await saveAgentFixture(d, work);
      await saveAgentFixture(d, work, id: 'other');
      await expectLater(
        a.start(w.workspace.id, runtime: 'missing'),
        rpcCode(ErrorCode.noRuntimeProfile),
      );
      await d.connection.request(
        Method.runtimeRemove,
        const RuntimeRemoveParams('acp'),
      );
      await expectLater(
        a.start(w.workspace.id),
        rpcCode(ErrorCode.noRuntimeProfile),
      );
      noResources();
    },
  );
  test('agent/start with a missing executable fails executable-not-found naming the path, no unit in the ledger, no record', () async {
    final d = await desktop();
    final w = await d.openWorkspace(work.path);
    final missing = joinPath(work.path, 'missing.exe');
    await saveAgentFixture(d, work, executable: missing);
    final error = await rpcFailure(AgentPeer(d).start(w.workspace.id));
    expect(error.reason, ErrorCode.executableNotFound);
    expect(error.message, contains(missing));
    noResources();
  });
  test('agent/start rejects a batch executable before spawning', () async {
    final d = await desktop();
    final w = await d.openWorkspace(work.path);
    final file = File(joinPath(work.path, 'adapter.cmd'))
      ..writeAsStringSync('exit /b 0');
    await saveAgentFixture(d, work, executable: file.path);
    await expectLater(
      AgentPeer(d).start(w.workspace.id),
      rpcCode(ErrorCode.notExecutable),
    );
    noResources();
  }, testOn: 'windows');
  for (final status in [1, 126, 127]) {
    test(
      'fixture adapter exiting $status before initialize preserves engine error and status without shim misclassification',
      () async {
        final d = await desktop();
        final w = await d.openWorkspace(work.path);
        await saveAgentFixture(
          d,
          work,
          script: {
            'beforeInitializeExit': {
              'status': status,
              'stderr': 'Node engine requires >=22',
            },
          },
        );
        final e = await rpcFailure(AgentPeer(d).start(w.workspace.id));
        expect(e.reason, ErrorCode.adapterStartFailed);
        expect(e.data['status'], status);
        expect(e.data['detail'], contains('Node engine requires >=22'));
        noResources();
      },
    );
  }
  test('fixture answering protocolVersion 2 fails the start with unsupported ACP protocol version and leaves no process', () async {
    final d = await desktop();
    final w = await d.openWorkspace(work.path);
    await saveAgentFixture(d, work, script: {'protocolVersion': 2});
    final e = await rpcFailure(AgentPeer(d).start(w.workspace.id));
    expect(e.reason, ErrorCode.adapterProtocol);
    expect(e.message, contains('unsupported ACP protocol version 2'));
    noResources();
    await expectAllGone(readReports(work));
  });
  test('unlisted version claims the baseline only; start names the version without load or resume', () async {
    final (_, a, _) = await session(
      script: {
        'agentInfo': {'name': 'fixture', 'version': 'unlisted'},
        'agentCapabilities': {
          'loadSession': true,
          'sessionCapabilities': {'resume': <String, Object?>{}},
        },
      },
    );
    expect(a.started.adapter.version, 'unlisted');
    expect(a.started.capabilities, [
      'prompt',
      'streaming',
      'tools',
      'permissions',
      'cancel',
    ]);
    await a.close();
  });
  test('fixture failing session/new leaves no record and preserves the adapter message', () async {
    final d = await desktop();
    final w = await d.openWorkspace(work.path);
    await saveAgentFixture(
      d,
      work,
      script: {
        'errors': {
          'session/new': {
            'code': -32007,
            'message': 'native adapter refused the session',
          },
        },
      },
    );
    final e = await rpcFailure(AgentPeer(d).start(w.workspace.id));
    expect(e.reason, ErrorCode.adapterStartFailed);
    expect(e.message, contains('native adapter refused the session'));
    expect(e.data['stage'], 'session/new');
    expect(e.data['nativeCode'], -32007);
    expect(e.data['nativeMessage'], 'native adapter refused the session');
    expect(e.data['nativeMessageTruncated'], isNot(isTrue));
    noResources();
    await expectAllGone(readReports(work));
  });
  test('observed session/new authentication error reports auth-required and cleans up without a record', () async {
    final d = await desktop();
    final w = await d.openWorkspace(work.path);
    await saveAgentFixture(
      d,
      work,
      script: {
        'errors': {
          'session/new': {'code': -32000, 'message': 'Authentication required'},
        },
      },
    );
    final e = await rpcFailure(AgentPeer(d).start(w.workspace.id));
    expect(e.reason, ErrorCode.authRequired);
    expect(e.message, contains('Authentication required'));
    expect(e.data['stage'], 'session/new');
    expect(e.data['nativeCode'], -32000);
    expect(e.data['nativeMessage'], 'Authentication required');
    expect(e.data['nativeMessageTruncated'], isNot(isTrue));
    noResources();
    await expectAllGone(readReports(work));
  });
  test('observed authentication signature during initialize stays a generic startup error', () async {
    final d = await desktop();
    final w = await d.openWorkspace(work.path);
    await saveAgentFixture(
      d,
      work,
      script: {
        'errors': {
          'initialize': {'code': -32000, 'message': 'Authentication required'},
        },
      },
    );
    final e = await rpcFailure(AgentPeer(d).start(w.workspace.id));
    expect(e.reason, ErrorCode.adapterStartFailed);
    expect(e.data['stage'], 'initialize');
    expect(e.data['nativeCode'], -32000);
    expect(e.data['nativeMessage'], 'Authentication required');
    noResources();
    await expectAllGone(readReports(work));
  });
  for (final mode in ['load', 'resume']) {
    test(
      'observed session/$mode authentication error preserves resume-unavailable with auth-required subreason',
      () async {
        final d = await desktop(
          env: {
            'KUMIKO_TEST_QUALIFIED_ADAPTERS':
                '[["scripted-acp","test-only",["load","resume"]]]',
          },
        );
        final w = await d.openWorkspace(work.path);
        final report = await saveAgentFixture(
          d,
          work,
          script: {
            'agentCapabilities': {
              if (mode == 'load') 'loadSession': true,
              'sessionCapabilities': {'resume': <String, Object?>{}},
            },
            'errors': {
              'session/$mode': {
                'code': -32000,
                'message': 'Authentication required',
              },
            },
          },
        );
        final original = AgentPeer(d);
        await original.start(w.workspace.id);
        await original.attach();
        await original.close();
        await original.call(Method.agentRelease);
        final row = agentRows(profile).single;
        report.writeAsStringSync('');
        final a = AgentPeer(d);
        final continued = AgentContinueResult.fromJson(
          await a.call(Method.agentContinue, {'sessionId': original.id}),
        );
        expect(
          continued.mode,
          mode == 'load' ? AgentContinueMode.load : AgentContinueMode.resume,
        );
        a.started = AgentStartResult(
          sessionId: original.id,
          eventChannel: continued.eventChannel,
          adapter: continued.adapter,
          capabilities: continued.capabilities,
        );
        await a.attach();
        final exit = await a.wait(Method.agentExited);
        expect(exit['reason'], 'failed');
        expect(exit['error'], ErrorCode.resumeUnavailable);
        expect(exit['resumeReason'], ErrorCode.authRequired);
        expect(exit['message'], 'Authentication required');
        expect(agentRows(profile).single, row);
        expect(LedgerView(profile).units(), isEmpty);
        expect(
          fixtureReports(report)
              .where((p) => p.containsKey('newCwd') || p.containsKey('prompt')),
          isEmpty,
        );
        await expectAllGone(readReports(work));
        await a.call(Method.agentRelease);
      },
    );
  }
  test(
    'concurrent native startup failures preserve truncation after held cleanup',
    () async {
      final d = await desktop();
      final w = await d.openWorkspace(work.path);
      final nativeMessage = 'Authentication required${'界' * 2000}';
      for (final method in ['initialize', 'session/new']) {
        await saveAgentFixture(
          d,
          work,
          id: method == 'initialize' ? 'init-error' : 'new-error',
          script: {
            'errors': {
              method: {
                'code': -32000,
                'message': nativeMessage,
                'data': {'private': 'x' * (1024 * 1024 + 64)},
              },
            },
          },
        );
      }
      final failures = <Future<RpcException>>[];
      var completed = 0;
      await d.setFault(TestFault.terminateHangs);
      try {
        for (final runtime in ['init-error', 'new-error']) {
          failures.add(
            rpcFailure(AgentPeer(d).start(w.workspace.id, runtime: runtime))
                .then((error) {
                  completed++;
                  return error;
                }),
          );
        }
        await eventually(
          () => LedgerView(profile).units().length == 2,
          reason: 'both concurrent failed launches must own contained units',
        );
        expect(completed, 0);
        expect(agentRows(profile), isEmpty);
      } finally {
        await d.setFault(TestFault.terminateHangs, enabled: false);
      }
      final errors = await Future.wait(failures);
      expect(errors.map((error) => error.data['stage']), [
        'initialize',
        'session/new',
      ]);
      for (final error in errors) {
        expect(error.reason, ErrorCode.adapterStartFailed);
        expect(error.data['nativeCode'], -32000);
        expect(error.data['nativeMessageTruncated'], isTrue);
        expect(error.data['nativeMessage'], clampUtf8(nativeMessage, 4096));
        expect(jsonEncode(error.toJson()), isNot(contains('"private"')));
      }
      noResources();
      await expectAllGone(readReports(work));
    },
  );

  test(
    'long native start error evidence is bounded and explicitly marked inexact',
    () async {
      final d = await desktop();
      final w = await d.openWorkspace(work.path);
      final nativeMessage = '界' * 2000;
      await saveAgentFixture(
        d,
        work,
        script: {
          'errors': {
            'session/new': {
              'code': -32007,
              'message': nativeMessage,
              'data': {'private': 'must-not-be-forwarded'},
            },
          },
        },
      );
      final e = await rpcFailure(AgentPeer(d).start(w.workspace.id));
      expect(e.reason, ErrorCode.adapterStartFailed);
      expect(e.data['nativeCode'], -32007);
      expect(e.data['nativeMessageTruncated'], isTrue);
      final message = e.data['nativeMessage'] as String;
      expect(utf8.encode(message).length, lessThanOrEqualTo(4096));
      expect(nativeMessage.startsWith(message), isTrue);
      expect(jsonEncode(e.toJson()), isNot(contains('must-not-be-forwarded')));
      noResources();
    },
  );
  test('no record is inserted while session/new is still pending', () async {
    final d = await desktop();
    final w = await d.openWorkspace(work.path);
    final report = await saveAgentFixture(
      d,
      work,
      script: {
        'new': [
          {'stallStdin': true},
        ],
      },
    );
    final starting = AgentPeer(d).start(w.workspace.id);
    final outcome = expectLater(starting, throwsA(isA<Exception>()));
    await waitFixture(report, (p) => p['stdinStalled'] == true);
    expect(agentRows(profile), isEmpty);
    await d.session.quit();
    await outcome;
    await expectAllGone(readReports(work));
  });
  test(
    'agent/start at the unit cap is refused unit-cap with no record',
    () async {
      final d = await desktop(env: {'KUMIKO_TEST_UNIT_CAP': '1'});
      final w = await d.openWorkspace(work.path);
      await saveAgentFixture(d, work);
      final unit = await d.launch(work, TestFixture.sleeper);
      await expectLater(
        AgentPeer(d).start(w.workspace.id),
        rpcCode(ErrorCode.unitCap),
      );
      expect(agentRows(profile), isEmpty);
      expect(LedgerView(profile).units().single['containment_id'], unit);
    },
  );
  test('agent/start with the channel limit reached is refused channel-limit with no unit started', () async {
    final d = await desktop();
    final w = await d.openWorkspace(work.path);
    await saveAgentFixture(d, work);
    for (var i = 0; i < maxChannels; i++) {
      await d.connection.request(
        Method.testChannelOpen,
        const TestChannelOpenParams(0),
      );
    }
    await expectLater(
      AgentPeer(d).start(w.workspace.id),
      rpcCode(ErrorCode.channelLimit),
    );
    noResources();
  });
  test('40 scripted chunks arrive as ordered agentText events before turnEnded and idle', () async {
    final (_, a, _) = await session(
      script: {
        'prompt': [
          for (var i = 0; i < 40; i++) {'update': textUpdate('chunk-$i;')},
        ],
      },
    );
    await a.prompt();
    await a.wait(Method.agentTurnEnded);
    await eventually(
      () => a.events.where((e) => e['kind'] == 'agentText').length == 40,
    );
    expect(
      a.events.where((e) => e['kind'] == 'agentText').map((e) => e['text']),
      [for (var i = 0; i < 40; i++) 'chunk-$i;'],
    );
    expect(a.events.last['kind'], 'turn');
    final states = a.of(Method.agentState);
    expect(states.last['state'], 'idle');
    expect(
      states.map((p) => p['seq']),
      orderedEquals((states.map((p) => p['seq'] as int).toList()..sort())),
    );
    await a.close();
  });
  test('unknown update is ignored and later tool plan and text events stay ordered', () async {
    final (_, a, _) = await session(
      script: {
        'prompt': [
          {
            'update': {'sessionUpdate': 'future_update'},
          },
          {
            'update': {
              'sessionUpdate': 'tool_call',
              'toolCallId': 't',
              'title': 'Edit',
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
          {
            'update': {
              'sessionUpdate': 'plan',
              'entries': [
                {'content': 'done', 'priority': 'high', 'status': 'completed'},
              ],
            },
          },
          {'update': textUpdate('after')},
        ],
      },
    );
    await a.prompt();
    await a.wait(Method.agentTurnEnded);
    await eventually(() => a.events.any((e) => e['kind'] == 'turn'));
    expect(a.events.map((e) => e['kind']), [
      'user',
      'tool',
      'toolUpdate',
      'plan',
      'agentText',
      'turn',
    ]);
    await a.close();
  });
  for (final option in ['yes', 'no']) {
    test(
      'permissionReply $option delivers explicit optionId and resolved replies write nothing',
      () async {
        final (_, a, report) = await session(
          script: {
            'prompt': [permissionAction],
          },
        );
        await a.prompt();
        final p = await a.wait(Method.agentPermissionRequested);
        expect((p['options'] as List).length, 2);
        expect(
          fixtureReports(report)
              .where((p) => p.containsKey('permissionOutcome')),
          isEmpty,
        );
        final reply = {
          'sessionId': a.id,
          'requestId': p['requestId'],
          'optionId': option,
        };
        final clock = Stopwatch()..start();
        await a.call(Method.agentPermissionReply, reply);
        expect(clock.elapsed, lessThan(const Duration(milliseconds: 250)));
        final answer = await waitFixture(
          report,
          (p) => p.containsKey('permissionOutcome'),
        );
        expect(answer['permissionOutcome'], {
          'outcome': 'selected',
          'optionId': option,
        });
        await expectLater(
          a.call(Method.agentPermissionReply, reply),
          rpcCode(ErrorCode.unknownRequest),
        );
        await a.wait(Method.agentTurnEnded);
        expect(
          fixtureReports(report)
              .where((p) => p.containsKey('permissionOutcome')),
          hasLength(1),
        );
        await a.close();
      },
    );
  }
  test('Stop with a pending request delivers cancelled before cancel and keeps the same unit alive', () async {
    final (_, a, report) = await session(
      script: {
        'prompt': [permissionAction],
        'holdPrompt': true,
      },
    );
    final unit = LedgerView(profile).units().single;
    await a.prompt();
    await a.wait(Method.agentPermissionRequested);
    final clock = Stopwatch()..start();
    await a.call(Method.agentStop);
    expect(clock.elapsed, lessThan(const Duration(milliseconds: 250)));
    expect((await a.wait(Method.agentStopResult))['outcome'], 'stopped');
    await a.wait(Method.agentState, where: (p) => p['state'] == 'idle');
    expect(
      (await waitFixture(
        report,
        (p) => p.containsKey('permissionOutcome'),
      ))['permissionOutcome'],
      {'outcome': 'cancelled'},
    );
    final reports = fixtureReports(report);
    expect(
      reports.indexWhere((p) => p.containsKey('permissionOutcome')),
      lessThan(reports.indexWhere((p) => p['cancelReceived'] == true)),
    );
    expect(
      LedgerView(profile).units().single['containment_id'],
      unit['containment_id'],
    );
    await a.prompt('second turn');
    await eventually(
      () =>
          fixtureReports(report).where((p) => p.containsKey('prompt')).length ==
          2,
    );
    await a.close();
  });
  test('no answer by the stop deadline yields notConfirmed, stopping and no termination; close still ends it', () async {
    final (_, a, report) = await session(
      script: {'holdPrompt': true, 'cancel': 'ignore'},
    );
    await a.prompt();
    await waitFixture(report, (p) => p.containsKey('prompt'));
    await a.call(Method.agentStop);
    expect((await a.wait(Method.agentStopResult))['outcome'], 'notConfirmed');
    expect(a.of(Method.agentState).last['state'], 'stopping');
    expect(LedgerView(profile).units(), hasLength(1));
    await a.close();
  });
  test('native prompt errors preserve their message and end the turn idle without failing the session', () async {
    final (_, a, _) = await session(
      script: {
        'errors': {
          'session/prompt': {
            'code': -32042,
            'message': 'native prompt failure',
          },
        },
      },
    );
    await a.prompt();
    final ended = await a.wait(Method.agentTurnEnded);
    expect(ended['error'], 'adapter-error');
    expect(ended['message'], 'native prompt failure');
    expect(ended['nativeCode'], -32042);
    expect(ended['nativeMessage'], 'native prompt failure');
    expect(ended['nativeMessageTruncated'], isNot(isTrue));
    await a.wait(Method.agentState, where: (p) => p['state'] == 'idle');
    expect(agentRows(profile).single['id'], a.id);
    await a.close();
  });
  test('start stderr tail is UTF8 safe and at most 4 KiB without entering host logs', () async {
    final d = await desktop();
    final w = await d.openWorkspace(work.path);
    final stderr = '${'界' * 24000}engine-tail';
    await saveAgentFixture(
      d,
      work,
      script: {
        'beforeInitializeExit': {'status': 1, 'stderr': stderr},
      },
    );
    final e = await rpcFailure(AgentPeer(d).start(w.workspace.id));
    expect(e.reason, ErrorCode.adapterStartFailed);
    final detail = e.data['detail'] as String;
    expect(utf8.encode(detail).length, lessThanOrEqualTo(4096));
    expect(detail, contains('engine-tail'));
    expect(detail, isNot(contains('\uFFFD')));
    expect(jsonEncode(readHostLog(profile)), isNot(contains('engine-tail')));
    noResources();
  });
  test('events remain reserved until attach and the first event arrives through the pre-registered channel', () async {
    final (_, a, report) = await session(
      attach: false,
      script: {
        'prompt': [
          {'update': textUpdate('first')},
          {'report': true},
        ],
      },
    );
    await a.prompt();
    await waitFixture(report, (p) => p.containsKey('argv'));
    expect(a.events, isEmpty);
    await a.attach();
    await eventually(() => a.events.any((e) => e['text'] == 'first'));
    expect(a.events.first['kind'], 'user');
    await a.close();
  });
  test('fixture exiting 1 mid-turn yields exited failed status 1 and the record remains', () async {
    final (_, a, _) = await session(
      script: {
        'prompt': [
          {'exit': 1},
        ],
      },
    );
    await a.prompt();
    final exit = await a.wait(Method.agentExited);
    expect(exit['reason'], 'failed');
    expect(exit['status'], 1);
    expect(agentRows(profile).single['id'], a.id);
    await eventually(() => LedgerView(profile).units().isEmpty);
    await a.call(Method.agentRelease);
  });
  test('agent/stop for a closed session fails unknown-session and other sessions are unaffected', () async {
    final (d, a, _) = await session();
    final b = AgentPeer(d);
    await b.start(agentRows(profile).single['workspace_id'] as String);
    await b.attach();
    await a.close();
    await expectLater(
      a.call(Method.agentStop),
      rpcCode(ErrorCode.unknownSession),
    );
    await b.prompt();
    await b.wait(Method.agentTurnEnded);
    await b.close();
  });
  test('ordinary agent RPC smoke: two turns explicit approval Stop close and private durable record', () async {
    const canary = 'kumiko-canary-7f3a';
    final (d, a, report) = await session(
      script: {
        'prompt': [
          permissionAction,
          {'update': textUpdate(canary)},
          {'stderr': canary},
        ],
        'holdPrompt': true,
      },
    );
    for (var turn = 0; turn < 2; turn++) {
      await a.prompt('$canary turn $turn');
      await eventually(
        () => a.of(Method.agentPermissionRequested).length == turn + 1,
      );
      final permission = a.of(Method.agentPermissionRequested).last;
      await a.call(Method.agentPermissionReply, {
        'sessionId': a.id,
        'requestId': permission['requestId'],
        'optionId': 'yes',
      });
      await eventually(
        () =>
            fixtureReports(report)
                .where(
                  (p) =>
                      p['permissionOutcome'] is Json &&
                      (p['permissionOutcome'] as Json)['optionId'] == 'yes',
                )
                .length ==
            turn + 1,
      );
      await eventually(
        () =>
            a.events.where((e) => e['kind'] == 'agentText').length == turn + 1,
      );
      await a.call(Method.agentStop);
      await eventually(() => a.of(Method.agentStopResult).length == turn + 1);
      expect(a.of(Method.agentStopResult).last['outcome'], 'stopped');
      await eventually(
        () =>
            a.of(Method.agentTurnEnded).length == turn + 1 &&
            a.of(Method.agentState).last['state'] == 'idle',
      );
    }
    final before = agentRows(profile).single;
    await a.close();
    await a.call(Method.agentRelease);
    await d.session.quit();
    expect(LedgerView(profile).units(), isEmpty);
    for (final entry
        in profile
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()) {
      expect(
        latin1.decode(entry.readAsBytesSync()),
        isNot(contains(canary)),
        reason: entry.path,
      );
    }
    await d.restart();
    await d.waitState();
    expect(agentRows(profile).single, before);
    expect(LedgerView(profile).units(), isEmpty);
  });
  test('after a host restart the store holds the same ids adapter version target path and identity', () async {
    final (d, a, _) = await session();
    final before = agentRows(profile).single;
    await a.close();
    await d.session.quit();
    await d.restart();
    await d.waitState();
    expect(agentRows(profile).single, before);
    expect(LedgerView(profile).units(), isEmpty);
  });
  test('after a canary prompt reply and stderr no profile file including store WAL or logs contains the canary', () async {
    const canary = 'kumiko-canary-7f3a';
    final (d, a, _) = await session(
      script: {
        'prompt': [
          {'update': textUpdate(canary)},
          {'stderr': canary},
        ],
      },
    );
    await a.prompt(canary);
    await a.wait(Method.agentTurnEnded);
    await eventually(() => a.events.any((e) => e['text'] == canary));
    void check({required bool hostRunning}) {
      final lockPath = joinPath(profile.path, 'kumiko.lock');
      for (final entry
          in profile
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()) {
        // Windows denies reads of the host's exclusively range-locked file.
        // Every conversation-bearing file, including DB/WAL/logs, is still
        // read while live. After quit even this named lock must be checked.
        if (hostRunning && entry.path == lockPath) continue;
        // The tool endpoint socket stores no bytes and cannot be opened.
        if (FileSystemEntity.typeSync(entry.path, followLinks: false) ==
            FileSystemEntityType.unixDomainSock) {
          continue;
        }
        expect(
          latin1.decode(entry.readAsBytesSync()),
          isNot(contains(canary)),
          reason: entry.path,
        );
      }
    }

    check(hostRunning: true);
    await a.close();
    await d.session.quit();
    check(hostRunning: false);
  });
}
