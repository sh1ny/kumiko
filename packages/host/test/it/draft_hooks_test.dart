import 'dart:async';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/agent_support.dart';
import 'support/harness.dart';

/// The draft store's test hooks (change `fix-draft-store-test-timing` design
/// D2, D3, D4): `test/draft.stats` reports `heldCommit` and `openHeld`,
/// `test/draft.expire` returns `{expired: n}` and `test/draft.releaseOpen`
/// returns `{released: bool}`. They are exercised over the wire against the
/// test host, as every other `test/*` hook is.
void main() {
  setUpAll(buildTestHost);

  late Directory profile;
  late Directory work;
  setUp(() {
    profile = tempDir('draft_hooks_profile_');
    work = tempDir('draft_hooks_work_');
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
      helloTimeout: _guard,
      environment: {
        'KUMIKO_TEST_RUNTIME_PATH': '',
        'KUMIKO_TEST_SHELL_PATH': '',
        'KUMIKO_TEST_RESOLVE_TIMEOUT_MS': '120000',
        'KUMIKO_TEST_ATTACH_TIMEOUT_MS': '120000',
        // Longer than the test's whole timeout, so only the explicit
        // `test/draft.expire` ever fails a held commit here (rule 3 of #28).
        'KUMIKO_TEST_DRAFT_DEADLINE_MS': '600000',
        ...env,
      },
    );
    addTearDown(d.dispose);
    await d.waitState(within: _guard);
    return d;
  }

  Future<Json> call(Desktop d, String method) async =>
      (await d.connection.request(method, <String, Object?>{}))! as Json;

  Future<AgentPeer> startSession(Desktop d) async {
    final workspace = await d.openWorkspace(work.path);
    await saveAgentFixture(d, work, id: 'acp', script: const {});
    final a = AgentPeer(d);
    await a.start(workspace.workspace.id, runtime: 'acp');
    await a.attach();
    return a;
  }

  Future<Object?> save(Desktop d, String id, String text, int revision) =>
      d.connection.request(
        Method.agentDraftSave,
        AgentDraftSaveParams(
          sessionId: id,
          text: text,
          revision: revision,
        ).toJson(),
      );

  test('an idle store reports no held commit and no held open; the hooks '
      'have nothing to act on', () async {
    final d = await desktop();
    final stats = await call(d, 'test/draft.stats');
    expect(stats.containsKey('heldCommit'), isTrue);
    expect(stats['heldCommit'], isNull);
    expect(stats['openHeld'], isFalse);
    expect(await call(d, 'test/draft.expire'), {'expired': 0});
    expect(await call(d, 'test/draft.releaseOpen'), {'released': false});
  });

  test('expire fails a held commit and reports it; the held commit stays held '
      'until released', () async {
    final d = await desktop();
    final a = await startSession(d);
    await d.setFault(TestFault.draftCommitHangs);
    final held = save(d, a.id, 'held', 1);
    final failure = expectLater(
      held,
      throwsA(
        isA<RpcException>().having(
          (e) => e.reason,
          'reason',
          ErrorCode.draftUnavailable,
        ),
      ),
    );
    await eventually(
      () async => (await call(d, 'test/draft.stats'))['heldCommit'] != null,
      within: _guard,
      reason: 'the commit never reached the hold',
    );
    expect(await call(d, 'test/draft.expire'), {'expired': 1});
    await failure;
    expect(
      (await call(d, 'test/draft.stats'))['heldCommit'],
      isNotNull,
      reason: 'expiry fails the caller only; the commit is still held',
    );
    expect(await call(d, 'test/draft.expire'), {'expired': 0});
    await d.setFault(TestFault.draftCommitHangs, enabled: false);
    await eventually(
      () async => (await call(d, 'test/draft.stats'))['heldCommit'] == null,
      within: _guard,
      reason: 'the released commit never answered',
    );
  });

  test('release open acknowledges the gate once: true, then false', () async {
    final d = await desktop(env: {'KUMIKO_TEST_DRAFT_OPEN_HELD': '1'});
    await eventually(
      () async => (await call(d, 'test/draft.stats'))['openHeld'] == true,
      within: _guard,
      reason: 'the worker never reported its open gate',
    );
    expect(await call(d, 'test/draft.releaseOpen'), {'released': true});
    expect((await call(d, 'test/draft.stats'))['openHeld'], isFalse);
    expect(await call(d, 'test/draft.releaseOpen'), {'released': false});
    await eventually(
      () async => (await call(d, 'test/draft.stats'))['phase'] == 'available',
      within: _guard,
      reason: 'the store never opened after the release',
    );
  });
}

/// A hang guard, not a bound under test (AGENTS.md, rule 4).
const Duration _guard = Duration(minutes: 2);
