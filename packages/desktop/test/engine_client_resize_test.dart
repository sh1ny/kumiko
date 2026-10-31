import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_alacritty/engine/engine_binding.dart';
import 'package:flutter_alacritty/engine/terminal_engine_client.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';
import 'package:flutter_test/flutter_test.dart';

/// The vendored engine client, where Kumiko patched it: an engine call in
/// flight across a resize.
void main() {
  late _Binding binding;
  late MirrorGrid grid;
  late TerminalEngineClient client;

  setUp(() {
    binding = _Binding();
    grid = MirrorGrid()..initializeEmpty(2, 4);
    client = TerminalEngineClient(
      binding: binding,
      grid: grid,
      schedule: (cb) => cb(),
    );
  });

  test('output taken before a resize does not undo it', () async {
    client.feed(Uint8List.fromList('x'.codeUnits));
    final drained = client.drainForTest();
    await pumpEventQueue();

    // The advance took its snapshot at 4 columns; the window grows to 6.
    client.resize(6, 2);
    expect(grid.columns, 6);
    binding.advanced.complete(binding.snapshot(4));
    await drained;

    expect(grid.columns, 6, reason: 'the stale 4-column snapshot is dropped');
  });

  test('a scroll taken before a resize does not undo it', () async {
    final pending = Completer<GridUpdate>();
    binding.scroll = pending;
    final scrolled = client.scrollLines(1);
    client.resize(6, 2);
    pending.complete(binding.snapshot(4));
    await scrolled;

    expect(grid.columns, 6);
  });
}

class _Binding extends Fake implements EngineBinding {
  final advanced = Completer<GridUpdate>();
  Completer<GridUpdate>? scroll;
  int columns = 4;

  GridUpdate snapshot(int columns) => GridUpdate(
    full: true,
    rows: 2,
    columns: columns,
    lines: [
      for (var row = 0; row < 2; row++)
        LineCells(
          line: row,
          codepoints: Uint32List(columns)..fillRange(0, columns, 32),
          fg: Uint32List(columns),
          bg: Uint32List(columns),
          flags: Uint16List(columns),
        ),
    ],
    cursorRow: 0,
    cursorCol: 0,
    cursorVisible: true,
  );

  @override
  Future<GridUpdate> advanceAndTakeDamage(Uint8List bytes) => advanced.future;

  @override
  Future<GridUpdate> scrollLines(int delta) => scroll!.future;

  @override
  void resize(int columns, int rows) => this.columns = columns;

  @override
  GridUpdate fullSnapshot() => snapshot(columns);

  @override
  GridUpdate fullSnapshotSearched() => snapshot(columns);

  @override
  bool searchIsActive() => false;

  @override
  void pumpEvents() {}
}
