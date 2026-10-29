/// Pure operations on the working-set document (design D2, D8, D11).
///
/// Callers supply every new id; nothing here is random. No operation ever
/// writes a tab's `workspace` binding.
library;

import 'dart:convert';

import 'bounds.dart';
import 'model.dart';

/// Why an operation changed nothing.
enum LayoutRefusal {
  groupLimit,
  tabLimit,
  needsWorkspace,
  stateTooLarge,
  unknownGroup,
  unknownTab,
  unknownSplit,
}

/// Either the new document or a refusal (document unchanged).
final class LayoutResult {
  const LayoutResult.ok(LayoutDocument this.document, {this.tabId})
    : refusal = null;
  const LayoutResult.refused(LayoutRefusal this.refusal)
    : document = null,
      tabId = null;

  final LayoutDocument? document;
  final LayoutRefusal? refusal;

  /// The tab opened or focused, when the operation involved one.
  final String? tabId;

  bool get isOk => document != null;
}

LayoutNode _mapGroups(LayoutNode n, TabGroup Function(TabGroup) f) =>
    switch (n) {
      TabGroup() => f(n),
      SplitNode() => n.withChildren(
        _mapGroups(n.first, f),
        _mapGroups(n.second, f),
      ),
    };

/// Replaces the group [id] by [replacement] in the tree.
LayoutNode _replaceGroup(LayoutNode n, String id, LayoutNode replacement) =>
    switch (n) {
      TabGroup() => n.id == id ? replacement : n,
      SplitNode() => n.withChildren(
        _replaceGroup(n.first, id, replacement),
        _replaceGroup(n.second, id, replacement),
      ),
    };

/// Removes the group [id]; its sibling takes the place of the split.
LayoutNode? _removeGroup(LayoutNode n, String id) {
  switch (n) {
    case TabGroup():
      return n.id == id ? null : n;
    case SplitNode():
      final a = _removeGroup(n.first, id);
      final b = _removeGroup(n.second, id);
      if (a == null) return b;
      if (b == null) return a;
      return n.withChildren(a, b);
  }
}

/// Removes the tab from its group, picking the group's next active tab and
/// dropping the group when it empties and is not the only one. Leaves
/// `recent` and focus to the caller.
LayoutNode _detach(LayoutDocument d, String tabId) {
  final g = d.groupOf(tabId)!;
  final remaining = [
    for (final t in g.tabs)
      if (t.id != tabId) t,
  ];
  if (remaining.isEmpty && d.groupCount > 1) {
    return _removeGroup(d.root, g.id)!;
  }
  String? active = g.active;
  if (g.active == tabId) {
    if (remaining.isEmpty) {
      active = null;
    } else {
      final ids = {for (final t in remaining) t.id};
      active = d.recent.firstWhere(
        (id) => id != tabId && ids.contains(id),
        orElse: () {
          final i = g.tabs.indexWhere((t) => t.id == tabId);
          return remaining[i < remaining.length ? i : remaining.length - 1].id;
        },
      );
    }
  }
  var updated = g.withTabs(remaining, active);
  // The next active tab sets the context, as activating it would (D8).
  if (active != null && active != g.active) {
    final ws = remaining.firstWhere((t) => t.id == active).workspace;
    if (ws != null) updated = updated.withContext(ws);
  }
  return _replaceGroup(d.root, g.id, updated);
}

List<String> _toFront(List<String> recent, String tabId) => [
  tabId,
  for (final id in recent)
    if (id != tabId) id,
];

LayoutDocument _activate(LayoutDocument d, String tabId) {
  final g = d.groupOf(tabId)!;
  final t = d.tab(tabId)!;
  var updated = g.withTabs(g.tabs, tabId);
  if (t.workspace != null) updated = updated.withContext(t.workspace);
  return d.copyWith(
    root: _replaceGroup(d.root, g.id, updated),
    focusedGroup: g.id,
    recent: _toFront(d.recent, tabId),
  );
}

/// Operations on [LayoutDocument].
extension LayoutOperations on LayoutDocument {
  /// Splits [groupId]: a new empty group with the same context is placed
  /// beside it and becomes focused.
  LayoutResult split(
    String groupId,
    SplitDirection direction,
    String newGroupId,
    String newSplitId,
  ) {
    final g = group(groupId);
    if (g == null) return const LayoutResult.refused(LayoutRefusal.unknownGroup);
    if (groupCount >= maxTabGroups) {
      return const LayoutResult.refused(LayoutRefusal.groupLimit);
    }
    final fresh = TabGroup(
      id: newGroupId,
      context: g.context,
      tabs: const [],
      active: null,
    );
    final node = SplitNode(
      id: newSplitId,
      direction: direction,
      ratio: 0.5,
      first: g,
      second: fresh,
    );
    return LayoutResult.ok(
      copyWith(
        root: _replaceGroup(root, groupId, node),
        focusedGroup: newGroupId,
      ),
    );
  }

  /// Moves a tab to [toGroupId], active there; the source group is dropped
  /// if it empties.
  LayoutResult moveTab(String tabId, String toGroupId) {
    final source = groupOf(tabId);
    if (source == null) {
      return const LayoutResult.refused(LayoutRefusal.unknownTab);
    }
    if (group(toGroupId) == null) {
      return const LayoutResult.refused(LayoutRefusal.unknownGroup);
    }
    final t = tab(tabId)!;
    if (source.id == toGroupId) {
      return LayoutResult.ok(_activate(this, tabId), tabId: tabId);
    }
    final detached = copyWith(root: _detach(this, tabId));
    final dest = detached.group(toGroupId)!;
    var updated = dest.withTabs([...dest.tabs, t], tabId);
    if (t.workspace != null) updated = updated.withContext(t.workspace);
    return LayoutResult.ok(
      copyWith(
        root: _replaceGroup(detached.root, toGroupId, updated),
        focusedGroup: toGroupId,
        recent: _toFront(recent, tabId),
      ),
      tabId: tabId,
    );
  }

