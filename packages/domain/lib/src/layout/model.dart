/// Immutable working-set layout model, format 2: tabs contain panes
/// (design D11).
///
/// Nothing here names a view kind: `kind` is an opaque string the desktop
/// interprets.
library;

/// Direction of a split.
enum SplitDirection { horizontal, vertical }

/// A node of a tab's split tree: a [PaneNode] leaf or a [SplitNode].
sealed class LayoutNode {
  const LayoutNode();
  String get id;

  /// The panes below this node in tree order (`first` before `second`).
  List<PaneNode> get panes;
}

/// A pane: one view for its whole life. `workspace` is set at creation and
/// never written by any operation; the pane id is the view's id.
final class PaneNode extends LayoutNode {
  const PaneNode({
    required this.id,
    required this.kind,
    required this.workspace,
    required this.item,
    this.state = const <String, Object?>{},
  });

  @override
  final String id;

  /// Opaque view kind; the desktop decides which kinds it knows.
  final String kind;

  /// Workspace this view is bound to, or null.
  final String? workspace;

  /// The kind's identity key used for focus-existing, or null.
  final String? item;

  /// Kind-owned JSON object, preserved verbatim.
  final Map<String, Object?> state;

  @override
  List<PaneNode> get panes => [this];
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

  /// The first child's share of the area.
  final double ratio;
  final LayoutNode first;
  final LayoutNode second;

  @override
  List<PaneNode> get panes => [...first.panes, ...second.panes];

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

/// A tab: a split tree of panes and the pane focused within it.
final class LayoutTabNode {
  const LayoutTabNode({
    required this.id,
    required this.root,
    required this.focusedPane,
  });

  final String id;
  final LayoutNode root;

  /// One of this tab's own panes.
  final String focusedPane;

  /// Panes in tree order.
  List<PaneNode> get panes => root.panes;
  int get paneCount => panes.length;

  LayoutTabNode withRoot(LayoutNode newRoot, String newFocused) =>
      LayoutTabNode(id: id, root: newRoot, focusedPane: newFocused);

  LayoutTabNode withFocus(String paneId) =>
      LayoutTabNode(id: id, root: root, focusedPane: paneId);
}

/// The working-set document.
final class LayoutDocument {
  const LayoutDocument({
    required this.tabs,
    required this.activeTab,
    required this.recent,
    required this.sidebarCollapsed,
    required this.selectedWorkspace,
  });

  /// No tabs, sidebar expanded, Personal selected.
  const LayoutDocument.initial()
    : tabs = const [],
      activeTab = null,
      recent = const [],
      sidebarCollapsed = false,
      selectedWorkspace = null;

  /// The strip, left to right.
  final List<LayoutTabNode> tabs;

  /// Id of the active tab; null if and only if [tabs] is empty.
  final String? activeTab;

  /// Pane ids, most recently focused first. Sparse: may omit panes.
  final List<String> recent;
  final bool sidebarCollapsed;

  /// The workspace new tabs bind to, or null for Personal.
  final String? selectedWorkspace;

  int get tabCount => tabs.length;

  /// All panes in strip order, then tree order.
  List<PaneNode> get panes => [for (final t in tabs) ...t.panes];
  int get paneCount => panes.length;

  /// The set of workspace ids that panes are bound to.
  Set<String> get boundWorkspaces => {
    for (final p in panes)
      if (p.workspace != null) p.workspace!,
  };

  LayoutTabNode? tab(String id) {
    for (final t in tabs) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// The active tab.
  LayoutTabNode? get active => activeTab == null ? null : tab(activeTab!);

  /// The window's focused pane: the active tab's.
  String? get focusedPane => active?.focusedPane;

  PaneNode? pane(String id) {
    for (final p in panes) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// The tab that holds the pane [paneId].
  LayoutTabNode? tabOf(String paneId) {
    for (final t in tabs) {
      if (t.panes.any((p) => p.id == paneId)) return t;
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

    for (final t in tabs) {
      walk(t.root);
    }
    return found;
  }

  LayoutDocument copyWith({
    List<LayoutTabNode>? tabs,
    Object? activeTab = _keep,
    List<String>? recent,
    bool? sidebarCollapsed,
    Object? selectedWorkspace = _keep,
  }) => LayoutDocument(
    tabs: tabs == null ? this.tabs : List.unmodifiable(tabs),
    activeTab: identical(activeTab, _keep)
        ? this.activeTab
        : activeTab as String?,
    recent: recent == null ? this.recent : List.unmodifiable(recent),
    sidebarCollapsed: sidebarCollapsed ?? this.sidebarCollapsed,
    selectedWorkspace: identical(selectedWorkspace, _keep)
        ? this.selectedWorkspace
        : selectedWorkspace as String?,
  );
}

const Object _keep = Object();
