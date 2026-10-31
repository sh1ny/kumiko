import 'dart:async';
import 'dart:typed_data';

import 'package:desktop/src/launcher_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:host_protocol/host_protocol.dart';

CleanupState stateOf(int revision, {bool reconciling = false}) => CleanupState(
  reconciling: reconciling,
  revision: revision,
  unresolvedWorkspaces: 0,
  unresolvedUnits: 0,
);

class _Pipe implements ByteSink {
  final StreamController<List<int>> controller = StreamController();

  @override
  void add(List<int> data) => controller.add(Uint8List.fromList(data));

  @override
  Future<void> flush() => Future.value();
}

void main() {
  test('a refused terminal/attach closes both channels and asks the host to '
      'close the terminal', () async {
    final toHost = _Pipe();
    final toDesktop = _Pipe();
    final hostCalls = <String>[];
    late final Connection host;
    host = Connection(
      input: toHost.controller.stream,
      output: toDesktop,
      capabilities: const {Capability.terminal},
      onHello: (params, negotiated) => const HelloInfo.ready('host-1'),
      onRequest: (method, params) {
        hostCalls.add(method);
        switch (method) {
          case Method.terminalOpen:
            final ids = host.reserveChannels(2).ids;
            return TerminalOpenResult(
              terminalId: 't1',
              outputChannel: ids[0],
              inputChannel: ids[1],
            ).toJson();
          case Method.terminalAttach:
            // The host's attach timeout ran out while the desktop slept.
            throw RpcException(ErrorCode.invalidParams, 'unknown terminal t1');
          default:
            return <String, Object?>{};
        }
      },
    );
    final desktop = Connection(
      input: toDesktop.controller.stream,
      output: toHost,
      capabilities: const {Capability.terminal},
    );
    await desktop.hello();

    await expectLater(
      openTerminalChannels(
        desktop,
        const TerminalOpenParams(profileId: 'p', cols: 80, rows: 24),
      ),
      throwsA(isA<RpcException>()),
    );
    // Every desktop slot is free again.
    desktop.reserveChannels(maxChannels).release();
    expect(hostCalls, contains(Method.terminalClose));
    await desktop.close();
    await host.close();
  });

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
