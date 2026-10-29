import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:domain/domain.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:host_protocol/host_protocol.dart';

import 'cleanup_controller.dart';
import 'folder_picker.dart';
import 'host_link.dart';
import 'layout_saver.dart';

/// A view kind registered in the desktop (design D7).
class ViewKind {
  const ViewKind(this.id, this.label, {required this.needsWorkspace});

  final String id;
  final String label;
  final bool needsWorkspace;
}

const String workspaceOverviewKind = 'workspace-overview';

/// The kinds the launcher offers. This change registers only the Workspace
/// overview; later changes add more.
const List<ViewKind> registeredViews = [
  ViewKind(workspaceOverviewKind, 'Workspace overview', needsWorkspace: true),
];

ViewKind? viewKindOf(String id) {
  for (final k in registeredViews) {
    if (k.id == id) return k;
  }
  return null;
}

String _randomId(String prefix) {
  final random = Random.secure();
  final bits = [
    for (var i = 0; i < 6; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ];
  return '$prefix-${bits.join()}';
}

/// The workbench: the working-set layout, the workspaces and their cleanup
/// state, over a [HostLink] that may come and go (Restart host keeps the
/// in-memory layout).
class WorkbenchController extends ChangeNotifier {
  WorkbenchController({
    required this._picker,
    String Function(String prefix)? newId,
  }) : _newId = newId ?? _randomId {
    _saver = LayoutSaver(save: _save);
    _saver.addListener(notifyListeners);
  }

  final FolderPicker _picker;
  final String Function(String prefix) _newId;
  late final LayoutSaver _saver;

  HostLink? _link;
  int _generation = 0;
  bool _disposed = false;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  LayoutDocument? _layout;
  bool _loading = false;
  String? _loadError;
  String? _restoreNotice;
  String? _message;
  bool _reconciling = false;

  List<WorkspaceRecord> _workspaces = const [];
  final Map<String, int> _seq = {};
  /// Per workspace: the `cleanupRevision` its cleanup fields were applied at.
  final Map<String, int> _cleanupOf = {};

  /// The `cleanupRevision` of the newest whole list applied (load or list).
  int _listApplied = 0;
  int _latestStateRevision = 0;
  int _listRequested = 0;
  bool _listing = false;
  bool _listLoaded = false;
  final Set<String> _removing = {};

  /// Removed ids: the host never reuses one, so a list answer taken before
  /// the remove must not add it back.
  final Set<String> _removed = {};

  /// The layout, or null until the first load.
  LayoutDocument? get layout => _layout;
  List<WorkspaceRecord> get workspaces => _workspaces;
  LayoutSaver get saver => _saver;
  HelloResult? get hello => _link?.hello;
  bool get connected => _link != null;
  bool get loading => _loading;

  /// Why the workbench could not be loaded, or null.
  String? get loadError => _loadError;

  /// Set when the saved layout was invalid and an empty one replaced it.
  String? get restoreNotice => _restoreNotice;

  /// The last operation's problem (a limit, a failed open ...), or null.
  String? get message => _message;

  /// The host is still cleaning up after the previous session.
  bool get reconciling => _reconciling;

  WorkspaceRecord? workspace(String id) {
    for (final w in _workspaces) {
      if (w.id == id) return w;
    }
    return null;
  }

  // --- connecting ---------------------------------------------------------

  Future<void> attach(HostLink link) async {
    final generation = ++_generation;
    _detachLink();
    _link = link;
    _loadError = null;
    _loading = _layout == null;
    _listLoaded = false;
    _listRequested = 0;
    _latestStateRevision = 0;
    _reconciling = link.hello.state == HostState.reconciling;
    _subscriptions
      ..add(link.cleanupStates.listen(_onCleanupState))
      ..add(link.workspaceChanges.listen(_onWorkspaceChanged));
    notifyListeners();

    final WorkbenchLoadResult result;
    try {
      result = await link.workbenchLoad();
    } on RpcException catch (e) {
      if (_stale(generation)) return;
      _failLoad(e.message.isEmpty ? e.reason : e.message);
      return;
    } on ConnectionClosedException {
      if (_stale(generation)) return;
      _failLoad('the host is gone');
      return;
    }
    if (_stale(generation)) return;

    _workspaces = [...result.workspaces];
    _seq
      ..clear()
      ..addEntries(result.workspaces.map((w) => MapEntry(w.id, w.seq)));
    _cleanupOf
      ..clear()
      ..addEntries(
        result.workspaces.map((w) => MapEntry(w.id, result.cleanupRevision)),
      );
    _listApplied = result.cleanupRevision;
    // A `cleanup/state` that arrived while the load was out may be newer.
    _latestStateRevision = max(_latestStateRevision, result.cleanupRevision);
    _listLoaded = true;
    _saver.raiseCounter(result.revision);

    final first = _layout == null;
    if (first) {
      final stored = result.layout;
      if (stored != null) {
        try {
          _layout = layoutFromJson(stored);
        } on LayoutInvalid catch (e) {
          _restoreNotice = 'The saved layout could not be restored: ${e.reason}';
        }
      } else if (result.restoreError != null) {
        _restoreNotice =
            'The saved layout could not be restored: ${result.restoreError}';
      }
      _layout ??= LayoutDocument.initial(_newId('g'));
    }
    _loading = false;
    final known = {for (final w in _workspaces) w.id};
    final repaired = _layout!.repairContexts(known);
    final repairedChanged = _encode(repaired) != _encode(_layout!);
    _layout = repaired;
    if (repairedChanged) {
      _saver.change(layoutToJson(repaired));
    } else if (!first) {
      // The in-memory layout survived a lost host: save it when it is dirty
      // or the new host stores an older one.
      if (_saver.dirty) {
        _saver.retry();
      } else if (result.revision < _saver.acknowledged) {
        _saver.change(layoutToJson(repaired));
      }
    }
    notifyListeners();
    if (_latestStateRevision > _listApplied) unawaited(_refreshList());
  }

  /// The host is gone: keep the layout, forget the link.
  void detach() {
    _generation++;
    _detachLink();
    _link = null;
    _loading = false;
    notifyListeners();
  }

  void _detachLink() {
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    _subscriptions.clear();
  }

  bool _stale(int generation) => _disposed || generation != _generation;

  void _failLoad(String reason) {
    _loading = false;
    _loadError = 'Could not load the workbench: $reason';
    notifyListeners();
  }

  Future<WorkbenchSaveResult> _save(Json layout, int revision) {
    final link = _link;
    if (link == null) {
      throw RpcException(ErrorCode.internalError, 'the host is gone');
    }
    return link.workbenchSave(layout, revision);
  }

  static String _encode(LayoutDocument d) => jsonEncode(layoutToJson(d));

  // --- layout operations --------------------------------------------------

  void _setLayout(LayoutDocument d) {
    _layout = d;
    _message = null;
    _saver.change(layoutToJson(d));
    notifyListeners();
  }

  bool _commit(LayoutResult r) {
    final d = r.document;
    if (d == null) {
      _message = switch (r.refusal!) {
        LayoutRefusal.groupLimit =>
          'Cannot split: the limit of $maxTabGroups tab groups is reached.',
        LayoutRefusal.tabLimit =>
          'Cannot open a view: the limit of $maxTabs tabs is reached.',
        LayoutRefusal.needsWorkspace =>
          'This view needs a workspace. Open a folder first.',
        LayoutRefusal.stateTooLarge => 'The view state is too large.',
        LayoutRefusal.unknownGroup ||
        LayoutRefusal.unknownTab ||
        LayoutRefusal.unknownSplit => 'That item is no longer there.',
      };
      notifyListeners();
      return false;
    }
    _setLayout(d);
    return true;
  }

  void split(String groupId, SplitDirection direction) {
    final d = _layout;
    if (d == null) return;
    _commit(d.split(groupId, direction, _newId('g'), _newId('s')));
  }

  void moveTab(String tabId, String toGroupId) {
    final d = _layout;
    if (d == null) return;
    _commit(d.moveTab(tabId, toGroupId));
  }

  void closeTab(String tabId) {
    final d = _layout;
    if (d == null) return;
    _commit(d.closeTab(tabId));
  }

  void activateTab(String tabId) {
    final d = _layout;
    if (d == null) return;
    _commit(d.activateTab(tabId));
  }

  void focusGroup(String groupId) {
    final d = _layout;
    if (d == null || d.focusedGroup == groupId) return;
    _commit(d.focusGroup(groupId));
  }

  void setRatio(String splitId, double ratio) {
    final d = _layout;
    if (d == null) return;
    _commit(d.setRatio(splitId, ratio));
  }

  void setSidebarCollapsed(bool collapsed) {
    final d = _layout;
    if (d == null || d.sidebarCollapsed == collapsed) return;
    _setLayout(d.setSidebarCollapsed(collapsed));
  }

  /// Opens a view of [kindId] in [groupId], bound to the group's context.
  void openView(String groupId, String kindId) {
    final d = _layout;
    final kind = viewKindOf(kindId);
    if (d == null || kind == null) return;
    final group = d.group(groupId);
    if (group == null) return;
    if (kind.needsWorkspace && _beingRemoved(group.context)) return;
    _commit(
      d.openOrFocus(
        groupId,
        kind.id,
        kind.needsWorkspace ? group.context : null,
        needsWorkspace: kind.needsWorkspace,
        newTabId: _newId('t'),
      ),
    );
  }

  /// Sidebar selection: focus the most recent tab bound to the workspace, or
  /// set the focused group's context.
  void selectWorkspace(String id) {
    final d = _layout;
    if (d == null || _beingRemoved(id)) return;
    _setLayout(d.selectWorkspace(id));
  }

  /// A remove of [id] is out: nothing new may bind to it until it answers,
  /// since the host decides from the layout it already stored.
  bool _beingRemoved(String? id) {
    if (id == null || !_removing.contains(id)) return false;
    _message = 'The workspace is being removed.';
    notifyListeners();
    return true;
  }

  void dismissMessage() {
    _message = null;
    notifyListeners();
  }

  void dismissRestoreNotice() {
    _restoreNotice = null;
    notifyListeners();
  }

  /// Retry of a failed layout save.
  void retrySave() => _saver.retry();

  /// Sends pending layout changes before the desktop quits.
  Future<void> flush() => _saver.flush();

  // --- workspaces ---------------------------------------------------------

  /// Open folder: the native picker, then `workspace/open`. [groupId], when
  /// given, is focused first so the folder becomes its context.
  Future<void> openFolder({String? groupId}) async {
    final link = _link;
    if (link == null || _layout == null) return;
    final generation = _generation;
    final String? path;
    try {
      path = await _picker.pickFolder();
    } on Exception catch (e) {
      if (_stale(generation)) return;
      final reason = e is PlatformException ? e.message ?? e.code : '$e';
      _message = 'Could not open the folder picker: $reason';
      notifyListeners();
      return;
    }
    if (path == null || _stale(generation)) return;
    try {
      final result = await link.workspaceOpen(path);
      if (_stale(generation)) return;
      _applyRecord(result.workspace, result.cleanupRevision, add: true);
      if (groupId != null) focusGroup(groupId);
      selectWorkspace(result.workspace.id);
    } on RpcException catch (e) {
      if (_stale(generation)) return;
      _message =
          'Could not open $path: ${e.message.isEmpty ? e.reason : e.message}';
      notifyListeners();
    } on ConnectionClosedException {
      if (_stale(generation)) return;
      _message = 'Could not open $path: the host is gone.';
      notifyListeners();
    }
  }

  /// Check again: `workspace/check`.
  Future<void> checkAgain(String id) async {
    final link = _link;
    if (link == null) return;
    final generation = _generation;
    try {
      final result = await link.workspaceCheck(id);
      if (_stale(generation)) return;
      _applyRecord(result.workspace, result.cleanupRevision);
      notifyListeners();
    } on RpcException catch (e) {
      if (_stale(generation)) return;
      _message =
          'Could not check the workspace: ${e.message.isEmpty ? e.reason : e.message}';
      notifyListeners();
    } on ConnectionClosedException {
      if (_stale(generation)) return;
      _message = 'Could not check the workspace: the host is gone.';
      notifyListeners();
    }
  }

  /// Whether tabs are bound to the workspace; Remove is disabled then.
  bool isBound(String id) => _layout?.boundWorkspaces.contains(id) ?? false;

  /// Remove (design D11): flush the layout, `workspace/remove`, then clear
  /// the context in memory and raise the revision counter.
  Future<void> removeWorkspace(String id) async {
    final link = _link;
    if (link == null || _layout == null || isBound(id)) return;
    if (!_removing.add(id)) return;
    final generation = _generation;
    try {
      await _saver.flush();
      if (_stale(generation)) return;
      final result = await link.workspaceRemove(id);
      if (_stale(generation)) return;
      _workspaces = [
        for (final w in _workspaces)
          if (w.id != id) w,
      ];
      _seq.remove(id);
      _cleanupOf.remove(id);
      _removed.add(id);
      _saver.raiseCounter(result.revision);
      _setLayout(_layout!.clearContext(id));
    } on RpcException catch (e) {
      if (_stale(generation)) return;
      _message = e.reason == ErrorCode.workspaceInUse
          ? 'The workspace is in use; close its tabs first.'
          : 'Could not remove the workspace: '
                '${e.message.isEmpty ? e.reason : e.message}';
      notifyListeners();
    } on ConnectionClosedException {
      if (_stale(generation)) return;
      _message = 'Could not remove the workspace: the host is gone.';
      notifyListeners();
    } finally {
      _removing.remove(id);
    }
  }

  /// The *cleanup unresolved* list limited to [workspaceId].
  CleanupController createCleanupController(String workspaceId) {
    final link = _link;
    if (link == null) throw StateError('no host');
    return CleanupController(link, workspace: workspaceId);
  }

  // --- applying records (design D5) ----------------------------------------

  /// Identity and availability apply only when [record]'s `seq` is above the
  /// last applied for its id and the id is listed ([add] lists a new one);
  /// the cleanup fields apply when [cleanupRevision] is not older than the
  /// last applied for that id. A one-workspace notification therefore never
  /// makes a whole list taken just before it stale for the others.
  void _applyRecord(
    WorkspaceRecord record,
    int cleanupRevision, {
    bool add = false,
  }) {
    final i = _workspaces.indexWhere((w) => w.id == record.id);
    if (i < 0) {
      if (!add || _removed.contains(record.id)) return;
      _workspaces = [..._workspaces, record];
      _seq[record.id] = record.seq;
      _cleanupOf[record.id] = cleanupRevision;
      return;
    }
    final current = _workspaces[i];
    final newer = record.seq > (_seq[record.id] ?? -1);
    final cleanupFresh = cleanupRevision >= (_cleanupOf[record.id] ?? -1);
    if (!newer && !cleanupFresh) return;
    final identity = newer ? record : current;
    final merged = WorkspaceRecord(
      id: current.id,
      path: identity.path,
      label: identity.label,
      identity: identity.identity,
      availability: identity.availability,
      reason: identity.reason,
      seq: identity.seq,
      cleanup: cleanupFresh ? record.cleanup : current.cleanup,
    );
    if (newer) _seq[record.id] = record.seq;
    if (cleanupFresh) _cleanupOf[record.id] = cleanupRevision;
    _workspaces = [..._workspaces]..[i] = merged;
  }

  void _onWorkspaceChanged(WorkspaceChanged e) {
    if (_disposed) return;
    _applyRecord(e.workspace, e.cleanupRevision);
    notifyListeners();
  }

  void _onCleanupState(CleanupState s) {
    if (_disposed) return;
    _reconciling = s.reconciling;
    if (s.revision > _latestStateRevision) _latestStateRevision = s.revision;
    notifyListeners();
    if (_listLoaded && s.revision > _listApplied) {
      unawaited(_refreshList());
    }
  }

  /// `workspace/list` again after a newer `cleanup/state` revision: one call
  /// at a time, extra revisions coalesce, results for older revisions drop.
  Future<void> _refreshList() async {
    if (_listing) return;
    _listing = true;
    final generation = _generation;
    try {
      while (_latestStateRevision > _listApplied &&
          _latestStateRevision > _listRequested) {
        _listRequested = _latestStateRevision;
        final link = _link;
        if (link == null) return;
        try {
          final result = await link.workspaceList();
          if (_stale(generation)) return;
          for (final w in result.workspaces) {
            _applyRecord(w, result.cleanupRevision, add: true);
          }
          _listApplied = max(_listApplied, result.cleanupRevision);
          notifyListeners();
        } on RpcException {
          // The next revision asks again.
        } on ConnectionClosedException {
          return;
        }
      }
    } finally {
      _listing = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _detachLink();
    _saver.removeListener(notifyListeners);
    _saver.dispose();
    super.dispose();
  }
}
