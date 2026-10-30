/// Pure operations on the working-set document (design D11).
///
/// Callers supply every new id and the new view; nothing here is random. No
/// operation ever writes a pane's `workspace` binding, and none looks at a
/// pane's `kind`.
library;

import 'dart:convert';

import 'bounds.dart';
import 'model.dart';

/// Why an operation changed nothing.
enum LayoutRefusal {
  /// The document already holds the maximum number of panes.
  paneLimit,

  /// The tab already holds, or the move would give it, too many panes.
  tabPaneLimit,
  stateTooLarge,
  unknownTab,
  unknownPane,
  unknownSplit,

  /// A tab's only pane, or the active tab, cannot be moved.
  nothingToMove,
}

/// Either the new document or a refusal (document unchanged).
final class LayoutResult {
  const LayoutResult.ok(LayoutDocument this.document, {this.tabId, this.paneId})
    : refusal = null;
  const LayoutResult.refused(LayoutRefusal this.refusal)
    : document = null,
      tabId = null,
      paneId = null;

  final LayoutDocument? document;
  final LayoutRefusal? refusal;

  /// The tab opened, focused or moved, when the operation involved one.
  final String? tabId;

  /// The pane opened, focused or moved, when the operation involved one.
  final String? paneId;

  bool get isOk => document != null;
}

/// Replaces the node [id] by [replacement] in the tree.
LayoutNode _replaceNode(LayoutNode n, String id, LayoutNode replacement) {
  if (n.id == id) return replacement;
  return switch (n) {
    PaneNode() => n,
    SplitNode() => n.withChildren(
      _replaceNode(n.first, id, replacement),
      _replaceNode(n.second, id, replacement),
    ),
  };
}

/// The tree without the pane [paneId], whose sibling takes its parent's place,
/// and that sibling's first pane in tree order. The tree must hold at least
/// two panes.
({LayoutNode root, String sibling}) _removePane(LayoutNode n, String paneId) {
  switch (n) {
    case PaneNode():
      throw StateError('a lone pane has no sibling');
    case SplitNode():
      if (n.first.id == paneId) {
        return (root: n.second, sibling: n.second.panes.first.id);
      }
      if (n.second.id == paneId) {
        return (root: n.first, sibling: n.first.panes.first.id);
      }
      if (n.first.panes.any((p) => p.id == paneId)) {
        final r = _removePane(n.first, paneId);
        return (root: n.withChildren(r.root, n.second), sibling: r.sibling);
      }
      final r = _removePane(n.second, paneId);
      return (root: n.withChildren(n.first, r.root), sibling: r.sibling);
  }
}

List<String> _toFront(List<String> recent, String paneId) => [
  paneId,
  for (final id in recent)
    if (id != paneId) id,
];

List<String> _prune(List<String> recent, Set<String> removed) => [
  for (final id in recent)
    if (!removed.contains(id)) id,
];

List<LayoutTabNode> _replaceTab(
  List<LayoutTabNode> tabs,
  LayoutTabNode replacement,
) => [for (final t in tabs) t.id == replacement.id ? replacement : t];

bool _stateTooLarge(PaneNode view) =>
    utf8.encode(jsonEncode(view.state)).length > maxTabStateBytes;

/// Focuses [paneId] in its tab, activates the tab and fronts the pane in
/// `recent`.
LayoutDocument _focus(LayoutDocument d, String paneId) {
  final tab = d.tabOf(paneId)!;
  return d.copyWith(
    tabs: _replaceTab(d.tabs, tab.withFocus(paneId)),
    activeTab: tab.id,
    recent: _toFront(d.recent, paneId),
  );
}

/// Removes the tab at [index]; the active tab moves right, else left.
LayoutDocument _removeTab(LayoutDocument d, int index) {
  final removed = d.tabs[index];
  final tabs = [...d.tabs]..removeAt(index);
  var recent = _prune(d.recent, {for (final p in removed.panes) p.id});
  var active = d.activeTab;
  if (removed.id == d.activeTab) {
    final next = index < tabs.length
        ? tabs[index]
        : (index > 0 ? tabs[index - 1] : null);
    active = next?.id;
    if (next != null) recent = _toFront(recent, next.focusedPane);
  }
  return d.copyWith(tabs: tabs, activeTab: active, recent: recent);
}

