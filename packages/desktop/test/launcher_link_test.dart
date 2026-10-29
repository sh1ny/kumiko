import 'dart:async';

import 'package:desktop/src/launcher_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:host_protocol/host_protocol.dart';

CleanupState stateOf(int revision, {bool reconciling = false}) => CleanupState(
  reconciling: reconciling,
  revision: revision,
  unresolvedWorkspaces: 0,
  unresolvedUnits: 0,
);

void main() {
  group('cleanup state replay', () {
    test('a late listener receives the newest state first', () async {
      final source = StreamController<CleanupState>(sync: true);
      final states = LatestCleanupState(source.stream);

      // The first consumer (the cleanup list) sees everything.
      final first = <CleanupState>[];
      states.stream.listen(first.add);
      source
        ..add(stateOf(1, reconciling: true))
        ..add(stateOf(2));
      await pumpEventQueue();

      // The workbench attaches after reconciliation ended.
      final late = <CleanupState>[];
      states.stream.listen(late.add);
      await pumpEventQueue();
      expect(late.map((s) => s.revision), [2]);
      expect(late.single.reconciling, isFalse);

      source.add(stateOf(3));
      await pumpEventQueue();
      expect(first.map((s) => s.revision), [1, 2, 3]);
      expect(late.map((s) => s.revision), [2, 3]);
      await source.close();
    });

    test('a listener before any state receives only live states', () async {
      final source = StreamController<CleanupState>(sync: true);
      final states = LatestCleanupState(source.stream);
      final seen = <CleanupState>[];
      states.stream.listen(seen.add);
      await pumpEventQueue();
      expect(seen, isEmpty);

      source.add(stateOf(1));
      await pumpEventQueue();
      expect(seen.map((s) => s.revision), [1]);
      await source.close();
    });
  });
}
