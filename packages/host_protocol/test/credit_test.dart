import 'dart:async';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/sinks.dart';

Uint8List _bytes(int n, [int seed = 0]) =>
    Uint8List.fromList([for (var i = 0; i < n; i++) (i + seed) % 253]);

void main() {
  test('credit overrun is a protocol violation', () async {
    final input = StreamController<List<int>>();
    final output = RecordingSink();
    final connection = Connection(input: input.stream, output: output);
    connection.attachInbound(1);

    // The grant is announced to the sender.
    final grant = output.frames.single;
    expect(grant.kind, FrameKind.credit);
    expect(grant.creditBytes, channelWindow);

    // Exactly the window is fine.
    for (var i = 0; i < channelWindow ~/ maxFramePayload; i++) {
      input.add(encodeFrame(1, FrameKind.data, Uint8List(maxFramePayload)));
    }
    await settle();
    expect(connection.isClosed, isFalse);

    // One byte more is not.
    input.add(encodeFrame(1, FrameKind.data, Uint8List(1)));
    final reason = await connection.closed;
    expect(reason.kind, CloseReason.protocolViolation);
    await input.close();
  });

  test('data on a never-opened channel is a violation', () async {
    final input = StreamController<List<int>>();
    final connection = Connection(input: input.stream, output: RecordingSink());
    input.add(encodeFrame(9, FrameKind.data, Uint8List(1)));
    expect((await connection.closed).kind, CloseReason.protocolViolation);
    await input.close();
  });

  test('a never-opened channel below an open one is a violation', () async {
    for (final kind in [FrameKind.data, FrameKind.credit]) {
      final input = StreamController<List<int>>();
      final connection = Connection(
        input: input.stream,
        output: RecordingSink(),
      );
      connection.attachInbound(9).listen((_) {});
      final frame = kind == FrameKind.data
          ? encodeFrame(8, FrameKind.data, Uint8List(1))
          : encodeCredit(8, 1024);
      input.add(frame);
      final reason = await connection.closed.timeout(
        const Duration(seconds: 2),
        onTimeout: () => const CloseReason('none', 'still open'),
      );
      expect(reason.kind, CloseReason.protocolViolation, reason: '$kind');
      await connection.close();
      await input.close();
    }
  });

  test('frames for a closed channel are discarded', () async {
    final input = StreamController<List<int>>();
    final connection = Connection(input: input.stream, output: RecordingSink());
    connection.attachInbound(1).listen((_) {});
    connection.closeChannel(1).ignore();
    input.add(encodeFrame(1, FrameKind.data, Uint8List(1)));
    await settle();
    expect(connection.isClosed, isFalse);
    await connection.close();
    await input.close();
  });

  test('the 33rd open channel is refused with channel-cap', () {
    final connection = Connection(
      input: const Stream<List<int>>.empty(),
      output: RecordingSink(),
    );
    for (var i = 0; i < maxChannels; i++) {
      connection.openOutbound();
    }
    expect(
      connection.openOutbound,
      throwsA(
        isA<RpcException>().having(
          (e) => e.reason,
          'reason',
          ErrorCode.channelCap,
        ),
      ),
    );
  });

  test('a stalled consumer stalls only its own channel', () async {
    final (sender, receiver) = connectedPair(
      onRequestB: (method, params) => <String, Object?>{},
    );
    await sender.hello();

    final stalled = sender.openOutbound();
    final flowing = sender.openOutbound();
    final stalledData = _bytes(channelWindow * 2 + 5);
    final stalledReceived = <int>[];
    final stalledSub =
        receiver.attachInbound(stalled.id).listen(stalledReceived.addAll)
          ..pause();
    final flowingReceived = <int>[];
    receiver.attachInbound(flowing.id).listen(flowingReceived.addAll);

    final stalledWritten = stalled.write(stalledData);
    final flowingData = _bytes(3 * channelWindow, 7);
    await flowing.write(flowingData);

    // The other channel and control traffic continue.
    await sender.request('ping');
    await settle();
    expect(flowingReceived, flowingData);

    // The stalled channel stopped at its granted credit.
    expect(stalled.credit, 0);
    expect(stalledReceived, isEmpty);

    // Resuming delivers every byte exactly once, in order.
    stalledSub.resume();
    await stalledWritten;
    await settle();
    expect(stalledReceived, stalledData);
  });
}
