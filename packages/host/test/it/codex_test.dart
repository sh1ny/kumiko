import 'dart:io';
import 'dart:convert';
import 'dart:math' show min;

import 'package:host_protocol/host_protocol.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/terminal_support.dart' show rpcFailure;
import 'support/codex_support.dart' hide codexCaps;

const _codexCaps = {
  Capability.agent,
  Capability.codex,
  Capability.agentExtensionsV1,
};

void main() {
  late Directory profile;
  late Directory work;
  Json child(String id, String parent) => nativeEvent('thread/started', {
    'thread': {
      'id': id,
      'parentThreadId': parent,
      'status': {'type': 'active'},
    },
  });
  Json childTurn(String id, String status) =>
      nativeEvent(status == 'inProgress' ? 'turn/started' : 'turn/completed', {
        'threadId': id,
        'turn': {
          'id': '$id-turn',
          'status': status,
          'items': <Object?>[],
          'error': null,
        },
      });
  for (final name in [
    'Child emits output',
    'Nested live children',
    'Two children use the same tool identifier',
  ]) {
    test('Codex: $name', () async {
      final f = NativeFixture(
        profile,
        work,
        script: {
          'turns': [
            {
              'actions': [
                child('child-a', 'root-thread'),
                child('child-b', 'child-a'),
                childTurn('child-a', 'inProgress'),
                childTurn('child-b', 'inProgress'),
                for (final id in ['child-a', 'child-b'])
                  nativeEvent('item/completed', {
                    'threadId': id,
                    'turnId': '$id-turn',
                    'item': {
                      'id': 'same-item',
                      'type': 'commandExecution',
                      'command': 'echo child',
                      'cwd': '/fixture',
                      'commandActions': <Object?>[],
                      'status': 'completed',
                      'aggregatedOutput': 'child-only-output',
                    },
                  }),
                childTurn('child-a', 'completed'),
                childTurn('child-b', 'completed'),
                terminalEvent('completed'),
              ],
            },
          ],
        },
      );
      await f.open();
      final a = await f.start();
      await a.prompt();
      await a.wait(Method.agentTurnEnded);
      await eventually(() => a.events.any((e) => e['kind'] == 'turn'));
      final tools = a.events
          .where((e) => e['toolKind'] == 'commandExecution')
          .toList();
      expect(tools, hasLength(2));
      expect(tools.map((e) => e['toolCallId']).toSet(), hasLength(2));
      expect(tools.last['parentThreadId'], 'child-a');
      expect(tools.first['rootThreadId'], 'root-thread');
      await a.close();
    });
  }
  for (final credit in [true, false]) {
    test(
      'Codex: ${credit ? 'Child starts' : 'Child starts with no transcript credit'}',
      () async {
        final f = NativeFixture(
          profile,
          work,
          script: {
            'turns': [
              {
                'actions': [
                  child('child-a', 'root-thread'),
                  childTurn('child-a', 'inProgress'),
                  terminalEvent('completed'),
                ],
              },
            ],
          },
        );
        await f.open();
        final a = AgentPeer(f.desktop);
        await a.start(f.workspace, runtime: 'native');
        await a.attach(credit: credit);
        await a.prompt();
        await a.wait(Method.agentTurnEnded);
        final idle = await a.wait(
          Method.agentState,
          where: (p) => p['state'] == 'idle' && p['seq'] as int > 3,
        );
        expect(idle['delegated'], {
          'activeChildren': 1,
          'waitingRequests': 0,
          'incomplete': false,
        });
        await a.close();
      },
    );
  }
  test('Codex: Attribution capacity is exceeded', () async {
    final f = NativeFixture(
      profile,
      work,
      script: {
        'turns': [
          {
            'actions': [
              for (var i = 0; i < 65; i++) child('child-$i', 'root-thread'),
              terminalEvent('completed'),
            ],
          },
        ],
      },
    );
    await f.open();
    final a = await f.start();
    await a.prompt();
    await a.wait(Method.agentTurnEnded);
    expect(
      (a.of(Method.agentState).last['delegated'] as Json?)?['incomplete'],
      true,
    );
    await a.close();
  });
  setUpAll(buildTestHost);
  test(
    'Codex: out-of-order nested metadata resolves attributed output',
    () async {
      final f = NativeFixture(
        profile,
        work,
        script: {
          'turns': [
            {
              'actions': [
                child('grandchild', 'child-a'),
                nativeEvent('item/agentMessage/delta', {
                  'threadId': 'grandchild',
                  'turnId': 'grandchild-turn',
                  'itemId': 'text',
                  'delta': 'attributed-only',
                }),
                child('child-a', 'root-thread'),
                terminalEvent('completed'),
              ],
            },
          ],
        },
      );
      await f.open();
      final a = await f.start();
      await a.prompt();
      await a.wait(Method.agentTurnEnded);
      await eventually(
        () => a.events.any((e) => e['text'] == 'attributed-only'),
      );
      final event = a.events.singleWhere((e) => e['text'] == 'attributed-only');
      expect(event['threadId'], 'grandchild');
      expect(event['parentThreadId'], 'child-a');
      expect(
        (a.of(Method.agentState).last['delegated'] as Json)['incomplete'],
        false,
      );
      await a.close();
    },
  );
  test('Codex: Child outcome is unknown', () async {
    final f = NativeFixture(
      profile,
      work,
      script: {
        'turns': [
          {
            'actions': [
              child('child-a', 'root-thread'),
              childTurn('child-a', 'inProgress'),
              {'closeStdout': true},
            ],
          },
        ],
      },
    );
    await f.open();
    final a = await f.start();
    await a.prompt();
    await a.wait(Method.agentExited);
    await eventually(
      () => a.events.any(
        (e) => e['kind'] == 'child' && e['status'] == 'disconnected',
      ),
      within: const Duration(seconds: 2),
    );
    expect(
      a.events.where(
        (e) => e['threadId'] == 'child-a' && e['status'] == 'completed',
      ),
      isEmpty,
    );
    expect(
      (a.of(Method.agentState).last['delegated'] as Json)['incomplete'],
      true,
    );
  });
  test('Codex: Root closes during child work', () async {
    final f = NativeFixture(
      profile,
      work,
      script: {
        'turns': [
          {
            'actions': [
              {'spawnTree': true},
              for (var i = 0; i < 33; i++) ...[
                child('child-$i', 'root-thread'),
                childTurn('child-$i', 'inProgress'),
              ],
              terminalEvent('completed'),
            ],
          },
        ],
      },
    );
    await f.open();
    final a = await f.start();
    await a.prompt();
    await a.wait(Method.agentTurnEnded);
    final error = await rpcFailure(a.call(Method.agentStop));
    expect(error.reason, ErrorCode.busy);
    expect(f.requests.where((r) => r['method'] == 'turn/interrupt'), isEmpty);
    expect(a.of(Method.agentState).last['state'], 'idle');
    final descendants = await waitReports(work, 4);
    await a.call(Method.agentClose);
    await a.wait(Method.agentExited, where: (r) => r['reason'] == 'closed');
    await expectAllGone(descendants);
    expect(LedgerView(profile).units(), isEmpty);
  });
  for (final unsupported in [false, true]) {
    test(
      'Codex: ${unsupported ? 'One child interruption is unsupported' : 'Codex native interruption completes'}',
      () async {
        final f = NativeFixture(
          profile,
          work,
          script: {
            if (unsupported) 'unsupportedInterruptThreads': ['child-a'],
            'turns': [
              {
                'actions': [
                  child('child-a', 'root-thread'),
                  childTurn('child-a', 'inProgress'),
                  terminalEvent('completed'),
                  {'waitInterrupt': 'child-a-turn'},
                  childTurn('child-a', 'interrupted'),
                ],
              },
            ],
          },
        );
        await f.open();
        final a = await f.start();
        await a.prompt();
        await a.wait(Method.agentTurnEnded);
        await a.call(Method.agentStop);
        final result = await a.wait(
          Method.agentStopResult,
          within: const Duration(seconds: 14),
        );
        expect(result['outcome'], unsupported ? 'notConfirmed' : 'stopped');
        expect(
          a.of(Method.agentState).last['state'],
          unsupported ? 'stopping' : 'idle',
        );
        expect(
          f.requests
              .where((r) => r['method'] == 'turn/interrupt')
              .map((r) => (r['params'] as Json)['threadId']),
          ['child-a'],
        );
        await a.close();
      },
    );
  }
  for (final aggregate in [
    ('interrupted', 'stopped'),
    ('completed', 'finishedFirst'),
    ('failed', 'endedWithError'),
  ]) {
    test('Codex: root and child Stop aggregate ${aggregate.$2}', () async {
      final f = NativeFixture(
        profile,
        work,
        script: {
          'turns': [
            {
              'actions': [
                child('child-a', 'root-thread'),
                childTurn('child-a', 'inProgress'),
                {
                  'send': {
                    'id': 'ready-child',
                    'method': 'item/commandExecution/requestApproval',
                    'params': {
                      'threadId': 'child-a',
                      'turnId': 'child-a-turn',
                      'itemId': 'ready',
                      'startedAtMs': 1,
                      'command': 'echo ready',
                      'cwd': '/fixture',
                      'availableDecisions': ['accept', 'decline'],
                    },
                  },
                },
                {'waitInterrupt': true},
                terminalEvent('completed'),
                {'waitInterrupt': 'child-a-turn'},
                childTurn('child-a', aggregate.$1),
              ],
            },
          ],
        },
      );
      await f.open();
      final a = await f.start();
      await a.prompt();
      await a.wait(Method.agentPermissionRequested);
      await a.call(Method.agentStop);
      final outcome = await a.wait(Method.agentStopResult);
      expect(outcome['outcome'], aggregate.$2);
      expect(
        f.requests
            .where((r) => r['method'] == 'turn/interrupt')
            .map((r) => (r['params'] as Json)['threadId'])
            .toSet(),
        {'root-thread', 'child-a'},
      );
      expect(a.of(Method.agentState).last['state'], 'idle');
      await a.prompt('still live');
      await eventually(() => a.of(Method.agentTurnEnded).length == 2);
      await a.close();
    });
  }
  test('Codex: Child asks permission', () async {
    final f = NativeFixture(
      profile,
      work,
      script: {
        'turns': [
          {
            'actions': [
              child('child-a', 'root-thread'),
              childTurn('child-a', 'inProgress'),
              terminalEvent('completed'),
              {
                'send': {
                  'id': 'child-approval',
                  'method': 'item/commandExecution/requestApproval',
                  'params': {
                    'threadId': 'child-a',
                    'turnId': 'child-a-turn',
                    'itemId': 'child-command',
                    'startedAtMs': 1,
                    'command': 'echo child',
                    'cwd': '/fixture',
                    'availableDecisions': ['accept', 'decline'],
                  },
                },
              },
              {'waitReply': 'child-approval'},
              childTurn('child-a', 'completed'),
            ],
          },
        ],
      },
    );
    await f.open();
    final a = await f.start();
    await a.prompt();
    final request = await a.wait(
      Method.agentPermissionRequested,
      within: const Duration(seconds: 3),
    );
    expect(request['title'], contains('child-a'));
    await a.call(Method.agentPermissionReply, {
      'sessionId': a.id,
      'requestId': request['requestId'],
      'optionId': ((request['options'] as List).first as Json)['optionId'],
    });
    await waitFixture(
      f.report,
      (r) => (r['received'] as Json?)?['id'] == 'child-approval',
    );
    expect(
      f.requests.singleWhere((r) => r['id'] == 'child-approval')['result'],
      {'decision': 'accept'},
    );
    await a.close();
  });
  test(
    'Codex: a stale collaboration snapshot cannot settle a live child turn',
    () async {
      final f = NativeFixture(
        profile,
        work,
        script: {
          'turns': [
            {
              'actions': [
                child('child-a', 'root-thread'),
                childTurn('child-a', 'inProgress'),
                terminalEvent('completed'),
                // A delayed snapshot says child-a completed, but carries no
                // child turn identity; the live child turn is still running.
                nativeEvent('item/completed', {
                  'threadId': 'root-thread',
                  'turnId': r'$turn',
                  'item': {
                    'id': 'stale-spawn',
                    'type': 'collabAgentToolCall',
                    'tool': 'spawnAgent',
                    'status': 'completed',
                    'senderThreadId': 'root-thread',
                    'receiverThreadIds': ['child-a'],
                    'prompt': 'delegated task',
                    'agentsStates': {
                      'child-a': {'status': 'completed', 'message': null},
                    },
                  },
                }),
                {
                  'send': {
                    'id': 'live-child-approval',
                    'method': 'item/commandExecution/requestApproval',
                    'params': {
                      'threadId': 'child-a',
                      'turnId': 'child-a-turn',
                      'itemId': 'child-command',
                      'startedAtMs': 1,
                      'command': 'echo child',
                      'cwd': '/fixture',
                      'availableDecisions': ['accept', 'decline'],
                    },
                  },
                },
                {'waitReply': 'live-child-approval'},
                childTurn('child-a', 'completed'),
              ],
            },
          ],
        },
      );
      await f.open();
      final a = await f.start();
      await a.prompt();
      final request = await a.wait(
        Method.agentPermissionRequested,
        within: const Duration(seconds: 3),
      );
      expect(request['title'], contains('child-a'));
      expect(
        (a.of(Method.agentState).last['delegated'] as Json)['activeChildren'],
        1,
      );
      await a.call(Method.agentPermissionReply, {
        'sessionId': a.id,
        'requestId': request['requestId'],
        'optionId': ((request['options'] as List).first as Json)['optionId'],
      });
      await waitFixture(
        f.report,
        (r) => (r['received'] as Json?)?['id'] == 'live-child-approval',
      );
      expect(
        f.requests.singleWhere(
          (r) => r['id'] == 'live-child-approval',
        )['result'],
        {'decision': 'accept'},
      );
      await a.close();
    },
  );
  test(
    'Codex: a spawn item after child registration supplies its task',
    () async {
      final f = NativeFixture(
        profile,
        work,
        script: {
          'turns': [
            {
              'actions': [
                child('child-a', 'root-thread'),
                nativeEvent('item/completed', {
                  'threadId': 'root-thread',
                  'turnId': r'$turn',
                  'item': {
                    'id': 'late-spawn',
                    'type': 'collabAgentToolCall',
                    'tool': 'spawnAgent',
                    'status': 'completed',
                    'senderThreadId': 'root-thread',
                    'receiverThreadIds': ['child-a'],
                    'prompt': 'review the parser',
                    'agentsStates': {
                      'child-a': {'status': 'running', 'message': null},
                    },
                  },
                }),
                terminalEvent('completed'),
              ],
            },
          ],
        },
      );
      await f.open();
      final a = await f.start();
      await a.prompt();
      await a.wait(Method.agentTurnEnded);
      await eventually(
        () => a.events.any(
          (e) => e['kind'] == 'child' && e['text'] == 'review the parser',
        ),
      );
      await a.close();
    },
  );
  for (final replaced in [false, true]) {
    test(
      'Codex: a late child question item cannot outlive its turn replaced=$replaced',
      () async {
        final f = NativeFixture(
          profile,
          work,
          script: {
            'turns': [
              {
                'actions': [
                  child('child-a', 'root-thread'),
                  childTurn('child-a', 'inProgress'),
                  if (replaced)
                    nativeEvent('turn/started', {
                      'threadId': 'child-a',
                      'turn': {
                        'id': 'child-a-next',
                        'status': 'inProgress',
                        'items': <Object?>[],
                        'error': null,
                      },
                    })
                  else
                    childTurn('child-a', 'completed'),
                  nativeEvent('item/completed', {
                    'threadId': 'child-a',
                    'turnId': 'child-a-turn',
                    'item': {
                      'id': 'late-question',
                      'type': 'agentMessage',
                      'text': 'Choose',
                      'questions': [
                        {
                          'title': 'Which?',
                          'options': ['One', 'Two'],
                        },
                      ],
                    },
                  }),
                  terminalEvent('completed'),
                ],
              },
            ],
          },
        );
        await f.open();
        final a = await f.start();
        await a.prompt();
        await a.wait(Method.agentTurnEnded);
        expect(a.of(Method.agentQuestionRequested), isEmpty);
        expect(a.events.where((e) => e['text'] == 'Choose'), isEmpty);
        await a.close();
      },
    );
  }
  test('Codex: a completed child cannot revive a retired approval', () async {
    final f = NativeFixture(
      profile,
      work,
      script: {
        'turns': [
          {
            'actions': [
              child('child-a', 'root-thread'),
              childTurn('child-a', 'inProgress'),
              childTurn('child-a', 'completed'),
              terminalEvent('completed'),
              {
                'send': {
                  'id': 'retired-child',
                  'method': 'item/commandExecution/requestApproval',
                  'params': {
                    'threadId': 'child-a',
                    'turnId': 'child-a-turn',
                    'itemId': 'old',
                    'startedAtMs': 1,
                    'command': 'echo old',
                    'cwd': '/fixture',
                    'availableDecisions': ['accept', 'decline'],
                  },
                },
              },
              {
                'send': {
                  'id': 'child-barrier',
                  'method': 'future/barrier',
                  'params': <String, Object?>{},
                },
              },
            ],
          },
        ],
      },
    );
    await f.open();
    final a = await f.start();
    await a.prompt();
    await waitFixture(
      f.report,
      (r) => (r['received'] as Json?)?['id'] == 'child-barrier',
    );
    expect(a.of(Method.agentPermissionRequested), isEmpty);
    expect(
      f.requests
          .singleWhere((r) => r['id'] == 'retired-child')
          .containsKey('error'),
      true,
    );
    await a.close();
  });
  test(
    'Codex: late child turn completion cannot retire newer work or requests',
    () async {
      Json turn(String id, String status) => nativeEvent(
        status == 'inProgress' ? 'turn/started' : 'turn/completed',
        {
          'threadId': 'child-a',
          'turn': {
            'id': id,
            'status': status,
            'items': <Object?>[],
            'error': null,
          },
        },
      );
      final f = NativeFixture(
        profile,
        work,
        script: {
          'turns': [
            {
              'actions': [
                child('child-a', 'root-thread'),
                turn('t1', 'inProgress'),
                turn('t2', 'inProgress'),
                {
                  'send': {
                    'id': 't2-request',
                    'method': 'item/commandExecution/requestApproval',
                    'params': {
                      'threadId': 'child-a',
                      'turnId': 't2',
                      'itemId': 't2-tool',
                      'startedAtMs': 1,
                      'command': 'echo newer',
                      'cwd': '/fixture',
                      'availableDecisions': ['accept', 'decline'],
                    },
                  },
                },
                turn('t1', 'completed'),
                terminalEvent('completed'),
                {'waitInterrupt': 't2'},
                turn('t2', 'interrupted'),
              ],
            },
          ],
        },
      );
      await f.open();
      final a = await f.start();
      await a.prompt();
      await a.wait(Method.agentPermissionRequested);
      await a.wait(Method.agentTurnEnded);
      expect(a.of(Method.agentState).last['delegated'], {
        'activeChildren': 1,
        'waitingRequests': 1,
        'incomplete': false,
      });
      expect(a.of(Method.agentPermissionResolved), isEmpty);
      await a.call(Method.agentStop);
      expect((await a.wait(Method.agentStopResult))['outcome'], 'stopped');
      final interrupt =
          f.requests.singleWhere(
                (r) => r['method'] == 'turn/interrupt',
              )['params']
              as Json;
      expect(interrupt, {'threadId': 'child-a', 'turnId': 't2'});
      expect(a.of(Method.agentPermissionResolved), hasLength(1));
      await a.close();
    },
  );
  test(
    'Codex: idle-root child async question answers its native thread once',
    () async {
      final release = File(joinPath(work.path, 'child-question-release'));
      final f = NativeFixture(
        profile,
        work,
        script: {
          'turns': [
            {
              'actions': [
                child('child-a', 'root-thread'),
                childTurn('child-a', 'inProgress'),
                terminalEvent('completed'),
                nativeEvent('item/completed', {
                  'threadId': 'child-a',
                  'turnId': 'child-a-turn',
                  'item': {
                    'id': 'child-question',
                    'type': 'agentMessage',
                    'text': 'child-only question',
                    'questions': [
                      {
                        'title': 'Choose child scope',
                        'options': ['One', 'Two'],
                      },
                    ],
                  },
                }),
                {'waitFile': release.path},
                childTurn('child-a', 'completed'),
              ],
            },
          ],
        },
      );
      await f.open();
      final a = await f.start();
      await a.prompt();
      await a.wait(Method.agentTurnEnded);
      final request = await a.wait(Method.agentQuestionRequested);
      expect(request['threadId'], 'child-a');
      expect(request['parentThreadId'], 'root-thread');
      final q = (request['questions'] as List).single as Json;
      final answer = {
        'sessionId': a.id,
        'runId': request['runId'],
        'requestId': request['requestId'],
        'turnId': request['turnId'],
        'answers': [
          {
            'questionId': q['id'],
            'values': [((q['options'] as List).first as Json)['id']],
          },
        ],
      };
      await a.call(Method.agentQuestionAnswer, answer);
      await waitFixture(
        f.report,
        (r) => (r['received'] as Json?)?['method'] == 'turn/steer',
      );
      final steer =
          f.requests.singleWhere((r) => r['method'] == 'turn/steer')['params']
              as Json;
      expect(steer['threadId'], 'child-a');
      expect(steer['expectedTurnId'], 'child-a-turn');
      release.writeAsStringSync('complete child');
      await a.wait(Method.agentQuestionResolved);
      expect(
        (await rpcFailure(a.call(Method.agentQuestionAnswer, answer))).reason,
        ErrorCode.unknownRequest,
      );
      expect(
        f.requests.where((r) => r['method'] == 'turn/steer'),
        hasLength(1),
      );
      await a.close();
    },
  );
  test('Codex: missing child turn identity remains not confirmed with child reason', () async {
    final f = NativeFixture(
      profile,
      work,
      script: {
        'turns': [
          {
            'actions': [
              child('child-a', 'root-thread'),
              terminalEvent('completed'),
            ],
          },
        ],
      },
    );
    await f.open();
    final a = await f.start();
    await a.prompt();
    await a.wait(Method.agentTurnEnded);
    await a.call(Method.agentStop);
    final outcome = await a.wait(
      Method.agentStopResult,
      within: const Duration(seconds: 13),
    );
    expect(outcome['outcome'], 'notConfirmed');
    expect(outcome['message'], contains('child-a'));
    expect(outcome['message'], contains('turn identity unavailable'));
    expect(a.of(Method.agentState).last['state'], 'stopping');
    expect(f.requests.where((r) => r['method'] == 'turn/interrupt'), isEmpty);
    await a.close();
  });
  setUp(() {
    profile = tempDir('codex_protocol_profile_');
    work = tempDir('codex_protocol_work_');
  });
  tearDown(() async {
    killReported(work);
    killReported(profile);
    await deleteTree(work);
    await deleteTree(profile);
  });
  Future<Desktop> desktop(Set<String> caps) async {
    final d = await Desktop.start(
      profile,
      capabilities: {...testCapabilities, ...caps},
      environment: {
        'KUMIKO_TEST_RUNTIME_PATH': '',
        'KUMIKO_TEST_RUNTIME_DIRS': '',
        'KUMIKO_TEST_SHELL_PATH': '',
        'KUMIKO_TEST_CODEX_PROBE_ARGS': jsonEncode([
          '--test-fixture',
          'codex-agent',
          '--script',
          joinPath(work.path, 'scripted.script.json'),
          '--probe',
        ]),
      },
    );
    addTearDown(d.dispose);
    await d.waitState();
    return d;
  }

  Future<(String, File)> seed({bool saved = false}) async {
    final d = await desktop(_codexCaps);
    final w = await d.openWorkspace(work.path);
    final report = await saveAgentFixture(
      d,
      work,
      id: 'scripted',
      script: {'reportLaunch': true},
    );
    if (saved) {
      final a = AgentPeer(d);
      await a.start(w.workspace.id, runtime: 'scripted');
      await a.attach();
      await a.close();
    }
    await d.connection.request(
      Method.runtimeSave,
      RuntimeSaveParams(
        RuntimeProfile(
          id: 'codex',
          name: 'Scripted native candidate',
          runtimeKind: 'codex',
          executable: testHostExecutable(),
          args: [
            '--test-fixture',
            'acp-agent',
            '--script',
            File(joinPath(work.path, 'scripted.script.json')).path,
          ],
          env: const {},
        ),
      ).toJson(),
    );
    await d.dispose();
    if (saved) {
      final db = sqlite3.open(joinPath(profile.path, 'kumiko.db'));
      try {
        db.execute(
          "UPDATE agent_session SET runtime_kind = 'codex', runtime_profile_id = 'codex'",
        );
      } finally {
        db.close();
      }
    }
    if (report.existsSync()) report.deleteSync();
    return (w.workspace.id, report);
  }

  for (final missing in _codexCaps) {
    test(
      'Codex: Older desktop missing $missing refuses before any spawn',
      () async {
        final (workspace, report) = await seed();
        final d = await desktop(_codexCaps.difference({missing}));
        for (var i = 0; i <= maxChannels; i++) {
          final error = await rpcFailure(
            d.connection.request(Method.agentStart, {
              'workspaceId': workspace,
              'runtimeProfileId': 'codex',
            }),
          );
          expect(error.reason, ErrorCode.methodNotAvailable);
          if (missing != Capability.agent) {
            expect(error.message, contains(missing));
          }
        }
        expect(report.existsSync(), isFalse);
        expect(LedgerView(profile).units(), isEmpty);
        expect(agentRows(profile), isEmpty);
      },
    );
  }
  test('Codex: Compatible peers', () async {
    final f = NativeFixture(profile, work);
    await f.open();
    final a = await f.start();
    expect(a.started.adapter.name, 'codex-app-server');
    await a.close();
  });
  test(
    'Codex: Older desktop cannot Continue a saved Codex through an ACP default',
    () async {
      final (_, report) = await seed(saved: true);
      final id = agentRows(profile).single['id'];
      final d = await desktop({Capability.agent, Capability.codex});
      final error = await rpcFailure(
        d.connection.request(Method.agentContinue, {'sessionId': id}),
      );
      expect(error.reason, ErrorCode.methodNotAvailable);
      expect(error.message, contains(Capability.agentExtensionsV1));
      expect(report.existsSync(), isFalse);
      expect(LedgerView(profile).units(), isEmpty);
      expect(agentRows(profile).single['id'], id);
    },
  );
  test(
    'Codex: Prior run sends a late answer and steer without native writes',
    () async {
      final d = await desktop(_codexCaps);
      final w = await d.openWorkspace(work.path);
      final report = await saveAgentFixture(
        d,
        work,
        id: 'claude',
        script: {'reportLaunch': true},
      );
      final a = AgentPeer(d);
      await a.start(w.workspace.id, runtime: 'claude');
      await a.attach();
      final before = fixtureReports(report).length;
      for (final method in [Method.agentSteer, Method.agentQuestionAnswer]) {
        final error = await rpcFailure(
          d.connection.request(method, {
            'sessionId': a.id,
            'runId': 'previous-run',
            'expectedTurnId': 'previous-turn',
            'turnId': 'previous-turn',
            'requestId': 'retired',
            'text': 'do not send',
            'answers': const <Json>[],
          }),
        );
        expect(error.reason, 'stale-run');
      }
      expect(fixtureReports(report).length, before);
      await a.prompt('Claude still works');
      await a.wait(Method.agentTurnEnded);
      await a.close();
    },
  );
  nativeCases(() => profile, () => work);
}

