/// JSON codec and validation for the working-set document (design D2, D10).
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
  'root': _nodeToJson(d.root),
  'focusedGroup': d.focusedGroup,
  'recent': d.recent,
  'sidebar': {'collapsed': d.sidebarCollapsed},
};

Map<String, Object?> _nodeToJson(LayoutNode n) => switch (n) {
  TabGroup() => {
    'type': 'group',
    'id': n.id,
    'context': n.context,
    'tabs': [for (final t in n.tabs) _tabToJson(t)],
    'active': n.active,
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

Map<String, Object?> _tabToJson(LayoutTab t) => {
  'id': t.id,
  'kind': t.kind,
  'workspace': t.workspace,
  'item': t.item,
  'state': t.state,
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
  final ids = <String>{};
  final tabIds = <String>{};
  final groupIds = <String>{};
  var nodes = 0;
  var tabCount = 0;

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
    final root = node(m['root']);
    final focused = id(m['focusedGroup'], 'focusedGroup');
    if (!groupIds.contains(focused)) {
      fail('focusedGroup "$focused" is not a group');
    }
    final recentRaw = m['recent'];
    if (recentRaw is! List) fail('recent must be a list');
    final recent = <String>[];
    final seen = <String>{};
    for (final r in recentRaw) {
      if (r is! String || !tabIds.contains(r)) {
        fail('recent names an unknown tab: $r');
      }
      if (!seen.add(r)) fail('recent contains duplicate tab "$r"');
      recent.add(r);
    }
    final sidebar = obj(m['sidebar'], 'sidebar');
    final collapsed = sidebar['collapsed'];
    if (collapsed is! bool) fail('sidebar.collapsed must be a boolean');
    return LayoutDocument(
      root: root,
      focusedGroup: focused,
      recent: List.unmodifiable(recent),
      sidebarCollapsed: collapsed,
    );
  }

  LayoutNode node(Object? v) {
    if (++nodes > 2 * maxTabGroups - 1) {
      fail('layout has more than $maxTabGroups tab groups');
    }
    final m = obj(v, 'node');
    switch (m['type']) {
      case 'group':
        return group(m);
      case 'split':
        return split(m);
      default:
        fail('unknown node type "${m['type']}"');
    }
  }

  TabGroup group(Map<String, Object?> m) {
    final gid = id(m['id'], 'group id');
    unique(gid, 'group');
    groupIds.add(gid);
    if (groupIds.length > maxTabGroups) {
      fail('layout has more than $maxTabGroups tab groups');
    }
    final context = optId(m['context'], 'group context');
    final tabsRaw = m['tabs'];
    if (tabsRaw is! List) fail('group tabs must be a list');
    final tabs = [for (final t in tabsRaw) tab(t)];
    final active = optId(m['active'], 'group active');
    if (tabs.isEmpty ? active != null : !tabs.any((t) => t.id == active)) {
      fail('group "$gid" active must be null iff empty, else one of its tabs');
    }
    return TabGroup(
      id: gid,
      context: context,
      tabs: List.unmodifiable(tabs),
      active: active,
    );
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

  LayoutTab tab(Object? v) {
    final m = obj(v, 'tab');
    if (++tabCount > maxTabs) fail('layout has more than $maxTabs tabs');
    final tid = id(m['id'], 'tab id');
    unique(tid, 'tab');
    tabIds.add(tid);
    final kind = id(m['kind'], 'tab kind');
    final workspace = optId(m['workspace'], 'tab workspace');
    final item = m['item'];
    if (item != null) {
      if (item is! String) fail('tab item must be a string or null');
      if (_bytes(item) > maxItemBytes) {
        fail('tab item exceeds $maxItemBytes bytes');
      }
    }
    final state = m['state'];
    if (state is! Map) fail('tab state must be a JSON object');
    if (_bytes(jsonEncode(state)) > maxTabStateBytes) {
      fail('tab state exceeds $maxTabStateBytes bytes');
    }
    return LayoutTab(
      id: tid,
      kind: kind,
      workspace: workspace,
      item: item as String?,
      state: state.cast<String, Object?>(),
    );
  }
}