/// Operations on [LayoutDocument].
extension LayoutOperations on LayoutDocument {
  /// Appends a one-pane tab holding [view] and activates it.
  LayoutResult openTab(PaneNode view, {required String tabId}) {
    if (paneCount >= maxPanes) {
      return const LayoutResult.refused(LayoutRefusal.paneLimit);
    }
    if (_stateTooLarge(view)) {
      return const LayoutResult.refused(LayoutRefusal.stateTooLarge);
    }
    final tab = LayoutTabNode(id: tabId, root: view, focusedPane: view.id);
    return LayoutResult.ok(
      copyWith(
        tabs: [...tabs, tab],
        activeTab: tabId,
        recent: _toFront(recent, view.id),
      ),
      tabId: tabId,
      paneId: view.id,
    );
  }

  /// Focuses the pane with the same `kind` and `item` as [view] wherever it
  /// is, activating its tab; otherwise opens a tab as [openTab] does. A null
  /// item never matches.
  LayoutResult openOrFocus(PaneNode view, {required String tabId}) {
    if (view.item != null) {
      for (final p in panes) {
        if (p.kind == view.kind && p.item == view.item) {
          return LayoutResult.ok(
            _focus(this, p.id),
            tabId: tabOf(p.id)!.id,
            paneId: p.id,
          );
        }
      }
    }
    return openTab(view, tabId: tabId);
  }

  /// Replaces [paneId] with a split of ratio 0.5: the old pane first, [view]
  /// second and focused.
  LayoutResult splitPane(
    String paneId,
    SplitDirection direction,
    PaneNode view, {
    required String splitId,
  }) {
    final tab = tabOf(paneId);
    if (tab == null) {
      return const LayoutResult.refused(LayoutRefusal.unknownPane);
    }
    if (tab.paneCount >= maxPanesPerTab) {
      return const LayoutResult.refused(LayoutRefusal.tabPaneLimit);
    }
    if (paneCount >= maxPanes) {
      return const LayoutResult.refused(LayoutRefusal.paneLimit);
    }
    if (_stateTooLarge(view)) {
      return const LayoutResult.refused(LayoutRefusal.stateTooLarge);
    }
    final old = pane(paneId)!;
    final node = SplitNode(
      id: splitId,
      direction: direction,
      ratio: 0.5,
      first: old,
      second: view,
    );
    final updated = tab.withRoot(_replaceNode(tab.root, paneId, node), view.id);
    return LayoutResult.ok(
      copyWith(
        tabs: _replaceTab(tabs, updated),
        activeTab: tab.id,
        recent: _toFront(recent, view.id),
      ),
      tabId: tab.id,
      paneId: view.id,
    );
  }

  /// Closes a pane; its sibling takes its place. A tab's last pane closes the
  /// tab.
  LayoutResult closePane(String paneId) {
    final tab = tabOf(paneId);
    if (tab == null) {
      return const LayoutResult.refused(LayoutRefusal.unknownPane);
    }
    if (tab.paneCount == 1) return closeTab(tab.id);
    final removal = _removePane(tab.root, paneId);
    final wasFocused = tab.focusedPane == paneId;
    final focused = wasFocused ? removal.sibling : tab.focusedPane;
    var newRecent = _prune(recent, {paneId});
    if (wasFocused && tab.id == activeTab) {
      newRecent = _toFront(newRecent, focused);
    }
    return LayoutResult.ok(
      copyWith(
        tabs: _replaceTab(tabs, tab.withRoot(removal.root, focused)),
        recent: newRecent,
      ),
      tabId: tab.id,
    );
  }

  /// Closes a tab and all its panes. Closing the active tab activates the
  /// tab to its right, else to its left, else none.
  LayoutResult closeTab(String tabId) {
    final index = tabs.indexWhere((t) => t.id == tabId);
    if (index < 0) {
      return const LayoutResult.refused(LayoutRefusal.unknownTab);
    }
    final after = _removeTab(this, index);
    return LayoutResult.ok(after, tabId: after.activeTab);
  }

  /// Moves a pane into a new tab right after its source tab.
  LayoutResult movePaneToNewTab(String paneId, {required String newTabId}) {
    final source = tabOf(paneId);
    if (source == null) {
      return const LayoutResult.refused(LayoutRefusal.unknownPane);
    }
    if (source.paneCount == 1) {
      return const LayoutResult.refused(LayoutRefusal.nothingToMove);
    }
    final moved = pane(paneId)!;
    final removal = _removePane(source.root, paneId);
    final focus = source.focusedPane == paneId
        ? removal.sibling
        : source.focusedPane;
    final fresh = LayoutTabNode(id: newTabId, root: moved, focusedPane: paneId);
    final strip = <LayoutTabNode>[];
    for (final t in tabs) {
      if (t.id == source.id) {
        strip
          ..add(t.withRoot(removal.root, focus))
          ..add(fresh);
      } else {
        strip.add(t);
      }
    }
    return LayoutResult.ok(
      copyWith(
        tabs: strip,
        activeTab: newTabId,
        recent: _toFront(recent, paneId),
      ),
      tabId: newTabId,
      paneId: paneId,
    );
  }

