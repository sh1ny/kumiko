import 'dart:async';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/sinks.dart';

void main() {
  test(
    'retained input counts paused delivery and drains in byte order',
    () async {
      final (sender, receiver) = connectedPair();
      addTearDown(sender.close);
      addTearDown(receiver.close);
      await sender.hello();
      final writer = sender.openOutbound();
      var retained = 0;
      var peak = 0;
      final received = <int>[];
      final subscription =
          receiver
              .attachInbound(
                writer.id,
                onRetainedBytesChanged: (bytes) {
                  retained = bytes;
                  if (bytes > peak) peak = bytes;
                },
              )
              .listen(received.addAll)
            ..pause();
      final data = Uint8List.fromList([
        for (var i = 0; i < 3 * channelWindow; i++) i % 251,
      ]);
      var finished = false;
      final write = writer.write(data).then((_) => finished = true);
      write.ignore();
      await settle();
      expect(retained, channelWindow);
      expect(peak, channelWindow);
      expect(finished, isFalse, reason: 'host credit applies backpressure');
      expect(received, isEmpty);
      subscription.resume();
      await write;
      await settle();
      expect(retained, 0);
      expect(received, data);
      await subscription.cancel();
    },
  );

  test(
    'onListen staged bytes stay counted while delivery is paused and closed',
    () async {
      final input = StreamController<List<int>>();
      final connection = Connection(
        input: input.stream,
        output: RecordingSink(),
      );
      addTearDown(connection.close);
      addTearDown(input.close);
      var retained = 0;
      final stream = connection.attachInbound(
        1,
        onRetainedBytesChanged: (bytes) => retained = bytes,
      );
      final data = Uint8List.fromList([
        for (var i = 0; i < maxFramePayload; i++) i % 251,
      ]);
      for (var i = 0; i < channelWindow ~/ maxFramePayload; i++) {
        input.add(encodeFrame(1, FrameKind.data, data));
      }
      await settle();
      expect(retained, channelWindow, reason: 'queued before listening');
      final received = <int>[];
      late StreamSubscription<Uint8List> subscription;
      var pauseOnce = true;
      subscription = stream.listen((bytes) {
        received.addAll(bytes);
        if (pauseOnce) {
          pauseOnce = false;
          subscription.pause();
        }
      });
      await settle();
      final staged = channelWindow - maxFramePayload;
      expect(
        retained,
        staged,
        reason: 'onListen staged three pending deliveries',
      );
      // onListen returned credit for the staged window. That extra window
      // can arrive while the consumer is paused: count BOTH owners.
      for (var i = 0; i < channelWindow ~/ maxFramePayload; i++) {
        input.add(encodeFrame(1, FrameKind.data, data));
      }
      await settle();
      expect(connection.isClosed, isFalse);
      expect(retained, staged + channelWindow);
      await connection.close();
      expect(
        retained,
        staged,
        reason: 'close cannot discard controller-owned deliveries',
      );
      subscription.resume();
      await settle();
      expect(retained, 0);
      expect(received, [...data, ...data, ...data, ...data]);
      await subscription.cancel();
    },
  );

  for (final ending in ['cancel', 'close', 'error']) {
    test('retained input is released on $ending', () async {
      final input = StreamController<List<int>>();
      final connection = Connection(
        input: input.stream,
        output: RecordingSink(),
      );
      addTearDown(connection.close);
      addTearDown(input.close);
      var retained = 0;
      final subscription =
          connection
              .attachInbound(
                1,
                onRetainedBytesChanged: (bytes) => retained = bytes,
              )
              .listen((_) {})
            ..pause();
      input.add(encodeFrame(1, FrameKind.data, Uint8List(123)));
      await settle();
      expect(retained, 123);
      if (ending == 'cancel') {
        await subscription.cancel();
      } else if (ending == 'close') {
        await connection.close();
      } else {
        input.addError(StateError('transport failed'));
        await connection.closed;
      }
      expect(retained, 0);
      await subscription.cancel();
    });
  }
}