void nativeCases(Directory Function() profile, Directory Function() work) {
  Future<(AgentPeer, Json)> restore(
    NativeFixture f, {
    Future<void> Function(Json)? beforeContinue,
    String? runtimeProfileId,
  }) async {
    await f.open();
    final original = await f.start();
    final row = agentRows(profile()).single;
    await original.close();
    await original.call(Method.agentRelease);
    await beforeContinue?.call(row);
    final peer = AgentPeer(f.desktop);
    final result = AgentContinueResult.fromJson(
      await peer.call(Method.agentContinue, {
        'sessionId': row['id'],
        'runtimeProfileId': ?runtimeProfileId,
      }),
    );
    peer.started = AgentStartResult(
      sessionId: row['id']! as String,
      eventChannel: result.eventChannel,
      adapter: result.adapter,
      capabilities: result.capabilities,
    );
    final duplicate = await rpcFailure(
      peer.call(Method.agentContinue, {'sessionId': row['id']}),
    );
    expect(duplicate.reason, ErrorCode.turnRunning);
    expect(f.requests.where((r) => r['method'] == 'thread/resume'), isEmpty);
    await peer.attach();
    return (peer, row);
  }

  final oldItem = <String, Object?>{
    'id': 'old-answer',
    'type': 'agentMessage',
    'text': 'old answer',
  };
  final oldTurn = <String, Object?>{
    'id': 'old-turn',
    'status': 'completed',
    'itemsView': 'full',
    'items': [oldItem],
  };
  final idleThread = <String, Object?>{
    'id': 'root-thread',
    'status': {'type': 'idle'},
    'historyMode': 'legacy',
    'turns': [oldTurn],
  };
  test('Codex: Nested and restored children', () async {
    Json relation(String id, String parent, String child) => {
      'id': id,
      'type': 'collabAgentToolCall',
      'tool': 'spawnAgent',
      'status': 'completed',
      'senderThreadId': parent,
      'receiverThreadIds': [child],
      'prompt': 'review delegated task',
      'agentsStates': {
        child: {'status': 'completed', 'message': null},
      },
    };
    final f = NativeFixture(
      profile(),
      work(),
      script: {
        'resumeThread': {
          ...idleThread,
          'turns': [
            {
              ...oldTurn,
              'items': [
                relation('spawn-a', 'root-thread', 'child-a'),
                relation('spawn-b', 'child-a', 'child-b'),
                relation('spawn-a', 'root-thread', 'child-a'),
              ],
            },
          ],
        },
      },
    );
    final (a, _) = await restore(f);
    await a.wait(Method.agentState, where: (p) => p['state'] == 'idle');
    await eventually(
      () => a.events.any((e) => e['kind'] == 'replay' && e['phase'] == 'end'),
    );
    final children = a.events.where((e) => e['kind'] == 'child').toList();
    expect(
      children.any(
        (e) => e['threadId'] == 'child-b' && e['parentThreadId'] == 'child-a',
      ),
      true,
    );
    expect(
      children.lastWhere((e) => e['threadId'] == 'child-a')['status'],
      'completed',
    );
    expect((a.of(Method.agentState).last['delegated'] as Json), {
      'activeChildren': 0,
      'waitingRequests': 0,
      'incomplete': false,
    });
    expect(f.requests.where((r) => r['method'] == 'turn/start'), isEmpty);
    expect(
      f.requests.where((r) => r['method'] == 'thread/start'),
      hasLength(1),
    );
    await a.close();
  });
  test('Codex: Another runtime profile is the default', () async {
    final f = NativeFixture(
      profile(),
      work(),
      script: {'resumeThread': idleThread},
    );
    final (peer, row) = await restore(
      f,
      runtimeProfileId: 'replacement',
      beforeContinue: (saved) async {
        await saveAgentFixture(f.desktop, work(), id: 'claude-default');
        await f.desktop.connection.request(
          Method.runtimeSetDefault,
          RuntimeSetDefaultParams('claude-default'),
        );
        await f.desktop.connection.request(
          Method.runtimeRemove,
          const RuntimeRemoveParams('native'),
        );
        final refused = await rpcFailure(
          f.desktop.connection.request(Method.agentContinue, {
            'sessionId': saved['id'],
          }),
        );
        expect(refused.reason, ErrorCode.noRuntimeProfile);
        expect(
          f.requests.where((r) => r['method'] == 'thread/resume'),
          isEmpty,
        );
        await f.desktop.connection.request(
          Method.runtimeSave,
          RuntimeSaveParams(
            RuntimeProfile(
              id: 'replacement',
              name: 'Compatible replacement',
              runtimeKind: 'codex',
              executable: testHostExecutable(),
              args: [
                '--test-fixture',
                'codex-agent',
                '--script',
                f.scriptFile.path,
              ],
              env: const {},
            ),
          ),
        );
      },
    );
    await peer.wait(Method.agentState, where: (p) => p['state'] == 'idle');
    expect(agentRows(profile()).single, row);
    expect(
      f.requests.where((r) => r['method'] == 'thread/resume'),
      hasLength(1),
    );
    expect(f.requests.where((r) => r['method'] == 'turn/start'), isEmpty);
    await peer.close();
  });
  for (final entry in <(String, Json, String)>[
    (
      'Missing native history',
      {
        'readError': {'code': -32600, 'message': 'native thread missing'},
      },
      'native thread missing',
    ),
    (
      'Empty native thread has no resumable history',
      {
        'resumeThread': {...idleThread, 'turns': <Object?>[]},
      },
      'history is empty',
    ),
    (
      'omitted native history is unavailable',
      {
        'resumeThread': {
          for (final e in idleThread.entries)
            if (e.key != 'turns') e.key: e.value,
        },
      },
      'history was omitted',
    ),
    (
      'summary is not full native history',
      {
        'resumeThread': {
          ...idleThread,
          'turns': [
            {...oldTurn, 'itemsView': 'summary'},
          ],
        },
      },
      'history is incomplete',
    ),
    (
      'currently active native root is refused',
      {
        'readThread': {
          ...idleThread,
          'status': {'type': 'active', 'activeFlags': <Object?>[]},
        },
      },
      'active',
    ),
    (
      'native resume cannot substitute identity',
      {
        'resumeThread': {...idleThread, 'id': 'replacement-thread'},
      },
      'identity changed',
    ),
    (
      'oversized native history is unavailable',
      {
        'resumeThread': {
          ...idleThread,
          'turns': [
            {
              ...oldTurn,
              'items': [
                for (var i = 0; i < 6; i++)
                  {...oldItem, 'id': 'old-$i', 'text': 'x' * 65536},
              ],
            },
          ],
        },
      },
      'display capacity',
    ),
  ]) {
    test('Codex: ${entry.$1}', () async {
      final f = NativeFixture(profile(), work(), script: entry.$2);
      final (peer, row) = await restore(f);
      final ended = await peer.wait(
        Method.agentExited,
        within: const Duration(seconds: 4),
      );
      expect(ended['error'], ErrorCode.resumeUnavailable);
      expect(ended['message'], contains(entry.$3));
      expect(agentRows(profile()).single, row);
      expect(f.requests.where((r) => r['method'] == 'turn/start'), isEmpty);
      expect(LedgerView(profile()).units(), isEmpty);
    });
  }
  test('Codex: Qualified native recovery', () async {
    final f = NativeFixture(
      profile(),
      work(),
      script: {
        'readThread': {
          ...idleThread,
          'historyMode': 'paginated',
          'status': {'type': 'notLoaded'},
        },
        'afterReadThread': {...idleThread, 'historyMode': 'paginated'},
        'resumeThread': {
          ...idleThread,
          'historyMode': 'paginated',
          'turns': <Object?>[],
        },
        'historyPages': [
          {
            'data': [
              {'turnId': 'old-turn', 'item': oldItem},
            ],
            'nextCursor': 'actual-native-cursor',
          },
          {
            'data': [
              {
                'turnId': 'old-turn',
                'item': {...oldItem, 'id': 'last', 'text': 'last answer'},
              },
            ],
            'nextCursor': null,
          },
        ],
        'historyBeforePage': [
          nativeEvent('item/completed', {
            'threadId': r'$thread',
            'turnId': 'old-turn',
            'item': oldItem,
          }),
        ],
      },
    );
    final (peer, row) = await restore(f);
    await peer.wait(Method.agentState, where: (p) => p['state'] == 'idle');
    await eventually(() => peer.events.any((e) => e['phase'] == 'end'));
    expect(
      peer.events.where((e) => e['kind'] == 'agentText').map((e) => e['text']),
      ['old answer', 'last answer'],
    );
    final pages = f.requests
        .where((r) => r['method'] == 'thread/items/list')
        .toList();
    expect(pages, hasLength(2));
    expect((pages.last['params'] as Json)['cursor'], 'actual-native-cursor');
    expect(pages.every((p) => (p['params'] as Json)['limit'] == 50), true);
    expect(agentRows(profile()).single, row);
    await peer.close();
  });
  test(
    'Codex: a collaboration item seen live during restore deduplicates',
    () async {
      final collab = <String, Object?>{
        'id': 'spawn',
        'type': 'collabAgentToolCall',
        'tool': 'spawnAgent',
        'senderThreadId': 'root-thread',
        'receiverThreadIds': ['restored-child'],
        'agentsStates': {
          'restored-child': {'status': 'completed', 'message': null},
        },
      };
      final f = NativeFixture(
        profile(),
        work(),
        script: {
          'readThread': {
            ...idleThread,
            'historyMode': 'paginated',
            'status': {'type': 'notLoaded'},
          },
          'afterReadThread': {...idleThread, 'historyMode': 'paginated'},
          'resumeThread': {
            ...idleThread,
            'historyMode': 'paginated',
            'turns': <Object?>[],
          },
          'historyPages': [
            {
              'data': [
                {'turnId': 'old-turn', 'item': oldItem},
                {'turnId': 'old-turn', 'item': collab},
              ],
              'nextCursor': null,
            },
          ],
          'historyBeforePage': [
            nativeEvent('item/completed', {
              'threadId': r'$thread',
              'turnId': 'old-turn',
              'item': collab,
            }),
          ],
        },
      );
      final (peer, row) = await restore(f);
      await peer.wait(Method.agentState, where: (p) => p['state'] == 'idle');
      await eventually(() => peer.events.any((e) => e['phase'] == 'end'));
      expect(
        peer.events.where(
          (e) =>
              e['kind'] == 'notice' &&
              (e['text'] as String).contains('history changed'),
        ),
        isEmpty,
      );
      expect(
        peer.events
            .where((e) => e['kind'] == 'agentText')
            .map((e) => e['text']),
        ['old answer'],
      );
      expect(agentRows(profile()).single, row);
      await peer.close();
    },
  );
  test(
    'Codex: paged history exceeds the dedup window with visible loss',
    () async {
      final f = NativeFixture(
        profile(),
        work(),
        script: {
          'readThread': {
            ...idleThread,
            'historyMode': 'paginated',
            'status': {'type': 'notLoaded'},
          },
          'afterReadThread': {...idleThread, 'historyMode': 'paginated'},
          'resumeThread': {...idleThread, 'historyMode': 'paginated'},
          'historyPages': [
            for (var page = 0; page < 84; page++)
              {
                'data': [
                  for (var i = page * 50; i < (page + 1) * 50; i++)
                    {
                      'turnId': 'old-turn',
                      'item': {
                        ...oldItem,
                        'id': 'item-$i',
                        'text': 'history-$i',
                      },
                    },
                ],
                'nextCursor': page == 83 ? null : 'cursor-${page + 1}',
              },
          ],
        },
      );
      final (peer, row) = await restore(f);
      await peer.wait(
        Method.agentState,
        where: (p) => p['state'] == 'idle',
        within: const Duration(seconds: 8),
      );
      await eventually(() => peer.events.any((e) => e['phase'] == 'end'));
      expect(
        peer.events.where((e) => e['kind'] == 'agentText'),
        hasLength(4200),
      );
      expect(
        peer.events.any(
          (e) => e['kind'] == 'notice' && e['text'].toString().contains('4096'),
        ),
        true,
      );
      expect(agentRows(profile()).single, row);
      await peer.close();
    },
  );
  test('Codex: Unsupported recovery', () async {
    final f = NativeFixture(
      profile(),
      work(),
      script: {
        'readThread': {
          ...idleThread,
          'historyMode': 'paginated',
          'status': {'type': 'notLoaded'},
        },
        'resumeThread': {...idleThread, 'historyMode': 'paginated'},
        'historyPages': [
          {'notData': <Object?>[]},
        ],
      },
    );
    final (peer, row) = await restore(f);
    final ended = await peer.wait(
      Method.agentExited,
      within: const Duration(seconds: 4),
    );
    expect(ended['error'], ErrorCode.resumeUnavailable);
    expect(ended['message'], contains('item history was omitted'));
    expect(agentRows(profile()).single, row);
    expect(f.requests.where((r) => r['method'] == 'turn/start'), isEmpty);
  });
  test('Codex: history mutation during snapshot refuses restoration', () async {
    final f = NativeFixture(
      profile(),
      work(),
      script: {
        'resumeActions': [deltaEvent('unowned work')],
        'resumeThread': {
          'id': 'root-thread',
          'historyMode': 'legacy',
          'status': {'type': 'idle'},
          'turns': [
            {
              'id': 'old-turn',
              'status': 'completed',
              'items': [
                {
                  'id': 'old-answer',
                  'type': 'agentMessage',
                  'text': 'old answer',
                },
              ],
            },
          ],
        },
      },
    );
    await f.open();
    final original = await f.start();
    final row = agentRows(profile()).single;
    await original.close();
    await original.call(Method.agentRelease);
    final peer = AgentPeer(f.desktop);
    final r = AgentContinueResult.fromJson(
      await peer.call(Method.agentContinue, {'sessionId': row['id']}),
    );
    peer.started = AgentStartResult(
      sessionId: row['id']! as String,
      eventChannel: r.eventChannel,
      adapter: r.adapter,
      capabilities: r.capabilities,
    );
    await peer.attach();
    final ended = await peer.wait(
      Method.agentExited,
      within: const Duration(seconds: 3),
    );
    expect(ended['error'], ErrorCode.resumeUnavailable);
    expect(ended['message'], contains('changed during history'));
    expect(agentRows(profile()).single, row);
    expect(f.requests.where((r) => r['method'] == 'turn/start'), isEmpty);
  });
  test('Codex: Continue a saved thread', () async {
    final f = NativeFixture(
      profile(),
      work(),
      script: {
        'resumeThread': {
          'id': 'root-thread',
          'historyMode': 'legacy',
          'status': {'type': 'idle'},
          'turns': [
            {
              'id': 'old-turn',
              'status': 'completed',
              'itemsView': 'full',
              'items': [
                {
                  'id': 'old-user',
                  'type': 'userMessage',
                  'content': [
                    {'type': 'text', 'text': 'original prompt'},
                  ],
                },
                {
                  'id': 'old-reply',
                  'type': 'agentMessage',
                  'text': 'original answer',
                },
              ],
            },
          ],
        },
      },
    );
    await f.open();
    final original = await f.start();
    final row = agentRows(profile()).single;
    await original.close();
    await original.call(Method.agentRelease);
    final peer = AgentPeer(f.desktop);
    final resumed = AgentContinueResult.fromJson(
      await peer.call(Method.agentContinue, {'sessionId': row['id']}),
    );
    peer.started = AgentStartResult(
      sessionId: row['id']! as String,
      eventChannel: resumed.eventChannel,
      adapter: resumed.adapter,
      capabilities: resumed.capabilities,
    );
    expect(f.requests.where((r) => r['method'] == 'thread/resume'), isEmpty);
    await peer.attach();
    await peer.wait(Method.agentState, where: (s) => s['state'] == 'idle');
    await eventually(
      () =>
          peer.events.any((e) => e['kind'] == 'replay' && e['phase'] == 'end'),
    );
    expect(
      peer.events.where((e) => e['kind'] == 'user').map((e) => e['text']),
      ['original prompt'],
    );
    expect(
      peer.events.where((e) => e['kind'] == 'agentText').map((e) => e['text']),
      ['original answer'],
    );
    expect(f.requests.where((r) => r['method'] == 'turn/start'), isEmpty);
    expect(
      f.requests.where((r) => r['method'] == 'thread/start'),
      hasLength(1),
    );
    expect(agentRows(profile()).single, row);
    await peer.close();
  });

  test('Codex: content-free audit cause maps attach without changing failure semantics', () async {
    final home = tempDir('audit_diag_home_');
    addTearDown(() => deleteTree(home));
    final f = NativeFixture(
      profile(),
      work(),
      script: {
        'initialize': {
          'userAgent': 'codex/0.166.0',
          'platformFamily': 'windows',
          'platformOs': 'windows',
          'codexHome': home.path,
        },
      },
    );
    await f.open(env: {'KUMIKO_TEST_CODEX_AUDIT_HOME': home.path});
    await f.desktop.connection.request('test/codex.audit.prepare', {});
    File(joinPath(home.path, 'models_cache.json'))
        .writeAsStringSync('PRIVATE_CONTENT');
    final a = await f.start();
    await a.close();
    final result = await f.desktop.connection.request('test/agent.stats', {
      'secretScanSessionId': a.id,
      'secretScanRoots': [home.path, joinPath(work().path, 'PRIVATE_MISSING')],
    }) as Json;
    final audit = result['secretAudit'] as Json;
    expect(audit['errorCount'], 2);
    expect(audit['complete'], false);
    expect(audit['matchedFiles'], 0);
    expect((audit['nativeErrorCategories'] as Json)['changedUnknownFile'], 1);
    expect((audit['nativeUnknownArtifactCategories'] as Json)['modelCache'], 1);
    expect((audit['rootErrorCategories'] as Json)['nonDirectory'], 1);
    expect(jsonEncode(audit), isNot(contains('PRIVATE_')));
    expect(jsonEncode(audit), isNot(contains(home.path)));
  });
  Future<NativeFixture> fixture([
    Json script = const {},
    Map<String, String> env = const {},
  ]) async {
    final f = NativeFixture(profile(), work(), script: script);
    await f.open(env: env);
    return f;
  }

  Future<RpcException> refusedStart(NativeFixture f) => rpcFailure(
    f.desktop.connection.request(Method.agentStart, {
      'workspaceId': f.workspace,
      'runtimeProfileId': 'native',
    }),
  );
  for (final resume in [false, true]) {
    test(
      'Codex: private MCP entry preserves unrelated CLI probe on ${resume ? 'resume' : 'start'}',
      () async {
        final probe = <String, Object?>{
          'command': 'inert-fixture-probe',
          'args': ['literal argument'],
          'env': {'PROBE_ONLY': 'unrelated'},
        };
        final f = NativeFixture(
          profile(),
          work(),
          script: {
            'cliOverrides': [
              {
                'key': 'mcp_servers.unrelated_probe.command',
                'value': probe['command'],
              },
              {
                'key': 'mcp_servers.unrelated_probe.args',
                'value': probe['args'],
              },
              {'key': 'mcp_servers.unrelated_probe.env', 'value': probe['env']},
            ],
            if (resume) 'resumeThread': idleThread,
          },
        );
        final AgentPeer a;
        if (resume) {
          (a, _) = await restore(f);
          await a.wait(
            Method.agentState,
            where: (state) => state['state'] == 'idle',
          );
        } else {
          await f.open();
          a = await f.start();
        }
        final facts = f.reports
            .where((r) => r.containsKey('mcpConfiguration'))
            .map((r) => r['mcpConfiguration'] as Json)
            .toList();
        expect(facts, hasLength(resume ? 2 : 1));
        for (final fact in facts.reversed) {
          expect(fact['entries'], containsAll(['kumiko', 'unrelated_probe']));
          expect(fact['probe'], probe);
          expect(fact['privateEnvironmentOnlyInKumiko'], true);
          expect(fact['kumikoHasPrivateEnvironment'], true);
        }
        expect(facts.last['method'], resume ? 'thread/resume' : 'thread/start');
        await a.close();
      },
    );
  }
  test('Codex: Start native Codex', () async {
    final f = await fixture();
    final a = await f.start();
    expect(a.started.adapter.name, 'codex-app-server');
    expect(a.started.adapter.version, '0.166.0');
    final launches = f.reports.where((r) => r.containsKey('launch')).toList();
    expect(launches.map((r) => r['launch']), ['probe', 'root']);
    expect(launches.first['cwd'], profile().path);
    expect(launches.first['unit'], true);
    expect(launches.first['parentCanary'], false);
    expect(launches.first['profileCanary'], false);
    expect(launches.last['cwd'], work().path);
    expect(launches.every((r) => r['secret'] == false), true);
    expect(f.requests.map((r) => r['method']), [
      'initialize',
      'initialized',
      'config/read',
      'thread/start',
    ]);
    final stats =
        await f.desktop.connection.request('test/agent.stats', {}) as Json;
    expect(((stats['sessions'] as Json)[a.id] as Json)['hasGrant'], true);
    expect(a.started.tools!.status, AgentToolsStatus.notYetUsed);
    final config = (f.requests.last['params'] as Json)['config'] as Json;
    expect(config.keys, ['mcp_servers.kumiko']);
    final entry = config['mcp_servers.kumiko'] as Json;
    expect((entry['env'] as Json)['KUMIKO_TOOL_SECRET'], '<redacted>');
    await a.close();
  });
  test('Codex: Initialization fails', () async {
    final f = await fixture({
      'initialize': {'userAgent': 4},
    });
    for (var i = 0; i < 3; i++) {
      final e = await refusedStart(f);
      expect(e.reason, ErrorCode.adapterProtocol);
      expect(LedgerView(profile()).units(), isEmpty);
      expect(agentRows(profile()), isEmpty);
    }
    expect(f.requests.where((r) => r['method'] == 'initialize'), hasLength(3));
  });
  test(
    'Codex: contained version probe timeout cleans unit and channel',
    () async {
      final f = await fixture({'probeDelayMs': 6000});
      final e = await refusedStart(f);
      expect(e.message, contains('probe'));
      expect(e.message, contains('timed out'));
      expect(f.reports.where((r) => r['launch'] == 'probe'), hasLength(1));
      expect(f.reports.where((r) => r['launch'] == 'root'), isEmpty);
      expect(LedgerView(profile()).units(), isEmpty);
    },
  );
  for (final early in [false, true]) {
    test('Codex: Start acknowledgement precedes output early=$early', () async {
      final actions = [deltaEvent('first'), terminalEvent('completed')];
      final f = await fixture({
        'turns': [
          early
              ? {'beforeResponse': actions, 'actions': <Json>[]}
              : {
                  'actions': [
                    {'delayMs': 100},
                    ...actions,
                  ],
                },
        ],
      });
      final a = await f.start();
      await a.prompt('one');
      await a.wait(Method.agentTurnEnded);
      expect(
        a.events.where((e) => e['kind'] == 'agentText').map((e) => e['text']),
        ['first'],
      );
      await a.prompt('two');
      await a.wait(
        Method.agentTurnEnded,
        where: (_) => a.of(Method.agentTurnEnded).length == 2,
      );
      expect(
        f.requests.where((r) => r['method'] == 'turn/start'),
        hasLength(2),
      );
      await a.close();
    });
  }
  for (final status in ['interrupted', 'completed', 'failed']) {
    test('Codex: Native interruption succeeds status=$status', () async {
      final f = await fixture({
        'turns': [
          {
            'actions': [
              {'waitInterrupt': true},
              terminalEvent(status),
            ],
          },
        ],
      });
      final a = await f.start();
      await a.prompt();
      await a.wait(Method.agentState, where: (p) => p['turnId'] != null);
      await a.call(Method.agentStop);
      final result = await a.wait(Method.agentStopResult);
      expect(
        result['outcome'],
        status == 'interrupted'
            ? 'stopped'
            : status == 'failed'
            ? 'endedWithError'
            : 'finishedFirst',
      );
      expect(LedgerView(profile()).units(), hasLength(1));
      await a.close();
    });
  }
  test('Codex: Parent information is missing', () async {
    final f = await fixture({
      'turns': [
        {
          'actions': [
            deltaEvent('child secret content', thread: 'unknown-child'),
            deltaEvent('root text'),
            terminalEvent('completed'),
          ],
        },
      ],
    });
    final a = await f.start();
    await a.prompt();
    await a.wait(Method.agentTurnEnded);
    expect(a.events.toString(), isNot(contains('child secret content')));
    expect(a.events.toString(), contains('unknown child'));
    expect(a.events.toString(), contains('root text'));
    await a.close();
  });
  test('Codex: startup protocol EOF preserves bounded stderr and status after cleanup', () async {
    final f = await fixture({
      'newActions': [
        {'stderr': 'fixture early native stderr'},
        {'closeStdout': true},
      ],
    });
    final error = await refusedStart(f);
    expect(error.reason, ErrorCode.adapterProtocol);
    expect(error.data['stage'], 'session/new');
    expect(
      error.data['detail'].toString().contains('fixture early native stderr'),
      true,
    );
    expect(error.data['status'], isA<int>());
    expect(error.message.contains('fixture early native stderr'), true);
    expect(utf8.encode(error.message).length, lessThanOrEqualTo(4096));
    expect(LedgerView(profile()).units(), isEmpty);
  });
  test('Codex: Experimental metadata changes in a newer version', () async {
    final f = await fixture({
      'version': 'codex-cli 0.167.0',
      'turns': [
        {
          'actions': [
            nativeEvent('thread/started', {
              'thread': {
                'id': 'future-child',
                'parentThreadId': {'futureShape': 'root-thread'},
                'status': {'type': 'active'},
              },
            }),
            deltaEvent('newer root first reply'),
            terminalEvent('completed'),
          ],
        },
        {
          'actions': [
            {
              'send': {
                'id': 'future-root-approval',
                'method': 'item/commandExecution/requestApproval',
                'params': {
                  'threadId': r'$thread',
                  'turnId': r'$turn',
                  'itemId': 'root-command',
                  'startedAtMs': 1,
                  'command': 'echo root still works',
                  'cwd': '/fixture',
                  'availableDecisions': ['accept', 'decline'],
                },
              },
            },
            {'waitReply': 'future-root-approval'},
            deltaEvent('newer root second reply'),
            {'waitInterrupt': true},
            terminalEvent('interrupted'),
          ],
        },
      ],
    });
    final agent = await f.start();
    expect(agent.started.adapter.version, '0.167.0');
    await agent.prompt('first root prompt');
    await agent.wait(Method.agentTurnEnded);
    await eventually(
      () => agent.events.any(
        (event) =>
            event['kind'] == 'notice' &&
            event['text'].toString().contains(
              'relationship metadata unavailable',
            ),
      ),
    );
    expect(
      (agent.of(Method.agentState).last['delegated'] as Json)['incomplete'],
      true,
    );
    expect(
      agent.events.any(
        (event) =>
            event['kind'] == 'agentText' &&
            event['text'] == 'newer root first reply',
      ),
      true,
    );
    await agent.prompt('second root prompt');
    final approval = await agent.wait(Method.agentPermissionRequested);
    final accept = (approval['options'] as List).cast<Json>().firstWhere(
      (option) => option['name'] == 'accept',
    );
    await agent.call(Method.agentPermissionReply, {
      'sessionId': agent.id,
      'requestId': approval['requestId'],
      'optionId': accept['optionId'],
    });
    await waitFixture(
      f.report,
      (row) => (row['received'] as Json?)?['id'] == 'future-root-approval',
    );
    expect(
      f.requests.singleWhere(
        (message) => message['id'] == 'future-root-approval',
      )['result'],
      {'decision': 'accept'},
    );
    await eventually(
      () => agent.events.any(
        (event) =>
            event['kind'] == 'agentText' &&
            event['text'] == 'newer root second reply',
      ),
    );
    await agent.call(Method.agentStop);
    await agent.wait(
      Method.agentTurnEnded,
      where: (_) => agent.of(Method.agentTurnEnded).length == 2,
    );
    final stopped = await agent.wait(
      Method.agentStopResult,
      within: const Duration(seconds: 14),
    );
    expect(
      stopped['outcome'],
      'notConfirmed',
      reason: 'unknown delegated work must not become confirmed stopped',
    );
    final interrupt = f.requests.singleWhere(
      (message) => message['method'] == 'turn/interrupt',
    );
    expect(interrupt['params'], {
      'threadId': 'root-thread',
      'turnId': 'turn-2',
    });
    expect(
      f.requests.where((message) => message['method'] == 'turn/start'),
      hasLength(2),
    );
    expect(LedgerView(profile()).units(), hasLength(1));
    await agent.close();
  });
  final requestedPreviewScope = <String, Object?>{
    'network': {'enabled': true},
    'fileSystem': {
      'entries': [
        {
          'access': 'write',
          'path': {'type': 'path', 'path': 'C:/approval-scope'},
        },
        {
          'access': 'deny',
          'path': {'type': 'glob_pattern', 'pattern': '**/private*'},
        },
      ],
      'globScanMaxDepth': 2,
    },
  };
  final previewCases =
      <
        ({
          String name,
          String method,
          Json params,
          List<String> fragments,
          Json result,
        })
      >[
        (
          name: 'command includes cwd and reason',
          method: 'item/commandExecution/requestApproval',
          params: {
            'command': 'echo approval-preview',
            'cwd': 'C:/native-command-cwd',
            'reason': 'Needed for the requested build',
            'availableDecisions': ['decline', 'accept'],
          },
          fragments: [
            'echo approval-preview',
            'C:/native-command-cwd',
            'Needed for the requested build',
          ],
          result: {'decision': 'accept'},
        ),
        (
          name: 'file includes grant root and reason',
          method: 'item/fileChange/requestApproval',
          params: {
            'grantRoot': 'C:/native-file-grant',
            'reason': 'Needed for generated files',
          },
          fragments: ['C:/native-file-grant', 'Needed for generated files'],
          result: {'decision': 'accept'},
        ),
        (
          name: 'additional permissions include the requested scope',
          method: 'item/permissions/requestApproval',
          params: {
            'cwd': 'C:/native-permission-cwd',
            'reason': 'Needed for scoped access',
            'permissions': requestedPreviewScope,
          },
          fragments: [
            'C:/native-permission-cwd',
            'Needed for scoped access',
            'network',
            'enabled',
            'true',
            'C:/approval-scope',
            'deny',
            '**/private*',
            'globScanMaxDepth',
          ],
          result: {'permissions': requestedPreviewScope, 'scope': 'turn'},
        ),
      ];
  for (final previewCase in previewCases) {
    test('Codex: approval preview ${previewCase.name}', () async {
      final f = await fixture({
        'turns': [
          {
            'actions': [
              {
                'send': {
                  'id': 'preview-approval',
                  'method': previewCase.method,
                  'params': {
                    'threadId': r'$thread',
                    'turnId': r'$turn',
                    'itemId': 'preview-item',
                    'startedAtMs': 1,
                    ...previewCase.params,
                  },
                },
              },
              {'waitReply': 'preview-approval'},
              terminalEvent('completed'),
            ],
          },
        ],
      });
      final a = await f.start();
      await a.prompt();
      final permission = await a.wait(Method.agentPermissionRequested);
      for (final fragment in previewCase.fragments) {
        expect(permission['preview'], contains(fragment));
      }
      expect(permission['truncated'] ?? false, false);
      expect(f.requests.where((m) => m['id'] == 'preview-approval'), isEmpty);
      final offered = (permission['options'] as List).cast<Json>();
      final choice = offered.firstWhere((o) => o['kind'] == 'allow_once');
      await a.call(Method.agentPermissionReply, {
        'sessionId': a.id,
        'requestId': permission['requestId'],
        'optionId': choice['optionId'],
      });
      await a.wait(Method.agentTurnEnded);
      expect(
        f.requests.where((m) => m['id'] == 'preview-approval').single['result'],
        previewCase.result,
      );
      await a.close();
    });
  }
  for (final mode in ['text', 'encoded', 'choice']) {
    final encoded = mode == 'encoded';
    final choice = mode == 'choice';
    final command = encoded || choice;
    test(
      choice
          ? 'Codex: approval preview refuses partial native decision scope'
          : 'Codex: approval preview overflow refuses partial scope encoded=$encoded',
      () async {
        final scope = <String, Object?>{
          'fileSystem': {
            'write': ['C:/${List.filled(17000, 'x').join()}'],
          },
        };
        final details = <String, Object?>{
          if (command) ...{
            'command': 'echo preview',
            'cwd': 'C:/native-cwd',
            'reason': encoded
                ? List.filled(10750, '\u0001').join()
                : 'Apply the requested command policy',
            'availableDecisions': choice
                ? [
                    // An oversize string name still refuses; object labels
                    // are indexed (see Codex decision display).
                    'future-command-scope-${List.filled(300, 'x').join()}',
                    'decline',
                  ]
                : List.filled(16, 'decline'),
          } else ...{
            'cwd': 'C:/native-cwd',
            'reason': 'Requested write access',
            'permissions': scope,
          },
        };
        final params = <String, Object?>{
          'threadId': r'$thread',
          'turnId': r'$turn',
          'itemId': 'preview-item',
          'startedAtMs': 1,
          ...details,
        };
        expect(utf8.encode(jsonEncode(params)).length, lessThan(64 * 1024));
        final f = await fixture({
          'turns': [
            {
              'actions': [
                {
                  'send': {
                    'id': 'overflow-preview',
                    'method': command
                        ? 'item/commandExecution/requestApproval'
                        : 'item/permissions/requestApproval',
                    'params': params,
                  },
                },
                {'waitReply': 'overflow-preview'},
                terminalEvent('completed'),
              ],
            },
          ],
        });
        final a = await f.start();
        await a.prompt();
        await eventually(
          () =>
              a.of(Method.agentPermissionRequested).isNotEmpty ||
              f.requests.any((m) => m['id'] == 'overflow-preview'),
        );
        expect(
          a.of(Method.agentPermissionRequested).isEmpty,
          isTrue,
          reason: 'truncated approval scope must not be offered',
        );
        await a.wait(Method.agentTurnEnded);
        expect(
          f.requests
              .where((m) => m['id'] == 'overflow-preview')
              .single['result'],
          command
              ? {'decision': 'cancel'}
              : {'permissions': <String, Object?>{}, 'scope': 'turn'},
        );
        await eventually(
          () => a.events.any(
            (e) =>
                e['kind'] == 'notice' &&
                e['text'].toString().contains('capacity'),
          ),
        );
        final notice = a.events
            .where(
              (e) =>
                  e['kind'] == 'notice' &&
                  e['text'].toString().startsWith(
                    'Native approval unavailable: full details exceed display capacity;',
                  ),
            )
            .single;
        final text = notice['text']! as String;
        expect(text, contains(' [display-v1 '));
        expect(text, isNot(contains('future-command-scope')));
        expect(utf8.encode(text).length, lessThan(1024));
        await a.close();
      },
    );
  }
  for (final surface in [
    'error',
    'tool title',
    'stderr tail',
    'truncated text',
  ]) {
    test(
      'Codex: clipped $surface never exposes a known secret boundary',
      () async {
        final f = await fixture();
        final report = await saveAgentFixture(
          f.desktop,
          work(),
          id: 'boundary-secret-owner',
        );
        final owner = AgentPeer(f.desktop);
        await owner.start(f.workspace, runtime: 'boundary-secret-owner');
        await owner.attach();
        final launch = await waitFixture(
          report,
          (row) => row['mcpServers'] is List,
        );
        final server = (launch['mcpServers'] as List).single as Json;
        final secret =
            ((server['env'] as List).cast<Json>().firstWhere(
                  (entry) => entry['name'] == 'KUMIKO_TOOL_SECRET',
                )['value'])!
                as String;
        expect(secret.length == 43, true);
        final fragment = surface == 'stderr tail'
            ? secret.substring(1)
            : secret.substring(0, 42);
        final clipped = '${List.filled(4096 - 42, 'x').join()}${secret}end';
        final script = jsonDecode(f.scriptFile.readAsStringSync()) as Json;
        if (surface == 'stderr tail') {
          script['newActions'] = [
            {'stderr': '$secret${List.filled(4096 - 42, 'x').join()}'},
          ];
          script['startError'] = {
            'code': -32001,
            'message': 'fixture startup refused',
          };
        } else if (surface == 'truncated text') {
          script['turns'] = [
            {
              'actions': [
                deltaEvent(
                  '${List.filled(1024 * 1024 - 42, 'x').join()}${secret}end',
                ),
                deltaEvent('unrelated next delta'),
                terminalEvent('completed'),
              ],
            },
          ];
        } else if (surface == 'error') {
          script['turns'] = [
            {
              'error': {'code': -32001, 'message': clipped},
            },
          ];
        } else {
          script['turns'] = [
            {
              'actions': [
                nativeEvent('item/completed', {
                  'threadId': r'$thread',
                  'turnId': r'$turn',
                  'item': {
                    'id': 'boundary-tool',
                    'type': 'commandExecution',
                    'command': clipped,
                    'cwd': '/fixture',
                    'commandActions': <Object?>[],
                    'status': 'completed',
                    'aggregatedOutput': 'done',
                  },
                }),
                terminalEvent('completed'),
              ],
            },
          ];
        }
        f.scriptFile.writeAsStringSync(jsonEncode(script));
        await owner.close();
        String public;
        if (surface == 'stderr tail') {
          final error = await refusedStart(f);
          public = '${error.message}${jsonEncode(error.data)}';
        } else {
          final agent = await f.start();
          await agent.prompt();
          await agent.wait(Method.agentTurnEnded);
          if (surface == 'tool title') {
            await eventually(
              () => agent.events.any((event) => event['kind'] == 'toolUpdate'),
            );
          }
          if (surface == 'truncated text') {
            await eventually(
              () => agent.events.any(
                (event) =>
                    event['kind'] == 'agentText' &&
                    event['text'].toString().contains('unrelated next delta'),
              ),
            );
          }
          public = '${agent.events}${agent.notifications}';
          await agent.close();
        }
        // Only booleans reach a failing assertion, never this ephemeral grant.
        expect(public.contains(fragment), false);
        expect(public.contains('<redacted>'), true);
      },
    );
  }
  test(
    'Codex: approval preview redacts live and revoked scope secrets',
    () async {
      final f = await fixture();
      final report = await saveAgentFixture(
        f.desktop,
        work(),
        id: 'preview-secret-owner',
      );
      final owner = AgentPeer(f.desktop);
      await owner.start(f.workspace, runtime: 'preview-secret-owner');
      await owner.attach();
      final launch = await waitFixture(report, (r) => r['mcpServers'] is List);
      final server = (launch['mcpServers'] as List).single as Json;
      final secret =
          ((server['env'] as List).cast<Json>().firstWhere(
                (e) => e['name'] == 'KUMIKO_TOOL_SECRET',
              )['value'])!
              as String;
      final script = jsonDecode(f.scriptFile.readAsStringSync()) as Json;
      script['turns'] = [
        for (var turn = 0; turn < 2; turn++)
          {
            'actions': [
              {
                'send': {
                  'id': 'secret-preview-$turn',
                  'method': 'item/permissions/requestApproval',
                  'params': {
                    'threadId': r'$thread',
                    'turnId': r'$turn',
                    'itemId': 'scope-$turn',
                    'startedAtMs': 1,
                    'cwd': 'C:/native-cwd',
                    'permissions': {
                      'fileSystem': {
                        'write': ['C:/$secret/scope'],
                      },
                    },
                  },
                },
              },
              {'waitReply': 'secret-preview-$turn'},
              terminalEvent('completed'),
            ],
          },
      ];
      f.scriptFile.writeAsStringSync(jsonEncode(script));
      final a = await f.start();
      for (var turn = 0; turn < 2; turn++) {
        if (turn == 1) await owner.close();
        await a.prompt();
        final permission = await a.wait(
          Method.agentPermissionRequested,
          where: (p) =>
              p['requestId'] !=
              (turn == 0
                  ? null
                  : a.of(Method.agentPermissionRequested).first['requestId']),
        );
        final preview = permission['preview']! as String;
        // Boolean assertions keep even a failing redaction test from logging
        // the temporary credential it is intended to protect.
        expect(preview.contains(secret), isFalse);
        expect(preview.contains('<redacted>'), isTrue);
        final decline = (permission['options'] as List).cast<Json>().firstWhere(
          (o) => o['kind'] == 'reject_once',
        );
        await a.call(Method.agentPermissionReply, {
          'sessionId': a.id,
          'requestId': permission['requestId'],
          'optionId': decline['optionId'],
        });
        await a.wait(
          Method.agentTurnEnded,
          where: (_) => a.of(Method.agentTurnEnded).length == turn + 1,
        );
      }
      await a.close();
    },
  );
  Future<void> commandDecisionCase(
    Json params, {
    List<Object?>? offered,
    int selected = 0,
    bool child = false,
  }) async {
    final f = await fixture({
      'turns': [
        {
          'actions': [
            if (child) ...[
              nativeEvent('thread/started', {
                'thread': {
                  'id': 'approval-child',
                  'parentThreadId': 'root-thread',
                  'status': {'type': 'active'},
                },
              }),
              nativeEvent('turn/started', {
                'threadId': 'approval-child',
                'turn': {
                  'id': 'child-turn',
                  'status': 'inProgress',
                  'items': <Object?>[],
                },
              }),
            ],
            {
              'send': {
                'id': 'command-decisions',
                'method': 'item/commandExecution/requestApproval',
                'params': {
                  'threadId': child ? 'approval-child' : r'$thread',
                  'turnId': child ? 'child-turn' : r'$turn',
                  'itemId': 'cmd',
                  'startedAtMs': 1,
                  'command': 'echo fixture',
                  ...params,
                },
              },
            },
            {'waitReply': 'command-decisions'},
            terminalEvent('completed'),
          ],
        },
        {
          'actions': [
            deltaEvent('later root reply'),
            terminalEvent('completed'),
          ],
        },
      ],
    });
    final a = await f.start();
    await a.prompt();
    Json? permission;
    if (offered != null) {
      permission = await a.wait(
        Method.agentPermissionRequested,
        within: const Duration(seconds: 2),
      );
      final options = (permission['options'] as List).cast<Json>();
      expect(options.map((o) => o['name']), [
        for (var i = 0; i < offered.length; i++)
          offered[i] is String ? offered[i] : 'Native option ${i + 1}',
      ]);
      expect(options.map((o) => o['kind']), [
        for (final value in offered)
          value is! String
              ? 'allow_always'
              : value == 'acceptForSession'
              ? 'allow_always'
              : value == 'decline' || value == 'cancel'
              ? 'reject_once'
              : 'allow_once',
      ]);
      expect(
        (permission['preview'] as String).contains('Native decisions: '),
        offered.any((value) => value is! String),
      );
      expect(
        options.map((o) => o['optionId']).toSet(),
        hasLength(offered.length),
      );
      expect(options.map((o) => o['optionId']), isNot(contains('accept')));
      expect(
        f.requests.where((m) => m['id'] == 'command-decisions'),
        isEmpty,
        reason: 'native answer requires an explicit user action',
      );
      if (child) expect(permission['title'], contains('approval-child'));
      await a.call(Method.agentPermissionReply, {
        'sessionId': a.id,
        'requestId': permission['requestId'],
        'optionId': options[selected]['optionId'],
      });
    }
    await a.wait(Method.agentTurnEnded, within: const Duration(seconds: 3));
    expect(
      f.requests.where((m) => m['id'] == 'command-decisions').single['result'],
      {'decision': offered == null ? 'decline' : offered[selected]},
    );
    if (offered == null) {
      expect(a.of(Method.agentPermissionRequested), isEmpty);
      await eventually(
        () => a.events.any(
          (e) =>
              e['kind'] == 'notice' &&
              (e['text'] as String).contains('Native approval unavailable'),
        ),
      );
      final notices = a.events.where(
        (e) =>
            e['kind'] == 'notice' &&
            (e['text'] as String).contains('Native approval unavailable'),
      );
      expect(notices, hasLength(1));
      expect((notices.single['text'] as String).length, lessThan(256));
    } else {
      final before = f.requests.length;
      await rpcFailure(
        a.call(Method.agentPermissionReply, {
          'sessionId': a.id,
          'requestId': permission!['requestId'],
          'optionId':
              ((permission['options'] as List)[selected] as Json)['optionId'],
        }),
      );
      expect(
        f.requests.length,
        before,
        reason: 'duplicate or retired answer cannot write',
      );
    }
    await a.prompt('later ordinary root prompt');
    await a.wait(
      Method.agentTurnEnded,
      where: (_) => a.of(Method.agentTurnEnded).length == 2,
    );
    await eventually(
      () => a.events.any((e) => e['text'] == 'later root reply'),
    );
    expect(
      f.requests.where((m) => m['method'] == 'thread/start'),
      hasLength(1),
    );
    expect(
      f.requests
          .where((m) => m['method'] == 'turn/start')
          .map((m) => (m['params'] as Json)['threadId']),
      ['root-thread', 'root-thread'],
    );
    expect(
      f.requests.where((m) => m['id'] == 'command-decisions'),
      hasLength(1),
    );
    await a.close();
  }

  for (final entry in <String, Json>{
    'absent accept': {},
    'null cancel': {'availableDecisions': null},
    'command kind': {'kind': 'command'},
    'null contexts and policy proposals': {
      'networkApprovalContext': null,
      'additionalPermissions': null,
      'proposedExecpolicyAmendment': ['echo'],
      'proposedNetworkPolicyAmendments': [
        {'action': 'allow', 'host': 'fixture'},
      ],
    },
    'known child': {},
  }.entries) {
    test(
      'Codex: Ordinary command defaults require an explicit answer ${entry.key}',
      () async {
        await commandDecisionCase(
          entry.value,
          offered: ['accept', 'cancel'],
          selected: entry.key == 'null cancel' ? 1 : 0,
          child: entry.key == 'known child',
        );
      },
    );
  }
  final explicit = <Object?>[
    'future_native_decision',
    {
      'futureScopedDecision': {'scope': 'single', 'opaque': 7},
    },
    'cancel',
    'acceptForSession',
  ];
  for (var selected = 0; selected < explicit.length; selected++) {
    final choice = selected;
    test(
      'Codex: Explicit command decisions remain authoritative choice=$choice',
      () async {
        await commandDecisionCase(
          {
            'kind': 'network',
            'networkApprovalContext': {'host': 'fixture'},
            'additionalPermissions': {},
            'availableDecisions': explicit,
          },
          offered: explicit,
          selected: choice,
        );
      },
    );
  }
  for (final entry in <String, Object?>{
    'empty': <Object?>[],
    'string': 'accept',
    'object': {'accept': true},
    'over limit': List.filled(17, 'accept'),
    'null entry': ['accept', null],
    'boolean entry': ['accept', true],
    'number entry': ['accept', 1],
    'list entry': ['accept', <Object?>[]],
  }.entries) {
    test(
      'Codex: Empty or malformed command decisions stay unavailable ${entry.key}',
      () async {
        await commandDecisionCase({'availableDecisions': entry.value});
      },
    );
  }
  for (final context in <String, Json>{
    'null kind': {'kind': null},
    'network kind': {'kind': 'network'},
    'network context': {'networkApprovalContext': {}},
    'additional permissions': {'additionalPermissions': {}},
  }.entries) {
    for (final nullList in [false, true]) {
      test(
        'Codex: Special approvals do not use ordinary defaults ${context.key} null=$nullList',
        () async {
          await commandDecisionCase({
            ...context.value,
            if (nullList) 'availableDecisions': null,
          });
        },
      );
    }
  }
  Future<(NativeFixture, AgentPeer)> decisionRequest(Json params) async {
    final f = await fixture({
      'turns': [
        {
          'actions': [
            {
              'send': {
                'id': 'command-decisions',
                'method': 'item/commandExecution/requestApproval',
                'params': {
                  'threadId': r'$thread',
                  'turnId': r'$turn',
                  'itemId': 'cmd',
                  'startedAtMs': 1,
                  'command': 'echo fixture',
                  'cwd': 'C:/native-cwd',
                  'reason': 'why',
                  ...params,
                },
              },
            },
            {'waitReply': 'command-decisions'},
            terminalEvent('completed'),
          ],
        },
      ],
    });
    final a = await f.start();
    await a.prompt();
    return (f, a);
  }

  final longObject = <String, Object?>{
    'futureScopedDecision': {
      'scope': 'single',
      'opaque': [
        7,
        null,
        true,
        {'nested': 'caf\u00e9 \u65e5\u672c\u8a9e'},
      ],
      'text': 'line one\nline two ``` fenced\n```',
      'padding': List.filled(300, 'p').join(),
    },
  };
  for (final selected in [1, 3]) {
    test(
      'Codex decision display: objects are indexed with the full ordered array selected=$selected',
      () async {
        final decisions = <Object?>[
          'future_native_decision',
          longObject,
          'cancel',
          {'second': 1},
          'acceptForSession',
        ];
        expect(utf8.encode(jsonEncode(longObject)).length, greaterThan(256));
        {
          final (f, a) = await decisionRequest({
            'availableDecisions': decisions,
          });
          final p = await a.wait(
            Method.agentPermissionRequested,
            within: const Duration(seconds: 2),
          );
          final options = (p['options'] as List).cast<Json>();
          expect(options.map((o) => o['name']), [
            'future_native_decision',
            'Native option 2',
            'cancel',
            'Native option 4',
            'acceptForSession',
          ]);
          expect(options.map((o) => o['kind']), [
            'allow_once',
            'allow_always',
            'reject_once',
            'allow_always',
            'allow_always',
          ]);
          expect(
            options.map((o) => o['kind']).where((k) => k == 'allow_once'),
            ['allow_once'],
          );
          final preview = p['preview'] as String;
          expect(
            preview,
            'Command: echo fixture\nWorking directory: C:/native-cwd\n'
            'Reason: why\nNative decisions: ${jsonEncode(decisions)}',
          );
          expect(preview.split('\n'), hasLength(4));
          expect(
            f.requests.where((m) => m['id'] == 'command-decisions'),
            isEmpty,
          );
          await a.call(Method.agentPermissionReply, {
            'sessionId': a.id,
            'requestId': p['requestId'],
            'optionId': options[selected]['optionId'],
          });
          await a.wait(Method.agentTurnEnded);
          expect(
            f.requests
                .where((m) => m['id'] == 'command-decisions')
                .single['result'],
            {'decision': decisions[selected]},
          );
          await a.close();
        }
      },
    );
  }
  test('Codex decision display: string-only lists are unchanged', () async {
    final (f, a) = await decisionRequest({
      'availableDecisions': ['accept', 'decline'],
    });
    final p = await a.wait(
      Method.agentPermissionRequested,
      within: const Duration(seconds: 2),
    );
    expect((p['options'] as List).map((o) => (o as Json)['name']), [
      'accept',
      'decline',
    ]);
    expect(p['preview'], isNot(contains('Native decisions')));
    expect(f.requests.where((m) => m['id'] == 'command-decisions'), isEmpty);
    await a.call(Method.agentPermissionReply, {
      'sessionId': a.id,
      'requestId': p['requestId'],
      'optionId': ((p['options'] as List).first as Json)['optionId'],
    });
    await a.wait(Method.agentTurnEnded);
    await a.close();
  });
  for (final context in <String, (String, Json)>{
    'network context': (
      'Network approval context',
      {'host': 'a.example', 'protocol': 'https', 'port': 443},
    ),
    'additional permissions': (
      'Additional permissions',
      {
        'network': {'enabled': true},
        'fileSystem': {
          'write': ['C:/grant-a'],
        },
      },
    ),
  }.entries) {
    test(
      'Codex decision display: command approval shows its ${context.key}',
      () async {
        final (label, value) = context.value;
        final key = context.key == 'network context'
            ? 'networkApprovalContext'
            : 'additionalPermissions';
        final (f, a) = await decisionRequest({
          'availableDecisions': ['accept', 'cancel'],
          key: value,
        });
        final p = await a.wait(
          Method.agentPermissionRequested,
          within: const Duration(seconds: 2),
        );
        expect(
          p['preview'],
          'Command: echo fixture\nWorking directory: C:/native-cwd\n'
          'Reason: why\n$label: ${jsonEncode(value)}',
        );
        expect(
          f.requests.where((m) => m['id'] == 'command-decisions'),
          isEmpty,
        );
        await a.call(Method.agentPermissionReply, {
          'sessionId': a.id,
          'requestId': p['requestId'],
          'optionId': ((p['options'] as List).last as Json)['optionId'],
        });
        await a.wait(Method.agentTurnEnded);
        await a.close();
      },
    );
  }
  test(
    'Codex decision overflow: a network context too large to show cancels',
    () async {
      final (f, a) = await decisionRequest({
        'availableDecisions': ['accept', 'cancel'],
        'networkApprovalContext': {
          'host': 'future-scope-${List.filled(17000, 'x').join()}',
        },
      });
      await a.wait(Method.agentTurnEnded);
      expect(a.of(Method.agentPermissionRequested), isEmpty);
      expect(
        f.requests
            .where((m) => m['id'] == 'command-decisions')
            .single['result'],
        {'decision': 'cancel'},
      );
      expect(
        a.events.where(
          (e) =>
              e['kind'] == 'notice' &&
              (e['text'] as String).startsWith(
                'Native approval unavailable: full details exceed display capacity',
              ),
        ),
        hasLength(1),
      );
      await a.close();
    },
  );
  test('Codex decision display: known child objects keep identity', () async {
    await commandDecisionCase(
      {
        'availableDecisions': [
          {'childScoped': 'x'},
          'accept',
        ],
      },
      offered: [
        {'childScoped': 'x'},
        'accept',
      ],
      selected: 0,
      child: true,
    );
  });
  test('Codex decision display: live and revoked secrets are redacted', () async {
    final f = await fixture();
    final report = await saveAgentFixture(
      f.desktop,
      work(),
      id: 'decision-secret-owner',
    );
    final owner = AgentPeer(f.desktop);
    await owner.start(f.workspace, runtime: 'decision-secret-owner');
    await owner.attach();
    final launch = await waitFixture(report, (r) => r['mcpServers'] is List);
    final server = (launch['mcpServers'] as List).single as Json;
    final secret =
        ((server['env'] as List).cast<Json>().firstWhere(
              (e) => e['name'] == 'KUMIKO_TOOL_SECRET',
            )['value'])!
            as String;
    final decision = {'scope': 'C:/$secret/scope'};
    final script = jsonDecode(f.scriptFile.readAsStringSync()) as Json;
    script['turns'] = [
      for (var turn = 0; turn < 2; turn++)
        {
          'actions': [
            {
              'send': {
                'id': 'secret-decision-$turn',
                'method': 'item/commandExecution/requestApproval',
                'params': {
                  'threadId': r'$thread',
                  'turnId': r'$turn',
                  'itemId': 'scope-$turn',
                  'startedAtMs': 1,
                  'command': 'echo $secret',
                  'availableDecisions': ['accept', decision],
                },
              },
            },
            {'waitReply': 'secret-decision-$turn'},
            terminalEvent('completed'),
          ],
        },
    ];
    f.scriptFile.writeAsStringSync(jsonEncode(script));
    final a = await f.start();
    for (var turn = 0; turn < 2; turn++) {
      if (turn == 1) await owner.close();
      await a.prompt();
      final p = await a.wait(
        Method.agentPermissionRequested,
        where: (p) =>
            p['requestId'] !=
            (turn == 0
                ? null
                : a.of(Method.agentPermissionRequested).first['requestId']),
      );
      final preview = p['preview']! as String;
      final options = (p['options'] as List).cast<Json>();
      // Boolean assertions keep a failure from logging the credential.
      expect(preview.contains(secret), isFalse);
      expect(preview.contains('<redacted>'), isTrue);
      expect(jsonEncode(p).contains(secret), isFalse);
      expect(options.map((o) => o['name']), ['accept', 'Native option 2']);
      await a.call(Method.agentPermissionReply, {
        'sessionId': a.id,
        'requestId': p['requestId'],
        'optionId': options[1]['optionId'],
      });
      await a.wait(
        Method.agentTurnEnded,
        where: (_) => a.of(Method.agentTurnEnded).length == turn + 1,
      );
      // The opaque token keeps the exact native value, never the display copy.
      final result = f.requests
          .where((m) => m['id'] == 'secret-decision-$turn')
          .single['result'];
      expect(jsonEncode(result) == jsonEncode({'decision': decision}), true);
    }
    await a.close();
  });
  Future<void> decisionCancelCase(
    List<Object?> decisions, {
    String reason = 'why',
    String notice = 'capacity',
  }) async {
    final (f, a) = await decisionRequest({
      'availableDecisions': decisions,
      'reason': reason,
    });
    await eventually(
      () =>
          a.of(Method.agentPermissionRequested).isNotEmpty ||
          f.requests.any((m) => m['id'] == 'command-decisions'),
    );
    expect(a.of(Method.agentPermissionRequested), isEmpty);
    await a.wait(Method.agentTurnEnded);
    expect(
      f.requests.where((m) => m['id'] == 'command-decisions').single['result'],
      {'decision': 'cancel'},
    );
    await eventually(
      () => a.events.any(
        (e) =>
            e['kind'] == 'notice' &&
            (e['text'] as String).startsWith('Native approval unavailable') &&
            (e['text'] as String).contains(notice),
      ),
    );
    final notices = a.events.where(
      (e) =>
          e['kind'] == 'notice' &&
          (e['text'] as String).startsWith('Native approval unavailable'),
    );
    expect(notices, hasLength(1));
    expect(
      utf8.encode(notices.single['text']! as String).length,
      lessThan(1024),
    );
    expect(notices.single['text'], isNot(contains('future-scope')));
    await a.close();
  }

  test('Codex decision overflow: raw preview exceeds its bound', () async {
    await decisionCancelCase([
      {'scope': 'future-scope-${List.filled(17000, 'x').join()}'},
      'decline',
    ]);
  });
  test(
    'Codex decision overflow: JSON-encoded preview exceeds its bound',
    () async {
      // 3000 control characters fit raw but expand to 18000 encoded bytes.
      await decisionCancelCase([
        {'scope': 'future-scope', 'pad': List.filled(3000, '\u0001').join()},
        'decline',
      ]);
    },
  );
  test('Codex decision overflow: oversize string names still refuse', () async {
    await decisionCancelCase([
      'future-scope-${List.filled(300, 'x').join()}',
      {'a': 1},
    ]);
  });
  test('Codex decision overflow: ambiguous option labels refuse', () async {
    await decisionCancelCase([
      'Native option 2',
      {'future-scope': 1},
    ], notice: 'ambiguous');
  });
  test('Codex: Approve a command', () async {
    final f = await fixture({
      'turns': [
        {
          'actions': [
            {
              'send': {
                'id': 'approval',
                'method': 'item/commandExecution/requestApproval',
                'params': {
                  'threadId': r'$thread',
                  'turnId': r'$turn',
                  'itemId': 'cmd',
                  'startedAtMs': 1,
                  'command': 'echo fixture',
                  'availableDecisions': ['decline', 'accept'],
                },
              },
            },
            {'waitReply': 'approval'},
            terminalEvent('completed'),
          ],
        },
      ],
    });
    final a = await f.start();
    await a.prompt();
    final p = await a.wait(
      Method.agentPermissionRequested,
      within: const Duration(seconds: 2),
    );
    final options = p['options'] as List;
    expect(options.map((o) => (o as Json)['name']), ['decline', 'accept']);
    final choice = (options.last as Json)['optionId'];
    await a.call(Method.agentPermissionReply, {
      'sessionId': a.id,
      'requestId': p['requestId'],
      'optionId': choice,
    });
    await a.wait(Method.agentTurnEnded);
    expect(f.requests.where((m) => m['id'] == 'approval').single['result'], {
      'decision': 'accept',
    });
    final before = f.requests.length;
    await rpcFailure(
      a.call(Method.agentPermissionReply, {
        'sessionId': a.id,
        'requestId': p['requestId'],
        'optionId': choice,
      }),
    );
    expect(f.requests.length, before);
    await a.close();
  });
  test('Codex: Answer a structured question', () async {
    final f = await fixture({
      'turns': [
        {
          'actions': [
            {
              'send': {
                'id': 'question',
                'method': 'item/tool/requestUserInput',
                'params': {
                  'threadId': r'$thread',
                  'turnId': r'$turn',
                  'itemId': 'q',
                  'isBlocking': true,
                  'questions': [
                    {
                      'id': 'choice',
                      'header': 'Choice',
                      'question': 'Which?',
                      'options': [
                        {'label': 'One', 'description': 'First'},
                      ],
                    },
                  ],
                },
              },
            },
            {'waitReply': 'question'},
            terminalEvent('completed'),
          ],
        },
      ],
    });
    final a = await f.start();
    await a.prompt();
    final q = await a.wait(
      Method.agentQuestionRequested,
      within: const Duration(seconds: 2),
    );
    final seqs = [
      for (final n in a.notifications)
        if (n.params['sessionId'] == a.id && n.params['seq'] is int)
          n.params['seq']! as int,
    ];
    expect(seqs, [...seqs]..sort());
    final question = (q['questions'] as List).single as Json;
    final option = (question['options'] as List).single as Json;
    await a.call(Method.agentQuestionAnswer, {
      'sessionId': a.id,
      'runId': q['runId'],
      'turnId': q['turnId'],
      'requestId': q['requestId'],
      'answers': [
        {
          'questionId': question['id'],
          'values': [option['id']],
        },
      ],
    });
    await a.wait(Method.agentTurnEnded);
    expect(f.requests.where((m) => m['id'] == 'question').single['result'], {
      'answers': {
        'choice': {
          'answers': ['One'],
        },
      },
    });
    await a.close();
  });
  for (final method in ['future/ordinary', 'future/requestApproval']) {
    for (final payload in <Object?>[
      null,
      <Object?>[],
      7,
      <String, Object?>{},
    ]) {
      test(
        'Codex: unknown request classifier $method ${jsonEncode(payload)}',
        () async {
          final f = await fixture({
            'turns': [
              {
                'actions': [
                  {
                    'send': {
                      'id': 'unknown-shape',
                      'method': method,
                      'params': payload,
                    },
                  },
                  {'waitReply': 'unknown-shape'},
                  terminalEvent('completed'),
                ],
              },
            ],
          });
          final a = await f.start();
          await a.prompt();
          await eventually(
            () =>
                a.of(Method.agentTurnEnded).isNotEmpty ||
                a.of(Method.agentState).any((p) => p['state'] == 'failed'),
          );
          expect(
            a.of(Method.agentState).any((p) => p['state'] == 'failed'),
            isFalse,
          );
          final replies = f.requests.where((m) => m['id'] == 'unknown-shape');
          expect(replies, hasLength(1));
          expect((replies.single['error'] as Json)['code'], -32601);
          expect(a.of(Method.agentPermissionRequested), isEmpty);
          expect(a.of(Method.agentQuestionRequested), isEmpty);
          expect(
            a.events.where(
              (e) =>
                  e['kind'] == 'notice' &&
                  (e['text'] as String).contains('unsupported native request'),
            ),
            hasLength(1),
          );
          await a.prompt();
          await eventually(() => a.of(Method.agentTurnEnded).length == 2);
          await a.close();
        },
      );
    }
  }
  for (final method in [
    'item/commandExecution/requestApproval',
    'item/fileChange/requestApproval',
    'item/permissions/requestApproval',
  ]) {
    test(
      'Codex: known core approval classifier remains fatal $method',
      () async {
        final f = await fixture({
          'turns': [
            {
              'actions': [
                {
                  'send': {
                    'id': 'malformed-known',
                    'method': method,
                    'params': null,
                  },
                },
              ],
            },
          ],
        });
        final a = await f.start();
        await a.prompt();
        await a.wait(Method.agentState, where: (p) => p['state'] == 'failed');
        expect(a.of(Method.agentPermissionRequested), isEmpty);
      },
    );
  }

  test('Codex: Unknown native request', () async {
    final f = await fixture({
      'turns': [
        {
          'actions': [
            {
              'send': {
                'id': 'unknown',
                'method': 'future/privileged',
                'params': {'threadId': r'$thread', 'turnId': r'$turn'},
              },
            },
            {'waitReply': 'unknown'},
            terminalEvent('completed'),
          ],
        },
      ],
    });
    final a = await f.start();
    await a.prompt();
    await a.wait(Method.agentTurnEnded);
    expect(
      f.requests.where((m) => m['id'] == 'unknown').single['error'],
      isA<Map<String, Object?>>(),
    );
    expect(a.events.toString(), contains('unsupported'));
    await a.close();
  });
  test('Codex: Steer running work', () async {
    final f = await fixture({
      'turns': [
        {
          'actions': [
            {'waitInterrupt': true},
            terminalEvent('interrupted'),
          ],
        },
      ],
    });
    final a = await f.start();
    await a.prompt();
    final state = await a.wait(
      Method.agentState,
      where: (s) => s['turnId'] != null,
    );
    await a.call(Method.agentSteer, {
      'sessionId': a.id,
      'runId': state['runId'],
      'expectedTurnId': state['turnId'],
      'text': 'steer fixture',
    });
    await waitFixture(
      f.report,
      (r) =>
          r['received'] is Json &&
          (r['received'] as Json)['method'] == 'turn/steer',
    );
    expect(f.requests.where((r) => r['method'] == 'turn/start'), hasLength(1));
    await a.call(Method.agentStop);
    await a.wait(Method.agentTurnEnded);
    await a.close();
  });
  test('Codex: prior turn events before new acceptance never finish or pollute replacement', () async {
    final f = await fixture({
      'turns': [
        {
          'actions': [terminalEvent('completed')],
        },
        {
          'beforeResponse': [
            nativeEvent('item/agentMessage/delta', {
              'threadId': r'$thread',
              'turnId': 'turn-1',
              'itemId': 'old',
              'delta': 'STALE-OLD-TURN',
            }),
            nativeEvent('turn/completed', {
              'threadId': r'$thread',
              'turn': {'id': 'turn-1', 'status': 'completed'},
            }),
          ],
          'actions': [
            deltaEvent('current replacement'),
            terminalEvent('completed'),
          ],
        },
      ],
    });
    final a = await f.start();
    await a.prompt('first');
    await a.wait(Method.agentTurnEnded);
    await a.prompt('second');
    await a.wait(
      Method.agentTurnEnded,
      where: (_) => a.of(Method.agentTurnEnded).length == 2,
      within: const Duration(seconds: 3),
    );
    expect(a.events.toString(), isNot(contains('STALE-OLD-TURN')));
    expect(a.events.toString(), contains('current replacement'));
    await a.close();
  });
  test(
    'Codex: oversized escaped Unicode delta has visible truncation',
    () async {
      final f = await fixture({
        'turns': [
          {
            'actions': [
              deltaEvent(List.filled(300000, '\u{1F98A}\u0000').join()),
              terminalEvent('completed'),
            ],
          },
        ],
      });
      final a = await f.start();
      await a.prompt();
      await a.wait(Method.agentTurnEnded);
      await eventually(() => a.events.any((e) => e['truncated'] == true));
      await a.close();
    },
  );
  test('Codex: command item maps native tool activity', () async {
    final f = await fixture({
      'turns': [
        {
          'actions': [
            nativeEvent('item/started', {
              'threadId': r'$thread',
              'turnId': r'$turn',
              'startedAtMs': 1,
              'item': {
                'id': 'native-command',
                'type': 'commandExecution',
                'command': 'echo fixture',
                'commandActions': <Json>[],
                'cwd': '/fixture',
                'status': 'inProgress',
              },
            }),
            nativeEvent('item/completed', {
              'threadId': r'$thread',
              'turnId': r'$turn',
              'item': {
                'id': 'native-command',
                'type': 'commandExecution',
                'command': 'echo fixture',
                'commandActions': <Json>[],
                'cwd': '/fixture',
                'status': 'completed',
                'aggregatedOutput': 'fixture output',
                'exitCode': 0,
              },
            }),
            terminalEvent('completed'),
          ],
        },
      ],
    });
    final a = await f.start();
    await a.prompt();
    await a.wait(Method.agentTurnEnded);
    expect(a.events.where((e) => e['kind'] == 'tool'), hasLength(1));
    expect(a.events.where((e) => e['kind'] == 'toolUpdate'), hasLength(1));
    await a.close();
  });
  const signedOut = {'account': null, 'requiresOpenaiAuth': true};
  const preflightSignal = {
    'KUMIKO_TEST_CODEX_AUTH_SIGNATURES': '["account-unauthenticated"]',
  };
  // An explicit empty override: the production registry confirms signals.
  const noSignals = {'KUMIKO_TEST_CODEX_AUTH_SIGNATURES': '[]'};
  const turnSignal = {'KUMIKO_TEST_CODEX_AUTH_SIGNATURES': '["turn-http-401"]'};
  Json failed401([Object? info]) => nativeEvent('turn/completed', {
    'threadId': r'$thread',
    'turn': {
      'id': r'$turn',
      'status': 'failed',
      'items': <Object?>[],
      'error': {
        'message': 'unexpected status 401 Unauthorized, request id fixture-1',
        'codexErrorInfo':
            info ??
            {
              'httpConnectionFailed': {'httpStatusCode': 401},
            },
      },
    },
  });
  List<String> methods(NativeFixture f, [int skip = 0]) => [
    for (final r in f.requests.skip(skip))
      if (r['method'] is String) r['method']! as String,
  ];
  test('Codex: test host refuses an unknown auth signal name', () async {
    await expectLater(
      Desktop.start(
        profile(),
        environment: {'KUMIKO_TEST_CODEX_AUTH_SIGNATURES': '["unauthorized"]'},
      ),
      throwsA(anything),
    );
  });
  for (final provider in [null, 'openai']) {
    test(
      'Codex: confirmed account-unauthenticated refuses Start before thread/start provider=$provider',
      () async {
        final f = await fixture({
          'accountRead': signedOut,
          if (provider != null)
            'cliOverrides': [
              {'key': 'model_provider', 'value': provider},
            ],
        }, preflightSignal);
        final error = await refusedStart(f);
        expect(error.reason, ErrorCode.authRequired);
        expect(methods(f), isNot(contains('thread/start')));
        expect(
          f.requests
              .where(
                (r) =>
                    r['method'] == 'config/read' &&
                    !(r['params'] as Json).containsKey('includeLayers'),
              )
              .single['params'],
          {'cwd': work().path},
        );
        expect(
          f.requests
              .where((r) => r['method'] == 'account/read')
              .single['params'],
          {'refreshToken': false},
        );
        expect(agentRows(profile()), isEmpty);
      },
    );
  }
  for (final open in <(String, Json, Map<String, String>)>[
    ('unconfirmed signal', {'accountRead': signedOut}, noSignals),
    (
      'another provider',
      {
        'accountRead': signedOut,
        'cliOverrides': [
          {'key': 'model_provider', 'value': 'azure'},
        ],
      },
      preflightSignal,
    ),
    (
      'unreadable configuration',
      {
        'accountRead': signedOut,
        'configReadError': {'code': -32000, 'message': 'config unavailable'},
      },
      preflightSignal,
    ),
    (
      'malformed configuration',
      {'accountRead': signedOut, 'configReadResult': 'not a config'},
      preflightSignal,
    ),
    (
      'present account',
      {
        'accountRead': {
          'account': {'type': 'apiKey'},
          'requiresOpenaiAuth': true,
        },
      },
      preflightSignal,
    ),
    (
      'requiresOpenaiAuth false',
      {
        'accountRead': {'account': null, 'requiresOpenaiAuth': false},
      },
      preflightSignal,
    ),
    (
      'requiresOpenaiAuth absent',
      {
        'accountRead': {'account': null},
      },
      preflightSignal,
    ),
    (
      'account absent',
      {
        'accountRead': {'requiresOpenaiAuth': true},
      },
      preflightSignal,
    ),
    (
      'malformed account result',
      {'accountRead': 'signed out'},
      preflightSignal,
    ),
    (
      'native error',
      {
        'accountReadError': {
          'code': -32000,
          'message': 'Authentication required',
        },
      },
      preflightSignal,
    ),
    ('method not found', const {}, preflightSignal),
    ('timeout', {'accountReadHang': true}, preflightSignal),
  ]) {
    test('Codex: account preflight fails open on ${open.$1}', () async {
      final f = await fixture(open.$2, open.$3);
      final a = await f.start();
      expect(methods(f), contains('thread/start'));
      if (open.$1 == 'unconfirmed signal' || open.$1 == 'another provider') {
        expect(methods(f), isNot(contains('account/read')));
      }
      expect(agentRows(profile()), hasLength(1));
      await a.close();
    });
  }
  test('Codex: Continue never runs the account preflight and a signed-out turn is auth-required', () async {
    final f = NativeFixture(
      profile(),
      work(),
      script: {
        'resumeThread': {
          'id': 'root-thread',
          'historyMode': 'legacy',
          'status': {'type': 'idle'},
          'turns': [
            {
              'id': 'old-turn',
              'status': 'completed',
              'itemsView': 'full',
              'items': [
                {
                  'id': 'old-reply',
                  'type': 'agentMessage',
                  'text': 'original answer',
                },
              ],
            },
          ],
        },
        'turns': [
          {
            'actions': [failed401()],
          },
        ],
      },
    );
    await f.open(
      env: {
        'KUMIKO_TEST_CODEX_AUTH_SIGNATURES':
            '["account-unauthenticated","turn-http-401"]',
      },
    );
    final original = await f.start();
    final row = agentRows(profile()).single;
    await original.close();
    await original.call(Method.agentRelease);
    // The default account is now signed out; a saved thread still resumes.
    final script = jsonDecode(f.scriptFile.readAsStringSync()) as Json;
    f.scriptFile.writeAsStringSync(
      jsonEncode({...script, 'accountRead': signedOut}),
    );
    final before = f.requests.length;
    final peer = AgentPeer(f.desktop);
    final resumed = AgentContinueResult.fromJson(
      await peer.call(Method.agentContinue, {'sessionId': row['id']}),
    );
    peer.started = AgentStartResult(
      sessionId: row['id']! as String,
      eventChannel: resumed.eventChannel,
      adapter: resumed.adapter,
      capabilities: resumed.capabilities,
    );
    await peer.attach();
    await peer.wait(Method.agentState, where: (s) => s['state'] == 'idle');
    expect(methods(f, before), contains('thread/resume'));
    expect(methods(f, before), isNot(contains('account/read')));
    await peer.prompt();
    final ended = await peer.wait(Method.agentTurnEnded);
    expect(ended['error'], ErrorCode.authRequired);
    expect(agentRows(profile()).single, row);
    await peer.close();
  });
  for (final key in [
    'httpConnectionFailed',
    'responseStreamConnectionFailed',
    'responseStreamDisconnected',
    'responseTooManyFailedAttempts',
  ]) {
    test('Codex: confirmed turn-http-401 classifies $key', () async {
      final f = await fixture({
        'turns': [
          {
            'actions': [
              failed401({
                key: {'httpStatusCode': 401},
              }),
            ],
          },
        ],
      }, turnSignal);
      final a = await f.start();
      final row = agentRows(profile()).single;
      await a.prompt();
      final ended = await a.wait(Method.agentTurnEnded);
      expect(ended['error'], ErrorCode.authRequired);
      await a.wait(Method.agentState, where: (s) => s['state'] == 'idle');
      expect(agentRows(profile()).single, row);
      await a.close();
    });
  }
  for (final other in <(String, Object?, Map<String, String>)>[
    (
      'an unconfirmed signal',
      {
        'httpConnectionFailed': {'httpStatusCode': 401},
      },
      noSignals,
    ),
    (
      'status 403',
      {
        'httpConnectionFailed': {'httpStatusCode': 403},
      },
      turnSignal,
    ),
    (
      'a string status',
      {
        'httpConnectionFailed': {'httpStatusCode': '401'},
      },
      turnSignal,
    ),
    (
      'two keys',
      {
        'httpConnectionFailed': {'httpStatusCode': 401},
        'responseStreamDisconnected': {'httpStatusCode': 401},
      },
      turnSignal,
    ),
    (
      'an unknown key',
      {
        'serverOverloaded': {'httpStatusCode': 401},
      },
      turnSignal,
    ),
    ('the unauthorized string', 'unauthorized', turnSignal),
    ('a preflight-only signal', null, preflightSignal),
  ]) {
    test('Codex: failed turn is not auth-required with ${other.$1}', () async {
      final f = await fixture({
        'turns': [
          {
            'actions': [failed401(other.$2)],
          },
        ],
      }, other.$3);
      final a = await f.start();
      await a.prompt();
      final ended = await a.wait(Method.agentTurnEnded);
      expect(ended['error'], 'adapter-error');
      expect(ended['nativeMessage'], contains('401 Unauthorized'));
      await a.close();
    });
  }
  test(
    'Codex: a retrying 401 error notification is never classified',
    () async {
      final f = await fixture({
        'turns': [
          {
            'actions': [
              nativeEvent('error', {
                'threadId': r'$thread',
                'turnId': r'$turn',
                'willRetry': true,
                'error': {
                  'message':
                      'unexpected status 401 Unauthorized, request id r-1',
                  'codexErrorInfo': {
                    'responseStreamDisconnected': {'httpStatusCode': 401},
                  },
                },
              }),
              terminalEvent('completed'),
            ],
          },
        ],
      }, turnSignal);
      final a = await f.start();
      await a.prompt();
      final ended = await a.wait(Method.agentTurnEnded);
      expect(ended['error'], isNull);
      await a.close();
    },
  );
  test(
    'Codex: Stop aggregation holds for an auth-required root turn',
    () async {
      final f = await fixture({
        'turns': [
          {
            'actions': [
              nativeEvent('thread/started', {
                'thread': {
                  'id': 'child-a',
                  'parentThreadId': 'root-thread',
                  'status': {'type': 'active'},
                },
              }),
              nativeEvent('turn/started', {
                'threadId': 'child-a',
                'turn': {
                  'id': 'child-a-turn',
                  'status': 'inProgress',
                  'items': <Object?>[],
                  'error': null,
                },
              }),
              {
                'send': {
                  'id': 'ready-child',
                  'method': 'item/commandExecution/requestApproval',
                  'params': {
                    'threadId': 'child-a',
                    'turnId': 'child-a-turn',
                    'itemId': 'ready',
                    'startedAtMs': 1,
                    'command': 'echo ready',
                    'cwd': '/fixture',
                    'availableDecisions': ['accept', 'decline'],
                  },
                },
              },
              {'waitInterrupt': true},
              failed401(),
              {'waitInterrupt': 'child-a-turn'},
              nativeEvent('turn/completed', {
                'threadId': 'child-a',
                'turn': {
                  'id': 'child-a-turn',
                  'status': 'interrupted',
                  'items': <Object?>[],
                  'error': null,
                },
              }),
            ],
          },
        ],
      }, turnSignal);
      final a = await f.start();
      await a.prompt();
      await a.wait(Method.agentPermissionRequested);
      await a.call(Method.agentStop);
      final ended = await a.wait(Method.agentTurnEnded);
      expect(ended['error'], ErrorCode.authRequired);
      await a.wait(Method.agentStopResult);
      expect(a.of(Method.agentState).last['state'], 'idle');
      await a.close();
    },
  );
  test(
    'Codex: auth-required completion after the Stop deadline stays honest',
    () async {
      final f = await fixture({
        'turns': [
          {
            'actions': [
              {'waitInterrupt': true},
              {'delayMs': 11000},
              failed401(),
            ],
          },
        ],
      }, turnSignal);
      final a = await f.start();
      await a.prompt();
      await a.wait(Method.agentState, where: (p) => p['turnId'] != null);
      await a.call(Method.agentStop);
      await a.wait(
        Method.agentStopResult,
        where: (r) => r['outcome'] == 'notConfirmed',
      );
      expect(a.of(Method.agentState).last['state'], 'stopping');
      final ended = await a.wait(Method.agentTurnEnded);
      expect(ended['error'], ErrorCode.authRequired);
      final late = await a.wait(
        Method.agentStopResult,
        where: (r) => r['late'] == true,
      );
      expect(late['outcome'], isNot('notConfirmed'));
      await a.close();
    },
  );
  test('Codex: repeated steering at stalled credit refuses before draft removal or native write', () async {
    final f = await fixture({
      'turns': [
        {
          'actions': [
            {'waitInterrupt': true},
            terminalEvent('interrupted'),
          ],
        },
      ],
    });
    final a = AgentPeer(f.desktop);
    await a.start(f.workspace, runtime: 'native');
    await a.attach(credit: false);
    await a.prompt();
    final state = await a.wait(
      Method.agentState,
      where: (p) => p['turnId'] != null,
    );
    final text = List.filled(200000, 's').join();
    await a.call(Method.agentDraftSave, {
      'sessionId': a.id,
      'revision': 1,
      'text': text,
    });
    RpcException? refusal;
    var admitted = 0;
    for (var i = 0; i < 20; i++) {
      try {
        await a.call(Method.agentSteer, {
          'sessionId': a.id,
          'runId': state['runId'],
          'expectedTurnId': state['turnId'],
          'text': text,
        });
        admitted++;
      } on RpcException catch (e) {
        refusal = e;
        break;
      }
    }
    expect(refusal?.reason, ErrorCode.busy);
    expect(admitted, greaterThan(0));
    int receivedSteers() =>
        f.requests.where((r) => r['method'] == 'turn/steer').length;
    // Host ACK means admitted, not that the native process has already read
    // its stdin. Settle earlier admissions before observing a refused write.
    await eventually(() => receivedSteers() >= admitted);
    expect(receivedSteers(), admitted);
    final refused = await rpcFailure(
      a.call(Method.agentSteer, {
        'sessionId': a.id,
        'runId': state['runId'],
        'expectedTurnId': state['turnId'],
        'text': text,
        'draftRevision': 1,
        'draftSynced': true,
      }),
    );
    expect(refused.reason, ErrorCode.busy);
    final draft = await a.call(Method.agentDraftLoad);
    expect(draft['text'], text);
    expect(receivedSteers(), admitted);
    await a.close();
    expect(receivedSteers(), admitted);
  });
  test('Codex: stale early interaction cannot surface in next turn', () async {
    final f = await fixture({
      'turns': [
        {
          'actions': [terminalEvent('completed')],
        },
        {
          'beforeResponse': [
            {
              'send': {
                'id': 'stale-permission',
                'method': 'item/commandExecution/requestApproval',
                'params': {
                  'threadId': r'$thread',
                  'turnId': 'turn-1',
                  'itemId': 'old',
                  'startedAtMs': 1,
                  'availableDecisions': ['accept', 'decline'],
                },
              },
            },
          ],
          'actions': [terminalEvent('completed')],
        },
      ],
    });
    final a = await f.start();
    await a.prompt();
    await a.wait(Method.agentTurnEnded);
    await a.prompt();
    await a.wait(
      Method.agentTurnEnded,
      where: (_) => a.of(Method.agentTurnEnded).length == 2,
    );
    expect(a.of(Method.agentPermissionRequested), isEmpty);
    expect(
      f.requests.where((m) => m['id'] == 'stale-permission').single['result'],
      {'decision': 'cancel'},
    );
    await a.close();
  });

  test(
    'Codex: Unknown auth-like diagnostic retains bounded native fields',
    () async {
      final f = await fixture({
        'startError': {'code': -32000, 'message': 'Authentication required'},
      });
      final error = await refusedStart(f);
      expect(error.reason, isNot(ErrorCode.authRequired));
      final data = error.data;
      expect(data['nativeCode'], -32000);
      expect(data['nativeMessage'], 'Authentication required');
    },
  );

  for (final blocking in [false, true]) {
    test(
      'Codex: a question too large once expanded is refused, not fatal blocking=$blocking',
      () async {
        final options = [for (var i = 0; i < 2000; i++) 'o$i'];
        final f = await fixture({
          'turns': [
            {
              'actions': [
                if (blocking) ...[
                  {
                    'send': {
                      'id': 'wide-question',
                      'method': 'item/tool/requestUserInput',
                      'params': {
                        'threadId': r'$thread',
                        'turnId': r'$turn',
                        'itemId': 'q',
                        'isBlocking': true,
                        'questions': [
                          {
                            'id': 'choice',
                            'header': 'Choice',
                            'question': 'Which?',
                            'options': [
                              for (final o in options) {'label': o},
                            ],
                          },
                        ],
                      },
                    },
                  },
                  {'waitReply': 'wide-question'},
                ] else
                  nativeEvent('item/completed', {
                    'threadId': r'$thread',
                    'turnId': r'$turn',
                    'item': {
                      'id': 'wide-question',
                      'type': 'agentMessage',
                      'text': 'Choose',
                      'questions': [
                        {'title': 'Which?', 'options': options},
                      ],
                    },
                  }),
                terminalEvent('completed'),
              ],
            },
            {
              'actions': [
                deltaEvent('still alive'),
                terminalEvent('completed'),
              ],
            },
          ],
        });
        final a = await f.start();
        await a.prompt();
        await a.wait(Method.agentTurnEnded);
        expect(a.of(Method.agentQuestionRequested), isEmpty);
        if (blocking) {
          expect(
            f.requests
                .where((m) => m['id'] == 'wide-question')
                .single['result'],
            {'answers': <String, Object?>{}},
          );
        }
        await eventually(
          () => a.events.any(
            (e) =>
                e['kind'] == 'notice' &&
                (e['text'] as String).contains('exceeds control capacity'),
          ),
        );
        await a.prompt();
        await a.wait(
          Method.agentTurnEnded,
          where: (_) => a.of(Method.agentTurnEnded).length == 2,
        );
        expect(
          a.of(Method.agentState).any((s) => s['state'] == 'failed'),
          false,
        );
        await a.close();
      },
    );
  }
  test('Codex: async question answer cannot steer a later turn', () async {
    final f = await fixture({
      'turns': [
        {
          'actions': [
            nativeEvent('item/completed', {
              'threadId': r'$thread',
              'turnId': r'$turn',
              'item': {
                'id': 'async-question',
                'type': 'agentMessage',
                'text': 'Choose',
                'questions': [
                  {
                    'title': 'Which?',
                    'options': ['One', 'Two'],
                  },
                ],
              },
            }),
            {'delayMs': 200},
            terminalEvent('completed'),
          ],
        },
        {
          'actions': [
            {'waitInterrupt': true},
            terminalEvent('interrupted'),
          ],
        },
      ],
    });
    final a = await f.start();
    await a.prompt();
    final q = await a.wait(
      Method.agentQuestionRequested,
      within: const Duration(seconds: 2),
    );
    await a.wait(Method.agentTurnEnded);
    await a.prompt();
    await a.wait(Method.agentState, where: (p) => p['turnId'] == 'turn-2');
    final before = f.requests.length;
    final question = (q['questions'] as List).single as Json;
    final error = await rpcFailure(
      a.call(Method.agentQuestionAnswer, {
        'sessionId': a.id,
        'runId': q['runId'],
        'turnId': q['turnId'],
        'requestId': q['requestId'],
        'answers': [
          {
            'questionId': question['id'],
            'values': ['option-0'],
          },
        ],
      }),
    );
    expect(error.reason, ErrorCode.unknownRequest);
    expect(f.requests.length, before);
    await a.close();
  });
  test('Codex: Interactive capacity reached and Stop cancellation precedes interruption', () async {
    final f = await fixture({
      'turns': [
        {
          'actions': [
            for (var i = 0; i < 17; i++)
              {
                'send': {
                  'id': 'approval-$i',
                  'method': 'item/commandExecution/requestApproval',
                  'params': {
                    'threadId': r'$thread',
                    'turnId': r'$turn',
                    'itemId': 'cmd-$i',
                    'startedAtMs': 1,
                    'availableDecisions': ['accept', 'decline'],
                  },
                },
              },
            {'waitReply': 'approval-16'},
            {'waitInterrupt': true},
            terminalEvent('interrupted'),
          ],
        },
      ],
    });
    final a = await f.start();
    await a.prompt();
    await eventually(() => a.of(Method.agentPermissionRequested).length == 16);
    await waitFixture(
      f.report,
      (r) =>
          r['received'] is Json &&
          (r['received'] as Json)['id'] == 'approval-16',
    );
    expect(f.requests.where((r) => r['id'] == 'approval-16').single['result'], {
      'decision': 'cancel',
    });
    await a.call(Method.agentStop);
    await a.wait(Method.agentStopResult);
    final interrupt = f.requests.indexWhere(
      (r) => r['method'] == 'turn/interrupt',
    );
    for (var i = 0; i < 16; i++) {
      final answer = f.requests.indexWhere((r) => r['id'] == 'approval-$i');
      expect(answer, lessThan(interrupt));
      expect(f.requests[answer]['result'], {'decision': 'cancel'});
    }
    await a.close();
  });

  test(
    'Codex: Interruption cannot be confirmed and late completion is honest',
    () async {
      final f = await fixture({
        'turns': [
          {
            'actions': [
              {'waitInterrupt': true},
              {'delayMs': 11000},
              terminalEvent('interrupted'),
            ],
          },
        ],
      });
      final a = await f.start();
      await a.prompt();
      await a.wait(Method.agentState, where: (p) => p['turnId'] != null);
      await a.call(Method.agentStop);
      final timeout = await a.wait(
        Method.agentStopResult,
        where: (r) => r['outcome'] == 'notConfirmed',
      );
      expect(timeout['late'], isNot(true));
      expect(a.of(Method.agentState).last['state'], 'stopping');
      expect(LedgerView(profile()).units(), hasLength(1));
      final late = await a.wait(
        Method.agentStopResult,
        where: (r) => r['outcome'] == 'stopped',
      );
      expect(late['late'], true);
      await a.close();
    },
  );
  test(
    'Codex: Stop while output has no transcript credit acknowledges locally',
    () async {
      final f = await fixture({
        'turns': [
          {
            'actions': [
              deltaEvent(List.filled(2000000, 'x').join()),
              {'waitInterrupt': true},
              terminalEvent('interrupted'),
            ],
          },
        ],
      });
      final a = AgentPeer(f.desktop);
      await a.start(f.workspace, runtime: 'native');
      await a.attach(credit: false);
      await a.prompt();
      await a.wait(Method.agentState, where: (p) => p['turnId'] != null);
      final timer = Stopwatch()..start();
      await a.call(Method.agentStop);
      timer.stop();
      expect(timer.elapsedMilliseconds, lessThanOrEqualTo(250));
      await a.close();
    },
  );
  test('Codex: malformed optional question never becomes free text', () async {
    final f = await fixture({
      'turns': [
        {
          'actions': [
            {
              'send': {
                'id': 'malformed-question',
                'method': 'item/tool/requestUserInput',
                'params': {
                  'threadId': r'$thread',
                  'turnId': r'$turn',
                  'itemId': 'q',
                  'isBlocking': true,
                  'questions': [
                    {
                      'id': 'q',
                      'header': 'Choose',
                      'question': 'Which?',
                      'options': [7],
                    },
                  ],
                },
              },
            },
            {'waitReply': 'malformed-question'},
            deltaEvent('core remains usable'),
            terminalEvent('completed'),
          ],
        },
      ],
    });
    final a = await f.start();
    await a.prompt();
    await a.wait(Method.agentTurnEnded);
    expect(a.of(Method.agentQuestionRequested), isEmpty);
    await eventually(() => a.events.toString().contains('unavailable'));
    expect(a.events.toString(), contains('core remains usable'));
    await a.close();
  });

  test(
    'Codex: Native input is full refuses without another canonical user event',
    () async {
      final f = await fixture({
        'noReadAfterTurn': true,
        'turns': [
          {'actions': <Json>[]},
        ],
      });
      final a = await f.start();
      await a.prompt();
      final state = await a.wait(
        Method.agentState,
        where: (p) => p['turnId'] != null,
      );
      final text = List.filled(200000, 'n').join();
      var accepted = 0;
      RpcException? refusal;
      for (var i = 0; i < 20; i++) {
        try {
          await a.call(Method.agentSteer, {
            'sessionId': a.id,
            'runId': state['runId'],
            'expectedTurnId': state['turnId'],
            'text': text,
          });
          accepted++;
          await eventually(
            () =>
                a.events
                    .where((e) => e['kind'] == 'user')
                    .map((e) => (e['text']! as String).length)
                    .fold<int>(0, (n, length) => n + length) >=
                5 + accepted * text.length,
          );
        } on RpcException catch (e) {
          refusal = e;
          break;
        }
      }
      expect(refusal?.reason, ErrorCode.busy);
      expect(accepted, lessThan(20));
      await a.close();
    },
  );
  test(
    'Codex: Native transport breaks after admission and settles shared unit',
    () async {
      final f = await fixture({
        'turns': [
          {
            'actions': [
              {'closeStdout': true},
            ],
          },
        ],
      });
      final a = await f.start();
      await a.prompt();
      await a.wait(Method.agentExited, where: (r) => r['reason'] == 'failed');
      expect(LedgerView(profile()).units(), isEmpty);
      expect(agentRows(profile()), hasLength(1));
    },
  );
  test(
    'Codex: repeated early turns reserve the same stalled relay budget',
    () async {
      final f = await fixture({
        'turns': [
          for (var i = 0; i < 20; i++)
            {
              'beforeResponse': [
                deltaEvent(List.filled(100000, 'e').join()),
                terminalEvent('completed'),
              ],
              'actions': <Json>[],
            },
        ],
      });
      final a = AgentPeer(f.desktop);
      await a.start(f.workspace, runtime: 'native');
      await a.attach(credit: false);
      var completed = 0;
      for (var i = 0; i < 20; i++) {
        await a.prompt();
        await eventually(
          () =>
              a.of(Method.agentTurnEnded).length > completed ||
              a.of(Method.agentState).any((s) => s['state'] == 'failed'),
        );
        final stats =
            await f.desktop.connection.request('test/agent.stats', {}) as Json;
        final sessions = stats['sessions'] as Json;
        final row = sessions[a.id] as Json?;
        if (row != null) {
          expect(
            (row['queuedBytes']! as int) + (row['reservedBytes']! as int),
            lessThanOrEqualTo(1024 * 1024),
          );
        }
        if (a.of(Method.agentState).any((s) => s['state'] == 'failed')) break;
        completed++;
      }
      expect(completed, lessThan(20));
      await a.wait(Method.agentExited, where: (r) => r['reason'] == 'failed');
      expect(LedgerView(profile()).units(), isEmpty);
    },
  );

  Json outputDelta(String item, String delta) =>
      nativeEvent('item/commandExecution/outputDelta', {
        'threadId': r'$thread',
        'turnId': r'$turn',
        'itemId': item,
        'delta': delta,
      });
  List<String> toolTexts(AgentPeer a, String item) => [
    for (final e in a.events)
      if ((e['toolCallId'] as String? ?? '').contains(item))
        for (final c in (e['content'] as List? ?? const []).cast<Json>())
          if (c['content'] case {'text': final String text}) text,
  ];
  test('Codex: streamed command output accumulates per tool', () async {
    final f = await fixture({
      'turns': [
        {
          'actions': [
            outputDelta('stream-cmd', 'first '),
            outputDelta('stream-cmd', 'second'),
            terminalEvent('completed'),
          ],
        },
      ],
    });
    final a = await f.start();
    await a.prompt();
    await a.wait(Method.agentTurnEnded);
    await eventually(() => toolTexts(a, 'stream-cmd').length == 2);
    expect(toolTexts(a, 'stream-cmd'), ['first ', 'first second']);
    await a.close();
  });
  test('Codex: a secret fragmented across tool output deltas never leaves the host', () async {
    final f = await fixture();
    final report = await saveAgentFixture(
      f.desktop,
      work(),
      id: 'stream-secret-owner',
    );
    final owner = AgentPeer(f.desktop);
    await owner.start(f.workspace, runtime: 'stream-secret-owner');
    await owner.attach();
    final launch = await waitFixture(report, (r) => r['mcpServers'] is List);
    final server = (launch['mcpServers'] as List).single as Json;
    final secret =
        ((server['env'] as List).cast<Json>().firstWhere(
              (e) => e['name'] == 'KUMIKO_TOOL_SECRET',
            )['value'])!
            as String;
    final pieces = [
      for (var i = 0; i < secret.length; i += 3)
        secret.substring(i, min(i + 3, secret.length)),
    ];
    final script = jsonDecode(f.scriptFile.readAsStringSync()) as Json;
    script['turns'] = [
      {
        'actions': [
          outputDelta('secret-cmd', 'token: '),
          for (final piece in pieces) outputDelta('secret-cmd', piece),
          outputDelta('secret-cmd', ' done'),
          terminalEvent('completed'),
        ],
      },
    ];
    f.scriptFile.writeAsStringSync(jsonEncode(script));
    final a = await f.start();
    await a.prompt();
    await a.wait(Method.agentTurnEnded);
    await eventually(
      () => toolTexts(a, 'secret-cmd').any((t) => t.endsWith(' done')),
    );
    // Boolean assertions keep a failure from logging the credential.
    expect(jsonEncode(a.events).contains(secret), isFalse);
    expect(toolTexts(a, 'secret-cmd').join().contains(secret), isFalse);
    expect(toolTexts(a, 'secret-cmd').last.contains('<redacted>'), isTrue);
    await a.close();
    await owner.close();
  });

  test(
    'Codex: minimum contract accepts granular native approval policy',
    () async {
      final f = await fixture({
        'approvalPolicy': {
          'granular': {
            'mcp_elicitations': true,
            'rules': true,
            'sandbox_approval': true,
          },
        },
      });
      final a = await f.start();
      await a.prompt();
      await a.wait(Method.agentTurnEnded);
      await a.close();
    },
  );

  test('Codex: unsupported native steer disables only steering before next draft removal', () async {
    final f = await fixture({
      'steerError': {'code': -32601, 'message': 'No steer method'},
      'turns': [
        {
          'actions': [
            {'waitInterrupt': true},
            terminalEvent('interrupted'),
          ],
        },
      ],
    });
    final a = await f.start();
    await a.prompt();
    final state = await a.wait(
      Method.agentState,
      where: (p) => p['turnId'] != null,
    );
    await a.call(Method.agentSteer, {
      'sessionId': a.id,
      'runId': state['runId'],
      'expectedTurnId': state['turnId'],
      'text': 'first',
    });
    await eventually(
      () => a.events.any(
        (e) =>
            e['kind'] == 'notice' && (e['text'] as String).contains('Steering'),
      ),
    );
    await a.call(Method.agentDraftSave, {
      'sessionId': a.id,
      'revision': 1,
      'text': 'keep second',
    });
    final error = await rpcFailure(
      a.call(Method.agentSteer, {
        'sessionId': a.id,
        'runId': state['runId'],
        'expectedTurnId': state['turnId'],
        'text': 'keep second',
        'draftRevision': 1,
        'draftSynced': true,
      }),
    );
    expect(error.reason, ErrorCode.methodNotAvailable);
    expect((await a.call(Method.agentDraftLoad))['text'], 'keep second');
    expect(f.requests.where((r) => r['method'] == 'turn/steer'), hasLength(1));
    await a.call(Method.agentStop);
    await a.wait(Method.agentTurnEnded);
    await a.close();
  });

  test(
    'Codex: known unavailable steering suppresses async forms only',
    () async {
      final f = await fixture({
        'steerError': {'code': -32601, 'message': 'No steer method'},
        'turns': [
          {
            'actions': [
              deltaEvent('ready'),
              {'delayMs': 500},
              nativeEvent('item/completed', {
                'threadId': r'$thread',
                'turnId': r'$turn',
                'item': {
                  'id': 'later-async',
                  'type': 'agentMessage',
                  'text': 'Choose',
                  'questions': [
                    {
                      'title': 'Async',
                      'options': ['One'],
                    },
                  ],
                },
              }),
              {
                'send': {
                  'id': 'blocking',
                  'method': 'item/tool/requestUserInput',
                  'params': {
                    'threadId': r'$thread',
                    'turnId': r'$turn',
                    'itemId': 'blocking-item',
                    'isBlocking': true,
                    'questions': [
                      {
                        'id': 'blocking-q',
                        'header': 'Blocking',
                        'question': 'Which?',
                        'options': [
                          {'label': 'One'},
                        ],
                      },
                    ],
                  },
                },
              },
              {'waitInterrupt': true},
              terminalEvent('interrupted'),
            ],
          },
        ],
      });
      final a = await f.start();
      await a.prompt();
      final state = await a.wait(
        Method.agentState,
        where: (p) => p['turnId'] != null,
      );
      await a.call(Method.agentSteer, {
        'sessionId': a.id,
        'runId': state['runId'],
        'expectedTurnId': state['turnId'],
        'text': 'first',
      });
      await eventually(
        () => a.events.any(
          (e) =>
              e['kind'] == 'notice' &&
              (e['text'] as String).contains('Steering'),
        ),
      );
      await a.wait(
        Method.agentQuestionRequested,
        where: (p) =>
            ((p['questions'] as List).single as Json)['header'] == 'Blocking',
      );
      expect(a.of(Method.agentQuestionRequested), hasLength(1));
      await a.call(Method.agentStop);
      await a.wait(Method.agentTurnEnded);
      await a.close();
    },
  );

  test(
    'Codex: Stop pending async question sends no invented RPC reply',
    () async {
      final f = await fixture({
        'turns': [
          {
            'actions': [
              nativeEvent('item/completed', {
                'threadId': r'$thread',
                'turnId': r'$turn',
                'item': {
                  'id': 'async-stop',
                  'type': 'agentMessage',
                  'text': 'Choose',
                  'questions': [
                    {
                      'title': 'Which?',
                      'options': ['One'],
                    },
                  ],
                },
              }),
              {'waitInterrupt': true},
              terminalEvent('interrupted'),
            ],
          },
        ],
      });
      final a = await f.start();
      await a.prompt();
      final q = await a.wait(Method.agentQuestionRequested);
      await a.call(Method.agentStop);
      await a.wait(Method.agentTurnEnded);
      expect(
        f.requests.where(
          (r) => r['method'] == null && r['id'] == 'item:async-stop',
        ),
        isEmpty,
      );
      expect(
        f.requests.where((r) => r['method'] == 'turn/interrupt'),
        hasLength(1),
      );
      final resolutions = a
          .of(Method.agentQuestionResolved)
          .where((r) => r['requestId'] == q['requestId']);
      expect(resolutions, hasLength(1));
      expect(resolutions.single['outcome'], 'cancelled');
      await a.close();
    },
  );

  test(
    'Codex: native request retirement cannot collide with async form identity',
    () async {
      final f = await fixture({
        'turns': [
          {
            'actions': [
              nativeEvent('item/completed', {
                'threadId': r'$thread',
                'turnId': r'$turn',
                'item': {
                  'id': 'collision',
                  'type': 'agentMessage',
                  'text': 'Choose',
                  'questions': [
                    {
                      'title': 'Which?',
                      'options': ['One'],
                    },
                  ],
                },
              }),
              {
                'send': {
                  'id': 'item:collision',
                  'method': 'item/commandExecution/requestApproval',
                  'params': {
                    'threadId': r'$thread',
                    'turnId': r'$turn',
                    'itemId': 'command',
                    'startedAtMs': 1,
                    'availableDecisions': ['accept', 'decline'],
                  },
                },
              },
              nativeEvent('serverRequest/resolved', {
                'threadId': r'$thread',
                'requestId': 'item:collision',
              }),
              deltaEvent('retirement processed'),
              {'waitInterrupt': true},
              terminalEvent('interrupted'),
            ],
          },
        ],
      });
      final a = await f.start();
      await a.prompt();
      final q = await a.wait(Method.agentQuestionRequested);
      await a.wait(Method.agentPermissionResolved);
      await eventually(
        () => a.events.any((e) => e['text'] == 'retirement processed'),
      );
      expect(a.of(Method.agentQuestionResolved), isEmpty);
      await a.call(Method.agentStop);
      await a.wait(Method.agentTurnEnded);
      expect(
        a
            .of(Method.agentQuestionResolved)
            .where((r) => r['requestId'] == q['requestId']),
        hasLength(1),
      );
      await a.close();
    },
  );

  for (final mode in ['unsupported', 'malformed', 'timeout']) {
    test('Codex: optional async answer $mode stays feature local', () async {
      final f = await fixture({
        if (mode == 'unsupported')
          'steerError': {'code': -32601, 'message': 'No steer method'},
        if (mode == 'malformed') 'steerResult': {'turnId': 'wrong'},
        if (mode == 'timeout') 'steerNoAck': true,
        'turns': [
          {
            'actions': [
              nativeEvent('item/completed', {
                'threadId': r'$thread',
                'turnId': r'$turn',
                'item': {
                  'id': 'async-question',
                  'type': 'agentMessage',
                  'text': 'Choose',
                  'questions': [
                    {
                      'title': 'Which?',
                      'options': ['One', 'Two'],
                    },
                  ],
                },
              }),
              {'waitInterrupt': true},
              terminalEvent('interrupted'),
            ],
          },
        ],
      });
      final a = await f.start();
      await a.prompt();
      final q = await a.wait(Method.agentQuestionRequested);
      final question = (q['questions'] as List).single as Json;
      final answer = <String, Object?>{
        'sessionId': a.id,
        'runId': q['runId'],
        'turnId': q['turnId'],
        'requestId': q['requestId'],
        'answers': [
          {
            'questionId': question['id'],
            'values': ['option-0'],
          },
        ],
      };
      await a.call(Method.agentQuestionAnswer, answer);
      await a.wait(Method.agentQuestionResolved);
      await eventually(
        () => a.events.any(
          (e) =>
              e['kind'] == 'notice' &&
              (e['text'] as String).contains('Steering'),
        ),
      );
      expect(
        a.of(Method.agentState).any((p) => p['state'] == 'failed'),
        isFalse,
      );
      expect(
        (await rpcFailure(a.call(Method.agentQuestionAnswer, answer))).reason,
        ErrorCode.unknownRequest,
      );
      expect(
        f.requests.where((r) => r['method'] == 'turn/steer'),
        hasLength(1),
      );
      await a.call(Method.agentStop);
      await a.wait(Method.agentTurnEnded);
      await a.close();
    });
  }
  for (final mode in ['rejected', 'timeout', 'malformed']) {
    test(
      'Codex: interrupt $mode has visible reason and honest outcome',
      () async {
        final f = await fixture({
          if (mode == 'rejected')
            'interruptError': {
              'code': -32601,
              'message': 'No interrupt method',
            },
          if (mode == 'timeout') 'interruptNoAck': true,
          if (mode == 'malformed') 'interruptResult': 'invalid',
          'turns': [
            {
              'actions': [
                {'delayMs': 12000},
                terminalEvent('completed'),
              ],
            },
          ],
        });
        final a = await f.start();
        await a.prompt();
        await a.wait(Method.agentState, where: (p) => p['turnId'] != null);
        await a.call(Method.agentStop);
        if (mode == 'malformed') {
          await a.wait(Method.agentState, where: (p) => p['state'] == 'failed');
        } else {
          await eventually(
            () => a.events.any(
              (e) =>
                  e['kind'] == 'notice' &&
                  (e['text'] as String).contains('Interruption'),
            ),
            within: const Duration(seconds: 11),
          );
          final reason =
              a.events.lastWhere(
                    (e) =>
                        e['kind'] == 'notice' &&
                        (e['text'] as String).contains('Interruption'),
                  )['text']
                  as String;
          expect(
            reason,
            contains(
              mode == 'rejected'
                  ? 'No interrupt method'
                  : 'turn/interrupt timed out',
            ),
          );
          expect(
            a.of(Method.agentState).any((p) => p['state'] == 'failed'),
            isFalse,
          );
          await a.wait(
            Method.agentStopResult,
            where: (p) => p['outcome'] == 'notConfirmed',
          );
          expect(a.of(Method.agentState).last['state'], 'stopping');
          await a.wait(Method.agentTurnEnded);
        }
        expect(
          f.requests.where((r) => r['method'] == 'turn/interrupt'),
          hasLength(1),
        );
        if (mode != 'malformed') await a.close();
      },
    );
  }

  test('Codex: Request is retired before answer', () async {
    final f = await fixture({
      'turns': [
        {
          'actions': [
            {
              'send': {
                'id': 'retiring',
                'method': 'item/commandExecution/requestApproval',
                'params': {
                  'threadId': r'$thread',
                  'turnId': r'$turn',
                  'itemId': 'command',
                  'startedAtMs': 1,
                  'availableDecisions': ['accept', 'decline'],
                },
              },
            },
            terminalEvent('completed'),
          ],
        },
      ],
    });
    final a = await f.start();
    await a.prompt();
    await a.wait(Method.agentTurnEnded);
    final p = a.of(Method.agentPermissionRequested).single;
    final before = f.requests.length;
    final error = await rpcFailure(
      a.call(Method.agentPermissionReply, {
        'sessionId': a.id,
        'requestId': p['requestId'],
        'optionId': ((p['options'] as List).first as Json)['optionId'],
      }),
    );
    expect(error.reason, ErrorCode.unknownRequest);
    expect(f.requests.length, before);
    await a.close();
  });
  test('Codex: Turn ended before steering', () async {
    final f = await fixture({
      'turns': [
        {
          'actions': [
            {'delayMs': 100},
            terminalEvent('completed'),
          ],
        },
      ],
    });
    final a = await f.start();
    await a.prompt();
    final state = await a.wait(
      Method.agentState,
      where: (p) => p['turnId'] != null,
    );
    await a.wait(Method.agentTurnEnded);
    await a.call(Method.agentDraftSave, {
      'sessionId': a.id,
      'revision': 1,
      'text': 'keep text',
    });
    final before = f.requests.length;
    final e = await rpcFailure(
      a.call(Method.agentSteer, {
        'sessionId': a.id,
        'runId': state['runId'],
        'expectedTurnId': state['turnId'],
        'text': 'keep text',
        'draftRevision': 1,
        'draftSynced': true,
      }),
    );
    expect(e.reason, ErrorCode.turnRunning);
    expect((await a.call(Method.agentDraftLoad))['text'], 'keep text');
    expect(f.requests.length, before);
    await a.close();
  });
  test('Codex: Untracked child asks permission', () async {
    final f = await fixture({
      'turns': [
        {
          'actions': [
            {
              'send': {
                'id': 'child-approval',
                'method': 'item/commandExecution/requestApproval',
                'params': {
                  'threadId': 'unknown-child',
                  'turnId': 'child-turn',
                  'itemId': 'cmd',
                  'startedAtMs': 1,
                  'availableDecisions': ['accept', 'decline'],
                },
              },
            },
            {'waitReply': 'child-approval'},
            terminalEvent('completed'),
          ],
        },
      ],
    });
    final a = await f.start();
    await a.prompt();
    await a.wait(Method.agentTurnEnded);
    expect(a.of(Method.agentPermissionRequested), isEmpty);
    expect(
      f.requests.where((r) => r['id'] == 'child-approval').single['error'],
      isNotNull,
    );
    await eventually(() => a.events.toString().contains('unknown child'));
    await a.close();
  });
  test(
    'Codex: live and revoked bridge secrets are redacted across native chunks',
    () async {
      final f = await fixture();
      final report = await saveAgentFixture(
        f.desktop,
        work(),
        id: 'secret-owner',
      );
      final owner = AgentPeer(f.desktop);
      await owner.start(f.workspace, runtime: 'secret-owner');
      await owner.attach();
      final launch = await waitFixture(report, (r) => r['mcpServers'] is List);
      final servers = launch['mcpServers'] as List;
      final entry = servers.single as Json;
      final env = entry['env'] as List;
      final secret =
          (env.cast<Json>().firstWhere(
                (v) => v['name'] == 'KUMIKO_TOOL_SECRET',
              )['value'])!
              as String;
      final script = jsonDecode(f.scriptFile.readAsStringSync()) as Json;
      script['turns'] = [
        {
          'actions': [
            deltaEvent(secret.substring(0, 11)),
            deltaEvent(secret.substring(11)),
            terminalEvent('completed'),
          ],
        },
      ];
      f.scriptFile.writeAsStringSync(jsonEncode(script));
      final a = await f.start();
      await owner.close();
      await a.prompt();
      await a.wait(Method.agentTurnEnded);
      await eventually(() => a.events.toString().contains('<redacted>'));
      expect(a.events.toString().contains(secret), false);
      expect(a.notifications.toString().contains(secret), false);
      expect(
        a.events
                .where((event) => event['kind'] == 'agentText')
                .map((event) => event['text'])
                .join() ==
            '<redacted>',
        true,
      );
      await a.close();
    },
  );

  test('Codex: Continue without safe config has no bridge entry', () async {
    final f = NativeFixture(
      profile(),
      work(),
      script: {
        'configReadError': {
          'code': -32601,
          'message': 'unsupported config/read',
        },
        'resumeThread': idleThread,
      },
    );
    final (a, row) = await restore(f);
    final state = await a.wait(
      Method.agentState,
      where: (p) => p['state'] == 'idle',
    );
    expect((state['tools'] as Json)['status'], 'unavailable');
    expect((state['tools'] as Json)['reason'], contains('config/read'));
    expect(f.requests.toString().contains('KUMIKO_TOOL_SECRET'), false);
    expect(
      f.requests.where((r) => r['method'] == 'thread/resume').single['params']
          as Json,
      isNot(contains('config')),
    );
    expect(agentRows(profile()).single, row);
    await a.close();
  });
  test(
    'Codex: more than 64 file changes retain visible omission count',
    () async {
      final f = await fixture({
        'turns': [
          {
            'actions': [
              nativeEvent('item/completed', {
                'threadId': r'$thread',
                'turnId': r'$turn',
                'item': {
                  'id': 'files',
                  'type': 'fileChange',
                  'status': 'completed',
                  'changes': [
                    for (var i = 0; i < 70; i++)
                      {
                        'path': 'file-$i',
                        'diff': '+x',
                        'kind': {'type': 'update', 'move_path': null},
                      },
                  ],
                },
              }),
              terminalEvent('completed'),
            ],
          },
        ],
      });
      final a = await f.start();
      await a.prompt();
      await a.wait(Method.agentTurnEnded);
      await eventually(() => a.events.any((e) => e['kind'] == 'toolUpdate'));
      final tool = a.events.firstWhere((e) => e['kind'] == 'toolUpdate');
      expect(tool['contentTruncated'], true);
      expect(tool['omittedItems'], 6);
      await a.close();
    },
  );
  for (final malformed in [
    3,
    {
      'path': 'file',
      'diff': '+x',
      'kind': {'type': 'mystery'},
    },
  ]) {
    test(
      'Codex: malformed file change core fails visibly $malformed',
      () async {
        final f = await fixture({
          'turns': [
            {
              'actions': [
                nativeEvent('item/completed', {
                  'threadId': r'$thread',
                  'turnId': r'$turn',
                  'item': {
                    'id': 'files',
                    'type': 'fileChange',
                    'status': 'completed',
                    'changes': [malformed],
                  },
                }),
                terminalEvent('completed'),
              ],
            },
          ],
        });
        final a = await f.start();
        await a.prompt();
        final exited = await a.wait(
          Method.agentExited,
          where: (p) => p['reason'] == 'failed',
          within: const Duration(seconds: 3),
        );
        expect(exited['error'], ErrorCode.adapterProtocol);
        expect(LedgerView(profile()).units(), isEmpty);
      },
    );
  }
  test(
    'Codex: oversized escaped Unicode tool output retains truncation metadata',
    () async {
      final output = List.filled(100000, '\u{1F98A}\u0000').join();
      final f = await fixture({
        'turns': [
          {
            'actions': [
              nativeEvent('item/commandExecution/outputDelta', {
                'threadId': r'$thread',
                'turnId': r'$turn',
                'itemId': 'cmd',
                'delta': output,
              }),
              terminalEvent('completed'),
            ],
          },
        ],
      });
      final a = await f.start();
      await a.prompt();
      await a.wait(Method.agentTurnEnded);
      await eventually(() => a.events.any((e) => e['kind'] == 'toolUpdate'));
      final tool = a.events.firstWhere((e) => e['kind'] == 'toolUpdate');
      expect(tool['contentTruncated'], true);
      expect(tool['truncated'], true);
      await a.close();
    },
  );
}
