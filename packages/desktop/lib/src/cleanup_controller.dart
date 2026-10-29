import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:host_protocol/host_protocol.dart';

import 'host_link.dart';

/// The paged *cleanup unresolved* list (design D5): the constant-size
/// `cleanup/state` gives counts and the revision, `cleanup/list` pages give
/// the workspaces. A new revision, or a page flagged stale, reloads from the
/// first page.
class CleanupController extends ChangeNotifier {
  CleanupController(this._link) {
    _reconciling = _link.hello.state == HostState.reconciling;
    _subscription = _link.cleanupStates.listen(_onState);
    if (!_reconciling) unawaited(reload());
  }

  final HostLink _link;
  late final StreamSubscription<CleanupState> _subscription;
  bool _disposed = false;

  bool _reconciling = false;
  CleanupState? _state;
  List<CleanupWorkspace> _workspaces = const [];
  String? _nextCursor;
  int? _loadedRevision;
  bool _loaded = false;
  bool _loading = false;
  int _loadToken = 0;
  String? _actionMessage;
  String? _loadMessage;
  final Set<String> _busy = {};

  /// Reconciliation has not finished: the host refuses launches.
  bool get reconciling => _reconciling;
  CleanupState? get state => _state;
  List<CleanupWorkspace> get workspaces => _workspaces;
  bool get hasMore => _nextCursor != null;
  bool get loaded => _loaded;
  bool get loading => _loading;

  /// The last action or load problem, for the user.
  String? get message => _actionMessage ?? _loadMessage;

  int get unresolvedWorkspaces =>
      _state?.unresolvedWorkspaces ?? _workspaces.length;
  int get unresolvedUnits =>
      _state?.unresolvedUnits ?? _workspaces.fold(0, (n, w) => n + w.unitCount);

  bool isBusy(String workspace) => _busy.contains(workspace);

  void _onState(CleanupState s) {
    if (_disposed) return;
    _state = s;
    _reconciling = s.reconciling;
    notifyListeners();
    if (!s.reconciling && (!_loaded || s.revision != _loadedRevision)) {
      unawaited(reload());
    }
  }

  /// Loads the first page again.
  Future<void> reload() => _load(first: true);

  /// Loads the next page.
  Future<void> loadMore() => _load(first: false);

  Future<void> _load({required bool first}) async {
    final cursor = first ? null : _nextCursor;
    if (!first && cursor == null) return;
    final token = ++_loadToken;
    _loading = true;
    notifyListeners();
    try {
      final result = await _link.cleanupList(
        cursor: cursor,
        revision: first ? null : _loadedRevision,
      );
      if (_disposed || token != _loadToken) return;
      if (result.stale && !first) {
        _loading = false;
        await reload();
        return;
      }
      _workspaces = first
          ? result.workspaces
          : [..._workspaces, ...result.workspaces];
      _nextCursor = result.nextCursor;
      _loadedRevision = result.revision;
      _loaded = true;
      _loadMessage = null;
    } on RpcException catch (e) {
      if (_disposed || token != _loadToken) return;
      _loadMessage = 'Could not load the cleanup list: ${e.message}';
    } on ConnectionClosedException {
      if (_disposed || token != _loadToken) return;
      _loadMessage = 'Could not load the cleanup list: the host is gone.';
    }
    _loading = false;
    notifyListeners();
  }

  Future<void> retry(String workspace) => _act(workspace, retry: true);

  Future<void> confirm(String workspace) => _act(workspace, retry: false);

  Future<void> _act(String workspace, {required bool retry}) async {
    if (!_busy.add(workspace)) return;
    _actionMessage = null;
    notifyListeners();
    try {
      final result = retry
          ? await _link.cleanupRetry(workspace)
          : await _link.cleanupConfirm(workspace);
      if (_disposed) return;
      if (retry && result.unresolvedUnits > 0) {
        final n = result.unresolvedUnits;
        final verb = n == 1 ? 'unit is' : 'units are';
        _actionMessage =
            '$n $verb still unresolved after the retry; the workspace stays '
            'blocked.';
      }
    } on RpcException catch (e) {
      if (_disposed) return;
      _actionMessage = e.reason == ErrorCode.retryInProgress
          ? 'A retry is still running for this workspace. Try again when it '
                'ends.'
          : '${retry ? 'Retry' : 'Confirm'} failed: ${e.message}';
    } on ConnectionClosedException {
      if (_disposed) return;
      _actionMessage = 'The host is gone.';
    }
    if (_disposed) return;
    _busy.remove(workspace);
    notifyListeners();
    await reload();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