  /// Closes a tab; an emptied group that is not the only one is removed.
  LayoutResult closeTab(String tabId) {
    final g = groupOf(tabId);
    if (g == null) return const LayoutResult.refused(LayoutRefusal.unknownTab);
    final newRecent = [
      for (final id in recent)
        if (id != tabId) id,
    ];
    final withoutTab = copyWith(root: _detach(this, tabId), recent: newRecent);
    var focused = focusedGroup;
    if (withoutTab.group(focused) == null) {
      final next = newRecent.isEmpty ? null : withoutTab.groupOf(newRecent.first);
      focused = (next ?? withoutTab.groups.first).id;
    }
    return LayoutResult.ok(withoutTab.copyWith(focusedGroup: focused));
  }

  /// Opens a view bound to the group's context, or focuses the existing tab
  /// with the same [kind] and [item] wherever it is.
  LayoutResult openOrFocus(
    String groupId,
    String kind,
    String? item, {
    required bool needsWorkspace,
    required String newTabId,
    Map<String, Object?> state = const {},
  }) {
    final g = group(groupId);
    if (g == null) return const LayoutResult.refused(LayoutRefusal.unknownGroup);
    if (item != null) {
      for (final t in tabs) {
        if (t.kind == kind && t.item == item) {
          return LayoutResult.ok(_activate(this, t.id), tabId: t.id);
        }
      }
    }
    if (needsWorkspace && g.context == null) {
      return const LayoutResult.refused(LayoutRefusal.needsWorkspace);
    }
    if (tabCount >= maxTabs) {
      return const LayoutResult.refused(LayoutRefusal.tabLimit);
    }
    if (utf8.encode(jsonEncode(state)).length > maxTabStateBytes) {
      return const LayoutResult.refused(LayoutRefusal.stateTooLarge);
    }
    final tab = LayoutTab(
      id: newTabId,
      kind: kind,
      workspace: g.context,
      item: item,
      state: state,
    );
    return LayoutResult.ok(
      copyWith(
        root: _replaceGroup(root, groupId, g.withTabs([...g.tabs, tab], newTabId)),
        focusedGroup: groupId,
        recent: _toFront(recent, newTabId),
      ),
      tabId: newTabId,
    );
  }

  /// Makes a tab active in its group and focuses that group.
  LayoutResult activateTab(String tabId) {
    if (tab(tabId) == null) {
      return const LayoutResult.refused(LayoutRefusal.unknownTab);
    }
    return LayoutResult.ok(_activate(this, tabId), tabId: tabId);
  }

  LayoutResult focusGroup(String groupId) {
    if (group(groupId) == null) {
      return const LayoutResult.refused(LayoutRefusal.unknownGroup);
    }
    return LayoutResult.ok(copyWith(focusedGroup: groupId));
  }

  /// Sidebar selection: focus the most recent tab bound to [workspaceId], or
  /// else set the focused group's context.
  LayoutDocument selectWorkspace(String workspaceId) {
    for (final id in recent) {
      if (tab(id)?.workspace == workspaceId) return _activate(this, id);
    }
    return copyWith(
      root: _mapGroups(
        root,
        (g) => g.id == focusedGroup ? g.withContext(workspaceId) : g,
      ),
    );
  }

  LayoutResult setGroupContext(String groupId, String? workspaceId) {
    if (group(groupId) == null) {
      return const LayoutResult.refused(LayoutRefusal.unknownGroup);
    }
    return LayoutResult.ok(
      copyWith(
        root: _mapGroups(
          root,
          (g) => g.id == groupId ? g.withContext(workspaceId) : g,
        ),
      ),
    );
  }

  /// Sets a split's ratio, clamped to the allowed range.
  LayoutResult setRatio(String splitId, double ratio) {
    if (splitNode(splitId) == null) {
      return const LayoutResult.refused(LayoutRefusal.unknownSplit);
    }
    final clamped = ratio.clamp(minSplitRatio, maxSplitRatio).toDouble();
    LayoutNode walk(LayoutNode n) => switch (n) {
      TabGroup() => n,
      SplitNode() =>
        n.id == splitId
            ? n.withRatio(clamped)
            : n.withChildren(walk(n.first), walk(n.second)),
    };
    return LayoutResult.ok(copyWith(root: walk(root)));
  }

  LayoutDocument setSidebarCollapsed(bool collapsed) =>
      copyWith(sidebarCollapsed: collapsed);

  /// Nulls every group context equal to [workspaceId] (D11).
  LayoutDocument clearContext(String workspaceId) => copyWith(
    root: _mapGroups(
      root,
      (g) => g.context == workspaceId ? g.withContext(null) : g,
    ),
  );

  /// Nulls every group context that is not in [known] (D11 load repair).
  LayoutDocument repairContexts(Set<String> known) => copyWith(
    root: _mapGroups(
      root,
      (g) => g.context != null && !known.contains(g.context)
          ? g.withContext(null)
          : g,
    ),
  );
}
