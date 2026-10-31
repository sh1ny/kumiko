import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:domain/domain.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show FocusManager;
import 'package:host_protocol/host_protocol.dart';

import 'cleanup_controller.dart';
import 'folder_picker.dart';
import 'host_link.dart';
import 'layout_saver.dart';
import 'terminal/terminal_controller.dart';
import 'terminal/terminal_surface.dart';

/// Why closing [pane] would lose running work, or null (design D9).
typedef WarnsOnClose = String? Function(
  WorkbenchController controller,
  PaneNode pane,
);

/// A view kind registered in the desktop (design D7).
class ViewKind {
  const ViewKind(
    this.id,
    this.label, {
    required this.needsWorkspace,
    this.warnsOnClose,
  });

  final String id;
  final String label;
  final bool needsWorkspace;

  /// Null when closing a pane of this kind never warns.
  final WarnsOnClose? warnsOnClose;
}

/// One pane a close would end running work in, and why.
typedef CloseWarning = ({String paneId, String title, String reason});

/// Asks the user to confirm a close that warns; true to go on.
typedef ConfirmClose = Future<bool> Function(List<CloseWarning> warnings);

/// What a Terminal launch did.
enum TerminalLaunchKind {
  opened,

  /// The host or the app cannot run terminals; [TerminalLaunch.message] says why.
  unavailable,

  /// The default profile is missing: the user picks one.
  chooseProfile,

  /// There is no profile at all: the user adds one.
  noProfile,

  /// The profile list could not be fetched.
  failed,
}

class TerminalLaunch {
  const TerminalLaunch(
    this.kind, {
    this.profiles = const [],
    this.missingDefault,
    this.message,
  });

  final TerminalLaunchKind kind;
  final List<ShellProfile> profiles;

  /// The name (or id) of the default profile that is no longer there.
  final String? missingDefault;
  final String? message;
}

const String workspaceOverviewKind = 'workspace-overview';

/// A terminal pane: `item` is a fresh UUID per launch, `state` is
/// `{profileId, profileName}` (design D8).
const String terminalKind = 'terminal';

String? _terminalWarnsOnClose(WorkbenchController c, PaneNode pane) =>
    c.terminals.warnsOnClose(pane.id);

/// The registered kinds. The Workspace overview is offered by the launcher
/// as it is; the terminal has entries of its own there.
const List<ViewKind> registeredViews = [
  ViewKind(workspaceOverviewKind, 'Workspace overview', needsWorkspace: true),
  ViewKind(
    terminalKind,
    'Terminal',
    needsWorkspace: false,
    warnsOnClose: _terminalWarnsOnClose,
  ),
];

/// The registered kinds the launcher offers as one plain entry each.
Iterable<ViewKind> get launcherViews =>
    registeredViews.where((k) => k.id != terminalKind);

ViewKind? viewKindOf(String id) {
  for (final k in registeredViews) {
    if (k.id == id) return k;
  }
  return null;
}

String _uuid() {
  final random = Random.secure();
  final bytes = [for (var i = 0; i < 16; i++) random.nextInt(256)];
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')];
  return '${hex.sublist(0, 4).join()}-${hex.sublist(4, 6).join()}-'
      '${hex.sublist(6, 8).join()}-${hex.sublist(8, 10).join()}-'
      '${hex.sublist(10).join()}';
}

