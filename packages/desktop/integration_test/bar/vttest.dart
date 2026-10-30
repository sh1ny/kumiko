import 'dart:io';

import 'probe.dart';

/// One vttest step: the key sent once the previous output went idle, and the
/// screen it leads to. Must match `STEPS` in `vttest/record.py`.
typedef VttestStep = ({String? key, String id});

/// vttest main menu items 1, 2 and 3, every screen (spike-results.md).
final List<VttestStep> vttestSteps = [
  (key: null, id: 'menu.0'),
  (key: '1\r', id: '1.1'),
  for (var i = 2; i <= 6; i++) (key: '\r', id: '1.$i'),
  (key: '\r', id: 'menu.1'),
  (key: '2\r', id: '2.1'),
  for (var i = 2; i <= 15; i++) (key: '\r', id: '2.$i'),
  (key: '\r', id: 'menu.2'),
  (key: '3\r', id: '3.1'),
  (key: '\r', id: 'menu.3'),
];

/// The screens that run but are not judged: what they test is outside the
/// bar (spike-results.md). Every other non-menu screen is judged.
const Set<String> vttestOutsideBar = {
  '1.2',
  '1.4',
  '2.3',
  '2.4',
  '2.5',
  '2.14',
};

/// What is wrong with the expected grids in [dir]: a judged screen without
/// one, or a screen outside the bar with one. Empty when they match.
List<String> vttestFixtureProblems(Directory dir) => [
  for (final s in vttestSteps)
    if (!s.id.startsWith('menu.'))
      if (vttestOutsideBar.contains(s.id) &&
          File('${dir.path}/${s.id}.txt').existsSync())
        '${s.id}: outside the bar but has an expected grid'
      else if (!vttestOutsideBar.contains(s.id) &&
          !File('${dir.path}/${s.id}.txt').existsSync())
        '${s.id}: judged but has no expected grid',
];

/// A judged screen's expected grid (`vttest/<id>.txt`): 24 rows of 80 cells,
/// the rows that are judged, and for some screens the expected attributes
/// (1 bold, 2 underline, 4 inverse; blink is outside the bar).
class ExpectedScreen {
  ExpectedScreen._(this.id, this.title, this.rows, this.judged, this.attrs);

  /// Reads `<dir>/<id>.txt`, or returns null when [id] is outside the bar.
  /// Throws a [StateError] when a judged screen has no expected grid.
  static ExpectedScreen? load(Directory dir, String id) {
    if (vttestOutsideBar.contains(id)) return null;
    final file = File('${dir.path}/$id.txt');
    if (!file.existsSync()) {
      throw StateError('vttest $id is judged but has no expected grid');
    }
    final lines = file.readAsStringSync().replaceAll('\r\n', '\n').split('\n');
    final title = lines[0].replaceFirst(RegExp(r'^# '), '');
    final spec = lines[1].replaceFirst('rows: ', '');
    List<String> grid(int from) => [
      for (var y = 0; y < 24; y++)
        lines[from + y].substring(1, lines[from + y].length - 1),
    ];
    final rows = grid(2);
    final judged = <int>{
      if (spec == 'all')
        for (var y = 0; y < 24; y++) y
      else
        for (final range in spec.split(','))
          for (
            var y = int.parse(range.split('-').first) - 1;
            y < int.parse(range.split('-').last);
            y++
          )
            y,
    };
    final attrs = lines.length > 27 && lines[26].startsWith('attrs')
        ? grid(27)
        : null;
    return ExpectedScreen._(id, title, rows, judged, attrs);
  }

  final String id;
  final String title;
  final List<String> rows;
  final Set<int> judged;
  final List<String>? attrs;

  /// The judged rows that differ from [grid], each with both versions.
  List<String> mismatches(BarProbe grid) {
    final actual = gridRows(grid);
    final actualAttrs = gridAttrs(grid);
    return [
      for (final y in judged.toList()..sort()) ...[
        if (actual[y] != rows[y])
          'row ${y + 1} text\n  want |${rows[y]}|\n  got  |${actual[y]}|',
        if (attrs != null && actualAttrs[y] != attrs![y])
          'row ${y + 1} attrs\n  want |${attrs![y]}|\n  got  |${actualAttrs[y]}|',
      ],
    ];
  }
}

/// The grid's text, one string of `columns` cells per row; a wide character's
/// spacer cell is left out. The engine keeps a tab in the first cell a tab
/// moved over, drawn blank, so it reads as a space.
List<String> gridRows(BarProbe grid) => [
  for (var y = 0; y < grid.rows; y++)
    String.fromCharCodes([
      for (var x = 0; x < grid.columns; x++)
        if (!grid.isSpacer(y, x))
          switch (grid.codepointAt(y, x)) {
            0 || 0x09 => 0x20,
            final c => c,
          },
    ]),
];

/// The grid's bold, underline and inverse flags as digits, as in the
/// expected files.
List<String> gridAttrs(BarProbe grid) => [
  for (var y = 0; y < grid.rows; y++)
    [for (var x = 0; x < grid.columns; x++) grid.attrsAt(y, x)].join(),
];
