import 'dart:async';
import 'dart:convert';

import 'package:domain/domain.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import 'host_faults.dart';
import 'ledger.dart';
import 'store/store.dart';
import 'workspace_service.dart';

/// The Personal working set: `workbench/load`, `workbench/save` and the
/// workspace removal that depends on the stored layout. The host is the only
/// writer of the `working_set` row.
class WorkbenchService {
  WorkbenchService({
    required this._store,
    required this.ledger,
    required this.workspaces,
    required this.faults,
  });

  final Store _store;
  final Ledger ledger;
  final WorkspaceService workspaces;
  final HostFaults faults;

  T _guard<T>(T Function() body) {
    try {
      return body();
    } on SqliteException catch (e) {
      throw RpcException(ErrorCode.storeError, 'workbench store failed: $e');
    }
  }

  ({String? layout, int revision}) _personal() => _guard(() {
    final r = _store
        .select(
          "SELECT layout, revision FROM working_set WHERE id = 'personal'",
        )
        .single;
    return (layout: r['layout'] as String?, revision: r['revision'] as int);
  });

  /// The stored layout, or the reason it cannot be restored; both null when
  /// none is stored.
  ({LayoutDocument? layout, String? error}) _decodeStored(String? source) {
    if (source == null) return (layout: null, error: null);
    try {
      return (layout: decodeLayout(source), error: null);
    } on LayoutInvalid catch (e) {
      return (layout: null, error: e.reason);
    }
  }

  void _write(String layout, int revision) => _guard(
    () => _store.execute(
      'UPDATE working_set SET layout = ?, layout_format = $layoutFormat, '
      "revision = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') "
      "WHERE id = 'personal'",
      [layout, revision],
    ),
  );

  /// Returns at once with every workspace *checking*; the checks run on and
  /// each ends in a `workspace/changed`. A sidebar selection naming a
  /// workspace that no longer exists is dropped from the returned layout; the
  /// stored document is left as it is (the next save replaces it). Only format
  /// 2 is decoded; anything else is a restore error.
  WorkbenchLoadResult load() {
    final stored = _personal();
    final decoded = _decodeStored(stored.layout);
    var layout = decoded.layout;
    if (layout != null) {
      layout = layout.repairSelection({
        for (final w in workspaces.rows()) w.id,
      });
    }
    return WorkbenchLoadResult(
      layout: layout == null ? null : layoutToJson(layout),
      restoreError: decoded.error,
      revision: stored.revision,
      workspaces: workspaces.startLoadChecks(),
      cleanupRevision: ledger.revision,
    );
  }

  /// Validates and stores [params] when its revision is above the stored one.
  Future<WorkbenchSaveResult> save(WorkbenchSaveParams params) async {
    final LayoutDocument document;
    final String encoded;
    try {
      // The size bound applies to the document as received, re-encoded.
      document = decodeLayout(jsonEncode(params.layout));
      encoded = encodeLayout(document);
    } on LayoutInvalid catch (e) {
      throw RpcException(ErrorCode.layoutInvalid, e.reason);
    }
    final known = {for (final w in workspaces.rows()) w.id};
    final unknown = document.boundWorkspaces.difference(known);
    if (unknown.isNotEmpty) {
      throw RpcException(
        ErrorCode.layoutInvalid,
        'unknown-workspace: a pane is bound to ${unknown.first}',
        {'detail': ErrorCode.unknownWorkspace, 'workspace': unknown.first},
      );
    }
    while (faults.layoutSaveHangs) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    ledger.inTransaction(() {
      final stored = _personal().revision;
      if (params.revision <= stored) {
        throw staleRevision(
          stored,
          'revision ${params.revision} is not above $stored',
        );
      }
      if (faults.layoutSaveFails) {
        throw RpcException(
          ErrorCode.storeError,
          'injected layout save failure',
        );
      }
      _write(encoded, params.revision);
    });
    return WorkbenchSaveResult(params.revision);
  }

  /// Removes workspace [id] unless a pane of the stored layout is bound to
  /// it. When a valid layout is stored whose sidebar selection names [id],
  /// the selection is cleared and the result stored at the next revision, in
  /// the same transaction as the row deletion. Otherwise, and for a missing
  /// or undecodable layout, the stored layout and revision stay. Returns the
  /// layout revision.
  WorkspaceRemoveResult removeWorkspace(String id) {
    workspaces.requireRow(id);
    final revision = ledger.inTransaction(() {
      final stored = _personal();
      final layout = _decodeStored(stored.layout).layout;
      var revision = stored.revision;
      if (layout != null) {
        if (layout.boundWorkspaces.contains(id)) {
          throw RpcException(
            ErrorCode.workspaceInUse,
            'a pane is bound to this workspace',
          );
        }
        if (layout.selectedWorkspace == id) {
          revision = stored.revision + 1;
          _write(encodeLayout(layout.clearSelection(id)), revision);
        }
      }
      workspaces.deleteRow(id);
      return revision;
    });
    workspaces.forget(id);
    return WorkspaceRemoveResult(revision);
  }
}
