/// Immutable working-set layout model (design D2, D7, D8).
library;

/// Direction of a split.
enum SplitDirection { horizontal, vertical }

/// A tab. `workspace` is set at creation and never written by any operation.
final class LayoutTab {
  const LayoutTab({
    required this.id,
    required this.kind,
    required this.workspace,
    required this.item,
    this.state = const <String, Object?>{},
  });

  final String id;

  /// Opaque view kind; the desktop decides which kinds it knows.
  final String kind;

  /// Workspace this tab is bound to, or null.
  final String? workspace;

  /// The kind's identity key used for focus-existing, or null.
  final String? item;

  /// Kind-owned JSON object, preserved verbatim.
  final Map<String, Object?> state;
}

/// A node of the split tree.
sealed class LayoutNode {
  const LayoutNode();
  String get id;
}

/// A group of tabs: a leaf of the split tree.
final class TabGroup extends LayoutNode {
  const TabGroup({
    required this.id,
    required this.context,
    required this.tabs,
    required this.active,
  });

  @override
  final String id;

  /// Workspace context new tabs bind to, or null.
  final String? context;
  final List<LayoutTab> tabs;

  /// Id of the active tab; null iff [tabs] is empty.
  final String? active;

  TabGroup withContext(String? value) =>
      TabGroup(id: id, context: value, tabs: tabs, active: active);

  TabGroup withTabs(List<LayoutTab> newTabs, String? newActive) => TabGroup(
    id: id,
    context: context,
    tabs: List.unmodifiable(newTabs),
    active: newActive,
  );
}

/// An interior node splitting the area between two children.
final class SplitNode extends LayoutNode {
  const SplitNode({
    required this.id,
    required this.direction,
    required this.ratio,
    required this.first,
    required this.second,
  });

  @override
  final String id;
  final SplitDirection direction;
  final double ratio;
  final LayoutNode first;
  final LayoutNode second;

  SplitNode withChildren(LayoutNode newFirst, LayoutNode newSecond) =>
      SplitNode(
        id: id,
        direction: direction,
        ratio: ratio,
        first: newFirst,
        second: newSecond,
      );

  SplitNode withRatio(double value) => SplitNode(
    id: id,
    direction: direction,
    ratio: value,
    first: first,
    second: second,
  );
}

/// The working-set document.
final class LayoutDocument {
  const LayoutDocument({
    required this.root,
    required this.focusedGroup,
    required this.recent,
    required this.sidebarCollapsed,
  });

  /// One empty group, no context, focused, sidebar expanded.
  factory LayoutDocument.initial(String groupId) => LayoutDocument(
    root: TabGroup(id: groupId, context: null, tabs: const [], active: null),
    focusedGroup: groupId,
    recent: const [],
    sidebarCollapsed: false,
  );

  final LayoutNode root;
  final String focusedGroup;

  /// Tab ids, most recently active first.
  final List<String> recent;
  final bool sidebarCollapsed;

  /// Groups in tree order (first before second).
  List<TabGroup> get groups {
    final out = <TabGroup>[];
    void walk(LayoutNode n) {
      switch (n) {
        case TabGroup():
          out.add(n);
        case SplitNode():
          walk(n.first);
          walk(n.second);
      }
    }

    walk(root);
    return out;
  }

  /// All tabs in tree order.
  List<LayoutTab> get tabs => [for (final g in groups) ...g.tabs];

  int get groupCount => groups.length;
  int get tabCount => tabs.length;

  /// The set of workspace ids that tabs are bound to.
  Set<String> get boundWorkspaces => {
    for (final t in tabs)
      if (t.workspace != null) t.workspace!,
  };

  TabGroup? group(String id) {
    for (final g in groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  LayoutTab? tab(String id) {
    for (final t in tabs) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// The group that holds the tab [tabId].
  TabGroup? groupOf(String tabId) {
    for (final g in groups) {
      if (g.tabs.any((t) => t.id == tabId)) return g;
    }
    return null;
  }

  /// The split with id [id].
  SplitNode? splitNode(String id) {
    SplitNode? found;
    void walk(LayoutNode n) {
      if (n is SplitNode) {
        if (n.id == id) found = n;
        walk(n.first);
        walk(n.second);
      }
    }

    walk(root);
    return found;
  }

  LayoutDocument copyWith({
    LayoutNode? root,
    String? focusedGroup,
    List<String>? recent,
    bool? sidebarCollapsed,
  }) => LayoutDocument(
    root: root ?? this.root,
    focusedGroup: focusedGroup ?? this.focusedGroup,
    recent: recent == null ? this.recent : List.unmodifiable(recent),
    sidebarCollapsed: sidebarCollapsed ?? this.sidebarCollapsed,
  );
}
