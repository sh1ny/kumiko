import 'dart:convert';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/sinks.dart';

const _profile = RuntimeProfile(
  id: 'p',
  name: 'Claude',
  runtimeKind: 'claude',
  executable: 'node',
  args: ['a b', '"quoted"', ''],
  env: {'X': '值'},
);

Matcher _invalid() => throwsA(
  isA<RpcException>().having(
    (e) => e.reason,
    'reason',
    ErrorCode.invalidParams,
  ),
);

void main() {
  group('Kumiko tools status (additive, no version bump)', () {
    Json rt(Json wire) => jsonDecode(jsonEncode(wire)) as Json;
    const adapter = AgentAdapter(name: 'claude', version: '1');

    test('state without or with a tools field round-trips', () {
      final bare = {'sessionId': 's', 'seq': 3, 'state': 'idle'};
      final parsedBare = AgentStateParams.fromJson(rt(bare));
      expect(parsedBare.tools, isNull);
      expect(parsedBare.toJson(), bare);

      const unavailable = AgentTools(
        AgentToolsStatus.unavailable,
        reason: 'endpoint-unavailable: path too long',
      );
      for (final tools in [
        const AgentTools(AgentToolsStatus.notYetUsed),
        const AgentTools(AgentToolsStatus.connected),
        const AgentTools(AgentToolsStatus.notStarted),
        unavailable,
      ]) {
        final wire = AgentStateParams(
          sessionId: 's',
          seq: 4,
          state: AgentState.running,
          tools: tools,
        ).toJson();
        expect(wire['tools'], {
          'status': tools.status.name,
          'reason': ?tools.reason,
        });
        final back = AgentStateParams.fromJson(rt(wire));
        expect(back.tools!.status, tools.status);
        expect(back.tools!.reason, tools.reason);
        expect(back.toJson(), wire);
      }
      expect(unavailable.toJson(), {
        'status': 'unavailable',
        'reason': 'endpoint-unavailable: path too long',
      });
    });

    test('an unknown tools status is tolerated as unknown', () {
      final parsed = AgentStateParams.fromJson(
        rt({
          'sessionId': 's',
          'seq': 5,
          'state': 'idle',
          'tools': {'status': 'quantum', 'extra': 1},
        }),
      );
      expect(parsed.seq, 5);
      expect(parsed.state, AgentState.idle);
      expect(parsed.tools!.status, AgentToolsStatus.unknown);
      expect(
        AgentStateParams.fromJson(parsed.toJson()).tools!.status,
        AgentToolsStatus.unknown,
      );
    });

    test('a malformed tools field never rejects the state message', () {
      for (final bad in <Object?>[
        'x',
        3,
        {'status': 7},
        <Object?>[],
      ]) {
        final parsed = AgentStateParams.fromJson(
          rt({'sessionId': 's', 'seq': 1, 'state': 'idle', 'tools': bad}),
        );
        expect(parsed.state, AgentState.idle);
        expect(
          parsed.tools?.status ?? AgentToolsStatus.unknown,
          AgentToolsStatus.unknown,
        );
      }
    });

    test('start and Continue results carry tools; older results decode', () {
      const tools = AgentTools(AgentToolsStatus.notYetUsed);
      final start = const AgentStartResult(
        sessionId: 's',
        eventChannel: 1,
        adapter: adapter,
        capabilities: [],
        tools: tools,
      ).toJson();
      expect(start['tools'], {'status': 'notYetUsed'});
      expect(
        AgentStartResult.fromJson(rt(start)).tools!.status,
        AgentToolsStatus.notYetUsed,
      );
      final cont = const AgentContinueResult(
        eventChannel: 2,
        adapter: adapter,
        capabilities: [],
        mode: AgentContinueMode.load,
        tools: AgentTools(AgentToolsStatus.unavailable, reason: 'r'),
      ).toJson();
      final contBack = AgentContinueResult.fromJson(rt(cont));
      expect(contBack.tools!.status, AgentToolsStatus.unavailable);
      expect(contBack.tools!.reason, 'r');

      final old = Map<String, Object?>.of(start)..remove('tools');
      expect(AgentStartResult.fromJson(rt(old)).tools, isNull);
      expect(AgentStartResult.fromJson(rt(old)).toJson(), old);
      final oldCont = Map<String, Object?>.of(cont)..remove('tools');
      expect(AgentContinueResult.fromJson(rt(oldCont)).tools, isNull);
    });
  });

  final requests = {
    Method.runtimeList: 'runtime/list',
    Method.runtimeSave: 'runtime/save',
    Method.runtimeRemove: 'runtime/remove',
    Method.runtimeSetDefault: 'runtime/setDefault',
    Method.agentStart: 'agent/start',
    Method.agentContinue: 'agent/continue',
    Method.agentAttach: 'agent/attach',
    Method.agentPrompt: 'agent/prompt',
    Method.agentStop: 'agent/stop',
    Method.agentPermissionReply: 'agent/permissionReply',
    Method.agentClose: 'agent/close',
    Method.agentRelease: 'agent/release',
    Method.agentRecords: 'agent/records',
    Method.agentDraftSave: 'agent/draftSave',
    Method.agentDraftLoad: 'agent/draftLoad',
    Method.agentDraftReset: 'agent/draftReset',
  };
  test('all request names are gated; notifications are not gated', () {
    expect(Capability.agent, 'agent');
    requests.forEach((method, wire) {
      expect(method, wire);
      expect(methodCapability[method], Capability.agent);
    });
    final notifications = {
      Method.agentState: 'agent/state',
      Method.agentPermissionRequested: 'agent/permissionRequested',
      Method.agentPermissionResolved: 'agent/permissionResolved',
      Method.agentStopResult: 'agent/stopResult',
      Method.agentTurnEnded: 'agent/turnEnded',
      Method.agentExited: 'agent/exited',
      Method.agentCloseFailed: 'agent/closeFailed',
      Method.agentDraftStoreReady: 'agent/draftStoreReady',
    };
    notifications.forEach((method, wire) {
      expect(method, wire);
      expect(methodCapability.containsKey(method), isFalse);
    });
  });

  test('typed round-trip of every runtime and agent method result and notification', () {
    void round(Json wire, Json Function(Json) parse) =>
        expect(parse(jsonDecode(jsonEncode(wire)) as Json), wire);
    round(_profile.toJson(), (j) => RuntimeProfile.fromJson(j).toJson());
    round(
      const RuntimeListResult(
        profiles: [_profile],
        defaultId: 'p',
        defaultAvailable: false,
        defaultReason: 'missing',
      ).toJson(),
      (j) => RuntimeListResult.fromJson(j).toJson(),
    );
    round(
      const RuntimeSaveParams(_profile).toJson(),
      (j) => RuntimeSaveParams.fromJson(j).toJson(),
    );
    round(
      const RuntimeRemoveParams('p').toJson(),
      (j) => RuntimeRemoveParams.fromJson(j).toJson(),
    );
    round(
      const RuntimeSetDefaultParams('p').toJson(),
      (j) => RuntimeSetDefaultParams.fromJson(j).toJson(),
    );
    round(
      const EmptyParams().toJson(),
      (j) => EmptyParams.fromJson(j).toJson(),
    );
    round(
      const EmptyResult().toJson(),
      (j) => EmptyResult.fromJson(j).toJson(),
    );
    round(
      const AgentStartParams(workspaceId: 'w', runtimeProfileId: 'p').toJson(),
      (j) => AgentStartParams.fromJson(j).toJson(),
    );
    const adapter = AgentAdapter(name: 'claude', version: '1');
    round(
      const AgentStartResult(
        sessionId: 's',
        eventChannel: 1,
        adapter: adapter,
        capabilities: ['prompt', 'load'],
      ).toJson(),
      (j) => AgentStartResult.fromJson(j).toJson(),
    );
    round(
      const AgentContinueResult(
        eventChannel: 2,
        adapter: adapter,
        capabilities: ['resume'],
        mode: AgentContinueMode.resume,
      ).toJson(),
      (j) => AgentContinueResult.fromJson(j).toJson(),
    );
    // These methods deliberately share the exact same session-id wire shape.
    for (final method in [
      Method.agentContinue,
      Method.agentAttach,
      Method.agentStop,
      Method.agentClose,
      Method.agentRelease,
    ]) {
      round(
        const AgentSessionParams('s').toJson(),
        (j) => AgentSessionParams.fromJson(j).toJson(),
      );
      expect(requests, contains(method));
    }
    round(
      const AgentPromptParams(sessionId: 's', text: 'hello\n值').toJson(),
      (j) => AgentPromptParams.fromJson(j).toJson(),
    );
    round(
      const AgentPermissionReplyParams(
        sessionId: 's',
        requestId: 'r',
        optionId: 'o',
      ).toJson(),
      (j) => AgentPermissionReplyParams.fromJson(j).toJson(),
    );
    round(
      const AgentRecordsParams(['s', 'unknown']).toJson(),
      (j) => AgentRecordsParams.fromJson(j).toJson(),
    );
    round(
      const AgentRecordsResult({
        's': AgentRecord(
          known: true,
          targetPath: '/a',
          adapterVersion: '1',
          workspaceAvailable: true,
        ),
        'unknown': AgentRecord(known: false, workspaceAvailable: false),
      }).toJson(),
      (j) => AgentRecordsResult.fromJson(j).toJson(),
    );
    round(
      const AgentStateParams(
        sessionId: 's',
        seq: 2,
        state: AgentState.waitingApproval,
      ).toJson(),
      (j) => AgentStateParams.fromJson(j).toJson(),
    );
    round(
      AgentPermissionRequestedParams(
        sessionId: 's',
        requestId: 'r',
        title: 'Read',
        options: const [
          AgentPermissionOption(
            optionId: 'o',
            name: 'Allow',
            kind: 'allow_once',
          ),
        ],
        preview: 'diff',
      ).toJson(),
      (j) => AgentPermissionRequestedParams.fromJson(j).toJson(),
    );
    round(
      const AgentPermissionResolvedParams(
        sessionId: 's',
        requestId: 'r',
        outcome: AgentPermissionOutcome.selected,
        optionId: 'o',
      ).toJson(),
      (j) => AgentPermissionResolvedParams.fromJson(j).toJson(),
    );
    for (final outcome in AgentStopOutcome.values) {
      round(
        AgentStopResultParams(
          sessionId: 's',
          outcome: outcome,
          late: true,
          stopReason: 'refusal',
          message: 'error',
        ).toJson(),
        (j) => AgentStopResultParams.fromJson(j).toJson(),
      );
    }
    round(
      const AgentTurnEndedParams(
        sessionId: 's',
        stopReason: 'refusal',
        error: 'auth-required',
        message: 'sign in',
        nativeCode: -9876,
        nativeMessage: 'synthetic native error',
        nativeMessageTruncated: true,
      ).toJson(),
      (j) => AgentTurnEndedParams.fromJson(j).toJson(),
    );
    round(
      const AgentExitedParams(
        sessionId: 's',
        reason: AgentExitReason.failed,
        eventCount: 17,
        status: 1,
        error: 'resume-unavailable',
        resumeReason: 'adapter-error',
        message: 'lost',
      ).toJson(),
      (j) => AgentExitedParams.fromJson(j).toJson(),
    );
    round(
      const AgentCloseFailedParams(
        sessionId: 's',
        reason: 'cleanup-unresolved',
        message: 'pending',
      ).toJson(),
      (j) => AgentCloseFailedParams.fromJson(j).toJson(),
    );
  });

  test(
    'agent exit requires a nonnegative final event count and preserves it',
    () {
      final wire = <String, Object?>{
        'sessionId': 's',
        'reason': 'failed',
        'status': 1,
        'eventCount': 17,
      };
      expect(AgentExitedParams.fromJson(wire).toJson()['eventCount'], 17);
      for (final invalid in <Object?>[null, -1, 1.5, '17']) {
        expect(
          () => AgentExitedParams.fromJson({...wire, 'eventCount': invalid}),
          throwsA(isA<RpcException>()),
        );
      }
      final missing = Map<String, Object?>.of(wire)..remove('eventCount');
      expect(
        () => AgentExitedParams.fromJson(missing),
        throwsA(isA<RpcException>()),
      );
    },
  );

  test('new error codes preserve structured data and reserved reason', () {
    final reasons = {
      ErrorCode.unknownSession: 'unknown-session',
      ErrorCode.unknownRequest: 'unknown-request',
      ErrorCode.turnRunning: 'turn-running',
      ErrorCode.noRuntimeProfile: 'no-runtime-profile',
      ErrorCode.readOnlyProfile: 'read-only-profile',
      ErrorCode.invalidProfile: 'invalid-profile',
      ErrorCode.adapterStartFailed: 'adapter-start-failed',
      ErrorCode.adapterProtocol: 'adapter-protocol',
      ErrorCode.authRequired: 'auth-required',
      ErrorCode.resumeUnavailable: 'resume-unavailable',
      ErrorCode.workspaceRequired: 'workspace-required',
    };
    reasons.forEach((reason, wire) {
      expect(reason, wire);
      final back = RpcException.fromJson(
        RpcException(reason, 'm', {'detail': 'x'}).toJson(),
      );
      expect(back.reason, wire);
      expect(back.data, {'detail': 'x'});
    });
    final start = RpcException.fromJson(
      adapterStartFailed('initialize', 'exit 1').toJson(),
    );
    expect(start.data, {'stage': 'initialize', 'detail': 'exit 1'});
    final resume = RpcException.fromJson(
      resumeUnavailable('not-qualified', detail: 'v2').toJson(),
    );
    expect(resume.reason, ErrorCode.resumeUnavailable);
    expect(resume.data, {'resumeReason': 'not-qualified', 'detail': 'v2'});
  });

  test('records max128ids and prompt max256KiB', () {
    expect(
      AgentRecordsParams.fromJson({'sessionIds': List.filled(128, 's')})
          .sessionIds,
      hasLength(128),
    );
    expect(
      () => AgentRecordsParams.fromJson({'sessionIds': List.filled(129, 's')}),
      _invalid(),
    );
    expect(
      AgentPromptParams.fromJson({'sessionId': 's', 'text': 'a' * (256 * 1024)})
          .text
          .length,
      256 * 1024,
    );
    expect(
      () => AgentPromptParams.fromJson({
        'sessionId': 's',
        'text': '😀' * (64 * 1024 + 1),
      }),
      _invalid(),
    );
  });

  Matcher draftRefusal(String reason) => throwsA(
    isA<RpcException>().having((e) => e.reason, 'reason', reason),
  );

  test(
    'draft one byte past 256 KiB encoded refused draft-too-large',
    () {
      Json save(String text) => {'sessionId': 's', 'text': text, 'revision': 1};
      // Plain bytes: the bound itself passes, one more is refused.
      expect(
        AgentDraftSaveParams.fromJson(save('a' * maxDraftBytes)).text,
        hasLength(maxDraftBytes),
      );
      expect(
        () => AgentDraftSaveParams.fromJson(save('a' * (maxDraftBytes + 1))),
        draftRefusal(ErrorCode.draftTooLarge),
      );
      // Escaping is counted: a quote encodes to two bytes, a control
      // character to six, so 131072 quotes fill the bound exactly.
      expect(
        AgentDraftSaveParams.fromJson(save('"' * (maxDraftBytes ~/ 2))).text,
        hasLength(maxDraftBytes ~/ 2),
      );
      expect(
        () => AgentDraftSaveParams.fromJson(
          save('${'"' * (maxDraftBytes ~/ 2)}a'),
        ),
        draftRefusal(ErrorCode.draftTooLarge),
      );
      expect(
        () => AgentDraftSaveParams.fromJson(save('\u0001' * 43691)),
        draftRefusal(ErrorCode.draftTooLarge),
      );
      // UTF-8 is counted: a 4-byte emoji is two UTF-16 units.
      expect(
        AgentDraftSaveParams.fromJson(save('😀' * (maxDraftBytes ~/ 4))).text,
        isNotEmpty,
      );
      expect(
        () => AgentDraftSaveParams.fromJson(
          save('${'😀' * (maxDraftBytes ~/ 4)}a'),
        ),
        draftRefusal(ErrorCode.draftTooLarge),
      );
      expect(jsonStringContentBytes('a"\n\u0001é😀'), 1 + 2 + 2 + 6 + 2 + 4);
    },
  );

  test('draft messages round-trip; the prompt carries the draft fields', () {
    Json rt(Json j) => jsonDecode(jsonEncode(j)) as Json;
    final save = const AgentDraftSaveParams(
      sessionId: 's',
      text: 'check the tests',
      revision: 7,
    ).toJson();
    expect(AgentDraftSaveParams.fromJson(rt(save)).toJson(), save);
    expect(
      AgentDraftSaveResult.fromJson(
        rt(const AgentDraftSaveResult(7).toJson()),
      ).revision,
      7,
    );
    expect(
      AgentDraftLoadResult.fromJson(
        rt(const AgentDraftLoadResult(revision: 3, text: 'x').toJson()),
      ).text,
      'x',
    );
    expect(
      AgentDraftLoadResult.fromJson(
        rt(const AgentDraftLoadResult(revision: 0).toJson()),
      ).text,
      isNull,
    );
    expect(
      () => AgentDraftSaveParams.fromJson({
        'sessionId': 's',
        'text': 'x',
        'revision': -1,
      }),
      _invalid(),
    );
    final send = AgentPromptParams.fromJson({
      'sessionId': 's',
      'text': 'go',
      'draftRevision': 4,
      'draftSynced': true,
    });
    expect(send.draftRevision, 4);
    expect(send.draftSynced, isTrue);
    final retry = AgentPromptParams.fromJson({'sessionId': 's', 'text': 'go'});
    expect(retry.draftRevision, isNull);
    expect(retry.toJson(), {'sessionId': 's', 'text': 'go'});
    final stale = RpcException(ErrorCode.staleRevision, 'stale', {
      'storedRevision': 500,
    });
    expect(storedRevisionOf(RpcException.fromJson(stale.toJson())), 500);
  });

  test(
    'permission request clamps UTF8 title options names preview with marker',
    () {
      final wire = AgentPermissionRequestedParams(
        sessionId: 's',
        requestId: 'r',
        title: '😀' * 2048,
        preview: '值' * 10000,
        options: [
          for (var i = 0; i < 20; i++)
            AgentPermissionOption(
              optionId: '$i',
              name: '😀' * 100,
              kind: 'allow_once',
            ),
        ],
      ).toJson();
      final parsed = AgentPermissionRequestedParams.fromJson(wire);
      expect(utf8.encode(parsed.title).length, lessThanOrEqualTo(4096));
      expect(utf8.encode(parsed.preview!).length, lessThanOrEqualTo(16384));
      expect(parsed.options, hasLength(16));
      expect(
        parsed.options.every((o) => utf8.encode(o.name).length <= 256),
        isTrue,
      );
      expect(parsed.truncated, isTrue);
      expect(
        utf8.encode(jsonEncode(wire)).length,
        lessThanOrEqualTo(64 * 1024),
      );
    },
  );

  test('permission encoded notification cap counts escaping and preserves identifiers', () {
    final request = AgentPermissionRequestedParams(
      sessionId: 's',
      requestId: 'r',
      title: '\u0000' * 4096,
      preview: '\u0000' * 16384,
      options: [
        for (var i = 0; i < 16; i++)
          AgentPermissionOption(
            optionId: 'o$i',
            name: '\u0000' * 256,
            kind: 'allow_once',
          ),
      ],
    );
    expect(
      utf8.encode(jsonEncode(request.toJson())).length,
      lessThanOrEqualTo(64 * 1024),
    );
    expect(request.truncated, isTrue);
    expect(request.options.map((o) => o.optionId), [
      for (var i = 0; i < 16; i++) 'o$i',
    ]);
    expect(request.requestId, 'r');
  });

  test('permission opaque identifiers remain exact; unrepresentable encoded metadata is refused', () {
    const optionId = 'opaque/"值\u0000';
    const kind = 'vendor/"许可';
    final request = AgentPermissionRequestedParams(
      sessionId: 's',
      requestId: 'r',
      title: 'Read',
      options: const [
        AgentPermissionOption(optionId: optionId, name: 'Allow', kind: kind),
      ],
    );
    final back = AgentPermissionRequestedParams.fromJson(
      jsonDecode(jsonEncode(request.toJson())) as Json,
    );
    expect(back.options.single.optionId, optionId);
    expect(back.options.single.kind, kind);
    expect(back.truncated, isFalse);
    expect(
      () => AgentPermissionRequestedParams(
        sessionId: 's',
        requestId: 'r',
        title: '',
        options: [
          AgentPermissionOption(
            optionId: '\u0000' * (12 * 1024),
            name: '',
            kind: kind,
          ),
        ],
      ),
      throwsA(
        isA<RpcException>()
            .having((e) => e.reason, 'reason', ErrorCode.invalidParams)
            .having((e) => e.message, 'message', contains('64 KiB')),
      ),
    );
  });

  test(
    'runtime profile uses shell bounds and requires runtimeKind without cwd',
    () {
      expect(_profile.toJson().containsKey('cwd'), isFalse);
      expect(
        () => RuntimeProfile.fromJson(
          {..._profile.toJson()}..remove('runtimeKind'),
        ),
        _invalid(),
      );
      for (final patch in <Json>[
        {'args': List.filled(257, '')},
        {
          'args': ['a' * 4097],
        },
        {
          'env': {for (var i = 0; i < 129; i++) '$i': ''},
        },
        {'name': 'a' * (12 * 1024)},
      ]) {
        expect(
          () => RuntimeProfile.fromJson({..._profile.toJson(), ...patch}),
          _invalid(),
        );
      }
    },
  );

  test(
    'runtime and agent methods dispatch when both advertise agent',
    () async {
      final (desktop, host) = connectedPair(
        capabilitiesA: {Capability.agent},
        capabilitiesB: {Capability.agent},
        onRequestB: (m, p) => {'method': m},
      );
      await desktop.hello();
      for (final method in requests.keys) {
        expect(await desktop.request(method, {}), {'method': method});
      }
      await desktop.close();
      await host.close();
    },
  );

  test('agent methods fail method-not-available; terminal and workbench keep working', () async {
    for (final absentAtHost in [true, false]) {
      final common = {Capability.terminal, Capability.workbench};
      final (desktop, host) = connectedPair(
        capabilitiesA: {...common, if (absentAtHost) Capability.agent},
        capabilitiesB: {...common, if (!absentAtHost) Capability.agent},
        onRequestB: (m, p) => {'method': m},
      );
      await desktop.hello();
      for (final method in requests.keys) {
        await expectLater(
          desktop.request(method, {}),
          throwsA(
            isA<RpcException>().having(
              (e) => e.reason,
              'reason',
              ErrorCode.methodNotAvailable,
            ),
          ),
        );
      }
      for (final method in [Method.terminalOpen, Method.workbenchLoad]) {
        expect(await desktop.request(method, {}), {'method': method});
      }
      await desktop.close();
      await host.close();
    }
  });
}