String _randomId(String prefix) {
  final random = Random.secure();
  final bits = [
    for (var i = 0; i < 6; i++)
      random.nextInt(256).toRadixString(16).padLeft(2, '0'),
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
    TerminalSurfaceFactory? surfaceFactory,
  }) : _newId = newId ?? _randomId,
       _hasEngine = surfaceFactory != null {
    _saver = LayoutSaver(save: _save);
    _saver.addListener(notifyListeners);
    terminals = TerminalController(
      surfaceFactory: surfaceFactory ?? _noSurface,
      removePane: removePane,
    );
    terminals.addListener(notifyListeners);
    terminals.addListener(_onTerminals);
  }

  final bool _hasEngine;

  static TerminalSurface _noSurface({int scrollbackLimit = 0}) =>
      throw StateError('no terminal engine');

  /// The terminal panes' links.
  late final TerminalController terminals;

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
  ProfileListResult? _profiles;

  /// Names of every profile seen, to name a default that was removed.
  final Map<String, String> _profileNames = {};

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

  /// `workspace/changed` records that arrived while `workbench/load` was
  /// out: applied once its snapshot is installed, or a resolution published
  /// meanwhile would be lost under the snapshot. Null when not loading.
  List<WorkspaceChanged>? _heldChanges;

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
    terminals.attach(link);
    _profiles = null;
    _loadError = null;
    _loading = _layout == null;
    _listLoaded = false;
    _listRequested = 0;
    _latestStateRevision = 0;
    _heldChanges = [];
    _reconciling = link.hello.state == HostState.reconciling;
    _subscriptions
      ..add(link.cleanupStates.listen(_onCleanupState))
      ..add(link.workspaceChanges.listen(_onWorkspaceChanged));
    notifyListeners();
    if (terminalsUnavailableReason == null) unawaited(refreshProfiles());

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
    final held = _heldChanges ?? const [];
    _heldChanges = null;
    for (final e in held) {
      _applyRecord(e.workspace, e.cleanupRevision);
    }
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
          _restoreNotice =
              'The saved layout could not be restored: ${e.reason}';
        }
      } else if (result.restoreError != null) {
        _restoreNotice =
            'The saved layout could not be restored: ${result.restoreError}';
      }
      _layout ??= LayoutDocument.initial();
    }
    _loading = false;
    final known = {for (final w in _workspaces) w.id};
    final repaired = _layout!.repairSelection(known);
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
    _heldChanges = null;
    _detachLink();
    terminals.detach();
    _link = null;
    _profiles = null;
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
    _heldChanges = null;
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

  /// The pane whose view should take the keyboard focus once it is mounted.
  String? _keyboardTarget;
  bool _keyboardScheduled = false;

  void _onTerminals() {
    if (_keyboardTarget != null) _scheduleKeyboardFocus();
  }

  /// The keyboard follows the window's focused pane: [paneId]'s terminal view
  /// takes it after the frame that mounts or reveals the view.
  /// Whether the pending keyboard request came from a click in the pane,
  /// which leaves the keys with a control of the pane that took them.
  bool _keyboardUnlessInPane = false;

  void _wantKeyboard(String? paneId, {bool unlessInPane = false}) {
    _keyboardTarget = paneId;
    _keyboardUnlessInPane = unlessInPane;
    if (paneId != null) _scheduleKeyboardFocus();
  }

  void _scheduleKeyboardFocus() {
    if (_keyboardScheduled || _disposed) return;
    _keyboardScheduled = true;
    try {
      SchedulerBinding.instance
        ..addPostFrameCallback((_) {
          _keyboardScheduled = false;
          _applyKeyboardFocus();
        })
        ..ensureVisualUpdate();
    } on Object {
      _keyboardScheduled = false; // no binding: no view to focus
    }
  }

  void _applyKeyboardFocus() {
    final id = _keyboardTarget;
    if (id == null || _disposed) return;
    final pane = _layout?.pane(id);
    if (pane == null || _layout?.focusedPane != id) {
      _keyboardTarget = null;
      return;
    }
    if (pane.kind != terminalKind) {
      // A view without keyboard input: the previous terminal lets go.
      _keyboardTarget = null;
      FocusManager.instance.primaryFocus?.unfocus();
      return;
    }
    // No link yet: asked again when the terminal controller changes.
    final link = terminals.linkOf(id);
    if (link == null) return;
    _keyboardTarget = null;
    // A click that put the keys in a control of the pane, such as the
    // search field, leaves them there.
    if (_keyboardUnlessInPane && _keyboardInPane(id)) return;
    link.surface.requestFocus();
  }

  /// Whether the primary focus sits inside the view of pane [id].
  static bool _keyboardInPane(String id) {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    final paneKey = Key('pane-$id');
    var inside = false;
    context.visitAncestorElements((e) {
      if (e.widget.key == paneKey) inside = true;
      return !inside;
    });
    return inside;
  }

  void _setLayout(LayoutDocument d, {bool refocus = false}) {
    final focusedBefore = _layout?.focusedPane;
    _layout = d;
    _message = null;
    _saver.change(layoutToJson(d));
    terminals.sync({
      for (final p in d.panes)
        if (p.kind == terminalKind) p.id,
    });
    if (refocus || d.focusedPane != focusedBefore) {
      _wantKeyboard(d.focusedPane);
    }
    notifyListeners();
  }

  bool _commit(LayoutResult r, {bool refocus = false}) {
    final d = r.document;
    if (d == null) {
      _message = switch (r.refusal!) {
        LayoutRefusal.paneLimit =>
          'Cannot open another pane: the workbench holds at most $maxPanes '
              'panes.',
        LayoutRefusal.tabPaneLimit =>
          'Cannot add the pane: a tab holds at most $maxPanesPerTab panes.',
        LayoutRefusal.stateTooLarge => 'The view state is too large.',
        LayoutRefusal.nothingToMove => 'There is nothing to move.',
        LayoutRefusal.unknownTab ||
        LayoutRefusal.unknownPane ||
        LayoutRefusal.unknownSplit => 'That item is no longer there.',
      };
      notifyListeners();
      return false;
    }
    _setLayout(d, refocus: refocus);
    return true;
  }

  /// Every id in use in the layout.
  Set<String> _usedIds() {
    final used = <String>{};
    void walk(LayoutNode n) {
      used.add(n.id);
      if (n is SplitNode) {
        walk(n.first);
        walk(n.second);
      }
    }

    for (final t in _layout?.tabs ?? const <LayoutTabNode>[]) {
      used.add(t.id);
      walk(t.root);
    }
    return used;
  }

  /// A new id that no tab, pane or split of the layout has.
  String _fresh(String prefix) {
    final used = _usedIds();
    var id = _newId(prefix);
    while (used.contains(id)) {
      id = _newId(prefix);
    }
    return id;
  }

  void splitPane(String paneId, SplitDirection direction, PaneNode view) {
    final d = _layout;
    if (d == null) return;
    _commit(d.splitPane(paneId, direction, view, splitId: _fresh('s')));
  }

  /// Moves a pane into a new tab after its source. Nothing is sent to the
  /// host: the pane keeps its id, so its terminal link follows it.
  void movePaneToNewTab(String paneId) {
    final d = _layout;
    if (d == null) return;
    _commit(d.movePaneToNewTab(paneId, newTabId: _fresh('t')), refocus: true);
  }

  /// Whether tab [tabId] can be moved into a split of the active tab.
  bool canMoveIntoSplit(String tabId) {
    final d = _layout;
    return d != null &&
        d.tab(tabId) != null &&
        d.activeTab != null &&
        d.activeTab != tabId;
  }

  void moveTabIntoSplit(String tabId, SplitDirection direction) {
    final d = _layout;
    if (d == null) return;
    _commit(
      d.moveTabIntoSplit(tabId, direction, splitId: _fresh('s')),
      refocus: true,
    );
  }

  /// Removes one pane from the layout (an ended terminal, or the others of a
  /// confirmed close); a tab's last pane takes the tab with it.
  void removePane(String paneId) {
    final d = _layout;
    if (d == null || d.pane(paneId) == null) return;
    _commit(d.closePane(paneId));
  }

  /// Closes the panes in one layout change; unknown ids are skipped.
  void _closePanes(Iterable<String> paneIds) {
    var d = _layout;
    if (d == null) return;
    for (final id in paneIds) {
      if (d!.pane(id) == null) continue;
      if (d.closePane(id).document case final next?) d = next;
    }
    if (!identical(d, _layout)) _setLayout(d!);
  }

  /// Pane and tab close go through here: panes whose kind warns are named in
  /// one [confirm]ation first (design D9). Cancel changes nothing. On confirm
  /// every terminal is asked to close in parallel; the other panes go at once.
  Future<void> requestClose(List<String> paneIds, ConfirmClose confirm) async {
    final warnings = <CloseWarning>[];
    for (final id in paneIds) {
      final pane = _layout?.pane(id);
      if (pane == null) continue;
      final reason = viewKindOf(pane.kind)?.warnsOnClose?.call(this, pane);
      if (reason != null) {
        warnings.add((paneId: id, title: paneTitle(pane), reason: reason));
      }
    }
    if (warnings.isNotEmpty && !await confirm(warnings)) return;
    // The dialog may have been open for a while: look at the panes again.
    final plain = <String>[];
    final terminalCloses = <Future<void>>[];
    for (final id in paneIds) {
      final pane = _layout?.pane(id);
      if (pane == null) continue;
      if (pane.kind == terminalKind) {
        terminalCloses.add(terminals.closeConfirmed(id));
      } else {
        plain.add(id);
      }
    }
    _closePanes(plain);
    await Future.wait(terminalCloses);
  }

  /// The ids of every pane in tab [tabId].
  List<String> panesOfTab(String tabId) => [
    for (final p in _layout?.tab(tabId)?.panes ?? const <PaneNode>[]) p.id,
  ];

  /// The title a pane shows (and a close warning names).
  String paneTitle(PaneNode pane) {
    final kind = viewKindOf(pane.kind);
    if (kind == null) return 'Unsupported view';
    if (kind.id == terminalKind) {
      final name =
          terminals.linkOf(pane.id)?.profileName ?? pane.state['profileName'];
      return name is String ? '${kind.label} · $name' : kind.label;
    }
    final workspace = pane.workspace == null
        ? null
        : this.workspace(pane.workspace!);
    return workspace == null
        ? kind.label
        : '${kind.label} · ${workspace.label}';
  }

  /// A tab is titled by its focused pane.
  String tabTitle(LayoutTabNode tab) {
    final pane = tab.panes.where((p) => p.id == tab.focusedPane);
    return pane.isEmpty ? 'Tab' : paneTitle(pane.first);
  }

  // --- terminals ----------------------------------------------------------

  /// Why a terminal cannot be started now, or null.
  String? get terminalsUnavailableReason {
    final hello = _link?.hello;
    if (hello == null) return 'the host is not connected';
    if (!hello.capabilities.contains(Capability.terminal)) {
      return 'the host does not support terminals';
    }
    if (!_hasEngine) return 'the terminal engine did not load';
    return null;
  }

  /// The profiles as the host last listed them, or null before the first
  /// answer.
  ProfileListResult? get profiles => _profiles;

  void _setProfiles(ProfileListResult list) {
    _profiles = list;
    for (final p in list.profiles) {
      _profileNames[p.id] = p.name;
    }
    notifyListeners();
  }

  String profileNameOf(String id) => _profileNames[id] ?? id;

  /// `profile/list`, remembered. Null when the host does not answer.
  Future<ProfileListResult?> refreshProfiles() async {
    final link = _link;
    if (link == null || terminalsUnavailableReason != null) return null;
    final generation = _generation;
    try {
      final list = await link.profileList();
      if (_stale(generation)) return null;
      _setProfiles(list);
      return list;
    } on RpcException {
      return null;
    } on ConnectionClosedException {
      return null;
    }
  }

  /// A fresh id for a profile the user adds.
  String newProfileId() => _newId('profile');

  /// The link for a profile call. Without a host the call fails as on a
  /// closed connection, which the profile dialog reports.
  HostLink _profileLink() =>
      _link ??
      (throw ConnectionClosedException(
        const CloseReason(CloseReason.closedLocally, 'no host is connected'),
      ));

  /// Saves a user profile; throws what the host refuses with.
  Future<ShellProfile> saveProfile(ShellProfile profile) async {
    final saved = await _profileLink().saveProfile(profile);
    await refreshProfiles();
    return saved;
  }

  Future<void> removeProfile(String id) async {
    await _profileLink().removeProfile(id);
    await refreshProfiles();
  }

  Future<void> setDefaultProfile(String id) async {
    await _profileLink().setDefaultProfile(id);
    await refreshProfiles();
  }

  /// The launcher's Terminal entry: opens a new tab holding a terminal pane
  /// with the default profile, or with [profileId], bound to the sidebar
  /// selection. [choose] asks for the list instead, for the profile picker.
  /// Nothing starts without a usable profile, and none is substituted.
  Future<TerminalLaunch> launchTerminal({
    String? profileId,
    bool choose = false,
  }) => _launch(profileId: profileId, choose: choose);

  /// A pane header's split: a terminal beside or below [paneId], bound to
  /// that pane's workspace; the pane itself is untouched. With a host that
  /// refuses the open, the new pane stays with the reason and **Start shell**.
  Future<TerminalLaunch> splitWithTerminal(
    String paneId,
    SplitDirection direction, {
    String? profileId,
    bool choose = false,
  }) => _launch(
    profileId: profileId,
    choose: choose,
    splitOf: paneId,
    direction: direction,
  );

  Future<TerminalLaunch> _launch({
    String? profileId,
    bool choose = false,
    String? splitOf,
    SplitDirection direction = SplitDirection.horizontal,
  }) async {
    final reason = terminalsUnavailableReason;
    final link = _link;
    if (reason != null || link == null || _layout == null) {
      final message = reason == null
          ? 'There is no workbench yet.'
          : 'A terminal cannot be started: $reason.';
      _message = message;
      notifyListeners();
      return TerminalLaunch(TerminalLaunchKind.unavailable, message: message);
    }
    if (splitOf != null && _layout!.pane(splitOf) == null) {
      return const TerminalLaunch(
        TerminalLaunchKind.failed,
        message: 'That item is no longer there.',
      );
    }
    final generation = _generation;
    final ProfileListResult list;
    try {
      list = await link.profileList();
    } on RpcException catch (e) {
      return _launchFailed(e.message.isEmpty ? e.reason : e.message);
    } on ConnectionClosedException {
      return _launchFailed('the host is gone');
    }
    if (_stale(generation)) {
      return const TerminalLaunch(TerminalLaunchKind.failed);
    }
    _setProfiles(list);
    if (list.profiles.isEmpty) {
      return const TerminalLaunch(TerminalLaunchKind.noProfile);
    }
    final wanted = profileId ?? (list.defaultAvailable ? list.defaultId : null);
    ShellProfile? profile;
    for (final p in list.profiles) {
      if (p.id == wanted) profile = p;
    }
    if (choose || profile == null) {
      return TerminalLaunch(
        TerminalLaunchKind.chooseProfile,
        profiles: list.profiles,
        missingDefault: choose || profileId != null || list.defaultId == null
            ? null
            : profileNameOf(list.defaultId!),
      );
    }
    final d = _layout;
    if (d == null) {
      return const TerminalLaunch(
        TerminalLaunchKind.failed,
        message: 'That item is no longer there.',
      );
    }
    final String? workspaceId;
    if (splitOf != null) {
      final pane = d.pane(splitOf);
      if (pane == null) {
        return const TerminalLaunch(
          TerminalLaunchKind.failed,
          message: 'That item is no longer there.',
        );
      }
      workspaceId = pane.workspace;
    } else {
      workspaceId = d.selectedWorkspace;
    }
    if (_beingRemoved(workspaceId)) {
      return TerminalLaunch(TerminalLaunchKind.failed, message: _message);
    }
    final view = PaneNode(
      id: _fresh('p'),
      kind: terminalKind,
      workspace: workspaceId,
      item: _uuid(),
      state: {'profileId': profile.id, 'profileName': profile.name},
    );
    final result = splitOf == null
        ? d.openTab(view, tabId: _fresh('t'))
        : d.splitPane(splitOf, direction, view, splitId: _fresh('s'));
    if (!_commit(result)) {
      return TerminalLaunch(TerminalLaunchKind.failed, message: _message);
    }
    unawaited(
      terminals.start(
        view.id,
        profileId: profile.id,
        profileName: profile.name,
        workspaceId: view.workspace,
      ),
    );
    return const TerminalLaunch(TerminalLaunchKind.opened);
  }

  TerminalLaunch _launchFailed(String reason) {
    final message = 'Could not list the shell profiles: $reason';
    _message = message;
    notifyListeners();
    return TerminalLaunch(TerminalLaunchKind.failed, message: message);
  }

  /// **Start shell** in a restored or ended terminal pane, with [profileId]
  /// (the pane's own, or the default the pane offered because its profile is
  /// gone). The host's current list decides whether it still exists.
  Future<void> startShell(String paneId, String profileId) async {
    final pane = _layout?.pane(paneId);
    if (pane == null || terminalsUnavailableReason != null) return;
    final list = await refreshProfiles();
    if (list == null || _layout?.pane(paneId) == null) return;
    ShellProfile? profile;
    for (final p in list.profiles) {
      if (p.id == profileId) profile = p;
    }
    if (profile == null) {
      _message = 'The profile is no longer available.';
      notifyListeners();
      return;
    }
    // A replacement (the offered default) is what the pane restores next.
    final current = _layout?.pane(paneId);
    if (current != null &&
        (current.state['profileId'] != profile.id ||
            current.state['profileName'] != profile.name)) {
      final state = {
        ...current.state,
        'profileId': profile.id,
        'profileName': profile.name,
      };
      if (!_commit(_layout!.setPaneState(paneId, state))) return;
    }
    await terminals.start(
      paneId,
      profileId: profile.id,
      profileName: profile.name,
      workspaceId: pane.workspace,
    );
  }

  void activateTab(String tabId) {
    final d = _layout;
    if (d == null || d.activeTab == tabId) return;
    _commit(d.activateTab(tabId));
  }

  void focusPane(String paneId) {
    final d = _layout;
    if (d == null) return;
    if (d.focusedPane == paneId) {
      // Clicked while the keys went elsewhere.
      _wantKeyboard(paneId, unlessInPane: true);
      return;
    }
    if (_commit(d.focusPane(paneId))) _keyboardUnlessInPane = true;
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

  /// Opens a view of [kindId] in a new tab, bound to the sidebar selection;
  /// an open item is focused where it is instead.
  void openView(String kindId) {
    final d = _layout;
    final kind = viewKindOf(kindId);
    if (d == null || kind == null) return;
    final selected = d.selectedWorkspace;
    if (kind.needsWorkspace && selected == null) {
      _message = 'This view needs a workspace. Open a folder first.';
      notifyListeners();
      return;
    }
    if (kind.needsWorkspace && _beingRemoved(selected)) return;
    _commit(
      d.openOrFocus(
        PaneNode(
          id: _fresh('p'),
          kind: kind.id,
          workspace: kind.needsWorkspace ? selected : null,
          item: kind.needsWorkspace ? selected : null,
          state: const {},
        ),
        tabId: _fresh('t'),
      ),
    );
  }

  /// Sidebar selection: sets the selection and focuses the most recent pane
  /// bound to the workspace. No binding changes.
  void selectWorkspace(String id) {
    final d = _layout;
    if (d == null || _beingRemoved(id)) return;
    _setLayout(d.selectWorkspace(id));
  }

  /// Sidebar Personal: no workspace selected. No binding changes.
  void selectPersonal() {
    final d = _layout;
    if (d == null || d.selectedWorkspace == null) return;
    _setLayout(d.copyWith(selectedWorkspace: null));
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

  /// Open folder: the native picker, then `workspace/open`; the folder
  /// becomes the sidebar selection.
  Future<void> openFolder() async {
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

  /// Whether panes are bound to the workspace; Remove is disabled then.
  bool isBound(String id) => _layout?.boundWorkspaces.contains(id) ?? false;

  /// Remove (design D11): flush the layout, `workspace/remove`, then clear
  /// the selection in memory and raise the revision counter.
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
      _setLayout(_layout!.clearSelection(id));
    } on RpcException catch (e) {
      if (_stale(generation)) return;
      _message = e.reason == ErrorCode.workspaceInUse
          ? 'The workspace is in use; close its panes first.'
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
    if (_heldChanges case final held?) {
      held.add(e);
      return;
    }
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
    terminals.removeListener(notifyListeners);
    terminals.removeListener(_onTerminals);
    terminals.dispose();
    _saver.removeListener(notifyListeners);
    _saver.dispose();
    super.dispose();
  }
}
