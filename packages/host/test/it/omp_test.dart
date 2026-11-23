import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
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

  test('OMP: OMP run without tool delivery', () async {
    final fixture = await openFixture();
    final peer = await fixture.start();
    expect(peer.started.tools?.status, AgentToolsStatus.unavailable);
    expect(peer.started.tools?.reason, contains('not delivered to OMP'));
    final stats = await fixture.desktop.connection.request(
      'test/agent.stats',
      {},
    ) as Json;
    expect(((stats['sessions'] as Json)[peer.id] as Json)['hasGrant'], isFalse);
    expect(
      fixture.reports
          .where((r) => r['launch'] != null)
          .every((r) => r['hasToolSecret'] == false),
      isTrue,
    );
    expect(fixture.commands.toString(), isNot(contains('kumiko')));
  });

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
    expect(fixture.commands.map((c) => c['type']).toList().sublist(2), [
      'prompt',
      'abort',
    ]);
  });

  test('OMP: Tool approval requested', () async {
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
        (e) => e['kind'] == 'notice' && '${e['text']}'.contains('Allow tool?'),
      ),
    );
    expect(peer.of(Method.agentPermissionRequested), isEmpty);
    expect(
      fixture.commands.where((c) => c['type'] == 'extension_ui_response'),
      hasLength(1),
    );
  });

  test('OMP: Continue on a saved OMP session', () async {
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

  for (final hangAfterEof in [false, true]) {
    final scenario = hangAfterEof ? 'OMP does not exit' : 'Orderly close';
    test('OMP: $scenario', () async {
      final fixture = await openFixture(
        script: {if (hangAfterEof) 'eofDelayMs': 20000},
      );
      final peer = await fixture.start();
      await peer.close();
      expect(fixture.reports.last['stdin'], 'eof');
      expect(LedgerView(fixture.profile).units(), isEmpty);
      expect(agentRows(fixture.profile), hasLength(1));
    });
  }
}
