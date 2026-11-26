import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:domain/domain.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/omp_support.dart';

void main() {
  setUpAll(buildTestHost);

  test('scripted OMP fixture reports version, command, cwd and EOF', () async {
    final profile = tempDir('omp_fixture_profile');
    final work = tempDir('omp_fixture_work');
    addTearDown(() => deleteTree(profile));
    addTearDown(() => deleteTree(work));
    final fixture = OmpFixture(
      profile,
      work,
      script: {
        'versionOutput': 'omp/19.1.2',
        'commands': {
          'prompt': [
            [
              {
                'type': 'prompt_result',
                'id': r'$prompt',
                'status': 'completed',
              },
              {'type': 'response', 'id': r'$id', 'success': true},
            ],
          ],
        },
      },
    )..writeScript();
    final probe = await Process.run(testHostExecutable(), [
      ...fixture.argv,
      '--version',
    ], workingDirectory: profile.path);
    expect(probe.exitCode, 0);
    expect((probe.stdout as String).trim(), 'omp/19.1.2');

    final root = await Process.start(
      testHostExecutable(),
      fixture.argv,
      workingDirectory: work.path,
      environment: {'OMP_PARENT_CANARY': 'smoke'},
    );
    var exited = false;
    addTearDown(() async {
      if (!exited) root.kill(ProcessSignal.sigkill);
      await root.exitCode;
    });
    final stderr = root.stderr.transform(utf8.decoder).join();
    final output = StreamIterator(
      root.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    addTearDown(output.cancel);
    Future<Json> frame() async {
      expect(await output.moveNext(), isTrue);
      return jsonDecode(output.current) as Json;
    }

    expect((await frame())['type'], 'ready');
    root.stdin.writeln('{"type":"prompt","id":"k7","message":"smoke"}');
    await root.stdin.flush();
    expect(await frame(), {
      'type': 'prompt_result',
      'id': 'k7',
      'status': 'completed',
    });
    expect(await frame(), {'type': 'response', 'id': 'k7', 'success': true});
    await root.stdin.close();
    expect(await output.moveNext(), isFalse);
    final exitCode = await root.exitCode;
    exited = true;
    expect(exitCode, 0, reason: await stderr);
    final reports = fixture.reports;
    expect(reports.map((row) => row['launch']).whereType<String>(), [
      'probe',
      'root',
    ]);
    expect(
      Directory(reports[1]['cwd']! as String).resolveSymbolicLinksSync(),
      work.resolveSymbolicLinksSync(),
    );
    expect(reports[1]['parentCanary'], 'smoke');
    expect(reports[1]['argv'], fixture.argv);
    expect(fixture.commands.single['id'], 'k7');
    expect(reports.last['stdin'], 'eof');
  });

  Future<OmpFixture> openFixture({
    Json script = const {},
    Set<String> caps = ompCaps,
    Map<String, String> environment = const {},
    String? executable,
    List<String>? profileArgs,
  }) async {
    final profile = tempDir('omp_host_profile');
    final work = tempDir('omp_host_work');
    addTearDown(() => deleteTree(profile));
    addTearDown(() => deleteTree(work));
    final fixture = OmpFixture(profile, work, script: script);
    await fixture.open(
      caps: caps,
      environment: environment,
      executable: executable,
      profileArgs: profileArgs,
    );
    return fixture;
  }

  Future<RpcException> refused(OmpFixture fixture) async {
    try {
      await fixture.start();
    } on RpcException catch (error) {
      expect(agentRows(fixture.profile), isEmpty);
      expect(LedgerView(fixture.profile).units(), isEmpty);
      return error;
    }
    fail('OMP started when it should have been refused');
  }

  test('OMP: Start native OMP', () async {
    final fixture = await openFixture();
    final peer = await fixture.start();
    expect(peer.started.adapter.name, 'omp-rpc');
    expect(fixture.reports.map((r) => r['launch']).whereType<String>(), [
      'probe',
      'root',
    ]);
    expect(fixture.commands.map((c) => c['type']), [
      'set_event_filter',
      'get_state',
      'set_subagent_subscription',
      'get_subagents',
      'set_host_tools',
    ]);
    expect(fixture.commands.first['events'], isNull);
    expect(fixture.commands.first['messageUpdates'], 'delta');
    await peer.wait(
      Method.agentState,
      where: (state) => state['state'] == 'idle',
    );
  });

  test('OMP: Compatible peers', () async {
    final fixture = await openFixture();
    expect(
      fixture.desktop.connection.negotiated?.capabilities,
      containsAll(ompCaps),
    );
    final peer = await fixture.start();
    expect(peer.started.eventChannel, greaterThan(0));
  });

  test('OMP: Older desktop', () async {
    final fixture = await openFixture(caps: {Capability.agent});
    final error = await refused(fixture);
    expect(error.reason, ErrorCode.methodNotAvailable);
    expect(error.message, contains('omp'));
    expect(fixture.reports, isEmpty);
  });

  test('OMP: Supported version', () async {
    final peer = await (await openFixture(
      script: {'versionOutput': 'omp/19.2.3'},
    )).start();
    expect(peer.started.adapter.version, '19.2.3');
  });

  test('OMP: Version too old', () async {
    final fixture = await openFixture(script: {'versionOutput': 'omp/18.20.0'});
    final error = await refused(fixture);
    expect(error.message, allOf(contains('18.20.0'), contains('18.20.1')));
    expect(fixture.reports.map((r) => r['launch']), ['probe']);
  });

  test('OMP: Probe fails', () async {
    final fixture = await openFixture(script: {'probeExit': 7});
    final error = await refused(fixture);
    expect(error.message, contains('exited 7'));
    expect(fixture.reports.map((r) => r['launch']), ['probe']);
  });

  test('OMP: Readiness never arrives', () async {
    final fixture = await openFixture(
      script: {
        'startupStderr': 'OMP startup diagnostic',
        'startup': [
          {'exit': 2},
        ],
      },
    );
    final error = await refused(fixture);
    expect(
      error.message,
      allOf(contains('ready'), contains('OMP startup diagnostic')),
    );
    expect(fixture.commands, isEmpty);
  });

  test('OMP: Unsupported protocol version', () async {
    final fixture = await openFixture(
      script: {
        'startup': [
          {
            'type': 'ready',
            'supportedProtocolVersions': [2, 3],
          },
        ],
      },
    );
    final error = await refused(fixture);
    expect(error.reason, ErrorCode.adapterProtocol);
    expect(
      error.message,
      allOf(contains('unsupported OMP RPC protocol'), contains('[2, 3]')),
    );
    expect(fixture.commands, isEmpty);
  });

  test('OMP: Identity stored', () async {
    final fixture = await openFixture();
    await fixture.start();
    final row = agentRows(fixture.profile).single;
    expect(row['native_session_id'], 'fixture-session');
    expect(row['runtime_kind'], 'omp');
    expect(row['adapter_name'], 'omp-rpc');
    expect(row['adapter_version'], '18.20.1');
    expect(row['workspace_id'], fixture.workspace);
    expect(row['target_identity'], isNotEmpty);
    expect(
      Directory(row['target_path']! as String).resolveSymbolicLinksSync(),
      fixture.work.resolveSymbolicLinksSync(),
    );
  });

  test('OMP: Identity missing', () async {
    final fixture = await openFixture(
      script: {
        'commands': {
          'get_state': [
            [
              {
                'type': 'response',
                'id': r'$id',
                'success': true,
                'data': <String, Object?>{},
              },
            ],
          ],
        },
      },
    );
    final error = await refused(fixture);
    expect(error.reason, ErrorCode.adapterProtocol);
    expect(error.message, contains('sessionId'));
  });

  test(
    'OMP: Native registration injects no MCP configuration or grant',
    () async {
      final fixture = await openFixture();
      final peer = await fixture.start();
      expect(peer.started.tools?.status, AgentToolsStatus.notYetUsed);
      final stats = await fixture.desktop.connection.request(
        'test/agent.stats',
        {},
      ) as Json;
      expect(
        ((stats['sessions'] as Json)[peer.id] as Json)['hasGrant'],
        isFalse,
      );
      expect(
        fixture.reports
            .where((r) => r['launch'] != null)
            .every((r) => r['hasToolSecret'] == false),
        isTrue,
      );
      final registration = fixture.commands.singleWhere(
        (c) => c['type'] == 'set_host_tools',
      );
      final definition = (registration['tools']! as List).cast<Json>().single;
      expect(definition, {
        'name': 'kumiko_session_info',
        'label': 'kumiko_session_info',
        'description': contains('Read-only'),
        'parameters': {
          'type': 'object',
          'properties': <String, Object?>{},
          'additionalProperties': false,
        },
        'loadMode': 'essential',
      });
      final sent = jsonEncode(fixture.commands);
      expect(
        sent,
        isNot(contains(RegExp(r'mcpServers|--mcp-bridge|KUMIKO_TOOL_SECRET'))),
      );
      expect(fixture.work.listSync(), isEmpty);
      await peer.close();
    },
  );

  test('OMP: User-configured provider', () async {
    const canary = 'test-only-provider-canary';
    final fixture = await openFixture(
      environment: {'OMP_PARENT_CANARY': canary},
    );
    final peer = await fixture.start();
    await peer.wait(Method.agentState);
    expect(
      fixture.reports
          .where((r) => r['launch'] == 'root')
          .single['parentCanary'],
      canary,
    );
    expect(
      fixture.reports
          .where((r) => r['launch'] == 'probe')
          .single['parentCanary'],
      isNull,
    );
    expect(
      jsonEncode([
        peer.started.toJson(),
        peer.of(Method.agentState),
        peer.events,
        agentRows(fixture.profile),
        readHostLog(fixture.profile),
      ]),
      isNot(contains(canary)),
    );
  });

  test('OMP: OMP follows minimum-version compatibility', () async {
    final peer = await (await openFixture()).start();
    expect(
      peer.started.capabilities,
      unorderedEquals(['prompt', 'streaming', 'cancel']),
    );
    expect(peer.started.tools?.status, AgentToolsStatus.notYetUsed);
  });

  // Keep the copy beside its bundled libraries. Never change the shared host.
  test('OMP: Executable replaced after the probe', () async {
    final source = File(testHostExecutable());
    final stamp = tempDir('omp_executable');
    addTearDown(() => deleteTree(stamp));
    final suffix = Platform.isWindows ? '.exe' : '';
    final executable = source.copySync(
      joinPath(
        source.parent.path,
        '${stamp.uri.pathSegments.where((s) => s.isNotEmpty).last}$suffix',
      ),
    );
    addTearDown(executable.deleteSync);
    final fixture = await openFixture(
      script: {'probeDelayMs': 1500},
      executable: executable.path,
    );
    final before = executable.lastModifiedSync();
    final failure = refused(fixture);
    final checked = expectLater(
      failure,
      completion(
        isA<RpcException>().having(
          (error) => error.message,
          'message',
          contains('executable changed after version probe'),
        ),
      ),
    );
    await waitFixture(fixture.report, (row) => row['launch'] == 'probe');
    try {
      executable.setLastModifiedSync(
        before.subtract(const Duration(seconds: 10)),
      );
      await checked;
    } finally {
      executable.setLastModifiedSync(before);
    }
    expect(fixture.reports.map((r) => r['launch']), ['probe']);
  });

  Json accepted([Json? data]) => {
    'type': 'response',
    'id': r'$id',
    'success': true,
    'data': ?data,
  };

  Json terminal(String status, {String? error}) => {
    'type': 'prompt_result',
    'id': r'$prompt',
    'status': status,
    'error': ?error,
  };

  Json delta(String value, {String subtype = 'text_delta', String id = 'm1'}) =>
      {
        'type': 'message_update',
        'messageId': id,
        'message': {'role': 'assistant'},
        'assistantMessageEvent': {
          'type': subtype,
          'delta': value,
          'contentIndex': 0,
        },
      };

  Future<OmpFixture> turns(List<List<Object?>> frames) => openFixture(
    script: {
      'commands': {'prompt': frames},
    },
  );

  Json approval(String id, List<String> options) => {
    'type': 'extension_ui_request',
    'id': id,
    'method': 'select',
    'title': 'Allow tool: bash\nCommand: echo demo',
    'options': options,
  };

  Future<Json> asked(AgentPeer peer, {String? except}) => peer.wait(
    Method.agentPermissionRequested,
    where: (request) => request['requestId'] != except,
    within: const Duration(minutes: 2),
  );

  Future<Json> answer(AgentPeer peer, Json request, String label) =>
      peer.call(Method.agentPermissionReply, {
        'sessionId': peer.id,
        'requestId': request['requestId'],
        'optionId': (request['options'] as List<Object?>)
            .cast<Json>()
            .singleWhere((option) => option['name'] == label)['optionId'],
      });

  test(
    'OMP: Explicit one-shot approval and denial round-trip exact values',
    () async {
      final fixture = await openFixture(
        script: {
          'commands': {
            'prompt': [
              [
                accepted(),
                approval('a1', [
                  'Approve',
                  'Approve bash for this session',
                  'Deny',
                ]),
              ],
              [
                accepted(),
                approval('a2', [
                  'Approve File',
                  'Always Approve File',
                  'Approve Once',
                  'Deny',
                ]),
              ],
            ],
            'extension_ui_response': [
              [terminal('completed')],
              [terminal('completed')],
            ],
          },
        },
      );
      final peer = await fixture.start();
      await peer.prompt('first');
      final request = await asked(peer);
      expect(request['preview'], contains('Command: echo demo'));
      final options = (request['options'] as List<Object?>).cast<Json>();
      expect(options.map((option) => option['name']), ['Approve', 'Deny']);
      expect(
        fixture.commands.where((row) => row['type'] == 'extension_ui_response'),
        isEmpty,
      );
      await expectLater(
        peer.call(Method.agentPermissionReply, {
          'sessionId': peer.id,
          'requestId': request['requestId'],
          'optionId': 'Approve bash for this session',
        }),
        rpcCode(ErrorCode.invalidParams),
      );
      await answer(peer, request, 'Approve');
      await expectLater(
        answer(peer, request, 'Deny'),
        rpcCode(ErrorCode.unknownRequest),
      );
      await peer.wait(
        Method.agentTurnEnded,
        within: const Duration(minutes: 2),
      );
      await peer.prompt('second');
      final next = await asked(peer, except: request['requestId'] as String);
      expect(
        (next['options'] as List<Object?>).cast<Json>().map((o) => o['name']),
        ['Approve Once', 'Deny'],
      );
      await answer(peer, next, 'Deny');
      await peer.wait(
        Method.agentPermissionResolved,
        where: (value) => value['requestId'] == next['requestId'],
        within: const Duration(minutes: 2),
      );
      await peer.close();
      expect(
        fixture.commands.where((row) => row['type'] == 'extension_ui_response'),
        [
          {'type': 'extension_ui_response', 'id': 'a1', 'value': 'Approve'},
          {'type': 'extension_ui_response', 'id': 'a2', 'value': 'Deny'},
        ],
      );
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test('OMP: Withdrawal and turn end retire the exact approval', () async {
    final fixture = await openFixture(
      script: {
        'commands': {
          'prompt': [
            [
              accepted(),
              approval('gone', ['Approve', 'Deny']),
              {
                'type': 'extension_ui_request',
                'method': 'cancel',
                'id': 'withdraw',
                'targetId': 'gone',
              },
              approval('keep', ['Approve', 'Deny']),
              approval('end', ['Approve', 'Deny']),
            ],
          ],
          'extension_ui_response': [
            [terminal('completed')],
          ],
        },
      },
    );
    final peer = await fixture.start();
    await peer.prompt();
    final end = await peer.wait(
      Method.agentPermissionRequested,
      where: (_) => peer.of(Method.agentPermissionRequested).length == 3,
      within: const Duration(minutes: 2),
    );
    final requests = peer.of(Method.agentPermissionRequested);
    expect(requests, hasLength(3));
    await expectLater(
      answer(peer, requests.first, 'Approve'),
      rpcCode(ErrorCode.unknownRequest),
    );
    await answer(peer, requests[1], 'Deny');
    await peer.wait(Method.agentTurnEnded, within: const Duration(minutes: 2));
    await expectLater(
      answer(peer, end, 'Approve'),
      rpcCode(ErrorCode.unknownRequest),
    );
    expect(
      peer
          .of(Method.agentPermissionResolved)
          .where((r) => r['outcome'] == 'cancelled')
          .map((r) => r['requestId']),
      [requests.first['requestId'], end['requestId']],
    );
    await peer.close();
    expect(
      fixture.commands.where((f) => f['type'] == 'extension_ui_response'),
      [
        {'type': 'extension_ui_response', 'id': 'keep', 'value': 'Deny'},
      ],
    );
  }, timeout: const Timeout(Duration(minutes: 4)));

  for (final credit in [true, false]) {
    test(
      credit
          ? 'OMP: Stop cancels the displayed request before abort'
          : 'OMP: Approval and Stop use control without transcript credit',
      () async {
        final fixture = await openFixture(
          script: {
            'commands': {
              'prompt': [
                [
                  accepted(),
                  approval('held', ['Approve', 'Deny']),
                ],
                [
                  accepted({'agentInvoked': false}),
                ],
              ],
              'abort': [
                [terminal('aborted'), accepted()],
              ],
            },
          },
        );
        final peer = AgentPeer(fixture.desktop);
        await peer.start(fixture.workspace, runtime: 'scripted-omp');
        await peer.attach(credit: credit);
        await peer.prompt('first');
        final request = await asked(peer);
        await peer.wait(
          Method.agentState,
          where: (s) => s['state'] == 'waitingApproval',
          within: const Duration(minutes: 2),
        );
        if (!credit) expect(peer.events, isEmpty);
        await peer.call(Method.agentStop);
        expect(
          (await peer.wait(
            Method.agentStopResult,
            within: const Duration(minutes: 2),
          ))['outcome'],
          'stopped',
        );
        await expectLater(
          answer(peer, request, 'Approve'),
          rpcCode(ErrorCode.unknownRequest),
        );
        await peer.prompt('second');
        await peer.close();
        final relevant = fixture.commands
            .where(
              (c) => [
                'extension_ui_response',
                'abort',
                'prompt',
              ].contains(c['type']),
            )
            .toList();
        expect(relevant.map((c) => c['type']), [
          'prompt',
          'extension_ui_response',
          'abort',
          'prompt',
        ]);
        expect(relevant[1], {
          'type': 'extension_ui_response',
          'id': 'held',
          'cancelled': true,
        });
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );
  }

  test('OMP: Close cancels a displayed approval before ending input', () async {
    final fixture = await openFixture(
      environment: {'KUMIKO_TEST_OMP_CLOSE_AWAITS_PEER': '1'},
      script: {
        'commands': {
          'prompt': [
            [
              accepted(),
              approval('close', ['Approve', 'Deny']),
            ],
          ],
          'abort': [
            [terminal('aborted'), accepted()],
          ],
        },
      },
    );
    final peer = await fixture.start();
    await peer.prompt();
    await asked(peer);
    await peer.close();
    expect(
      fixture.commands.where((c) => c['type'] == 'extension_ui_response'),
      [
        {'type': 'extension_ui_response', 'id': 'close', 'cancelled': true},
      ],
    );
    expect(fixture.reports.last, {'stdin': 'eof'});
  }, timeout: const Timeout(Duration(minutes: 4)));

  test(
    'OMP: Native approval policy stays in force without synthetic requests',
    () async {
      final fixture = await turns([
        [accepted(), terminal('completed')],
      ]);
      final peer = await fixture.start();
      await peer.prompt();
      await peer.wait(
        Method.agentTurnEnded,
        within: const Duration(minutes: 2),
      );
      await peer.close();
      expect(peer.of(Method.agentPermissionRequested), isEmpty);
      expect(
        fixture.reports
            .where((record) => record['launch'] == 'root')
            .single['argv'],
        fixture.argv,
      );
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  const infoTool = 'kumiko_session_info';
  const guard = Duration(minutes: 2);

  Json callTool(
    String id, {
    String name = infoTool,
    Object? arguments = const <String, Object?>{},
  }) => {
    'type': 'host_tool_call',
    'id': id,
    'toolCallId': 'native-$id',
    'toolName': name,
    'arguments': arguments,
  };

  Iterable<Json> results(OmpFixture fixture) =>
      fixture.commands.where((f) => f['type'] == 'host_tool_result');

  Json info(Json frame) {
    expect(frame['isError'], isNot(true));
    final content = ((frame['result'] as Json)['content'] as List)
        .cast<Json>()
        .single;
    expect(content['type'], 'text');
    return jsonDecode(content['text']! as String) as Json;
  }

  void registered(AgentPeer peer) =>
      expect(peer.started.tools?.status, AgentToolsStatus.notYetUsed);

  Future<void> turnEnded(AgentPeer peer, {int after = 0}) async {
    await peer.wait(
      Method.agentTurnEnded,
      where: (_) => peer.of(Method.agentTurnEnded).length > after,
      within: guard,
    );
  }

  test(
    'OMP: Registered stays not yet used until a successful result',
    () async {
      final fixture = await openFixture(
        script: {
          'commands': {
            'prompt': [
              [accepted(), terminal('completed')],
              [accepted(), callTool('info')],
            ],
            'host_tool_result': [
              [terminal('completed')],
            ],
          },
        },
      );
      final peer = await fixture.start();
      registered(peer);
      await peer.prompt('no tools');
      await turnEnded(peer);
      expect(
        AgentTools.fromJsonField(peer.of(Method.agentState).last)?.status,
        AgentToolsStatus.notYetUsed,
      );
      expect(results(fixture), isEmpty);
      await peer.prompt('one tool');
      await turnEnded(peer, after: 1);
      expect(info(results(fixture).single)['sessionId'], peer.id);
      await peer.wait(
        Method.agentState,
        where: (s) =>
            AgentTools.fromJsonField(s)?.status == AgentToolsStatus.connected,
        within: guard,
      );
      expect(
        peer
            .of(Method.agentState)
            .map(AgentTools.fromJsonField)
            .map((s) => s?.status),
        isNot(contains(AgentToolsStatus.notStarted)),
      );
      expect(
        peer.notifications.map((n) => n.method),
        everyElement(isNot(contains('host_tool'))),
      );
      await peer.close();
    },
  );

  test(
    'OMP: Registered tool returns the bound saved session and original target',
    () async {
      final fixture = await openFixture(
        script: {
          'commands': {
            'prompt': [
              [accepted(), callTool('call')],
            ],
            'host_tool_result': [
              [terminal('completed')],
            ],
          },
        },
      );
      final other = tempDir('omp_other_target_');
      addTearDown(() => deleteTree(other));
      final peer = await fixture.start();
      registered(peer);
      final focus = (await fixture.desktop.openWorkspace(other.path))
          .workspace
          .id;
      await fixture.desktop.saveWorkbench(
        layoutToJson(
          const LayoutDocument.initial().copyWith(selectedWorkspace: focus),
        ),
        1,
      );
      await peer.prompt();
      await turnEnded(peer);
      final row = agentRows(fixture.profile).single;
      final reported = info(results(fixture).single);
      expect(reported, {
        'sessionId': row['id'],
        'role': 'coding',
        'runtime': 'omp',
        'adapter': {'name': 'omp-rpc', 'version': '18.20.1'},
        'target': {'path': row['target_path']},
      });
      expect(row['id'], peer.id);
      expect(row['workspace_id'], fixture.workspace);
      expect((reported['target'] as Json)['path'], isNot(other.path));
      await peer.close();
    },
  );

  test('OMP: Equal callback ids cannot cross run or target', () async {
    final fixture = await openFixture(
      script: {
        'commands': {
          'prompt': [
            [accepted(), callTool('same')],
          ],
          'host_tool_result': [
            [terminal('completed')],
          ],
        },
      },
    );
    final other = tempDir('omp_second_target_');
    addTearDown(() => deleteTree(other));
    final secondary = (await fixture.desktop.openWorkspace(other.path))
        .workspace
        .id;
    final first = await fixture.start();
    final second = AgentPeer(fixture.desktop);
    await second.start(secondary, runtime: 'scripted-omp');
    await second.attach();
    registered(first);
    registered(second);
    await first.prompt();
    await turnEnded(first);
    await second.prompt();
    await turnEnded(second);
    final answers = results(fixture).toList();
    expect(answers.map((f) => f['id']), ['same', 'same']);
    final expected = {
      for (final row in agentRows(fixture.profile))
        row['id']: row['target_path'],
    };
    for (final (row, peer) in [(answers[0], first), (answers[1], second)]) {
      final reported = info(row);
      expect(reported['sessionId'], peer.id);
      expect((reported['target'] as Json)['path'], expected[peer.id]);
    }
    expect(expected.values.toSet(), hasLength(2));
    await first.close();
    await second.close();
  });

  test(
    'OMP: Registration refusal and bad acknowledgement leave chat usable',
    () async {
      for (final (response, reason) in [
        (
          {
            'type': 'response',
            'id': r'$id',
            'success': false,
            'error': 'Tool name collision',
          },
          'collision',
        ),
        (
          accepted({
            'toolNames': ['different'],
          }),
          'acknowledgement',
        ),
      ]) {
        final fixture = await openFixture(
          script: {
            'commands': {
              'set_host_tools': [
                [response],
              ],
              'prompt': [
                [accepted(), callTool('blocked')],
              ],
              'host_tool_result': [
                [terminal('completed')],
              ],
            },
          },
        );
        final peer = await fixture.start();
        expect(peer.started.tools?.status, AgentToolsStatus.unavailable);
        expect(peer.started.tools?.reason, contains(reason));
        await peer.prompt();
        await turnEnded(peer);
        expect(results(fixture).single, containsPair('isError', true));
        expect(
          fixture.commands.where((f) => f['type'] == 'set_host_tools'),
          hasLength(1),
        );
        expect(
          peer
              .of(Method.agentState)
              .map(AgentTools.fromJsonField)
              .map((s) => s?.status),
          isNot(contains(AgentToolsStatus.connected)),
        );
        await peer.close();
      }
    },
  );

  test(
    'OMP: Unknown tool, invalid arguments and unbound callbacks are refused',
    () async {
      final fixture = await openFixture(
        script: {
          'commands': {
            'set_host_tools': [
              [
                callTool('early'),
                accepted({
                  'toolNames': [infoTool],
                }),
              ],
            ],
            'prompt': [
              [
                accepted(),
                callTool('unknown', name: 'not_a_kumiko_tool'),
                callTool('wrong-run', arguments: {'sessionId': 'elsewhere'}),
                callTool('bad-type', arguments: ['not', 'an', 'object']),
              ],
            ],
            'host_tool_result': [
              <Object?>[],
              <Object?>[],
              <Object?>[],
              [terminal('completed')],
            ],
          },
        },
      );
      final peer = await fixture.start();
      registered(peer);
      await peer.prompt();
      await turnEnded(peer);
      expect(results(fixture).map((f) => (f['id'], f['isError'])), [
        ('early', true),
        ('unknown', true),
        ('wrong-run', true),
        ('bad-type', true),
      ]);
      expect(
        AgentTools.fromJsonField(peer.of(Method.agentState).last)?.status,
        AgentToolsStatus.notYetUsed,
      );
      await peer.close();
    },
  );

  test('OMP: Native tools work with the MCP endpoint down', () async {
    final fixture = await openFixture(
      environment: {
        'KUMIKO_TEST_TOOL_ENDPOINT_FAULT': 'fixture endpoint unavailable',
      },
      script: {
        'commands': {
          'prompt': [
            [accepted(), callTool('info')],
          ],
          'host_tool_result': [
            [terminal('completed')],
          ],
        },
      },
    );
    final peer = await fixture.start();
    registered(peer);
    await peer.prompt();
    await turnEnded(peer);
    expect(info(results(fixture).single)['sessionId'], peer.id);
    await peer.wait(
      Method.agentState,
      where: (s) =>
          AgentTools.fromJsonField(s)?.status == AgentToolsStatus.connected,
      within: guard,
    );
    await peer.close();
  });

  test('OMP: Recorded tool failure leaves catalog unregistered', () async {
    final fixture = await openFixture(
      environment: {
        'KUMIKO_TEST_TOOL_DELIVERY_FAILURES': jsonEncode([
          ['omp-rpc', '18.20.1', 'known fixture failure'],
        ]),
      },
    );
    final peer = await fixture.start();
    expect(peer.started.tools?.status, AgentToolsStatus.unavailable);
    expect(peer.started.tools?.reason, contains('known fixture failure'));
    expect(
      fixture.commands.where((f) => f['type'] == 'set_host_tools'),
      isEmpty,
    );
    await peer.close();
  });

  test('OMP: Close revokes native tool authority before EOF', () async {
    final fixture = await openFixture(
      environment: {'KUMIKO_TEST_OMP_CLOSE_AWAITS_PEER': '1'},
      script: {
        'commands': {
          'prompt': [
            [accepted()],
          ],
          'abort': [
            [accepted(), callTool('late')],
          ],
          'host_tool_result': [
            [terminal('aborted')],
          ],
        },
      },
    );
    final peer = await fixture.start();
    registered(peer);
    await peer.prompt();
    await peer.close();
    expect(
      results(fixture).single,
      allOf(containsPair('id', 'late'), containsPair('isError', true)),
    );
    expect(fixture.reports.last['stdin'], 'eof');
    expect(
      peer
          .of(Method.agentState)
          .map(AgentTools.fromJsonField)
          .map((s) => s?.status),
      isNot(contains(AgentToolsStatus.connected)),
    );
  });

  test(
    'OMP: Callback waits for its own relay while another session can Stop',
    () async {
      final fixture = await openFixture(
        script: {
          'commands': {
            'prompt': [
              [
                accepted(),
                for (var n = 0; n < 24; n++)
                  delta('x' * (64 * 1024), id: 'm$n'),
                callTool('blocked'),
              ],
            ],
            'host_tool_result': [
              [terminal('completed')],
            ],
          },
        },
      );
      final held = AgentPeer(fixture.desktop);
      await held.start(fixture.workspace, runtime: 'scripted-omp');
      await held.attach(credit: false);
      await saveAgentFixture(
        fixture.desktop,
        fixture.work,
        id: 'mixed-acp',
        script: {'holdPrompt': true},
      );
      final other = AgentPeer(fixture.desktop);
      await other.start(fixture.workspace, runtime: 'mixed-acp');
      await other.attach();
      registered(held);
      expect(other.started.tools?.status, AgentToolsStatus.notYetUsed);
      await held.prompt('hold relay');
      await eventually(
        () async {
          final stats = await fixture.desktop.connection.request(
            'test/agent.stats',
            {},
          ) as Json;
          return ((stats['sessions'] as Json)[held.id] as Json)['paused'] ==
              true;
        },
        within: guard,
        reason: 'OMP relay did not backpressure its native reader',
      );
      expect(results(fixture), isEmpty);
      await other.prompt('other run');
      await other.call(Method.agentStop);
      await other.wait(
        Method.agentStopResult,
        where: (result) => result['outcome'] == 'stopped',
        within: guard,
      );
      expect(results(fixture), isEmpty);
      fixture.desktop.connection.grantInitial(held.started.eventChannel);
      await turnEnded(held);
      expect(info(results(fixture).single)['sessionId'], held.id);
      await held.close();
      await other.close();
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test('OMP: Older peer starts with conservative delegated activity and no child frames', () async {
    final fixture = await openFixture(
      script: {
        'commands': {
          'get_subagents': [
            [
              accepted({
                'subagents': [
                  {'id': 'native-worker', 'status': 'running'},
                ],
              }),
            ],
          ],
        },
      },
    );
    final root = await fixture.start();
    final state = await root.wait(
      Method.agentState,
      where: (state) => state['state'] == 'idle',
      within: guard,
    );
    expect(AgentStateParams.fromJson(state).delegated?.activeChildren, 1);
    expect(state['runId'], isNull);
    expect(root.events.where((event) => event['threadId'] != null), isEmpty);
  });

  test(
    'OMP: Child history waits for credit without blocking control',
    () async {
      final profile = tempDir('omp_child_credit_profile');
      final work = tempDir('omp_child_credit_work');
      addTearDown(() => deleteTree(profile));
      addTearDown(() => deleteTree(work));
      final childFile = File(joinPath(work.path, 'child-private.jsonl'));
      final header = {
        'type': 'session',
        'id': 'child-native-session',
        'cwd': work.path,
      };
      final entry = {
        'type': 'message',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'earlier subagent answer'},
          ],
        },
      };
      childFile.writeAsStringSync(
        '${jsonEncode(header)}\n${jsonEncode(entry)}\n',
      );
      final fixture = OmpFixture(
        profile,
        work,
        script: {
          'commands': {
            'get_subagents': [
              [
                accepted({
                  'subagents': [
                    {
                      'id': 'worker',
                      'status': 'running',
                      'sessionFile': childFile.path,
                    },
                  ],
                }),
              ],
            ],
            'get_subagent_messages': [
              [
                accepted({
                  'sessionFile': childFile.path,
                  'fromByte': 0,
                  'nextByte': childFile.lengthSync(),
                  'reset': false,
                  'entries': [header, entry],
                }),
              ],
            ],
            'prompt': [
              [
                accepted(),
                for (var n = 0; n < 8; n++)
                  delta('x' * (64 * 1024), id: 'credit$n'),
              ],
            ],
          },
        },
      );
      await fixture.open(caps: {...ompCaps, 'omp-history'});
      final root = await fixture.start();
      final state = await root.wait(
        Method.agentState,
        where: (s) => s['state'] == 'idle',
        within: guard,
      );
      expect(state['runId'], isA<String>());
      await eventually(
        () => root.events.any((e) => e['kind'] == 'child'),
        within: guard,
        reason: 'no child opened on the root channel',
      );
      final childKey = root.events.singleWhere(
        (e) => e['kind'] == 'child',
      )['threadId'];
      root.data!.pause();
      try {
        await root.prompt();
        await eventually(
          () async {
            final stats = await root.call('test/agent.stats', {});
            final rootStats = (stats['sessions'] as Json)[root.id] as Json;
            return rootStats['channelQueuedBytes'] == channelWindow;
          },
          within: guard,
          reason: 'root channel did not exhaust desktop credit',
        );
        final request = {
          'sessionId': root.id,
          'runId': state['runId'],
          'childKey': childKey,
          'viewToken': 'current-view',
        };
        await expectLater(
          root.call('agent/childHistory', {
            ...request,
            'runId': 'previous-run',
          }),
          rpcCode(ErrorCode.staleRun),
        );
        expect(
          fixture.commands.where((c) => c['type'] == 'get_subagent_messages'),
          isEmpty,
        );
        final result = await root.call('agent/childHistory', request);
        expect(result, containsPair('status', 'queued'));
        expect(jsonEncode(result), isNot(contains(childFile.path)));
        expect(
          root.events.where((event) => event['viewToken'] == 'current-view'),
          isEmpty,
        );
        final records = await root.call(Method.agentRecords, {
          'sessionIds': [root.id],
        });
        expect(records['records'], contains(root.id));
      } finally {
        root.data!.resume();
      }
      await eventually(
        () => root.events.any(
          (e) => e['viewToken'] == 'current-view' && e['phase'] == 'end',
        ),
        within: guard,
        reason: 'child history did not follow the root credit',
      );
      final replay = root.events.where((e) => e['viewToken'] == 'current-view');
      expect(replay.map((e) => e['threadId']), everyElement(childKey));
      expect(replay.map((e) => e['text']), contains('earlier subagent answer'));
      expect(
        jsonEncode(replay.toList()),
        isNot(contains('child-private.jsonl')),
      );
      expect(
        fixture.commands.singleWhere(
          (c) => c['type'] == 'get_subagent_messages',
        ),
        containsPair('sessionFile', childFile.path),
      );
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'OMP: Child output and saved history redact live and revoked grants',
    () async {
      final profile = tempDir('omp_redaction_profile');
      final work = tempDir('omp_redaction_work');
      addTearDown(() => deleteTree(profile));
      addTearDown(() => deleteTree(work));
      final native = File(joinPath(work.path, 'omp-root.jsonl'));
      final child = File(joinPath(work.path, 'omp-child.jsonl'));
      Json header(String id) => {'type': 'session', 'id': id, 'cwd': work.path};
      native.writeAsStringSync('${jsonEncode(header('original'))}\n');
      final state = accepted({
        'sessionId': 'original',
        'sessionFile': native.path,
        'isSettled': true,
        'hasPendingAsyncWork': false,
      });
      final commands = <String, Object?>{
        'get_state': [
          [state],
          [state],
        ],
      };
      final fixture = OmpFixture(profile, work, script: {'commands': commands});
      await fixture.open(
        caps: {...ompCaps, Capability.ompHistory},
        profileArgs: ['--mode', 'rpc', '--offline'],
      );
      final original = await fixture.start();
      await original.close();

      Future<String> grantSecret(String id, {required bool revoke}) async {
        final report = await saveAgentFixture(
          fixture.desktop,
          work,
          id: id,
          script: {'reportLaunch': true},
        );
        final session = AgentPeer(fixture.desktop);
        await session.start(fixture.workspace, runtime: id);
        final launch = await waitFixture(
          report,
          (r) => r.containsKey('newCwd'),
        );
        final servers = (launch['mcpServers']! as List<Object?>)
            .whereType<Json>();
        final env = (servers.single['env']! as List<Object?>).whereType<Json>();
        final secret =
            env.singleWhere(
                  (entry) => entry['name'] == 'KUMIKO_TOOL_SECRET',
                )['value']!
                as String;
        if (revoke) await session.close();
        return secret;
      }

      final revoked = await grantSecret('revoked-grant', revoke: true);
      final live = await grantSecret('live-grant', revoke: false);
      Json text(String value) => {'type': 'text', 'text': value};
      Json assistant(String value) => {
        'role': 'assistant',
        'content': [text(value)],
      };
      Json childEvent(Json event) => {
        'type': 'subagent_event',
        'payload': {'id': 'worker', 'event': event},
      };
      final entry = {
        'type': 'message',
        'message': assistant('child replay $live'),
      };
      child.writeAsStringSync(
        '${jsonEncode(header('child'))}\n${jsonEncode(entry)}\n',
      );
      commands.addAll({
        'get_messages_page': [
          [
            accepted({
              'messages': [assistant('root replay $revoked')],
              'totalMessages': 1,
            }),
          ],
        ],
        'get_subagents': [
          [
            accepted({
              'subagents': [
                {
                  'id': 'worker',
                  'status': 'running',
                  'sessionFile': child.path,
                },
              ],
            }),
          ],
        ],
        'get_subagent_messages': [
          [
            accepted({
              'sessionFile': child.path,
              'fromByte': 0,
              'nextByte': child.lengthSync(),
              'reset': false,
              'entries': [header('child'), entry],
            }),
          ],
        ],
        'prompt': [
          [
            accepted(),
            childEvent({
              'type': 'message_end',
              'message': assistant('child live $live'),
            }),
            childEvent({
              'type': 'tool_execution_start',
              'toolCallId': 'inspect',
              'toolName': 'read',
              'args': {'value': live},
            }),
            childEvent({
              'type': 'tool_execution_end',
              'toolCallId': 'inspect',
              'toolName': 'read',
              'result': {
                'content': [text('tool output $revoked')],
              },
              'isError': false,
            }),
            {...terminal('completed'), 'sessionSettled': true},
          ],
        ],
      });
      fixture.writeScript();
      final continued = AgentContinueResult.fromJson(
        await original.call(Method.agentContinue),
      );
      expect(continued.mode, AgentContinueMode.load);
      final root = AgentPeer(fixture.desktop)
        ..started = AgentStartResult(
          sessionId: original.id,
          eventChannel: continued.eventChannel,
          adapter: continued.adapter,
          capabilities: continued.capabilities,
        );
      await root.attach();
      final idle = await root.wait(
        Method.agentState,
        where: (s) => s['state'] == 'idle',
        within: guard,
      );
      await eventually(
        () => root.events.any((e) => e['kind'] == 'child'),
        within: guard,
        reason: 'no child announced on the restored root',
      );
      final childKey = root.events.singleWhere(
        (e) => e['kind'] == 'child',
      )['threadId'];
      expect(
        await root.call(Method.agentChildHistory, {
          'sessionId': root.id,
          'runId': idle['runId'],
          'childKey': childKey,
          'viewToken': 'current-view',
        }),
        containsPair('status', 'queued'),
      );
      await root.prompt();
      await eventually(
        () =>
            root.events.any(
              (e) => e['viewToken'] == 'current-view' && e['phase'] == 'end',
            ) &&
            root.events.any(
              (e) => e['threadId'] == childKey && e['status'] == 'completed',
            ),
        within: guard,
        reason: 'the child replay and live tool result did not arrive',
      );
      final events = jsonEncode(root.events);
      expect(
        events.contains(live) || events.contains(revoked),
        isFalse,
        reason: 'A known grant secret reached the desktop transcript',
      );
      expect(
        root.events.where((e) => e['threadId'] == null).map((e) => e['text']),
        contains('root replay <redacted>'),
      );
      expect(
        root.events
            .where(
              (e) =>
                  e['threadId'] == childKey && e['viewToken'] == 'current-view',
            )
            .map((e) => e['text']),
        contains('child replay <redacted>'),
      );
      expect(
        root.events
            .where((e) => e['threadId'] == childKey && e['viewToken'] == null)
            .map((e) => e['text']),
        contains('child live <redacted>'),
      );
      expect(events, contains('tool output <redacted>'));
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test('OMP: Admission precedes output', () async {
    final fixture = await turns([
      [
        delta('early'),
        {'delayMs': 250},
        accepted(),
        delta(' late'),
        terminal('completed'),
      ],
    ]);
    final peer = await fixture.start();
    final sent = peer.prompt('keep ordering');
    await waitFixture(
      fixture.report,
      (r) => (r['received'] as Json?)?['type'] == 'prompt',
    );
    expect(peer.events.where((e) => e['kind'] == 'user'), isEmpty);
    await sent;
    await peer.wait(Method.agentTurnEnded);
    await eventually(() => peer.events.any((e) => e['kind'] == 'turn'));
    final events = peer.events.where(
      (e) => ['user', 'agentText', 'turn'].contains(e['kind']),
    );
    expect(events.first['kind'], 'user');
    expect(events.where((e) => e['kind'] == 'user'), hasLength(1));
    expect(
      events
          .where((e) => e['kind'] == 'agentText')
          .map((e) => e['text'])
          .join(),
      'early late',
    );
    expect(events.last['kind'], 'turn');
  });

  test('OMP: Handled without the agent', () async {
    final fixture = await turns([
      [
        accepted({'agentInvoked': false}),
      ],
      [
        accepted({'agentInvoked': false}),
      ],
    ]);
    final peer = await fixture.start();
    await peer.prompt('first');
    await peer.wait(Method.agentTurnEnded);
    await peer.prompt('second');
    expect(fixture.commands.where((c) => c['type'] == 'prompt'), hasLength(2));
  });

  test('OMP: Admission refused', () async {
    final fixture = await turns([
      [
        delta('must be discarded'),
        {
          'type': 'response',
          'id': r'$id',
          'success': false,
          'error': 'not admitted',
        },
      ],
    ]);
    final peer = await fixture.start();
    await expectLater(
      peer.prompt('keep me'),
      throwsA(
        isA<RpcException>().having(
          (e) => e.message,
          'message',
          contains('not admitted'),
        ),
      ),
    );
    expect(
      peer.of(Method.agentState).map((s) => s['state']),
      isNot(contains('running')),
    );
    expect(
      peer.events.where((e) => ['user', 'agentText'].contains(e['kind'])),
      isEmpty,
    );
  });

  for (final newer in [false, true]) {
    test(
      'OMP: refused admission respects draft revision (newer=$newer)',
      () async {
        final fixture = await turns([
          [
            {'delayMs': 350},
            {
              'type': 'response',
              'id': r'$id',
              'success': false,
              'error': 'refused',
            },
          ],
        ]);
        final peer = await fixture.start();
        await peer.call(Method.agentDraftSave, {
          'sessionId': peer.id,
          'revision': 1,
          'text': 'original',
        });
        final sending = expectLater(
          peer.call(Method.agentPrompt, {
            'sessionId': peer.id,
            'text': 'original',
            'draftRevision': 1,
            'draftSynced': true,
          }),
          rpcCode('adapter-error'),
        );
        await waitFixture(
          fixture.report,
          (r) => (r['received'] as Json?)?['type'] == 'prompt',
        );
        expect((await peer.wait(Method.agentState))['state'], 'idle');
        await expectLater(
          peer.prompt('concurrent'),
          rpcCode(ErrorCode.turnRunning),
        );
        if (newer) {
          await peer.call(Method.agentDraftSave, {
            'sessionId': peer.id,
            'revision': 3,
            'text': 'newer',
          });
        }
        await sending;
        expect(
          (await peer.call(Method.agentDraftLoad))['text'],
          newer ? 'newer' : 'original',
        );
        expect(
          fixture.commands.where((c) => c['type'] == 'prompt'),
          hasLength(1),
        );
      },
    );
  }

  test('OMP: Transport breaks after admission', () async {
    final fixture = await turns([
      [
        accepted(),
        {'exit': 2},
      ],
    ]);
    final peer = await fixture.start();
    await peer.call(Method.agentDraftSave, {
      'sessionId': peer.id,
      'revision': 1,
      'text': 'committed',
    });
    await peer.call(Method.agentPrompt, {
      'sessionId': peer.id,
      'text': 'committed',
      'draftRevision': 1,
      'draftSynced': true,
    });
    await peer.wait(Method.agentExited, where: (e) => e['reason'] == 'failed');
    expect((await peer.call(Method.agentDraftLoad))['text'], isNull);
    await eventually(() => peer.events.any((e) => e['kind'] == 'user'));
    expect(
      peer.events.where((e) => e['kind'] == 'user').single['text'],
      'committed',
    );
    expect(LedgerView(fixture.profile).units(), isEmpty);
    expect(agentRows(fixture.profile), hasLength(1));
  });

  test('OMP: Malformed frame after start', () async {
    final fixture = await turns([
      [accepted(), 'not JSON'],
    ]);
    final peer = await fixture.start();
    await peer.prompt();
    await peer.wait(Method.agentExited, where: (e) => e['reason'] == 'failed');
    expect(agentRows(fixture.profile), hasLength(1));
  });

  test('OMP: Streamed reply', () async {
    final fixture = await turns([
      [
        accepted(),
        for (var i = 0; i < 40; i++) delta('$i,'),
        {
          'type': 'message_end',
          'messageId': 'm1',
          'message': {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': List.generate(40, (i) => '$i,').join()},
            ],
          },
        },
        terminal('completed'),
      ],
    ]);
    final peer = await fixture.start();
    await peer.prompt();
    await peer.wait(Method.agentTurnEnded);
    await eventually(() => peer.events.any((e) => e['kind'] == 'turn'));
    expect(
      peer.events
          .where((e) => e['kind'] == 'agentText')
          .map((e) => e['text'])
          .join(),
      List.generate(40, (i) => '$i,').join(),
    );
  });

  test('OMP: Provider error', () async {
    final fixture = await turns([
      [accepted(), terminal('error', error: '401 invalid api key')],
      [accepted(), terminal('completed')],
    ]);
    final peer = await fixture.start();
    await peer.prompt();
    final ended = await peer.wait(Method.agentTurnEnded);
    expect(ended.toString(), contains('401 invalid api key'));
    await peer.prompt('another prompt');
  });

  for (final (status, outcome) in [
    ('aborted', 'stopped'),
    ('completed', 'finishedFirst'),
  ]) {
    final scenario = status == 'aborted'
        ? 'Abort succeeds'
        : 'Turn finished first';
    test('OMP: $scenario', () async {
      final fixture = await openFixture(
        script: {
          'commands': {
            'prompt': [
              [accepted()],
              [
                accepted({'agentInvoked': false}),
              ],
            ],
            'abort': [
              [terminal(status), accepted()],
            ],
          },
        },
      );
      final peer = await fixture.start();
      await peer.prompt();
      await peer.call(Method.agentStop);
      final result = await peer.wait(Method.agentStopResult);
      expect(result['outcome'], outcome);
      await peer.wait(Method.agentTurnEnded);
      await peer.prompt('still usable');
    });
  }

  test('OMP: Abort not confirmed', () async {
    final fixture = await openFixture(
      script: {
        'commands': {
          'prompt': [
            [accepted()],
          ],
          'abort': [
            [
              {
                'type': 'response',
                'id': r'$id',
                'success': false,
                'error': 'cannot abort',
              },
            ],
          ],
        },
      },
    );
    final peer = await fixture.start();
    await peer.prompt();
    await peer.call(Method.agentStop);
    expect(
      (await peer.wait(Method.agentStopResult))['outcome'],
      'notConfirmed',
    );
    expect(LedgerView(fixture.profile).units(), hasLength(1));
  });

  test('OMP: Abort acknowledged after its deadline', () async {
    final fixture = await openFixture(
      script: {
        'commands': {
          'prompt': [
            [accepted()],
            [
              accepted({'agentInvoked': false}),
            ],
          ],
          'abort': [
            [
              {'delayMs': 10500},
              accepted(),
              {'delayMs': 150},
              terminal('aborted'),
            ],
          ],
        },
      },
    );
    final peer = await fixture.start();
    await peer.prompt();
    await peer.call(Method.agentStop);
    await peer.wait(
      Method.agentStopResult,
      where: (e) => e['outcome'] == 'notConfirmed',
    );
    expect(
      (await peer.wait(
        Method.agentState,
        where: (e) => e['state'] == 'stopping',
      ))['state'],
      'stopping',
    );
    final late = await peer.wait(
      Method.agentStopResult,
      where: (e) => e['outcome'] == 'stopped',
    );
    expect(late['late'], isTrue);
    expect(LedgerView(fixture.profile).units(), hasLength(1));
    await peer.wait(Method.agentTurnEnded);
    await peer.prompt('same native process');
  });

  test('OMP: direct Stop addresses an admitting prompt', () async {
    final fixture = await openFixture(
      script: {
        'commands': {
          'prompt': [
            [
              {'delayMs': 400},
              accepted(),
            ],
          ],
          'abort': [
            [accepted(), terminal('aborted')],
          ],
        },
      },
    );
    final peer = await fixture.start();
    final sending = peer.prompt();
    await waitFixture(
      fixture.report,
      (r) => (r['received'] as Json?)?['type'] == 'prompt',
    );
    expect((await peer.wait(Method.agentState))['state'], 'idle');
    await peer.call(Method.agentStop);
    await sending;
    expect((await peer.wait(Method.agentStopResult))['outcome'], 'stopped');
    expect(
      fixture.commands
          .map((c) => c['type'])
          .skipWhile((type) => type != 'prompt'),
      ['prompt', 'abort'],
    );
  });

  test(
    'OMP: Malformed approval is declined without echoing its title',
    () async {
      final fixture = await turns([
        [
          accepted(),
          {
            'type': 'extension_ui_request',
            'id': 'approval',
            'method': 'select',
            'title': 'Allow tool?',
          },
          terminal('completed'),
        ],
      ]);
      final peer = await fixture.start();
      await peer.prompt();
      final response = await waitFixture(fixture.report, (row) {
        return (row['received'] as Json?)?['type'] == 'extension_ui_response';
      });
      expect(response['received'], {
        'type': 'extension_ui_response',
        'id': 'approval',
        'cancelled': true,
      });
      await peer.wait(Method.agentTurnEnded);
      await eventually(
        () => peer.events.any(
          (e) => e['kind'] == 'notice' && '${e['text']}'.contains('declined'),
        ),
      );
      expect(
        peer.events.where((e) => '${e['text']}'.contains('Allow tool?')),
        isEmpty,
      );
      expect(peer.of(Method.agentPermissionRequested), isEmpty);
      expect(
        fixture.commands.where((c) => c['type'] == 'extension_ui_response'),
        hasLength(1),
      );
    },
  );

  test('OMP: Older peer cannot Continue a saved OMP session', () async {
    final fixture = await openFixture();
    final peer = await fixture.start();
    await peer.close();
    final before = agentRows(fixture.profile);
    await expectLater(
      peer.call(Method.agentContinue),
      throwsA(
        isA<RpcException>()
            .having((e) => e.reason, 'reason', ErrorCode.methodNotAvailable)
            .having((e) => e.message, 'message', contains('OMP Continue')),
      ),
    );
    expect(agentRows(fixture.profile), before);
    expect(fixture.reports.map((r) => r['launch']).whereType<String>(), [
      'probe',
      'root',
    ]);
  });

  test(
    'OMP: Upgraded peer gets a record-specific missing locator refusal',
    () async {
      final fixture = await openFixture(caps: {...ompCaps, 'omp-history'});
      final peer = await fixture.start();
      await peer.close();
      final before = agentRows(fixture.profile);
      final record = await peer.call(Method.agentRecords, {
        'sessionIds': [peer.id],
      });
      expect(jsonEncode(record), contains('omp-locator-unavailable'));
      await expectLater(
        peer.call(Method.agentContinue),
        throwsA(
          isA<RpcException>()
              .having((e) => e.reason, 'error', ErrorCode.resumeUnavailable)
              .having(
                (e) => e.data,
                'reason',
                containsPair('resumeReason', 'omp-locator-unavailable'),
              ),
        ),
      );
      expect(agentRows(fixture.profile), before);
      expect(fixture.reports.where((r) => r['launch'] == 'root'), hasLength(1));
    },
  );

  test('OMP: Continue verifies the original file and restores native pages before Send', () async {
    final profile = tempDir('omp_resume_profile');
    final work = tempDir('omp_resume_work');
    addTearDown(() => deleteTree(profile));
    addTearDown(() => deleteTree(work));
    final history = File(joinPath(profile.path, 'native-history.jsonl'));
    final header = {'type': 'session', 'id': 'original', 'cwd': work.path};
    const title =
        '{"type":"title","v":1,"title":"private","updatedAt":"","pad":"';
    history.writeAsStringSync(
      '$title${' ' * (256 - title.length - 3)}"}\n${jsonEncode(header)}\n',
    );
    Json response(Json data) => {
      'type': 'response',
      'id': r'$id',
      'success': true,
      'data': data,
    };
    final fixture = OmpFixture(
      profile,
      work,
      script: {
        'commands': {
          'get_state': [
            [
              response({
                'sessionId': 'original',
                'sessionFile': history.path,
                'isSettled': true,
                'hasPendingAsyncWork': false,
              }),
            ],
            [
              response({
                'sessionId': 'original',
                'sessionFile': history.path,
                'isSettled': true,
                'hasPendingAsyncWork': false,
              }),
            ],
          ],
          'get_messages_page': [
            [
              response({
                'totalMessages': 3,
                'nextCursor': 'next',
                'messages': [
                  {'role': 'user', 'content': 'old question'},
                ],
              }),
            ],
            [
              response({
                'totalMessages': 3,
                'messages': [
                  {
                    'role': 'assistant',
                    'content': [
                      {'type': 'text', 'text': 'old answer'},
                      {
                        'type': 'toolCall',
                        'id': 'check',
                        'name': 'read',
                        'arguments': {'key': 'value'},
                      },
                      {'type': 'image', 'data': 'private-unsupported-content'},
                    ],
                  },
                  {
                    'role': 'toolResult',
                    'toolCallId': 'check',
                    'toolName': 'read',
                    'isError': true,
                    'content': [
                      {'type': 'text', 'text': 'read failed'},
                    ],
                  },
                ],
              }),
            ],
          ],
        },
      },
    );
    await fixture.open(
      caps: {...ompCaps, 'omp-history'},
      profileArgs: ['--mode', 'rpc', '--thinking=low', '--offline'],
    );
    final old = await fixture.start();
    await old.close();
    final saved = agentRows(profile).single;
    expect(saved['omp_session_file'], history.path);
    await old.call(
      Method.runtimeSave,
      RuntimeSaveParams(
        RuntimeProfile(
          id: 'unsafe-omp',
          name: 'Unsafe OMP',
          runtimeKind: 'omp',
          executable: testHostExecutable(),
          args: ['--mode', 'rpc', '--continue'],
        ),
      ).toJson(),
    );
    await expectLater(
      old.call(Method.agentContinue, {
        'sessionId': old.id,
        'runtimeProfileId': 'unsafe-omp',
      }),
      rpcCode(ErrorCode.noRuntimeProfile),
    );
    expect(fixture.reports.map((r) => r['launch']).whereType<String>(), [
      'probe',
      'root',
    ]);
    final originalScript = fixture.scriptFile.readAsStringSync();
    fixture.scriptFile.writeAsStringSync(
      jsonEncode({
        'reportFile': fixture.report.path,
        'startupStderr': 'internal startup path: ${history.path}',
        'commands': {
          'get_state': [
            [
              response({
                'sessionId': 'wrong-native-id',
                'sessionFile': history.path,
                'isSettled': true,
                'hasPendingAsyncWork': false,
              }),
            ],
          ],
        },
      }),
    );
    await expectLater(
      old.call(Method.agentContinue),
      throwsA(
        isA<RpcException>()
            .having((e) => e.reason, 'code', ErrorCode.resumeUnavailable)
            .having(
              (e) => jsonEncode([e.message, e.data]),
              'diagnostic',
              isNot(contains('native-history.jsonl')),
            ),
      ),
    );
    expect(LedgerView(profile).units(), isEmpty);
    expect(agentRows(profile).single, saved);
    fixture.scriptFile.writeAsStringSync(originalScript);
    final continued = AgentContinueResult.fromJson(
      await old.call(Method.agentContinue),
    );
    expect(continued.mode, AgentContinueMode.load);
    final peer = AgentPeer(fixture.desktop)
      ..started = AgentStartResult(
        sessionId: old.id,
        eventChannel: continued.eventChannel,
        adapter: continued.adapter,
        capabilities: continued.capabilities,
      );
    await peer.attach(credit: false);
    await expectLater(peer.prompt(), rpcCode(ErrorCode.turnRunning));
    peer.notifications.clear();
    fixture.desktop.connection.grantInitial(continued.eventChannel);
    await peer.wait(Method.agentState, where: (p) => p['state'] == 'idle');
    await eventually(
      () =>
          peer.events.any((e) => e['kind'] == 'replay' && e['phase'] == 'end'),
      within: const Duration(minutes: 2),
      reason: 'the verified snapshot did not cross the event channel',
    );
    expect(
      peer.events.map((e) => e['text']).whereType<String>(),
      containsAllInOrder(['old question', 'old answer']),
    );
    final eventJson = jsonEncode(peer.events);
    expect(eventJson, contains('read failed'));
    expect(
      eventJson,
      contains('Some recorded OMP content could not be shown.'),
    );
    expect(eventJson, isNot(contains('private-unsupported-content')));
    expect(eventJson, isNot(contains('native-history.jsonl')));
    expect(fixture.commands.where((c) => c['type'] == 'prompt'), isEmpty);
    expect(
      fixture.commands
          .where((c) => c['type'] == 'get_messages_page')
          .last['cursor'],
      'next',
    );
    final resumedArgv =
        fixture.reports.where((r) => r['launch'] == 'root').last['argv']!
            as List;
    expect(resumedArgv.take(6), [
      '--mode',
      'rpc',
      '--thinking=low',
      '--offline',
      '--resume',
      history.path,
    ]);
    expect(agentRows(profile).single['native_session_id'], 'original');
  });

  Future<OmpFixture> closingFixture({
    Json script = const {},
    Json commands = const {},
    bool persist = true,
    bool manual = false,
    bool historyPeer = true,
  }) async {
    final profile = tempDir('omp_close_profile');
    final work = tempDir('omp_close_work');
    addTearDown(() => deleteTree(profile));
    addTearDown(() => deleteTree(work));
    final history = File(joinPath(work.path, 'private-session.jsonl'));
    if (persist) {
      history.writeAsStringSync(
        '${jsonEncode({'type': 'session', 'id': 'fixture-session', 'cwd': work.path})}\n',
      );
    }
    final fixture = OmpFixture(
      profile,
      work,
      script: {
        ...script,
        'commands': {
          ...commands,
          'get_state': [
            [
              {
                'type': 'response',
                'id': r'$id',
                'success': true,
                'data': {
                  'sessionId': 'fixture-session',
                  'isSettled': true,
                  'hasPendingAsyncWork': false,
                  if (persist) 'sessionFile': history.path,
                },
              },
            ],
          ],
        },
      },
    );
    await fixture.open(
      caps: {
        ...ompCaps,
        Capability.lifecycle,
        if (historyPeer) Capability.ompHistory,
      },
      quitTimeout: const Duration(minutes: 3),
      environment: {
        'KUMIKO_TEST_SHUTDOWN_DEADLINE_MS': '120000',
        if (manual)
          'KUMIKO_TEST_OMP_CLOSE_MANUAL': '1'
        else
          'KUMIKO_TEST_OMP_CLOSE_AWAITS_PEER': '1',
      },
    );
    return fixture;
  }

  const hangGuard = Timeout(Duration(minutes: 4));
  for (final (name, script, persist, reason) in <(String, Json, bool, String?)>[
    ('Orderly close', {}, true, null),
    (
      'Nonzero disposal reports an unconfirmed history save with cleaned containment',
      {'eofExit': 9},
      true,
      'nativeExitNonzero',
    ),
    (
      'No native persistence does not claim a save',
      {},
      false,
      'noNativePersistence',
    ),
    (
      'Malformed native output after EOF does not confirm a save',
      {
        'eofFrames': ['not JSON'],
      },
      true,
      'nativeTransportFailed',
    ),
  ]) {
    test('OMP: $name', () async {
      final fixture = await closingFixture(script: script, persist: persist);
      final peer = await fixture.start();
      await peer.close();
      expect(fixture.reports.last['stdin'], 'eof');
      expect(LedgerView(fixture.profile).units(), isEmpty);
      final exit = peer.of(Method.agentExited).single;
      expect(exit['status'], script['eofExit'] ?? 0);
      expect(exit['historyUnconfirmed'], reason);
      expect(
        agentRows(fixture.profile).single['omp_history_unconfirmed'],
        reason,
      );
      final records = AgentRecordsResult.fromJson(
        await peer.call(Method.agentRecords, {
          'sessionIds': [peer.id],
        }),
      );
      expect(records.records[peer.id]?.historyUnconfirmed, reason);
      expect(
        jsonEncode(records.toJson()),
        isNot(contains('private-session.jsonl')),
      );
    }, timeout: hangGuard);
  }

  test('OMP: OMP does not exit', () async {
    final fixture = await closingFixture(
      manual: true,
      script: {'holdEof': true},
    );
    final peer = await fixture.start();
    final close = peer.close();
    await waitFixture(fixture.report, (row) => row['stdin'] == 'eof');
    final expired = await peer.call('test/omp.expireGrace', {});
    expect(expired['expired'], 1);
    await close;
    expect(LedgerView(fixture.profile).units(), isEmpty);
    expect(
      peer.of(Method.agentExited).single['historyUnconfirmed'],
      'nativeEofUnconfirmed',
    );
    expect(
      agentRows(fixture.profile).single['omp_history_unconfirmed'],
      'nativeEofUnconfirmed',
    );
  }, timeout: hangGuard);

  test('OMP: Old desktop receives no history outcome fields', () async {
    final fixture = await closingFixture(
      script: {'eofExit': 9},
      historyPeer: false,
    );
    final peer = await fixture.start();
    await peer.close();
    expect(
      peer.of(Method.agentExited).single,
      isNot(contains('historyUnconfirmed')),
    );
    final records = await peer.call(Method.agentRecords, {
      'sessionIds': [peer.id],
    });
    expect(jsonEncode(records), isNot(contains('historyUnconfirmed')));
    expect(
      agentRows(fixture.profile).single['omp_history_unconfirmed'],
      'nativeExitNonzero',
    );
  }, timeout: hangGuard);

  test(
    'OMP: Failed warning write is not reported as a saved history',
    () async {
      final fixture = await closingFixture(script: {'eofExit': 9});
      final peer = await fixture.start();
      final db = sqlite3.open(joinPath(fixture.profile.path, 'kumiko.db'));
      try {
        db.execute('''
        CREATE TRIGGER refuse_history_warning
        BEFORE UPDATE OF omp_history_unconfirmed ON agent_session
        BEGIN SELECT RAISE(FAIL, 'private store error'); END
      ''');
      } finally {
        db.close();
      }
      await peer.close();
      final exit = peer.of(Method.agentExited).single;
      expect(exit['historyUnconfirmed'], 'storeWriteFailed');
      expect(jsonEncode(exit), isNot(contains('private store error')));
      expect(LedgerView(fixture.profile).units(), isEmpty);
      expect(
        agentRows(fixture.profile).single['omp_history_unconfirmed'],
        isNull,
      );
    },
    timeout: hangGuard,
  );

  test(
    'OMP: Announced EOF closes idle and active fixture units before settlement',
    () async {
      final fixture = await closingFixture(
        script: {'isolateReports': true},
        commands: {
          'prompt': [
            [accepted()],
          ],
          'abort': [
            [
              {...terminal('aborted'), 'sessionSettled': true},
              accepted(),
            ],
          ],
        },
      );
      final idle = await fixture.start();
      final active = await fixture.start();
      await active.prompt();
      await active.wait(
        Method.agentState,
        where: (p) => p['state'] == 'running',
        within: const Duration(minutes: 2),
      );
      expect(agentRows(fixture.profile).map((r) => r['id']), [
        idle.id,
        active.id,
      ]);
      await fixture.desktop.announceQuit();
      expect(fixture.reports.where((r) => r['stdin'] == 'eof'), isEmpty);
      final quit = await fixture.desktop.session.quit();
      expect(quit.timedOut, isFalse);
      expect(quit.exitCode, 0);
      expect(fixture.reports.where((r) => r['stdin'] == 'eof'), hasLength(2));
      expect(fixture.commands.where((c) => c['type'] == 'abort'), hasLength(1));
      expect(LedgerView(fixture.profile).units(), isEmpty);
      expect(
        LedgerView(fixture.profile).instances().single['exit_kind'],
        'quit',
      );
      expect(
        agentRows(fixture.profile).map((r) => r['omp_history_unconfirmed']),
        [null, null],
      );
    },
    timeout: hangGuard,
  );

  test(
    'OMP: Quit persists an unconfirmed save separately from ledger state',
    () async {
      final fixture = await closingFixture(script: {'eofExit': 8});
      final peer = await fixture.start();
      await fixture.desktop.announceQuit();
      final quit = await fixture.desktop.session.quit();
      expect(quit.timedOut, isFalse);
      expect(quit.exitCode, 0);
      final ledger = LedgerView(fixture.profile);
      expect(ledger.units(), isEmpty);
      expect(ledger.instances().single['closed_cleanly'], 1);
      expect(
        agentRows(fixture.profile).single['omp_history_unconfirmed'],
        'nativeExitNonzero',
      );
      final reopened = await Desktop.start(
        fixture.profile,
        capabilities: {
          ...testCapabilities,
          ...ompCaps,
          Capability.ompHistory,
          Capability.lifecycle,
        },
      );
      addTearDown(reopened.dispose);
      await reopened.waitState();
      final records = AgentRecordsResult.fromJson(
        (await reopened.connection.request(Method.agentRecords, {
          'sessionIds': [peer.id],
        })) as Json,
      );
      expect(records.records[peer.id]?.historyUnconfirmed, 'nativeExitNonzero');
      expect((await reopened.previousExit()).kind, PreviousExitKind.quit);
      expect(LedgerView(fixture.profile).units(), isEmpty);
    },
    timeout: hangGuard,
  );

  test('OMP: Unannounced disconnect skips OMP grace and keeps the unexpected-exit outcome', () async {
    final fixture = await closingFixture(script: {'holdEof': true});
    await fixture.start();
    final session = fixture.desktop.session;
    final quit = await session.quit();
    expect(quit.timedOut, isFalse);
    expect(quit.exitCode, 0, reason: session.stderrTail);
    expect(fixture.reports.where((r) => r['stdin'] == 'eof'), isEmpty);
    final ledger = LedgerView(fixture.profile);
    expect(ledger.units(), isEmpty);
    expect(ledger.instances().single['exit_kind'], isNull);
  }, timeout: hangGuard);
}
