import 'package:domain/domain.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import 'ledger.dart';
import 'store/store.dart';
import 'workspace_service.dart';

/// The Personal working set: `workbench/load` and the workspace removal that
/// depends on the stored layout. Layout saving and repair are added with the
/// layout rules.
class WorkbenchService {
  WorkbenchService({
    required this._store,
    required this.ledger,
    required this.workspaces,
  });

  final Store _store;
  final Ledger ledger;
  final WorkspaceService workspaces;

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

  /// The stored layout, or null when none is stored or it does not decode.
  LayoutDocument? _storedLayout(String? source) {
    if (source == null) return null;
    try {
      return decodeLayout(source);
    } on LayoutInvalid {
      return null;
    }
  }

  /// Returns at once with every workspace *checking*; the checks run on and
  /// each ends in a `workspace/changed`.
  WorkbenchLoadResult load() {
    final stored = _personal();
    final layout = _storedLayout(stored.layout);
    return WorkbenchLoadResult(
      layout: layout == null ? null : layoutToJson(layout),
      revision: stored.revision,
      workspaces: workspaces.startLoadChecks(),
      cleanupRevision: ledger.revision,
    );
  }

  /// Removes workspace [id] unless a tab of the stored layout is bound to it.
  /// Returns the layout revision.
  WorkspaceRemoveResult removeWorkspace(String id) {
    workspaces.requireRow(id);
    final stored = _personal();
    final layout = _storedLayout(stored.layout);
    if (layout != null && layout.boundWorkspaces.contains(id)) {
      throw RpcException(
        ErrorCode.workspaceInUse,
        'a tab is bound to this workspace',
      );
    }
    ledger.inTransaction(() => workspaces.deleteRow(id));
    workspaces.forget(id);
    return WorkspaceRemoveResult(stored.revision);
  }
}
