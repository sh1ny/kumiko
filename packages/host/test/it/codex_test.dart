import 'dart:io';
import 'dart:convert';

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
  setUpAll(buildTestHost);
  late Directory profile;
  late Directory work;
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
      'thread/start',
    ]);
    final stats =
        await f.desktop.connection.request('test/agent.stats', {}) as Json;
    expect(((stats['sessions'] as Json)[a.id] as Json)['hasGrant'], false);
    expect(a.started.tools!.status, AgentToolsStatus.unavailable);
    expect(a.started.tools!.reason, contains('safe'));
    expect(a.started.tools!.reason, isNot(contains('endpoint-unavailable')));
    expect(f.requests.toString(), isNot(contains('KUMIKO_TOOL_SECRET')));
    expect(f.requests.toString(), isNot(contains('mcp_servers')));
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
                    {
                      'acceptWithExecpolicyAmendment': {
                        'execpolicy_amendment': [
                          'echo',
                          List.filled(300, 'x').join(),
                          'future-command-scope',
                        ],
                      },
                    },
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
        await a.close();
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
  for (final duringTurn in [false, true]) {
    test(
      'Codex: Known Codex authentication failure duringTurn=$duringTurn',
      () async {
        final error = {
          'code': -32123,
          'message': 'fixture-confirmed-native-auth',
        };
        final f = await fixture(
          duringTurn
              ? {
                  'turns': [
                    {'error': error},
                  ],
                }
              : {'startError': error},
          {
            'KUMIKO_TEST_CODEX_AUTH_SIGNATURES':
                '[[-32123,"fixture-confirmed-native-auth"]]',
          },
        );
        if (duringTurn) {
          final a = await f.start();
          await a.prompt();
          final ended = await a.wait(Method.agentTurnEnded);
          expect(ended['error'], ErrorCode.authRequired);
          await a.close();
        } else {
          expect((await refusedStart(f)).reason, ErrorCode.authRequired);
        }
      },
    );
  }
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
      await a.close();
    },
  );

  test('Codex: Continue before native history has no bridge entry and reports safe delivery unavailable', () async {
    final f = await fixture();
    final a = await f.start();
    await a.close();
    final error = await rpcFailure(
      f.desktop.connection.request(Method.agentContinue, {'sessionId': a.id}),
    );
    expect(error.reason, ErrorCode.resumeUnavailable);
    expect(error.data['tools'], isA<Json>());
    expect(
      ((error.data['tools'] as Json)['reason']! as String).contains('safe'),
      true,
    );
    expect(f.requests.toString().contains('KUMIKO_TOOL_SECRET'), false);
    expect(f.requests.toString().contains('mcp_servers'), false);
    expect(LedgerView(profile()).units(), isEmpty);
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