  /// Moves a tab into a split of the active tab: the active root first, the
  /// moved root second. The moved tab leaves the strip and its focused pane
  /// is focused.
  LayoutResult moveTabIntoSplit(
    String tabId,
    SplitDirection direction, {
    required String splitId,
  }) {
    final moved = tab(tabId);
    if (moved == null) {
      return const LayoutResult.refused(LayoutRefusal.unknownTab);
    }
    final target = active;
    if (target == null || target.id == tabId) {
      return const LayoutResult.refused(LayoutRefusal.nothingToMove);
    }
    if (target.paneCount + moved.paneCount > maxPanesPerTab) {
      return const LayoutResult.refused(LayoutRefusal.tabPaneLimit);
    }
    final node = SplitNode(
      id: splitId,
      direction: direction,
      ratio: 0.5,
      first: target.root,
      second: moved.root,
    );
    final merged = target.withRoot(node, moved.focusedPane);
    return LayoutResult.ok(
      copyWith(
        tabs: [
          for (final t in tabs)
            if (t.id == target.id) merged else if (t.id != tabId) t,
        ],
        recent: _toFront(recent, moved.focusedPane),
      ),
      tabId: target.id,
      paneId: moved.focusedPane,
    );
  }

  /// Makes a tab active; its own focused pane is the window's.
  LayoutResult activateTab(String tabId) {
    final t = tab(tabId);
    if (t == null) return const LayoutResult.refused(LayoutRefusal.unknownTab);
    return LayoutResult.ok(
      copyWith(activeTab: tabId, recent: _toFront(recent, t.focusedPane)),
      tabId: tabId,
      paneId: t.focusedPane,
    );
  }

  /// Focuses a pane, activating its tab.
  LayoutResult focusPane(String paneId) {
    final t = tabOf(paneId);
    if (t == null) {
      return const LayoutResult.refused(LayoutRefusal.unknownPane);
    }
    return LayoutResult.ok(_focus(this, paneId), tabId: t.id, paneId: paneId);
  }

  /// Sets a split's ratio, clamped to the allowed range. `recent` is
  /// unchanged.
  LayoutResult setRatio(String splitId, double ratio) {
    if (splitNode(splitId) == null) {
      return const LayoutResult.refused(LayoutRefusal.unknownSplit);
    }
    final clamped = ratio.clamp(minSplitRatio, maxSplitRatio).toDouble();
    LayoutNode walk(LayoutNode n) => switch (n) {
      PaneNode() => n,
      SplitNode() =>
        n.id == splitId
            ? n.withRatio(clamped)
            : n.withChildren(walk(n.first), walk(n.second)),
    };
    return LayoutResult.ok(
      copyWith(
        tabs: [for (final t in tabs) t.withRoot(walk(t.root), t.focusedPane)],
      ),
    );
  }

  /// Sidebar selection: sets the selection and focuses the workspace's first
  /// pane in `recent`, else in strip and tree order; focus is unchanged when
  /// it has no pane. No binding changes.
  LayoutDocument selectWorkspace(String workspaceId) {
    final selected = copyWith(selectedWorkspace: workspaceId);
    for (final id in recent) {
      if (pane(id)?.workspace == workspaceId) return _focus(selected, id);
    }
    for (final p in panes) {
      if (p.workspace == workspaceId) return _focus(selected, p.id);
    }
    return selected;
  }

  LayoutDocument setSidebarCollapsed(bool collapsed) =>
      copyWith(sidebarCollapsed: collapsed);

  /// Nulls the selection when it names [workspaceId].
  LayoutDocument clearSelection(String workspaceId) =>
      selectedWorkspace == workspaceId
      ? copyWith(selectedWorkspace: null)
      : this;

  /// Nulls the selection when it is not in [known] (load repair).
  LayoutDocument repairSelection(Set<String> known) =>
      selectedWorkspace != null && !known.contains(selectedWorkspace)
      ? copyWith(selectedWorkspace: null)
      : this;
}
