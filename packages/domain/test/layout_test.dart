import 'dart:convert';

import 'package:domain/domain.dart';
import 'package:test/test.dart';

LayoutDocument ok(LayoutResult r) =>
    r.document ?? (throw StateError('refused: ${r.refusal}'));

LayoutDocument open(
  LayoutDocument d,
  String group,
  String tabId, {
  String kind = 'terminal',
  String? item,
  bool needs = false,
}) => ok(
  d.openOrFocus(
    group,
    kind,
    item ?? tabId,
    needsWorkspace: needs,
    newTabId: tabId,
  ),
);

Map<String, String?> bindings(LayoutDocument d) => {
  for (final t in d.tabs) t.id: t.workspace,
};

String enc(LayoutDocument d) => encodeLayout(d);

/// Grows a document to [n] groups by repeatedly splitting `g1`.
LayoutDocument withGroups(int n) {
  var d = LayoutDocument.initial('g1');
  for (var i = 2; i <= n; i++) {
    d = ok(d.split('g1', SplitDirection.horizontal, 'g$i', 's$i'));
  }
  return d;
}

Map<String, Object?> baseJson() {
  var d = LayoutDocument.initial('g1');
  d = ok(d.setGroupContext('g1', 'w1'));
  d = open(d, 'g1', 't1', kind: 'editor', item: 'file:a');
  return jsonDecode(enc(d)) as Map<String, Object?>;
}

Map<String, Object?> firstGroup(Map<String, Object?> doc) =>
    doc['root'] as Map<String, Object?>;

Map<String, Object?> firstTab(Map<String, Object?> doc) =>
    (firstGroup(doc)['tabs'] as List).first as Map<String, Object?>;

void expectInvalid(Object? json, [Pattern? reason]) {
  expect(
    () => layoutFromJson(json),
    throwsA(
      isA<LayoutInvalid>().having(
        (e) => e.reason,
        'reason',
        reason == null ? isNotEmpty : contains(reason),
      ),
    ),
  );
}

