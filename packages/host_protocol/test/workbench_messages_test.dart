import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

WorkspaceRecord record({
  Availability availability = Availability.available,
  String? reason,
}) => WorkspaceRecord(
  id: 'w1',
  path: '/a/b',
  label: 'b',
  identity: 'dev:1',
  availability: availability,
  reason: reason,
  seq: 3,
  cleanup: const WorkspaceCleanup(groups: 2),
);

void expectInvalid(void Function() f) => expect(
  f,
  throwsA(
    isA<RpcException>().having(
      (e) => e.reason,
      'reason',
      ErrorCode.invalidParams,
    ),
  ),
);

void main() {
  test('workbench capability and method gating', () {
    expect(Capability.workbench, 'workbench');
    for (final m in [
      Method.workbenchLoad,
      Method.workbenchSave,
      Method.workspaceOpen,
      Method.workspaceCheck,
      Method.workspaceList,
      Method.workspaceRemove,
    ]) {
      expect(methodCapability[m], Capability.workbench, reason: m);
    }
    expect(Method.workbenchLoad, 'workbench/load');
    expect(Method.workbenchSave, 'workbench/save');
    expect(Method.workspaceOpen, 'workspace/open');
    expect(Method.workspaceCheck, 'workspace/check');
    expect(Method.workspaceList, 'workspace/list');
    expect(Method.workspaceRemove, 'workspace/remove');
    expect(Method.workspaceChanged, 'workspace/changed');
    // Notifications are not gated, like cleanup/state.
    expect(methodCapability.containsKey(Method.workspaceChanged), isFalse);
  });

  test('error reasons round-trip through RpcException', () {
    const reasons = {
      ErrorCode.layoutInvalid: 'layout-invalid',
      ErrorCode.staleRevision: 'stale-revision',
      ErrorCode.resolveTimeout: 'resolve-timeout',
      ErrorCode.workspaceCap: 'workspace-cap',
      ErrorCode.workspaceInUse: 'workspace-in-use',
      ErrorCode.unknownWorkspace: 'unknown-workspace',
    };
    reasons.forEach((constant, wire) {
      expect(constant, wire);
      final back = RpcException.fromJson(RpcException(constant, 'm').toJson());
      expect(back.reason, wire);
      expect(back.message, 'm');
    });
  });

  test('stale-revision carries storedRevision', () {
    final e = staleRevision(7);
    final back = RpcException.fromJson(e.toJson());
    expect(back.reason, ErrorCode.staleRevision);
    expect(storedRevisionOf(back), 7);
    expect(storedRevisionOf(RpcException(ErrorCode.staleRevision)), isNull);
  });

  test('WorkspaceRecord round-trips', () {
    for (final r in [
      record(),
      record(availability: Availability.checking),
      record(availability: Availability.unavailable, reason: 'resolve-timeout'),
    ]) {
      final json = r.toJson();
      expect(json['cleanup'], {'groups': 2});
      final back = WorkspaceRecord.fromJson(json);
      expect(back.toJson(), json);
      expect(back.availability, r.availability);
      expect(back.reason, r.reason);
      expect(back.seq, 3);
      expect(back.cleanup.groups, 2);
    }
    expect(record().toJson().containsKey('reason'), isFalse);
    expect(record().toJson()['availability'], 'available');
  });

  test('WorkspaceRecord rejects bad input', () {
    final good = record().toJson();
    expectInvalid(
      () => WorkspaceRecord.fromJson({...good, 'availability': 'x'}),
    );
    expectInvalid(() => WorkspaceRecord.fromJson({...good, 'seq': 'x'}));
    expectInvalid(() => WorkspaceRecord.fromJson({...good}..remove('cleanup')));
    expectInvalid(
      () => WorkspaceRecord.fromJson({...good, 'cleanup': <String, Object?>{}}),
    );
    expectInvalid(() => WorkspaceRecord.fromJson({...good}..remove('id')));
  });

  test('WorkbenchLoadResult round-trips', () {
    final layout = <String, Object?>{'v': 1, 'tabs': <Object?>[]};
    final withLayout = WorkbenchLoadResult(
      layout: layout,
      revision: 4,
      workspaces: [record()],
      cleanupRevision: 9,
    );
    expect(
      WorkbenchLoadResult.fromJson(withLayout.toJson()).toJson(),
      withLayout.toJson(),
    );
    expect(withLayout.toJson().containsKey('restoreError'), isFalse);

    final failed = WorkbenchLoadResult(
      restoreError: 'unreadable',
      revision: 4,
      workspaces: const [],
      cleanupRevision: 9,
    );
    final back = WorkbenchLoadResult.fromJson(failed.toJson());
    expect(back.layout, isNull);
    expect(back.restoreError, 'unreadable');
    expect(back.workspaces, isEmpty);
    expect(back.cleanupRevision, 9);

    final fresh = WorkbenchLoadResult(
      revision: 0,
      workspaces: const [],
      cleanupRevision: 0,
    );
    expect(WorkbenchLoadResult.fromJson(fresh.toJson()).layout, isNull);
  });

  test('WorkbenchLoadResult rejects layout with restoreError', () {
    expectInvalid(
      () => WorkbenchLoadResult.fromJson({
        'layout': {'a': 1},
        'restoreError': 'x',
        'revision': 1,
        'workspaces': <Object?>[],
        'cleanupRevision': 1,
      }),
    );
    expectInvalid(
      () => WorkbenchLoadResult.fromJson({
        'revision': 1,
        'workspaces': <Object?>[],
      }),
    );
  });

  test('WorkbenchSaveParams and result round-trip', () {
    final p = WorkbenchSaveParams(layout: {'v': 1}, revision: 2);
    final back = WorkbenchSaveParams.fromJson(p.toJson());
    expect(back.layout, {'v': 1});
    expect(back.revision, 2);
    expectInvalid(() => WorkbenchSaveParams.fromJson({'revision': 2}));
    expectInvalid(() => WorkbenchSaveParams.fromJson({'layout': {}}));
    expectInvalid(
      () => WorkbenchSaveParams.fromJson({'layout': 'x', 'revision': 2}),
    );
    expect(
      WorkbenchSaveResult.fromJson(const WorkbenchSaveResult(3).toJson())
          .revision,
      3,
    );
    expectInvalid(() => WorkbenchSaveResult.fromJson({}));
  });

  test('WorkspaceOpenParams is bounded by maxPathBytes', () {
    expect(WorkspaceOpenParams.fromJson({'path': '/a'}).path, '/a');
    expect(const WorkspaceOpenParams('/a').toJson(), {'path': '/a'});
    expectInvalid(() => WorkspaceOpenParams.fromJson({}));
    expectInvalid(() => WorkspaceOpenParams.fromJson({'path': 3}));
    expectInvalid(
      () => WorkspaceOpenParams.fromJson({'path': 'a' * (maxPathBytes + 1)}),
    );
    expect(
      WorkspaceOpenParams.fromJson({'path': 'a' * maxPathBytes}).path.length,
      maxPathBytes,
    );
  });

  test('workspace results round-trip', () {
    final open = WorkspaceOpenResult(
      workspace: record(),
      existing: true,
      cleanupRevision: 5,
    );
    final o = WorkspaceOpenResult.fromJson(open.toJson());
    expect(o.existing, isTrue);
    expect(o.cleanupRevision, 5);
    expect(o.toJson(), open.toJson());
    expectInvalid(
      () => WorkspaceOpenResult.fromJson({
        'workspace': record().toJson(),
        'cleanupRevision': 1,
      }),
    );

    final check = WorkspaceCheckResult(workspace: record(), cleanupRevision: 6);
    expect(
      WorkspaceCheckResult.fromJson(check.toJson()).toJson(),
      check.toJson(),
    );

    final list = WorkspaceListResult(
      workspaces: [record()],
      cleanupRevision: 7,
    );
    final l = WorkspaceListResult.fromJson(list.toJson());
    expect(l.workspaces.single.id, 'w1');
    expect(l.cleanupRevision, 7);
    expectInvalid(() => WorkspaceListResult.fromJson({'workspaces': []}));

    expect(
      WorkspaceRemoveResult.fromJson(const WorkspaceRemoveResult(8).toJson())
          .revision,
      8,
    );
  });

  test('WorkspaceCheck and Remove params round-trip', () {
    expect(
      WorkspaceCheckParams.fromJson(const WorkspaceCheckParams('w').toJson())
          .id,
      'w',
    );
    expect(
      WorkspaceRemoveParams.fromJson(const WorkspaceRemoveParams('w').toJson())
          .id,
      'w',
    );
    expectInvalid(() => WorkspaceCheckParams.fromJson({}));
    expectInvalid(() => WorkspaceRemoveParams.fromJson({'id': 1}));
  });

  test('WorkspaceChanged round-trips', () {
    final n = WorkspaceChanged(workspace: record(), cleanupRevision: 11);
    final back = WorkspaceChanged.fromJson(n.toJson());
    expect(back.workspace.id, 'w1');
    expect(back.cleanupRevision, 11);
    expectInvalid(() => WorkspaceChanged.fromJson({'cleanupRevision': 1}));
  });

  test('CleanupListParams workspace filter round-trips', () {
    final none = CleanupListParams.fromJson(const CleanupListParams().toJson());
    expect(none.workspace, isNull);
    expect(
      const CleanupListParams().toJson().containsKey('workspace'),
      isFalse,
    );
    final some = CleanupListParams.fromJson(
      const CleanupListParams(workspace: 'w1').toJson(),
    );
    expect(some.workspace, 'w1');
    expectInvalid(() => CleanupListParams.fromJson({'workspace': 3}));
  });
}
