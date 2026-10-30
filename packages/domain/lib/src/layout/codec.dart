/// JSON codec and validation for the working-set document, format 2
/// (design D11).
library;

import 'dart:convert';

import 'bounds.dart';
import 'model.dart';

/// A stored layout failed decoding or validation; [reason] is human-readable.
final class LayoutInvalid implements Exception {
  const LayoutInvalid(this.reason);
  final String reason;

  @override
  String toString() => 'LayoutInvalid: $reason';
}

int _bytes(String s) => utf8.encode(s).length;

Map<String, Object?> layoutToJson(LayoutDocument d) => {
  'format': layoutFormat,
  'tabs': [for (final t in d.tabs) _tabToJson(t)],
  'activeTab': d.activeTab,
  'recent': d.recent,
  'sidebar': {'collapsed': d.sidebarCollapsed, 'selected': d.selectedWorkspace},
};

Map<String, Object?> _tabToJson(LayoutTabNode t) => {
  'id': t.id,
  'focusedPane': t.focusedPane,
  'root': _nodeToJson(t.root),
};

Map<String, Object?> _nodeToJson(LayoutNode n) => switch (n) {
  PaneNode() => {
    'type': 'pane',
    'id': n.id,
    'kind': n.kind,
    'workspace': n.workspace,
    'item': n.item,
    'state': n.state,
  },
  SplitNode() => {
    'type': 'split',
    'id': n.id,
    'direction': n.direction.name,
    'ratio': n.ratio,
    'first': _nodeToJson(n.first),
    'second': _nodeToJson(n.second),
  },
};

String encodeLayout(LayoutDocument d) => jsonEncode(layoutToJson(d));

/// Decodes and validates [source]; the 256 KiB size bound applies to it.
LayoutDocument decodeLayout(String source) {
  if (_bytes(source) > maxDocumentBytes) {
    throw const LayoutInvalid('layout exceeds $maxDocumentBytes bytes');
  }
  Object? json;
  try {
    json = jsonDecode(source);
  } on FormatException catch (e) {
    throw LayoutInvalid('layout is not valid JSON: ${e.message}');
  }
  return layoutFromJson(json);
}

/// Validates and decodes an already-parsed document.
LayoutDocument layoutFromJson(Object? json) => _Decoder().document(json);

final class _Decoder {
  /// Ids of tabs, splits and panes share one namespace.
  final ids = <String>{};
  final paneIds = <String>{};
  var currentTab = '';
  var panesInTab = 0;
  var totalPanes = 0;

  Never fail(String reason) => throw LayoutInvalid(reason);

  Map<String, Object?> obj(Object? v, String what) {
    if (v is Map<String, Object?>) return v;
    if (v is Map) return v.cast<String, Object?>();
    fail('$what must be an object');
  }

  String id(Object? v, String what) {
    if (v is! String) fail('$what must be a string');
    if (v.isEmpty) fail('$what must not be empty');
    if (_bytes(v) > maxIdBytes) fail('$what exceeds $maxIdBytes bytes');
    return v;
  }

  String? optId(Object? v, String what) => v == null ? null : id(v, what);

  void unique(String v, String what) {
    if (!ids.add(v)) fail('duplicate id "$v" ($what)');
  }

