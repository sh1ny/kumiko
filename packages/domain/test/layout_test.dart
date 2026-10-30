import 'dart:convert';
import 'dart:math';

import 'package:domain/domain.dart';
import 'package:test/test.dart';

typedef Json = Map<String, Object?>;

// ---- format 2 JSON builders (the codec tests use raw documents) ----

Json paneJson(
  String id, {
  String kind = 'terminal',
  String? workspace,
  String? item,
  Json state = const {},
}) => {
  'type': 'pane',
  'id': id,
  'kind': kind,
  'workspace': workspace,
  'item': item ?? id,
  'state': state,
};

Json splitJson(
  String id,
  Json first,
  Json second, {
  String direction = 'horizontal',
  double ratio = 0.5,
}) => {
  'type': 'split',
  'id': id,
  'direction': direction,
  'ratio': ratio,
  'first': first,
  'second': second,
};

Json tabJson(String id, Json root, String focused) => {
  'id': id,
  'focusedPane': focused,
  'root': root,
};

Json docJson({
  List<Json> tabs = const [],
  String? activeTab,
  List<String> recent = const [],
  bool collapsed = false,
  String? selected,
}) => {
  'format': 2,
  'tabs': tabs,
  'activeTab': activeTab,
  'recent': recent,
  'sidebar': {'collapsed': collapsed, 'selected': selected},
};

/// A tab of [n] panes `<prefix>0..`, chained by splits.
Json chainTab(String tab, String prefix, int n) {
  var root = paneJson('${prefix}0');
  for (var i = 1; i < n; i++) {
    root = splitJson('${prefix}s$i', root, paneJson('$prefix$i'));
  }
  return tabJson(tab, root, '${prefix}0');
}

/// A valid one-tab document to mutate.
Json base() => docJson(
  tabs: [
    tabJson(
      't1',
      splitJson(
        's1',
        paneJson('p1', workspace: 'w1'),
        paneJson('p2', kind: 'workspace-overview', workspace: 'w1'),
      ),
      'p2',
    ),
  ],
  activeTab: 't1',
  recent: ['p2', 'p1'],
  selected: 'w1',
);

Json rootOf(Json doc, [int tab = 0]) =>
    (doc['tabs']! as List)[tab].cast<String, Object?>()['root']! as Json;

void expectInvalid(Object? json, Pattern reason) {
  expect(
    () => layoutFromJson(json),
    throwsA(
      isA<LayoutInvalid>().having((e) => e.reason, 'reason', contains(reason)),
    ),
  );
}

void expectRoundTrip(Json json) {
  final decoded = layoutFromJson(json);
  expect(jsonDecode(encodeLayout(decoded)), json);
  expect(jsonDecode(encodeLayout(decodeLayout(jsonEncode(json)))), json);
}

// ---- operations ----

/// Kinds every operation is run over: a terminal, a Workspace overview and a
/// kind this build knows nothing about.
const kinds = ['terminal', 'workspace-overview', 'mystery-kind'];

LayoutDocument ok(LayoutResult r) =>
    r.document ?? (throw StateError('refused: ${r.refusal}'));

PaneNode view(
  String id, {
  String kind = 'terminal',
  String? workspace,
  String? item,
  Map<String, Object?> state = const {},
}) => PaneNode(
  id: id,
  kind: kind,
  workspace: workspace,
  item: item ?? id,
  state: state,
);

LayoutDocument addTab(
  LayoutDocument d,
  String tab,
  String pane, {
  String kind = 'terminal',
  String? workspace,
}) => ok(
  d.openTab(
    view(pane, kind: kind, workspace: workspace),
    tabId: tab,
  ),
);

LayoutDocument split(
  LayoutDocument d,
  String pane,
  String newPane, {
  String? splitId,
  String kind = 'terminal',
  SplitDirection direction = SplitDirection.horizontal,
  String? workspace,
}) => ok(
  d.splitPane(
    pane,
    direction,
    view(newPane, kind: kind, workspace: workspace),
    splitId: splitId ?? 's_$newPane',
  ),
);

List<String> tabIds(LayoutDocument d) => [for (final t in d.tabs) t.id];

List<String> paneIds(LayoutNode n) => [for (final p in n.panes) p.id];

/// A tab `t1` holding A beside (B above C), all of [kind], with A focused.
/// recent: A, C, B.
LayoutDocument abc({String kind = 'terminal'}) {
  var d = addTab(const LayoutDocument.initial(), 't1', 'A', kind: kind);
  d = split(d, 'A', 'B', kind: kind, splitId: 's1');
  d = split(
    d,
    'B',
    'C',
    kind: kind,
    splitId: 's2',
    direction: SplitDirection.vertical,
  );
  return ok(d.focusPane('A'));
}

/// Three one-pane tabs t1..t3 (panes p1..p3), the middle one active.
LayoutDocument threeTabs({String kind = 'terminal'}) {
  var d = const LayoutDocument.initial();
  for (var i = 1; i <= 3; i++) {
    d = addTab(d, 't$i', 'p$i', kind: kind);
  }
  return ok(d.activateTab('t2'));
}

/// [tabs] tabs of [panes] panes each, tab `t<i>` with panes `t<i>p<j>`.
LayoutDocument grid(int tabs, int panes) => layoutFromJson(
  docJson(
    tabs: [for (var i = 0; i < tabs; i++) chainTab('t$i', 't${i}p', panes)],
    activeTab: tabs == 0 ? null : 't0',
  ),
);

Map<String, String?> bindings(LayoutDocument d) => {
  for (final p in d.panes) p.id: p.workspace,
};

String enc(LayoutDocument d) => encodeLayout(d);

