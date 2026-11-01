import 'dart:io';

import 'package:host/src/host_options.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/agent_support.dart';
import 'support/harness.dart';
import 'support/terminal_support.dart' show rpcFailure;

void main() {
  setUpAll(buildTestHost);
  late Directory profile;
  late Directory savedWork;
  late Directory liveWork;
  late Desktop desktop;
  late AgentPeer saved;
  late AgentPeer live;
  late Json savedRow;
  late String targetPath;
  late String savedWorkspaceId;
  late String savedWorkspacePath;

  setUp(() async {
    profile = tempDir('agent_target_profile_');
    savedWork = tempDir('agent_target_saved_');
    liveWork = tempDir('agent_target_live_');
    addTearDown(() async {
      await deleteTree(liveWork);
      await deleteTree(savedWork);
      await deleteTree(profile);
    });
    desktop = await Desktop.start(
      profile,
      capabilities: {...testCapabilities, Capability.agent},
      environment: {
        'KUMIKO_TEST_RUNTIME_PATH': '',
        'KUMIKO_TEST_SHELL_PATH': '',
        'KUMIKO_TEST_RESOLVE_TIMEOUT_MS': '1500',
        'KUMIKO_TEST_QUALIFIED_ADAPTERS':
            '[["scripted-acp","test-only",["load","resume"]]]',
      },
    );
    addTearDown(desktop.dispose);
    await desktop.waitState();
    final workspace = await desktop.openWorkspace(savedWork.path);
    savedWorkspaceId = workspace.workspace.id;
    savedWorkspacePath = workspace.workspace.path;
    await saveAgentFixture(
      desktop,
      savedWork,
      id: 'saved',
      script: {
        'agentCapabilities': {'loadSession': true},
      },
    );
    saved = AgentPeer(desktop);
    await saved.start(workspace.workspace.id, runtime: 'saved');
    await saved.attach();
    savedRow = agentRows(profile).single;
    targetPath = savedRow['target_path'] as String;
    await saved.close();
    await saved.call(Method.agentRelease);

    final controlWorkspace = await desktop.openWorkspace(liveWork.path);
    await saveAgentFixture(
      desktop,
      liveWork,
      id: 'control',
      script: {
        'prompt': [
          permissionAction,
          {'waitCancel': true},
        ],
      },
    );
    live = AgentPeer(desktop);
    await live.start(controlWorkspace.workspace.id, runtime: 'control');
    await live.attach();
    await live.prompt();
    await live.wait(Method.agentPermissionRequested);
  });

  Future<AgentRecord> inspect() async {
    final result = AgentRecordsResult.fromJson(
      await desktop.connection.request(
        Method.agentRecords,
        AgentRecordsParams([saved.id]),
      ) as Json,
    );
    return result.records[saved.id]!;
  }

  Future<void> controlResponds() async {
    final request = live.of(Method.agentPermissionRequested).single;
    final permissionClock = Stopwatch()..start();
    await live.call(Method.agentPermissionReply, {
      'sessionId': live.id,
      'requestId': request['requestId'],
      'optionId': 'yes',
    });
    expect(
      permissionClock.elapsed,
      lessThan(const Duration(milliseconds: 250)),
    );
    final stopClock = Stopwatch()..start();
    await live.call(Method.agentStop);
    expect(stopClock.elapsed, lessThan(const Duration(milliseconds: 250)));
    expect((await live.wait(Method.agentStopResult))['outcome'], 'stopped');
  }

  test('Start stalled workspace target leaves native controls responsive and creates no record', () async {
    await desktop.resolveFault(savedWorkspacePath, delayMs: 3000);
    final pending = rpcFailure(saved.call(Method.agentStart, AgentStartParams(
      workspaceId: savedWorkspaceId,
      runtimeProfileId: 'saved',
    ).toJson()));
    await desktop.listWorkspaces();
    await controlResponds();
    final error = await pending.timeout(const Duration(seconds: 5));
    expect(error.reason, ErrorCode.workspaceUnavailable);
    expect(LedgerView(profile).units(), hasLength(1));
    expect(agentRows(profile), hasLength(2));
    expect(agentRows(profile).first, savedRow);
    await live.close();
  });

  test('unit launch target recheck remains bounded beside live native controls', () async {
    await desktop.resolveFault(targetPath, delayMs: 3000);
    final pending = rpcFailure(desktop.launch(Directory(targetPath), TestFixture.sleeper));
    await desktop.listWorkspaces();
    await controlResponds();
    final error = await pending.timeout(const Duration(seconds: 5));
    expect(error.reason, ErrorCode.targetUnavailable);
    expect(error.message, contains('did not answer'));
    expect(LedgerView(profile).units(), hasLength(1));
    expect(agentRows(profile), hasLength(2));
    await live.close();
  });

  for (final start in [true, false]) {
    test('${start ? 'Start' : 'Continue'} stalled executable leaves native control responsive and times out before spawn', () async {
      final executable = testHostExecutable();
      await desktop.resolveFault(executable, delayMs: 3000);
      final pending = rpcFailure(start
          ? saved.call(Method.agentStart, AgentStartParams(
              workspaceId: savedWorkspaceId,
              runtimeProfileId: 'saved',
            ).toJson())
          : saved.call(Method.agentContinue));
      await desktop.listWorkspaces();
      await controlResponds();
      final error = await pending.timeout(const Duration(seconds: 5));
      expect(error.reason, ErrorCode.busy);
      expect(error.data['executable'], executable);
      expect(error.message, contains('did not answer'));
      expect(LedgerView(profile).units(), hasLength(1));
      expect(agentRows(profile).first, savedRow);
      expect(agentRows(profile), hasLength(2));
      await live.close();
    });
  }

  test('saved records stalled target leaves native control responsive and times out unavailable', () async {
    await desktop.resolveFault(targetPath, hang: true);
    var completed = false;
    final pending = inspect().then((record) {
      completed = true;
      return record;
    });
    try {
      // Same-connection control reply is an ordering barrier, not a sleep.
      await desktop.listWorkspaces();
      expect(
        completed,
        isFalse,
        reason: 'records must use the stalled resolver',
      );
      await controlResponds();
      expect(completed, isFalse);
      final record = await pending.timeout(const Duration(seconds: 5));
      expect(record.known, isTrue);
      expect(record.targetPath, targetPath);
      expect(record.workspaceAvailable, isFalse);
      expect(agentRows(profile).first, savedRow);
    } finally {
      await desktop.releaseResolve(targetPath);
      await pending;
    }
    await live.close();
    await eventually(() async => (await inspect()).workspaceAvailable);
  });

  test('saved target checks share resolver slots and busy Continue never launches elsewhere', () async {
    final pending = <Future<AgentRecord>>[];
    try {
      for (var i = 0; i < HostOptions.resolveSlots; i++) {
        await desktop.resolveFault(targetPath, hang: true);
        pending.add(inspect());
        // Consumes the fault and takes the slot before the next request.
        await desktop.listWorkspaces();
      }
      final busy = await inspect().timeout(const Duration(milliseconds: 500));
      expect(busy.known, isTrue);
      expect(busy.workspaceAvailable, isFalse);
      final error = await rpcFailure(saved.call(Method.agentContinue));
      expect(error.reason, ErrorCode.busy);
      await controlResponds();
      final timedOut = await Future.wait(pending)
          .timeout(const Duration(seconds: 5));
      expect(timedOut.every((record) => !record.workspaceAvailable), isTrue);
      // Timeouts must not free still-hung slots.
      expect((await inspect()).workspaceAvailable, isFalse);
      expect(
        (await rpcFailure(saved.call(Method.agentContinue))).reason,
        ErrorCode.busy,
      );
      expect(LedgerView(profile).units(), hasLength(1));
      expect(agentRows(profile).first, savedRow);
    } finally {
      await desktop.releaseResolve(targetPath);
      await Future.wait(pending);
    }
    await live.close();
    await eventually(() async => (await inspect()).workspaceAvailable);
  });

  test('Continue stalled target reserves record before await and times out without spawning', () async {
    await desktop.resolveFault(targetPath, hang: true);
    final pending = rpcFailure(saved.call(Method.agentContinue));
    try {
      await desktop.listWorkspaces();
      await expectLater(
        saved.call(Method.agentContinue),
        rpcCode(ErrorCode.turnRunning),
      );
      await controlResponds();
      final error = await pending.timeout(const Duration(seconds: 5));
      expect(error.reason, ErrorCode.resumeUnavailable);
      expect(error.data['resumeReason'], 'target-missing');
      expect(error.message, contains('did not answer'));
      expect(LedgerView(profile).units(), hasLength(1));
      expect(agentRows(profile).first, savedRow);
    } finally {
      await desktop.releaseResolve(targetPath);
      // A failed assertion still drains the accepted request before teardown.
      await pending;
    }
    await live.close();
    await eventually(() async => (await inspect()).workspaceAvailable);
  });
}