  LayoutDocument document(Object? json) {
    final m = obj(json, 'layout');
    final format = m['format'];
    if (format != layoutFormat) fail('unsupported layout format $format');
    final tabsRaw = m['tabs'];
    if (tabsRaw is! List) fail('tabs must be a list');
    if (tabsRaw.length > maxTabs) fail('layout has more than $maxTabs tabs');
    final tabs = [for (final t in tabsRaw) tab(t)];
    final active = optId(m['activeTab'], 'activeTab');
    if (tabs.isEmpty) {
      if (active != null) {
        fail('activeTab must be null when there are no tabs');
      }
    } else {
      if (active == null) {
        fail('activeTab must name a tab when there are tabs');
      }
      if (!tabs.any((t) => t.id == active)) {
        fail('activeTab "$active" is not a tab');
      }
    }
    final recentRaw = m['recent'];
    if (recentRaw is! List) fail('recent must be a list');
    final recent = <String>[];
    final seen = <String>{};
    for (final r in recentRaw) {
      if (r is! String || !paneIds.contains(r)) {
        fail('recent names an unknown pane: $r');
      }
      if (!seen.add(r)) fail('recent contains duplicate pane "$r"');
      recent.add(r);
    }
    final sidebar = obj(m['sidebar'], 'sidebar');
    final collapsed = sidebar['collapsed'];
    if (collapsed is! bool) fail('sidebar.collapsed must be a boolean');
    final selected = optId(sidebar['selected'], 'sidebar.selected');
    return LayoutDocument(
      tabs: List.unmodifiable(tabs),
      activeTab: active,
      recent: List.unmodifiable(recent),
      sidebarCollapsed: collapsed,
      selectedWorkspace: selected,
    );
  }

  LayoutTabNode tab(Object? v) {
    final m = obj(v, 'tab');
    final tid = id(m['id'], 'tab id');
    unique(tid, 'tab');
    currentTab = tid;
    panesInTab = 0;
    final root = node(m['root']);
    final focused = id(m['focusedPane'], 'focusedPane');
    if (!root.panes.any((p) => p.id == focused)) {
      fail('focusedPane "$focused" is not a pane of tab "$tid"');
    }
    return LayoutTabNode(id: tid, root: root, focusedPane: focused);
  }

  LayoutNode node(Object? v) {
    final m = obj(v, 'node');
    switch (m['type']) {
      case 'pane':
        return pane(m);
      case 'split':
        return split(m);
      default:
        fail('unknown node type "${m['type']}"');
    }
  }

  SplitNode split(Map<String, Object?> m) {
    final sid = id(m['id'], 'split id');
    unique(sid, 'split');
    final dir = m['direction'];
    final direction = SplitDirection.values.where((d) => d.name == dir);
    if (direction.isEmpty) fail('unknown split direction "$dir"');
    final r = m['ratio'];
    if (r is! num) fail('split ratio must be a number');
    final ratio = r.toDouble();
    if (!(ratio >= minSplitRatio && ratio <= maxSplitRatio)) {
      fail('split ratio $ratio is outside $minSplitRatio..$maxSplitRatio');
    }
    if (m['first'] == null || m['second'] == null) {
      fail('split "$sid" needs two children');
    }
    final first = node(m['first']);
    final second = node(m['second']);
    return SplitNode(
      id: sid,
      direction: direction.first,
      ratio: ratio,
      first: first,
      second: second,
    );
  }

  PaneNode pane(Map<String, Object?> m) {
    final pid = id(m['id'], 'pane id');
    unique(pid, 'pane');
    paneIds.add(pid);
    if (++totalPanes > maxPanes) fail('layout has more than $maxPanes panes');
    if (++panesInTab > maxPanesPerTab) {
      fail('tab "$currentTab" has more than $maxPanesPerTab panes');
    }
    final kind = id(m['kind'], 'pane kind');
    final workspace = optId(m['workspace'], 'pane workspace');
    final item = m['item'];
    if (item != null) {
      if (item is! String) fail('pane item must be a string or null');
      if (_bytes(item) > maxItemBytes) {
        fail('pane item exceeds $maxItemBytes bytes');
      }
    }
    final state = m['state'];
    if (state is! Map) fail('pane state must be a JSON object');
    if (_bytes(jsonEncode(state)) > maxTabStateBytes) {
      fail('pane state exceeds $maxTabStateBytes bytes');
    }
    return PaneNode(
      id: pid,
      kind: kind,
      workspace: workspace,
      item: item as String?,
      state: state.cast<String, Object?>(),
    );
  }
}