/// Checks [d] against the validator through its own JSON, and the bounds.
void expectValid(LayoutDocument d, [String? after]) {
  final reason = after == null ? '' : 'after $after';
  final back = layoutFromJson(jsonDecode(enc(d)));
  expect(enc(back), enc(d), reason: reason);
  expect(d.tabCount, lessThanOrEqualTo(d.paneCount), reason: reason);
  expect(d.paneCount, lessThanOrEqualTo(maxPanes), reason: reason);
}

/// Applies random operations over panes of every kind and checks, after each,
/// that no binding or unknown-kind pane changed and the result is valid.
void _randomWalk(int seed) {
  final rnd = Random(seed);
  var d = const LayoutDocument.initial();
  var n = 0;
  String fresh(String prefix) => '$prefix${n++}';
  T pick<T>(List<T> xs) => xs[rnd.nextInt(xs.length)];
  PaneNode newView() => PaneNode(
    id: fresh('p'),
    kind: pick(kinds),
    workspace: pick(<String?>[null, 'w1', 'w2']),
    item: rnd.nextBool() ? fresh('i') : null,
    state: {
      'n': rnd.nextInt(100),
      'deep': {
        'k': [1, 2],
      },
    },
  );
  final bound = <String, String?>{};
  final unknownJson = <String, String>{};

  for (var step = 0; step < 250; step++) {
    final op = rnd.nextInt(18);
    final tabs = d.tabs;
    final panes = d.panes;
    final needsPane = op >= 5 && op <= 13;
    LayoutResult? r;
    LayoutDocument? direct;
    if (panes.isEmpty && needsPane || op <= 2) {
      r = d.openTab(newView(), tabId: fresh('t'));
    } else if (op <= 4) {
      final existing = panes.isEmpty ? null : pick(panes);
      final v = existing != null && rnd.nextBool()
          ? PaneNode(
              id: fresh('p'),
              kind: existing.kind,
              workspace: existing.workspace,
              item: existing.item,
            )
          : newView();
      r = d.openOrFocus(v, tabId: fresh('t'));
    } else if (op <= 7) {
      r = d.splitPane(
        pick(panes).id,
        pick(SplitDirection.values),
        newView(),
        splitId: fresh('s'),
      );
    } else if (op == 8) {
      r = d.closePane(pick(panes).id);
    } else if (op == 9) {
      r = d.closeTab(pick(tabs).id);
    } else if (op == 10) {
      r = d.movePaneToNewTab(pick(panes).id, newTabId: fresh('t'));
    } else if (op == 11) {
      r = d.moveTabIntoSplit(
        pick(tabs).id,
        pick(SplitDirection.values),
        splitId: fresh('s'),
      );
    } else if (op == 12) {
      r = d.focusPane(pick(panes).id);
    } else if (op == 13) {
      r = d.activateTab(pick(tabs).id);
    } else if (op == 14) {
      final id = d.splitNode(pick(['s0', 's1', 's2', 's3', 's4']));
      r = id == null
          ? d.setRatio('missing', 0.5)
          : d.setRatio(id.id, rnd.nextDouble());
    } else if (op == 15) {
      direct = d.selectWorkspace(pick(['w1', 'w2', 'w3']));
    } else if (op == 16) {
      direct = d.clearSelection(pick(['w1', 'w2']));
    } else {
      direct = d.repairSelection({'w1'});
    }

    final next = direct ?? r!.document ?? d;
    if (r != null && !r.isOk) {
      expect(next, same(d), reason: 'a refusal changes nothing');
    }
    for (final p in next.panes) {
      if (bound.containsKey(p.id)) {
        expect(p.workspace, bound[p.id], reason: 'binding of ${p.id}');
      } else {
        bound[p.id] = p.workspace;
      }
      if (p.kind == 'mystery-kind') {
        final mine = jsonEncode({
          'kind': p.kind,
          'workspace': p.workspace,
          'item': p.item,
          'state': p.state,
        });
        expect(unknownJson.putIfAbsent(p.id, () => mine), mine);
      }
    }
    expectValid(next, 'seed $seed step $step op $op');
    d = next;
  }
}