void main() {
  group('split', () {
    test('creates a focused empty group beside it with the same context', () {
      var d = ok(LayoutDocument.initial('g1').setGroupContext('g1', 'w1'));
      d = ok(d.split('g1', SplitDirection.vertical, 'g2', 's1'));
      expect(d.groupCount, 2);
      final root = d.root as SplitNode;
      expect(root.direction, SplitDirection.vertical);
      expect(root.ratio, 0.5);
      expect(d.focusedGroup, 'g2');
      expect(d.group('g2')!.context, 'w1');
      expect(d.group('g2')!.tabs, isEmpty);
    });

    test('split refused at 16 groups', () {
      final d = withGroups(16);
      expect(d.groupCount, 16);
      final r = d.split('g1', SplitDirection.horizontal, 'g17', 's17');
      expect(r.document, isNull);
      expect(r.refusal, LayoutRefusal.groupLimit);
      expect(enc(d), enc(withGroups(16)));
    });

    test('unknown group is refused', () {
      final r = LayoutDocument.initial(
        'g1',
      ).split('nope', SplitDirection.horizontal, 'g2', 's1');
      expect(r.refusal, LayoutRefusal.unknownGroup);
    });
  });

  group('move and close', () {
    LayoutDocument twoGroups() {
      var d = ok(LayoutDocument.initial('g1').setGroupContext('g1', 'w1'));
      d = open(d, 'g1', 't1');
      d = open(d, 'g1', 't2');
      d = ok(d.split('g1', SplitDirection.horizontal, 'g2', 's1'));
      return ok(d.setGroupContext('g2', 'w2'));
    }

    test('move keeps tab id and workspace binding', () {
      final d = twoGroups();
      final before = bindings(d);
      final moved = ok(d.moveTab('t1', 'g2'));
      expect(bindings(moved), before);
      expect(moved.group('g2')!.tabs.map((t) => t.id), ['t1']);
      expect(moved.group('g2')!.active, 't1');
      expect(moved.group('g1')!.tabs.map((t) => t.id), ['t2']);
      expect(moved.group('g1')!.active, 't2');
      expect(moved.tab('t1')!.workspace, 'w1');
      expect(moved.focusedGroup, 'g2');
      expect(moved.recent.first, 't1');
    });

    test('moving the only tab out removes the emptied group', () {
      var d = LayoutDocument.initial('g1');
      d = open(d, 'g1', 't1');
      d = ok(d.split('g1', SplitDirection.horizontal, 'g2', 's1'));
      d = ok(d.moveTab('t1', 'g2'));
      expect(d.groupCount, 1);
      expect(d.root, isA<TabGroup>());
      expect(d.focusedGroup, 'g2');
    });

    test('closing the last tab of a split group removes the group and its '
        'split', () {
      var d = LayoutDocument.initial('g1');
      d = open(d, 'g1', 't1');
      d = ok(d.split('g1', SplitDirection.horizontal, 'g2', 's1'));
      d = open(d, 'g2', 't2');
      d = ok(d.closeTab('t2'));
      expect(d.groupCount, 1);
      expect(d.root, isA<TabGroup>());
      expect((d.root as TabGroup).id, 'g1');
      expect(d.focusedGroup, 'g1');
      expect(d.recent, ['t1']);
    });

    test('closing the last tab of the only group keeps the group', () {
      var d = open(LayoutDocument.initial('g1'), 'g1', 't1');
      d = ok(d.closeTab('t1'));
      expect(d.groupCount, 1);
      expect(d.group('g1')!.active, isNull);
    });

    test('closing the active tab activates the most recent remaining', () {
      var d = open(LayoutDocument.initial('g1'), 'g1', 't1');
      d = open(d, 'g1', 't2');
      d = open(d, 'g1', 't3');
      d = ok(d.activateTab('t1'));
      d = ok(d.activateTab('t3'));
      d = ok(d.closeTab('t3'));
      expect(d.group('g1')!.active, 't1');
      expect(d.recent, ['t1', 't2']);
    });

    test('unknown tab is refused', () {
      expect(
        LayoutDocument.initial('g1').closeTab('x').refusal,
        LayoutRefusal.unknownTab,
      );
      expect(
        LayoutDocument.initial('g1').moveTab('x', 'g1').refusal,
        LayoutRefusal.unknownTab,
      );
    });
  });

  group('open or focus', () {
    test('binds to the group context and focuses the group', () {
      var d = ok(LayoutDocument.initial('g1').setGroupContext('g1', 'w1'));
      d = open(d, 'g1', 't1', needs: true);
      expect(d.tab('t1')!.workspace, 'w1');
      expect(d.group('g1')!.active, 't1');
      expect(d.focusedGroup, 'g1');
      expect(d.recent, ['t1']);
    });

    test('a kind needing a workspace is refused in a group without one', () {
      final d = LayoutDocument.initial('g1');
      final r = d.openOrFocus(
        'g1',
        'editor',
        'a',
        needsWorkspace: true,
        newTabId: 't1',
      );
      expect(r.refusal, LayoutRefusal.needsWorkspace);
      expect(d.tabCount, 0);
    });

    test('a kind not needing a workspace opens unbound', () {
      final d = open(LayoutDocument.initial('g1'), 'g1', 't1');
      expect(d.tab('t1')!.workspace, isNull);
    });

    test('open refused at 128 tabs', () {
      var d = ok(LayoutDocument.initial('g1').setGroupContext('g1', 'w1'));
      for (var i = 0; i < 128; i++) {
        d = open(d, 'g1', 't$i');
      }
      expect(d.tabCount, 128);
      final r = d.openOrFocus(
        'g1',
        'terminal',
        'extra',
        needsWorkspace: false,
        newTabId: 'tx',
      );
      expect(r.refusal, LayoutRefusal.tabLimit);
      expect(r.document, isNull);
    });

    test('open-or-focus focuses the existing item tab in another group', () {
      var d = ok(LayoutDocument.initial('g1').setGroupContext('g1', 'w1'));
      d = open(d, 'g1', 't1', kind: 'editor', item: 'file:a');
      d = ok(d.split('g1', SplitDirection.horizontal, 'g2', 's1'));
      expect(d.focusedGroup, 'g2');
      final r = d.openOrFocus(
        'g2',
        'editor',
        'file:a',
        needsWorkspace: true,
        newTabId: 'tNew',
      );
      final after = ok(r);
      expect(r.tabId, 't1');
      expect(after.tabCount, 1);
      expect(after.focusedGroup, 'g1');
      expect(after.group('g1')!.active, 't1');
    });

    test('focusing an existing tab still works at the tab limit', () {
      var d = ok(LayoutDocument.initial('g1').setGroupContext('g1', 'w1'));
      for (var i = 0; i < 128; i++) {
        d = open(d, 'g1', 't$i');
      }
      final r = d.openOrFocus(
        'g1',
        'terminal',
        't5',
        needsWorkspace: false,
        newTabId: 'tx',
      );
      expect(r.tabId, 't5');
      expect(ok(r).recent.first, 't5');
    });

    test('open-or-focus after close creates a tab in the launcher\'s group', () {
      var d = ok(LayoutDocument.initial('g1').setGroupContext('g1', 'w1'));
      d = open(d, 'g1', 't1', kind: 'editor', item: 'file:a');
      d = ok(d.split('g1', SplitDirection.horizontal, 'g2', 's1'));
      d = ok(d.closeTab('t1'));
      d = ok(
        d.openOrFocus(
          'g2',
          'editor',
          'file:a',
          needsWorkspace: true,
          newTabId: 't2',
        ),
      );
      expect(d.tabCount, 1);
      expect(d.groupOf('t2')!.id, 'g2');
      expect(d.focusedGroup, 'g2');
    });

    test('items of different kinds do not collide', () {
      var d = ok(LayoutDocument.initial('g1').setGroupContext('g1', 'w1'));
      d = open(d, 'g1', 't1', kind: 'editor', item: 'x');
      d = open(d, 'g1', 't2', kind: 'diff', item: 'x');
      expect(d.tabCount, 2);
    });

    test('a null item always opens a new tab', () {
      var d = LayoutDocument.initial('g1');
      for (final id in ['t1', 't2']) {
        d = ok(
          d.openOrFocus(
            'g1',
            'terminal',
            null,
            needsWorkspace: false,
            newTabId: id,
          ),
        );
      }
      expect(d.tabCount, 2);
    });

    test('oversized state is refused', () {
      final r = LayoutDocument.initial('g1').openOrFocus(
        'g1',
        'terminal',
        null,
        needsWorkspace: false,
        newTabId: 't1',
        state: {'k': 'x' * 4089},
      );
      expect(r.refusal, LayoutRefusal.stateTooLarge);
    });
  });

  group('select workspace', () {
    LayoutDocument scenario() {
      var d = ok(LayoutDocument.initial('g1').setGroupContext('g1', 'w1'));
      d = open(d, 'g1', 't1');
      d = ok(d.split('g1', SplitDirection.horizontal, 'g2', 's1'));
      d = ok(d.setGroupContext('g2', 'w2'));
      d = open(d, 'g2', 't2');
      d = ok(d.setGroupContext('g2', 'w1'));
      d = open(d, 'g2', 't3');
      return d;
    }

    test('select workspace focuses its most recent tab and keeps all '
        'bindings', () {
      var d = scenario();
      expect(bindings(d), {'t1': 'w1', 't2': 'w2', 't3': 'w1'});
      d = ok(d.activateTab('t1'));
      final before = bindings(d);
      final sel = d.selectWorkspace('w1');
      expect(sel.focusedGroup, 'g1');
      expect(sel.group('g1')!.active, 't1');
      expect(sel.recent.first, 't1');
      expect(bindings(sel), before);

      final sel2 = d.selectWorkspace('w2');
      expect(sel2.focusedGroup, 'g2');
      expect(sel2.group('g2')!.active, 't2');
      expect(sel2.group('g2')!.context, 'w2');
      expect(bindings(sel2), before);

      // After activating t3, w1's most recent tab is t3.
      final d3 = ok(d.activateTab('t3')).selectWorkspace('w1');
      expect(d3.group('g2')!.active, 't3');
      expect(d3.focusedGroup, 'g2');
    });

    test('select workspace without tabs sets the focused group context '
        'only', () {
      final d = scenario();
      final before = bindings(d);
      final sel = d.selectWorkspace('w9');
      expect(sel.group(d.focusedGroup)!.context, 'w9');
      expect(sel.focusedGroup, d.focusedGroup);
      expect(bindings(sel), before);
      expect(sel.recent, d.recent);
      final other = d.groups.firstWhere((g) => g.id != d.focusedGroup);
      expect(sel.group(other.id)!.context, other.context);
    });
  });

  test('no operation changes a tab\'s binding (all ops)', () {
    var d = ok(LayoutDocument.initial('g1').setGroupContext('g1', 'w1'));
    d = open(d, 'g1', 't1');
    d = open(d, 'g1', 't2');
    d = ok(d.split('g1', SplitDirection.horizontal, 'g2', 's1'));
    d = ok(d.setGroupContext('g2', 'w2'));
    d = open(d, 'g2', 't3');
    d = open(d, 'g2', 't4', kind: 'editor', item: 'f');
    final expected = bindings(d);
    expect(expected, {'t1': 'w1', 't2': 'w1', 't3': 'w2', 't4': 'w2'});

    final steps = <String, LayoutDocument Function(LayoutDocument)>{
      'split': (x) => ok(x.split('g1', SplitDirection.vertical, 'g3', 's2')),
      'move': (x) => ok(x.moveTab('t1', 'g2')),
      'activate': (x) => ok(x.activateTab('t2')),
      'focusGroup': (x) => ok(x.focusGroup('g2')),
      'selectWorkspace': (x) => x.selectWorkspace('w2'),
      'selectWorkspaceNone': (x) => x.selectWorkspace('nope'),
      'setGroupContext': (x) => ok(x.setGroupContext('g1', 'w7')),
      'setRatio': (x) => ok(x.setRatio('s1', 0.3)),
      'collapse': (x) => x.setSidebarCollapsed(true),
      'openExisting': (x) => ok(
        x.openOrFocus(
          'g1',
          'editor',
          'f',
          needsWorkspace: true,
          newTabId: 'zz',
        ),
      ),
      'openNew': (x) => open(x, 'g1', 'tn'),
      'clearContext': (x) => x.clearContext('w2'),
      'clearContextBound': (x) => x.clearContext('w1'),
      'repair': (x) => x.repairContexts({'w1'}),
      'repairNone': (x) => x.repairContexts({}),
    };
    for (final e in steps.entries) {
      final after = e.value(d);
      for (final t in after.tabs) {
        if (expected.containsKey(t.id)) {
          expect(
            t.workspace,
            expected[t.id],
            reason: 'op ${e.key} changed ${t.id}',
          );
        }
      }
    }
    // Closing other tabs.
    final closed = ok(ok(d.closeTab('t3')).closeTab('t1'));
    expect(closed.tab('t2')!.workspace, 'w1');
    expect(closed.tab('t4')!.workspace, 'w2');
    // Chained moves and splits.
    var c = ok(d.moveTab('t3', 'g1'));
    c = ok(c.split('g1', SplitDirection.horizontal, 'g9', 's9'));
    c = ok(c.moveTab('t2', 'g9'));
    expect(bindings(c), expected);
  });

  group('context', () {
    test('clearContext nulls every group context equal to the id', () {
      var d = ok(LayoutDocument.initial('g1').setGroupContext('g1', 'w1'));
      d = ok(d.split('g1', SplitDirection.horizontal, 'g2', 's1'));
      d = ok(d.split('g2', SplitDirection.horizontal, 'g3', 's2'));
      d = ok(d.setGroupContext('g3', 'w2'));
      final c = d.clearContext('w1');
      expect(c.group('g1')!.context, isNull);
      expect(c.group('g2')!.context, isNull);
      expect(c.group('g3')!.context, 'w2');
    });

    test('clearContext leaves tab bindings alone', () {
      var d = ok(LayoutDocument.initial('g1').setGroupContext('g1', 'w1'));
      d = open(d, 'g1', 't1');
      final c = d.clearContext('w1');
      expect(c.tab('t1')!.workspace, 'w1');
      expect(c.group('g1')!.context, isNull);
    });

    test('repairContexts nulls contexts that are not known', () {
      var d = ok(LayoutDocument.initial('g1').setGroupContext('g1', 'gone'));
      d = ok(d.split('g1', SplitDirection.horizontal, 'g2', 's1'));
      d = ok(d.setGroupContext('g2', 'w2'));
      final r = d.repairContexts({'w2'});
      expect(r.group('g1')!.context, isNull);
      expect(r.group('g2')!.context, 'w2');
    });

    test('boundWorkspaces lists tab bindings only', () {
      var d = ok(LayoutDocument.initial('g1').setGroupContext('g1', 'w1'));
      d = open(d, 'g1', 't1');
      d = ok(d.setGroupContext('g1', 'w2'));
      expect(d.boundWorkspaces, {'w1'});
      expect(LayoutDocument.initial('g1').boundWorkspaces, isEmpty);
    });
  });

  group('ratio and sidebar', () {
    test('setRatio clamps to 0.1..0.9', () {
      var d = ok(
        LayoutDocument.initial(
          'g1',
        ).split('g1', SplitDirection.horizontal, 'g2', 's1'),
      );
      expect((ok(d.setRatio('s1', 0.01)).root as SplitNode).ratio, 0.1);
      expect((ok(d.setRatio('s1', 5)).root as SplitNode).ratio, 0.9);
      expect((ok(d.setRatio('s1', 0.7)).root as SplitNode).ratio, 0.7);
      expect(d.setRatio('nope', 0.5).refusal, LayoutRefusal.unknownSplit);
    });

    test('sidebar state toggles and starts expanded', () {
      final d = LayoutDocument.initial('g1');
      expect(d.sidebarCollapsed, isFalse);
      expect(d.setSidebarCollapsed(true).sidebarCollapsed, isTrue);
    });
  });

  group('codec', () {
    test('codec round-trips sidebar state', () {
      for (final collapsed in [true, false]) {
        final d = LayoutDocument.initial('g1').setSidebarCollapsed(collapsed);
        final back = decodeLayout(enc(d));
        expect(back.sidebarCollapsed, collapsed);
        expect(enc(back), enc(d));
      }
    });

    test('round-trips a full document', () {
      var d = ok(LayoutDocument.initial('g1').setGroupContext('g1', 'w1'));
      d = open(d, 'g1', 't1', kind: 'editor', item: 'file:a');
      d = ok(d.split('g1', SplitDirection.vertical, 'g2', 's1'));
      d = ok(d.setRatio('s1', 0.25));
      final s = enc(d);
      expect(jsonDecode(enc(decodeLayout(s))), jsonDecode(s));
      final j = jsonDecode(s) as Map<String, Object?>;
      expect(j['format'], 1);
      expect(j['focusedGroup'], 'g2');
      expect(j['sidebar'], {'collapsed': false});
      expect((j['root'] as Map)['type'], 'split');
    });

    test('unknown kind round-trips unchanged', () {
      final json = baseJson();
      final tab = firstTab(json);
      tab['kind'] = 'future-kind';
      tab['state'] = {
        'a': [
          1,
          2.5,
          {'b': null},
          'x',
        ],
        'z': true,
      };
      final s = jsonEncode(json);
      final back = decodeLayout(s);
      expect(back.tab('t1')!.kind, 'future-kind');
      expect(jsonDecode(enc(back)), jsonDecode(s));
    });

    test('null item and null workspace round-trip', () {
      final json = baseJson();
      final tab = firstTab(json);
      tab['item'] = null;
      tab['workspace'] = null;
      final back = decodeLayout(jsonEncode(json));
      expect(back.tab('t1')!.item, isNull);
      expect(back.tab('t1')!.workspace, isNull);
      expect(jsonDecode(enc(back)), json);
    });

    test('invalid JSON text reports a reason', () {
      expect(() => decodeLayout('{nope'), throwsA(isA<LayoutInvalid>()));
    });
  });

  group('validation', () {
    test('format other than 1 is unsupported', () {
      final j = baseJson()..['format'] = 2;
      expectInvalid(j, 'unsupported layout format 2');
    });

    test('non-object document is invalid', () {
      expectInvalid([], null);
    });

    test('duplicate ids are invalid', () {
      final j = baseJson();
      firstTab(j)['id'] = 'g1';
      expectInvalid(j, 'duplicate');
    });

    test('active must be null iff group has no tabs', () {
      final a = baseJson();
      firstGroup(a)['active'] = null;
      expectInvalid(a, 'active');
      final b = baseJson();
      firstGroup(b)['active'] = 'other';
      expectInvalid(b, 'active');
      final c = baseJson();
      firstGroup(c)['tabs'] = [];
      c['recent'] = [];
      expectInvalid(c, 'active');
    });

    test('focusedGroup must exist', () {
      final j = baseJson()..['focusedGroup'] = 'missing';
      expectInvalid(j, 'focusedGroup');
    });

    test('recent must name existing tabs without duplicates', () {
      final a = baseJson()..['recent'] = ['t1', 't1'];
      expectInvalid(a, 'recent');
      final b = baseJson()..['recent'] = ['ghost'];
      expectInvalid(b, 'recent');
    });

    test('state must be an object', () {
      final j = baseJson();
      firstTab(j)['state'] = [1];
      expectInvalid(j, 'state');
    });

    test('sidebar and node types are checked', () {
      expectInvalid(baseJson()..['sidebar'] = {'collapsed': 'yes'}, 'sidebar');
      final j = baseJson();
      firstGroup(j)['type'] = 'blob';
      expectInvalid(j, 'type');
    });

    test('unknown direction is invalid', () {
      final j = jsonDecode(
        enc(
          ok(
            LayoutDocument.initial(
              'g1',
            ).split('g1', SplitDirection.horizontal, 'g2', 's1'),
          ),
        ),
      ) as Map<String, Object?>;
      (j['root'] as Map)['direction'] = 'diagonal';
      expectInvalid(j, 'direction');
    });

    group('bounds', () {
      void idCase(String label, void Function(Map<String, Object?>, String) set) {
        test('$label: 64 bytes ok, 65 invalid, empty invalid', () {
          final at = baseJson();
          set(at, 'a' * 64);
          expect(() => layoutFromJson(at), returnsNormally);
          final over = baseJson();
          set(over, 'a' * 65);
          expectInvalid(over);
          final empty = baseJson();
          set(empty, '');
          expectInvalid(empty);
        });
      }

      idCase('tab id', (j, v) {
        firstTab(j)['id'] = v;
        j['recent'] = [v];
        firstGroup(j)['active'] = v;
      });
      idCase('group id', (j, v) {
        firstGroup(j)['id'] = v;
        j['focusedGroup'] = v;
      });
      idCase('kind', (j, v) => firstTab(j)['kind'] = v);
      idCase('workspace ref', (j, v) => firstTab(j)['workspace'] = v);
      idCase('context', (j, v) => firstGroup(j)['context'] = v);

      test('multi-byte ids are measured in UTF-8 bytes', () {
        final at = baseJson();
        firstTab(at)['kind'] = 'é' * 32; // 64 bytes
        expect(() => layoutFromJson(at), returnsNormally);
        final over = baseJson();
        firstTab(over)['kind'] = 'é' * 33; // 66 bytes
        expectInvalid(over);
      });

      test('item: 4096 bytes ok, 4097 invalid', () {
        final at = baseJson();
        firstTab(at)['item'] = 'a' * 4096;
        expect(() => layoutFromJson(at), returnsNormally);
        final over = baseJson();
        firstTab(over)['item'] = 'a' * 4097;
        expectInvalid(over, 'item');
      });

      test('state: 4096 encoded bytes ok, 4097 invalid', () {
        // {"k":"..."} adds 8 bytes around the payload.
        final at = baseJson();
        firstTab(at)['state'] = {'k': 'x' * 4088};
        expect(utf8.encode(jsonEncode(firstTab(at)['state'])).length, 4096);
        expect(() => layoutFromJson(at), returnsNormally);
        final over = baseJson();
        firstTab(over)['state'] = {'k': 'x' * 4089};
        expectInvalid(over, 'state');
      });

      test('document: 262144 bytes ok, 262145 invalid', () {
        final s = jsonEncode(baseJson());
        final pad = maxDocumentBytes - utf8.encode(s).length;
        expect(() => decodeLayout(s + ' ' * pad), returnsNormally);
        expect(
          () => decodeLayout(s + ' ' * (pad + 1)),
          throwsA(isA<LayoutInvalid>()),
        );
        expect(maxDocumentBytes, 262144);
      });

      test('ratio: 0.1 and 0.9 ok, 0.09 and 0.91 invalid', () {
        Map<String, Object?> withRatio(Object r) {
          final j = jsonDecode(
            enc(
              ok(
                LayoutDocument.initial(
                  'g1',
                ).split('g1', SplitDirection.horizontal, 'g2', 's1'),
              ),
            ),
          ) as Map<String, Object?>;
          (j['root'] as Map)['ratio'] = r;
          return j;
        }

        expect(() => layoutFromJson(withRatio(0.1)), returnsNormally);
        expect(() => layoutFromJson(withRatio(0.9)), returnsNormally);
        expectInvalid(withRatio(0.09), 'ratio');
        expectInvalid(withRatio(0.91), 'ratio');
        expectInvalid(withRatio('half'), 'ratio');
      });

      test('groups: 16 ok, 17 invalid', () {
        final d = withGroups(16);
        expect(() => decodeLayout(enc(d)), returnsNormally);
        final j = jsonDecode(enc(d)) as Map<String, Object?>;
        j['root'] = {
          'type': 'split',
          'id': 's99',
          'direction': 'horizontal',
          'ratio': 0.5,
          'first': j['root'],
          'second': {
            'type': 'group',
            'id': 'g99',
            'context': null,
            'tabs': <Object?>[],
            'active': null,
          },
        };
        expectInvalid(j, 'group');
      });

      test('tabs: 128 ok, 129 invalid', () {
        var d = LayoutDocument.initial('g1');
        for (var i = 0; i < 128; i++) {
          d = open(d, 'g1', 't$i');
        }
        expect(() => decodeLayout(enc(d)), returnsNormally);
        final j = jsonDecode(enc(d)) as Map<String, Object?>;
        (firstGroup(j)['tabs'] as List).add({
          'id': 'extra',
          'kind': 'terminal',
          'workspace': null,
          'item': null,
          'state': <String, Object?>{},
        });
        j['recent'] = [...(j['recent'] as List), 'extra'];
        expectInvalid(j, 'tab');
      });
    });
  });
}