void main() {
  group('format 2 codec', () {
    test('round-trips a document with a one-pane tab', () {
      expectRoundTrip(
        docJson(
          tabs: [
            tabJson(
              't1',
              paneJson(
                'p1',
                workspace: 'w1',
                item: '0b6b7d8e-2f5a-4c1e-9d3a-6f1b2c3d4e5f',
                state: {'profileId': 'builtin:bash', 'profileName': 'bash'},
              ),
              'p1',
            ),
          ],
          activeTab: 't1',
          recent: ['p1'],
          selected: 'w1',
        ),
      );
    });

    test('round-trips a split tab: a terminal beside an overview', () {
      expectRoundTrip(base());
    });

    test('round-trips an empty document and the sidebar state', () {
      expectRoundTrip(docJson());
      expectRoundTrip(docJson(collapsed: true, selected: 'w9'));
      final d = layoutFromJson(docJson(collapsed: true, selected: 'w9'));
      expect(d.sidebarCollapsed, isTrue);
      expect(d.selectedWorkspace, 'w9');
      expect(d.activeTab, isNull);
      expect(d.tabs, isEmpty);
    });

    test('an unknown-kind pane round-trips unchanged', () {
      final unknown = paneJson(
        'p2',
        kind: 'chat-over-acp',
        workspace: 'w1',
        item: 'session:7',
        state: {
          'nested': [
            1,
            {'a': null, 'b': 'x'},
            true,
          ],
          'n': 2.5,
        },
      );
      final json = docJson(
        tabs: [tabJson('t1', splitJson('s1', paneJson('p1'), unknown), 'p1')],
        activeTab: 't1',
        recent: ['p1'],
      );
      expectRoundTrip(json);
      final pane = layoutFromJson(json).pane('p2')!;
      expect(pane.kind, 'chat-over-acp');
      expect(pane.state['nested'], isA<List<Object?>>());
    });

    test('a stored terminal pane loads with its binding and state', () {
      final d = layoutFromJson(
        docJson(
          tabs: [
            tabJson(
              't1',
              paneJson(
                'p1',
                workspace: 'w1',
                item: 'uuid-1',
                state: {'profileId': 'builtin:pwsh', 'profileName': 'pwsh'},
              ),
              'p1',
            ),
          ],
          activeTab: 't1',
        ),
      );
      final p = d.pane('p1')!;
      expect(p.kind, 'terminal');
      expect(p.workspace, 'w1');
      expect(p.item, 'uuid-1');
      expect(p.state, {'profileId': 'builtin:pwsh', 'profileName': 'pwsh'});
    });

    test('null item and null workspace round-trip', () {
      final pane = paneJson('p1')..['item'] = null;
      expectRoundTrip(
        docJson(
          tabs: [tabJson('t1', pane, 'p1')],
          activeTab: 't1',
          recent: ['p1'],
        ),
      );
    });

    test('a valid document whose recent omits panes is valid', () {
      expectRoundTrip(base()..['recent'] = ['p1']);
      expectRoundTrip(base()..['recent'] = <String>[]);
    });

    test('invalid JSON text reports a reason', () {
      expect(
        () => decodeLayout('{nope'),
        throwsA(isA<LayoutInvalid>().having((e) => e.reason, 'r', isNotEmpty)),
      );
    });
  });

  group('format 2 validation', () {
    test('a format 1 document is unsupported', () {
      expectInvalid({
        'format': 1,
        'root': {
          'type': 'group',
          'id': 'g1',
          'context': null,
          'tabs': <Object?>[],
          'active': null,
        },
        'focusedGroup': 'g1',
        'recent': <Object?>[],
        'sidebar': {'collapsed': false},
      }, 'unsupported layout format 1');
    });

    test('a non-object document is invalid', () {
      expectInvalid(<Object?>[], 'layout must be an object');
    });

    test('a pane without a kind is invalid', () {
      final j = base();
      (rootOf(j)['first']! as Json).remove('kind');
      expectInvalid(j, 'pane kind must be a string');
    });

    test('a split with one child is invalid', () {
      final j = base();
      rootOf(j).remove('second');
      expectInvalid(j, 'split "s1" needs two children');
    });

    test('an unknown node type is invalid', () {
      final j = base();
      (rootOf(j)['first']! as Json)['type'] = 'group';
      expectInvalid(j, 'unknown node type "group"');
    });

    test('activeTab set with no tabs is invalid', () {
      expectInvalid(
        docJson(activeTab: 't1'),
        'activeTab must be null when there are no tabs',
      );
    });

    test('activeTab null with tabs is invalid', () {
      expectInvalid(
        base()..['activeTab'] = null,
        'activeTab must name a tab when there are tabs',
      );
    });

    test('activeTab naming no tab is invalid', () {
      expectInvalid(
        base()..['activeTab'] = 'tx',
        'activeTab "tx" is not a tab',
      );
    });

    test('a focusedPane outside its tab is invalid', () {
      final j = docJson(
        tabs: [
          tabJson('t1', paneJson('p1'), 'p1'),
          tabJson('t2', paneJson('p2'), 'p1'),
        ],
        activeTab: 't1',
      );
      expectInvalid(j, 'focusedPane "p1" is not a pane of tab "t2"');
      expectInvalid(
        base()..['tabs'] = [tabJson('t1', paneJson('p1'), 'pX')],
        'focusedPane "pX" is not a pane of tab "t1"',
      );
    });

    test('duplicate ids are invalid across tabs, splits and panes', () {
      expectInvalid(
        docJson(
          tabs: [
            tabJson('t1', paneJson('p1'), 'p1'),
            tabJson('t2', paneJson('p1'), 'p1'),
          ],
          activeTab: 't1',
        ),
        'duplicate id "p1"',
      );
      expectInvalid(
        docJson(
          tabs: [
            tabJson('t1', splitJson('x', paneJson('p1'), paneJson('x')), 'p1'),
          ],
          activeTab: 't1',
        ),
        'duplicate id "x"',
      );
      expectInvalid(
        docJson(
          tabs: [
            tabJson('t1', paneJson('p1'), 'p1'),
            tabJson('p1', paneJson('p2'), 'p2'),
          ],
          activeTab: 't1',
        ),
        'duplicate id "p1"',
      );
      expectInvalid(
        docJson(
          tabs: [
            tabJson('t1', paneJson('p1'), 'p1'),
            tabJson('t1', paneJson('p2'), 'p2'),
          ],
          activeTab: 't1',
        ),
        'duplicate id "t1"',
      );
    });

    test('recent naming an unknown or duplicate pane is invalid', () {
      expectInvalid(
        base()..['recent'] = ['p1', 'nope'],
        'recent names an unknown pane',
      );
      expectInvalid(
        base()..['recent'] = ['t1'],
        'recent names an unknown pane',
      );
      expectInvalid(
        base()..['recent'] = ['p1', 'p2', 'p1'],
        'recent contains duplicate pane "p1"',
      );
    });

    test('state must be an object, direction known, sidebar well-formed', () {
      final badState = base();
      (rootOf(badState)['first']! as Json)['state'] = [1];
      expectInvalid(badState, 'pane state must be a JSON object');

      final badDir = base();
      rootOf(badDir)['direction'] = 'diagonal';
      expectInvalid(badDir, 'unknown split direction "diagonal"');

      expectInvalid(
        base()..['sidebar'] = {'collapsed': 1, 'selected': null},
        'sidebar.collapsed must be a boolean',
      );
      expectInvalid(
        base()..['sidebar'] = {'collapsed': false, 'selected': 4},
        'sidebar.selected',
      );
    });

    group('bounds', () {
      test('129 tabs are invalid, 128 are valid', () {
        List<Json> tabs(int n) => [
          for (var i = 0; i < n; i++) tabJson('t$i', paneJson('p$i'), 'p$i'),
        ];
        expectInvalid(
          docJson(tabs: tabs(129), activeTab: 't0'),
          'more than 128 tabs',
        );
        layoutFromJson(docJson(tabs: tabs(128), activeTab: 't0'));
      });

      test('17 panes in a tab are invalid, 16 are valid', () {
        expectInvalid(
          docJson(tabs: [chainTab('t1', 'p', 17)], activeTab: 't1'),
          'tab "t1" has more than 16 panes',
        );
        layoutFromJson(
          docJson(tabs: [chainTab('t1', 'p', 16)], activeTab: 't1'),
        );
      });

      test('129 panes are invalid, 128 are valid', () {
        Json docOf(int fullTabs, int last) => docJson(
          tabs: [
            for (var i = 0; i < fullTabs; i++) chainTab('t$i', 'a${i}_', 16),
            if (last > 0) chainTab('tl', 'z', last),
          ],
          activeTab: 't0',
        );
        expectInvalid(docOf(8, 1), 'more than 128 panes');
        layoutFromJson(docOf(8, 0));
      });

      test('a document over 256 KiB is invalid', () {
        final state = {'pad': 'x' * 4000};
        Json tab(int t) {
          var root = paneJson('t${t}p0', state: state);
          for (var i = 1; i < 15; i++) {
            root = splitJson(
              't${t}s$i',
              root,
              paneJson('t${t}p$i', state: state),
            );
          }
          return tabJson('t$t', root, 't${t}p0');
        }

        final source = jsonEncode(
          docJson(tabs: [for (var t = 0; t < 7; t++) tab(t)], activeTab: 't0'),
        );
        expect(utf8.encode(source).length, greaterThan(maxDocumentBytes));
        expect(
          () => decodeLayout(source),
          throwsA(
            isA<LayoutInvalid>().having(
              (e) => e.reason,
              'reason',
              contains('exceeds $maxDocumentBytes bytes'),
            ),
          ),
        );
      });

      test('state over 4 KiB is invalid, at 4 KiB it is valid', () {
        Json withState(int pad) => docJson(
          tabs: [
            tabJson('t1', paneJson('p1', state: {'p': 'x' * pad}), 'p1'),
          ],
          activeTab: 't1',
        );
        // {"p":"..."} is 8 bytes of structure around the padding.
        layoutFromJson(withState(maxTabStateBytes - 8));
        expectInvalid(
          withState(maxTabStateBytes - 7),
          'pane state exceeds $maxTabStateBytes bytes',
        );
      });

      test('item over 4 KiB is invalid', () {
        Json withItem(int n) => docJson(
          tabs: [tabJson('t1', paneJson('p1', item: 'i' * n), 'p1')],
          activeTab: 't1',
        );
        layoutFromJson(withItem(maxItemBytes));
        expectInvalid(
          withItem(maxItemBytes + 1),
          'pane item exceeds $maxItemBytes bytes',
        );
      });

      test('ids and kinds over 64 bytes are invalid', () {
        expectInvalid(
          docJson(
            tabs: [tabJson('t1', paneJson('p' * 65), 'p' * 65)],
            activeTab: 't1',
          ),
          'exceeds $maxIdBytes bytes',
        );
        expectInvalid(
          docJson(
            tabs: [tabJson('t' * 65, paneJson('p1'), 'p1')],
            activeTab: 't' * 65,
          ),
          'exceeds $maxIdBytes bytes',
        );
        expectInvalid(
          docJson(
            tabs: [tabJson('t1', paneJson('p1', kind: 'k' * 65), 'p1')],
            activeTab: 't1',
          ),
          'exceeds $maxIdBytes bytes',
        );
      });

      test('a split ratio outside 0.1 to 0.9 is invalid', () {
        for (final r in [0.09, 0.91, 0.0, 1.0]) {
          final j = base();
          rootOf(j)['ratio'] = r;
          expectInvalid(j, 'outside 0.1..0.9');
        }
        for (final r in [0.1, 0.9]) {
          final j = base();
          rootOf(j)['ratio'] = r;
          layoutFromJson(j);
        }
      });
    });
  });

  group('open', () {
    for (final kind in kinds) {
      test('openTab appends an active one-pane tab ($kind)', () {
        var d = addTab(const LayoutDocument.initial(), 't1', 'p1', kind: kind);
        d = addTab(d, 't2', 'p2', kind: kind, workspace: 'w1');
        expect(tabIds(d), ['t1', 't2']);
        expect(d.activeTab, 't2');
        expect(d.focusedPane, 'p2');
        expect(d.tab('t1')!.focusedPane, 'p1');
        expect(paneIds(d.tab('t2')!.root), ['p2']);
        expect(d.pane('p2')!.kind, kind);
        expect(d.pane('p2')!.workspace, 'w1');
        expect(d.recent, ['p2', 'p1']);
        expectValid(d);
      });
    }

    test('openTab keeps the sidebar selection and takes no workspace', () {
      var d = const LayoutDocument.initial().selectWorkspace('w1');
      d = addTab(d, 't1', 'p1');
      expect(d.selectedWorkspace, 'w1');
      expect(d.pane('p1')!.workspace, isNull, reason: 'the caller binds');
    });

    test('openTab is refused at 128 panes and changes nothing', () {
      final d = grid(16, 8);
      expect(d.paneCount, 128);
      final r = d.openTab(view('extra'), tabId: 'tx');
      expect(r.refusal, LayoutRefusal.paneLimit);
      expect(r.document, isNull);
    });

    test('oversized state is refused', () {
      final big = {'pad': 'x' * maxTabStateBytes};
      final r = const LayoutDocument.initial().openTab(
        view('p1', state: big),
        tabId: 't1',
      );
      expect(r.refusal, LayoutRefusal.stateTooLarge);
    });

    for (final kind in kinds) {
      test('openOrFocus focuses the matching pane in another tab ($kind)', () {
        var d = addTab(const LayoutDocument.initial(), 't1', 'p1', kind: kind);
        d = split(d, 'p1', 'p1b', kind: kind);
        d = addTab(d, 't2', 'p2', kind: kind);
        expect(d.activeTab, 't2');
        final r = d.openOrFocus(
          view('fresh', kind: kind, item: 'p1'),
          tabId: 'tfresh',
        );
        final after = ok(r);
        expect(r.tabId, 't1');
        expect(r.paneId, 'p1');
        expect(after.activeTab, 't1');
        expect(after.tab('t1')!.focusedPane, 'p1');
        expect(after.recent.first, 'p1');
        expect(after.tabCount, d.tabCount);
        expect(after.paneCount, d.paneCount);
        expectValid(after);
      });
    }

    test('items of different kinds do not collide', () {
      var d = addTab(const LayoutDocument.initial(), 't1', 'p1');
      d = ok(
        d.openOrFocus(
          view('p2', kind: 'workspace-overview', item: 'p1'),
          tabId: 't2',
        ),
      );
      expect(d.tabCount, 2);
    });

    test('a null item always opens a new tab', () {
      final noItem = PaneNode(id: 'p1', kind: 'k', workspace: null, item: null);
      var d = ok(
        const LayoutDocument.initial().openOrFocus(noItem, tabId: 't1'),
      );
      d = ok(
        d.openOrFocus(
          PaneNode(id: 'p2', kind: 'k', workspace: null, item: null),
          tabId: 't2',
        ),
      );
      expect(d.tabCount, 2);
    });

    test('terminals with fresh item ids are never matched', () {
      var d = const LayoutDocument.initial();
      for (final (tab, pane, item) in [
        ('t1', 'p1', '0b6b7d8e-2f5a-4c1e-9d3a-6f1b2c3d4e5f'),
        ('t2', 'p2', '7a1c9e20-5b3d-4f6a-8c2e-1d0f9a8b7c6d'),
      ]) {
        final r = d.openOrFocus(
          view(
            pane,
            item: item,
            state: {'profileId': 'builtin:pwsh', 'profileName': 'pwsh'},
          ),
          tabId: tab,
        );
        expect(r.tabId, tab, reason: 'a new tab, not the first');
        d = ok(r);
      }
      expect(d.tabCount, 2);
    });

    test('focusing an existing pane still works at the pane limit', () {
      final d = grid(16, 8);
      final r = d.openOrFocus(view('x', item: 't3p0'), tabId: 'tx');
      expect(ok(r).activeTab, 't3');
    });

    test('opening after the pane closed opens a new tab', () {
      var d = addTab(const LayoutDocument.initial(), 't1', 'p1');
      d = ok(d.closePane('p1'));
      expect(d.tabs, isEmpty);
      final r = d.openOrFocus(view('p2', item: 'p1'), tabId: 't2');
      expect(r.tabId, 't2');
      expect(ok(r).tabCount, 1);
    });
  });

  group('split', () {
    for (final kind in kinds) {
      for (final direction in SplitDirection.values) {
        test('splitPane places the new pane second and focuses it '
            '($kind, ${direction.name})', () {
          var d = addTab(
            const LayoutDocument.initial(),
            't1',
            'p1',
            kind: kind,
            workspace: 'w1',
          );
          d = addTab(d, 't2', 'q1');
          d = ok(d.activateTab('t1'));
          final r = d.splitPane(
            'p1',
            direction,
            view('p2', kind: 'terminal', workspace: 'w1'),
            splitId: 's1',
          );
          final after = ok(r);
          expect(r.paneId, 'p2');
          final root = after.tab('t1')!.root as SplitNode;
          expect(root.id, 's1');
          expect(root.direction, direction);
          expect(root.ratio, 0.5);
          expect(paneIds(root.first), ['p1']);
          expect(paneIds(root.second), ['p2']);
          expect(after.pane('p1')!.kind, kind, reason: 'old pane unchanged');
          expect(after.tab('t1')!.focusedPane, 'p2');
          expect(after.activeTab, 't1');
          expect(after.recent.first, 'p2');
          expect(after.pane('p2')!.workspace, 'w1');
          expectValid(after);
        });
      }
    }

    test('splitPane splits a pane inside a nested split', () {
      final d = abc();
      final after = split(d, 'C', 'D', splitId: 's3');
      expect(paneIds(after.tab('t1')!.root), ['A', 'B', 'C', 'D']);
      expect(after.splitNode('s2')!.second, isA<SplitNode>());
      expect(after.tab('t1')!.focusedPane, 'D');
    });

    test('splitPane is refused at 16 panes in the tab', () {
      final d = grid(1, 16);
      final r = d.splitPane(
        't0p3',
        SplitDirection.horizontal,
        view('x'),
        splitId: 'sx',
      );
      expect(r.refusal, LayoutRefusal.tabPaneLimit);
      expect(r.document, isNull);
      final ok15 = grid(1, 15);
      expect(
        ok15
            .splitPane(
              't0p3',
              SplitDirection.horizontal,
              view('x'),
              splitId: 'sx',
            )
            .isOk,
        isTrue,
      );
    });

    test('splitPane is refused at 128 panes in the document', () {
      final d = grid(16, 8);
      final r = d.splitPane(
        't0p0',
        SplitDirection.vertical,
        view('x'),
        splitId: 'sx',
      );
      expect(r.refusal, LayoutRefusal.paneLimit);
    });

    test('splitPane refuses an unknown pane and oversized state', () {
      final d = abc();
      expect(
        d
            .splitPane(
              'nope',
              SplitDirection.horizontal,
              view('x'),
              splitId: 'sx',
            )
            .refusal,
        LayoutRefusal.unknownPane,
      );
      expect(
        d
            .splitPane(
              'A',
              SplitDirection.horizontal,
              view('x', state: {'pad': 'x' * maxTabStateBytes}),
              splitId: 'sx',
            )
            .refusal,
        LayoutRefusal.stateTooLarge,
      );
    });

    test('splitPane on a pane of a background tab activates that tab', () {
      var d = addTab(const LayoutDocument.initial(), 't1', 'p1');
      d = addTab(d, 't2', 'p2');
      d = split(d, 'p1', 'p1b');
      expect(d.activeTab, 't1');
      expect(d.focusedPane, 'p1b');
      expect(d.recent, ['p1b', 'p2', 'p1']);
    });
  });

  group('close', () {
    for (final kind in kinds) {
      test('closing one of two panes gives its space to the sibling '
          '($kind)', () {
        var d = addTab(const LayoutDocument.initial(), 't1', 'L', kind: kind);
        d = split(d, 'L', 'R', kind: kind, splitId: 's1');
        final after = ok(d.closePane('R'));
        expect(after.tab('t1')!.root, isA<PaneNode>());
        expect(paneIds(after.tab('t1')!.root), ['L']);
        expect(after.tab('t1')!.focusedPane, 'L');
        expect(after.focusedPane, 'L');
        expect(after.recent, ['L']);
        expectValid(after);
      });
    }

    test('closing B in A beside (B above C) leaves A beside C', () {
      final d = ok(abc().setRatio('s1', 0.3).document!.closePane('B'));
      final root = d.tab('t1')!.root as SplitNode;
      expect(root.id, 's1');
      expect(root.ratio, 0.3, reason: 'the outer ratio is unchanged');
      expect(root.direction, SplitDirection.horizontal);
      expect(paneIds(root.first), ['A']);
      expect(paneIds(root.second), ['C']);
      expect(d.splitNode('s2'), isNull);
    });

    for (final kind in kinds) {
      test('closing focused A focuses the sibling\'s first pane, whatever '
          'recent says ($kind)', () {
        final d = abc(kind: kind);
        expect(d.recent, ['A', 'C', 'B'], reason: 'C is newer than B');
        final after = ok(d.closePane('A'));
        expect(paneIds(after.tab('t1')!.root), ['B', 'C']);
        expect(after.tab('t1')!.focusedPane, 'B');
        expect(after.recent, ['B', 'C']);
        expectValid(after);
      });
    }

    test('closing an unfocused pane keeps the tab\'s focus', () {
      final d = abc();
      final after = ok(d.closePane('C'));
      expect(after.tab('t1')!.focusedPane, 'A');
      expect(after.recent, ['A', 'B'], reason: 'order kept, id pruned');
      final other = ok(d.closePane('B'));
      expect(other.tab('t1')!.focusedPane, 'A');
    });

    test('closing the last pane of the active middle tab activates the '
        'right tab with its own focused pane', () {
      var d = threeTabs();
      d = split(d, 'p3', 'p3b'); // t3 now focuses p3b; t3 becomes active
      d = ok(d.activateTab('t2'));
      expect(d.recent.first, 'p2');
      final after = ok(d.closePane('p2'));
      expect(tabIds(after), ['t1', 't3']);
      expect(after.activeTab, 't3');
      expect(after.focusedPane, 'p3b');
      expect(after.recent.first, 'p3b');
      expect(after.recent, isNot(contains('p2')));
      expectValid(after);
    });

    test('closing the rightmost active tab activates its left neighbour '
        'with its own focused pane', () {
      var d = threeTabs();
      d = split(d, 'p2', 'p2b');
      d = ok(d.activateTab('t3'));
      final after = ok(d.closeTab('t3'));
      expect(tabIds(after), ['t1', 't2']);
      expect(after.activeTab, 't2');
      expect(after.focusedPane, 'p2b');
      expect(after.recent.first, 'p2b');
    });

    test('closing the only tab leaves activeTab null', () {
      final d = ok(
        addTab(
          const LayoutDocument.initial(),
          't1',
          'p1',
        ).selectWorkspace('w1').closeTab('t1'),
      );
      expect(d.tabs, isEmpty);
      expect(d.activeTab, isNull);
      expect(d.focusedPane, isNull);
      expect(d.recent, isEmpty);
      expect(d.selectedWorkspace, 'w1', reason: 'the selection stays');
      expectValid(d);
    });

    test('closing the leftmost active tab activates the one that was right '
        'of it', () {
      var d = threeTabs();
      d = ok(d.activateTab('t1'));
      final after = ok(d.closeTab('t1'));
      expect(after.activeTab, 't2');
    });

    test('closing a tab that is not active changes no focus', () {
      var d = threeTabs();
      d = split(d, 'p3', 'p3b');
      d = ok(d.activateTab('t2'));
      final before = d;
      final after = ok(d.closeTab('t3'));
      expect(after.activeTab, before.activeTab);
      expect(after.focusedPane, before.focusedPane);
      expect(after.recent, [
        for (final id in before.recent)
          if (id != 'p3' && id != 'p3b') id,
      ]);
      expect(tabIds(after), ['t1', 't2']);
      expectValid(after);
    });

    test('closing the focused pane of a background tab changes no window '
        'focus or history order', () {
      var d = addTab(const LayoutDocument.initial(), 't1', 'a');
      d = split(d, 'a', 'b');
      d = addTab(d, 't2', 'x');
      expect(d.tab('t1')!.focusedPane, 'b');
      final before = d;
      final after = ok(d.closePane('b'));
      expect(after.activeTab, 't2');
      expect(after.focusedPane, 'x');
      expect(after.tab('t1')!.focusedPane, 'a');
      expect(after.recent, [
        for (final id in before.recent)
          if (id != 'b') id,
      ]);
    });

    test('closing a tab removes all its panes from the document', () {
      final d = ok(abc().closeTab('t1'));
      expect(d.paneCount, 0);
      expect(d.recent, isEmpty);
    });

    test('unknown pane and tab are refused', () {
      final d = abc();
      expect(d.closePane('nope').refusal, LayoutRefusal.unknownPane);
      expect(d.closeTab('nope').refusal, LayoutRefusal.unknownTab);
    });
  });

  group('move', () {
    for (final kind in kinds) {
      test('movePaneToNewTab inserts the tab after its source and keeps '
          'the pane ($kind)', () {
        var d = addTab(
          const LayoutDocument.initial(),
          't1',
          'p1',
          kind: kind,
          workspace: 'w1',
        );
        d = split(d, 'p1', 'p2', kind: kind, workspace: 'w1');
        d = split(d, 'p2', 'p3', kind: kind, workspace: 'w1');
        d = addTab(d, 't2', 'q1');
        final before = d.pane('p2');
        final r = d.movePaneToNewTab('p2', newTabId: 'tn');
        final after = ok(r);
        expect(r.tabId, 'tn');
        expect(tabIds(after), ['t1', 'tn', 't2']);
        expect(paneIds(after.tab('t1')!.root), ['p1', 'p3']);
        expect(paneIds(after.tab('tn')!.root), ['p2']);
        expect(after.pane('p2'), same(before), reason: 'the pane is untouched');
        expect(after.activeTab, 'tn');
        expect(after.focusedPane, 'p2');
        expect(after.recent.first, 'p2');
        expect(bindings(after), bindings(d));
        expectValid(after);
      });
    }

    test('movePaneToNewTab is refused for a tab\'s only pane', () {
      final d = threeTabs();
      final r = d.movePaneToNewTab('p1', newTabId: 'tn');
      expect(r.refusal, LayoutRefusal.nothingToMove);
      expect(
        d.movePaneToNewTab('nope', newTabId: 'tn').refusal,
        LayoutRefusal.unknownPane,
      );
    });

    test('moving focused A out of A beside (B above C) focuses B in the '
        'source and A in the new tab', () {
      final d = abc();
      expect(d.focusedPane, 'A');
      final after = ok(d.movePaneToNewTab('A', newTabId: 'tn'));
      expect(after.tab('t1')!.focusedPane, 'B');
      expect(after.tab('tn')!.focusedPane, 'A');
      expect(after.activeTab, 'tn');
      expect(after.recent.first, 'A');
      expect(paneIds(after.tab('t1')!.root), ['B', 'C']);
      expect(after.tab('t1')!.root, isA<SplitNode>());
      expect(after.splitNode('s1'), isNull);
    });

    test('moving an unfocused pane out keeps the source tab\'s focus', () {
      final after = ok(abc().movePaneToNewTab('C', newTabId: 'tn'));
      expect(after.tab('t1')!.focusedPane, 'A');
      expect(after.tab('tn')!.focusedPane, 'C');
    });

    for (final direction in SplitDirection.values) {
      test('moveTabIntoSplit puts the moved root second and focuses its '
          'pane (${direction.name})', () {
        var d = addTab(
          const LayoutDocument.initial(),
          't1',
          'p1',
          workspace: 'w1',
        );
        d = split(d, 'p1', 'p1b', workspace: 'w1');
        d = addTab(d, 't2', 'ov', kind: 'workspace-overview', workspace: 'w2');
        d = addTab(d, 't3', 'mx', kind: 'mystery-kind');
        d = ok(d.activateTab('t1'));
        final oldRoot = d.tab('t1')!.root;
        final moved = d.tab('t2')!.root;
        final r = d.moveTabIntoSplit('t2', direction, splitId: 'sm');
        final after = ok(r);
        expect(tabIds(after), ['t1', 't3']);
        expect(after.activeTab, 't1');
        final root = after.tab('t1')!.root as SplitNode;
        expect(root.id, 'sm');
        expect(root.direction, direction);
        expect(root.ratio, 0.5);
        expect(root.first, same(oldRoot));
        expect(root.second, same(moved));
        expect(after.tab('t1')!.focusedPane, 'ov');
        expect(after.recent.first, 'ov');
        expect(bindings(after), bindings(d));
        expectValid(after);
      });
    }

    test('moveTabIntoSplit puts a terminal beside an overview', () {
      var d = addTab(const LayoutDocument.initial(), 't1', 'term');
      d = addTab(d, 't2', 'ov', kind: 'workspace-overview', workspace: 'w1');
      d = ok(d.activateTab('t1'));
      final after = ok(
        d.moveTabIntoSplit('t2', SplitDirection.horizontal, splitId: 'sm'),
      );
      expect(after.pane('term')!.kind, 'terminal');
      expect(after.pane('ov')!.kind, 'workspace-overview');
      expect(after.pane('ov')!.workspace, 'w1');
      expect(paneIds(after.tab('t1')!.root), ['term', 'ov']);
    });

    test('moveTabIntoSplit is refused for the active tab and unknown tab', () {
      final d = threeTabs();
      expect(
        d
            .moveTabIntoSplit('t2', SplitDirection.vertical, splitId: 'sm')
            .refusal,
        LayoutRefusal.nothingToMove,
      );
      expect(
        d
            .moveTabIntoSplit('nope', SplitDirection.vertical, splitId: 'sm')
            .refusal,
        LayoutRefusal.unknownTab,
      );
    });

    test('moveTabIntoSplit over 16 panes is refused and changes nothing', () {
      final d = grid(2, 9);
      expect(d.activeTab, 't0');
      final r = d.moveTabIntoSplit(
        't1',
        SplitDirection.vertical,
        splitId: 'sm',
      );
      expect(r.refusal, LayoutRefusal.tabPaneLimit);
      expect(r.document, isNull);
      final fits = grid(2, 8);
      expect(
        fits
            .moveTabIntoSplit('t1', SplitDirection.vertical, splitId: 'sm')
            .isOk,
        isTrue,
      );
    });
  });

  group('focus and history', () {
    test('focusPane focuses the pane, activates its tab, fronts recent', () {
      var d = threeTabs();
      d = split(d, 'p1', 'p1b');
      d = ok(d.activateTab('t3'));
      final after = ok(d.focusPane('p1'));
      expect(after.activeTab, 't1');
      expect(after.tab('t1')!.focusedPane, 'p1');
      expect(after.recent.first, 'p1');
      expect(after.recent.toSet().length, after.recent.length);
      expect(d.focusPane('nope').refusal, LayoutRefusal.unknownPane);
    });

    test('activateTab shows the tab\'s own focused pane and fronts it', () {
      var d = threeTabs();
      d = split(d, 'p1', 'p1b');
      d = ok(d.activateTab('t3'));
      final after = ok(d.activateTab('t1'));
      expect(after.focusedPane, 'p1b');
      expect(after.recent.first, 'p1b');
      expect(d.activateTab('nope').refusal, LayoutRefusal.unknownTab);
    });

    test('setRatio clamps to 0.1..0.9 and leaves recent alone', () {
      final d = abc();
      expect(ok(d.setRatio('s1', 0.02)).splitNode('s1')!.ratio, 0.1);
      expect(ok(d.setRatio('s1', 0.97)).splitNode('s1')!.ratio, 0.9);
      expect(ok(d.setRatio('s2', 0.25)).splitNode('s2')!.ratio, 0.25);
      expect(ok(d.setRatio('s2', 0.25)).recent, d.recent);
      expect(d.setRatio('nope', 0.5).refusal, LayoutRefusal.unknownSplit);
    });

    test('the sidebar starts expanded and toggles', () {
      const d = LayoutDocument.initial();
      expect(d.sidebarCollapsed, isFalse);
      expect(d.setSidebarCollapsed(true).sidebarCollapsed, isTrue);
      expect(
        d.setSidebarCollapsed(true).setSidebarCollapsed(false).sidebarCollapsed,
        isFalse,
      );
    });
  });

  group('workspace selection', () {
    /// Tabs t1 (pane a1 of A), t2 (b2 of B), t3 (b3 of B, b3b of B).
    LayoutDocument workspaces() {
      var d = addTab(
        const LayoutDocument.initial(),
        't1',
        'a1',
        workspace: 'A',
      );
      d = addTab(d, 't2', 'b2', workspace: 'B');
      d = addTab(d, 't3', 'b3', workspace: 'B');
      d = split(d, 'b3', 'b3b', workspace: 'B');
      return ok(d.activateTab('t1'));
    }

    test('selectWorkspace focuses its first pane in recent and keeps every '
        'binding', () {
      var d = workspaces();
      d = ok(d.focusPane('b2'));
      d = ok(d.focusPane('b3b'));
      d = ok(d.focusPane('a1'));
      expect(d.recent, ['a1', 'b3b', 'b2', 'b3', ...d.recent.skip(4)]);
      final after = d.selectWorkspace('B');
      expect(after.selectedWorkspace, 'B');
      expect(after.activeTab, 't3');
      expect(after.focusedPane, 'b3b');
      expect(after.recent.first, 'b3b');
      expect(bindings(after), bindings(d));
      expectValid(after);
    });

    test('selectWorkspace without panes sets the selection only', () {
      final d = workspaces();
      final after = d.selectWorkspace('C');
      expect(after.selectedWorkspace, 'C');
      expect(after.activeTab, d.activeTab);
      expect(after.focusedPane, d.focusedPane);
      expect(after.recent, d.recent);
      expect(bindings(after), bindings(d));
    });

    test('with a sparse recent naming none of B\'s panes, the first pane in '
        'strip and tree order is focused', () {
      final base = workspaces();
      final sparse = base.copyWith(recent: ['a1']);
      expectValid(sparse);
      final after = sparse.selectWorkspace('B');
      expect(after.activeTab, 't2');
      expect(after.focusedPane, 'b2');
      expect(after.recent.first, 'b2');
      // The tree-order case: B's first pane in t3 is b3, not b3b.
      final onlyT3 = ok(sparse.closeTab('t2'))
          .copyWith(recent: <String>[])
          .selectWorkspace('B');
      expect(onlyT3.activeTab, 't3');
      expect(onlyT3.focusedPane, 'b3');
    });

    test('clearSelection nulls a selection naming the workspace only', () {
      final d = workspaces().selectWorkspace('B');
      expect(d.clearSelection('A').selectedWorkspace, 'B');
      final cleared = d.clearSelection('B');
      expect(cleared.selectedWorkspace, isNull);
      expect(cleared.recent, d.recent);
      expect(bindings(cleared), bindings(d));
    });

    test('repairSelection nulls an unknown workspace only', () {
      final d = workspaces().selectWorkspace('B');
      expect(d.repairSelection({'A', 'B'}).selectedWorkspace, 'B');
      final repaired = d.repairSelection({'A'});
      expect(repaired.selectedWorkspace, isNull);
      expect(repaired.recent, d.recent);
      expect(
        const LayoutDocument.initial().repairSelection({}).selectedWorkspace,
        isNull,
      );
    });
  });

  group('invariants', () {
    test('no operation writes a binding, changes an unknown-kind pane, or '
        'breaks validation', () {
      for (var seed = 1; seed <= 12; seed++) {
        _randomWalk(seed);
      }
    });
  });
}
