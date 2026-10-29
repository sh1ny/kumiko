import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

/// Qualification of the wire protocol against the real test host over real
/// pipes (design D6, D7, Resource Bounds): control latency under a saturating
/// channel, credit stalls, resume, and the channel and buffering bounds.
///
/// The test host's `test/channel.open` streams byte `i % 251` at stream
/// offset `i`, never faster than the credit the desktop grants.

const int _window = channelWindow;

/// The data bytes the host put on each channel, read off the pipe before the
/// connection sees them, and what the desktop's consumers took of them.
///
/// The host sends only against granted credit and the desktop grants credit
/// only for bytes its consumer took, so `sent - consumed` is what the host
/// has emitted that the desktop has not yet taken: it is bounded by the
/// window exactly when the host respects its credit.
class Wire {
  final FrameDecoder _decoder = FrameDecoder();
  final Map<int, int> sent = {};
  final Map<int, int> consumed = {};

  /// The largest `sent - consumed` seen per channel.
  final Map<int, int> peak = {};

  void tap(List<int> chunk) {
    for (final frame in _decoder.add(chunk)) {
      if (frame.channel == controlChannel || frame.kind != FrameKind.data) {
        continue;
      }
      final id = frame.channel;
      sent[id] = (sent[id] ?? 0) + frame.payload.length;
      final out = outstanding(id);
      if (out > (peak[id] ?? 0)) peak[id] = out;
    }
  }

  void took(int channel, int bytes) =>
      consumed[channel] = (consumed[channel] ?? 0) + bytes;

  int outstanding(int channel) =>
      (sent[channel] ?? 0) - (consumed[channel] ?? 0);

  int get totalSent => sent.values.fold(0, (a, b) => a + b);
}

/// One data channel's consumer on the desktop side.
class Consumer {
  Consumer(this.id, this.subscription);

  final int id;
  final StreamSubscription<Uint8List> subscription;
  int received = 0;

  /// Stream offsets whose byte was not `offset % 251`, or the first such.
  int? firstMismatch;
}

class Rig {
  Rig(this.host, this.wire);

  final RawHost host;
  final Wire wire;
  final List<Consumer> consumers = [];

  Connection get connection => host.connection;

  static Future<Rig> start(Directory profile, {bool tapWire = true}) async {
    final wire = Wire();
    final host = await RawHost.start(profile, tap: tapWire ? wire.tap : null);
    final result = await host.hello();
    expect(result.capabilities, contains(Capability.testChannels));
    return Rig(host, wire);
  }

  /// Asks the host for a channel streaming at [rate] (0: as fast as credit
  /// allows) and attaches a consumer. A [paused] consumer takes nothing.
  Future<Consumer> open({
    int rate = 0,
    bool paused = false,
    int writeBytes = TestChannelOpenParams.defaultWriteBytes,
  }) async {
    final reply = await connection.request(
      Method.testChannelOpen,
      TestChannelOpenParams(rate, writeBytes: writeBytes).toJson(),
    );
    final id = TestChannelOpenResult.fromJson(reply as Json).channel;
    late final Consumer consumer;
    final subscription = connection.attachInbound(id).listen((bytes) {
      var offset = consumer.received;
      if (consumer.firstMismatch == null) {
        for (var i = 0; i < bytes.length; i++) {
          if (bytes[i] != (offset + i) % 251) {
            consumer.firstMismatch = offset + i;
            break;
          }
        }
      }
      consumer.received += bytes.length;
      wire.took(id, bytes.length);
    });
    consumer = Consumer(id, subscription);
    if (paused) subscription.pause();
    consumers.add(consumer);
    return consumer;
  }

  /// One cheap control round-trip, answered by the host without a store or a
  /// process.
  Future<void> control() => connection.request(
    Method.testFaultSet,
    TestFaultSetParams(TestFault.killFails, enabled: false).toJson(),
  );

  Future<void> dispose() async {
    for (final c in consumers) {
      unawaited(c.subscription.cancel());
    }
    await host.dispose();
  }
}

void main() {
  setUpAll(buildTestHost);

  late Directory profile;
  Rig? rig;

  setUp(() => profile = tempDir('qual_'));

  tearDown(() async {
    await rig?.dispose();
    rig = null;
    await deleteTree(profile);
  });

  /// Waits until [channels] have each sent [bytes] and nothing more arrives
  /// for [quiet].
  Future<void> expectStallAt(
    Rig r,
    Iterable<Consumer> channels,
    int bytes, {
    Duration quiet = const Duration(milliseconds: 600),
  }) async {
    await eventually(
      () => channels.every((c) => (r.wire.sent[c.id] ?? 0) >= bytes),
      reason: 'channels did not reach $bytes bytes: ${r.wire.sent}',
    );
    final at = {for (final c in channels) c.id: r.wire.sent[c.id]};
    await Future<void>.delayed(quiet);
    for (final c in channels) {
      expect(
        r.wire.sent[c.id],
        at[c.id],
        reason: 'channel ${c.id} sent more while stalled',
      );
      expect(r.wire.sent[c.id], bytes, reason: 'channel ${c.id} stall point');
    }
  }

  test('control round-trip ≤ 250 ms under saturating channel', () async {
    final r = rig = await Rig.start(profile, tapWire: false);
    const channels = 4;
    final saturating = [for (var i = 0; i < channels; i++) await r.open()];
    int total() => saturating.fold(0, (a, c) => a + c.received);

    // The channels are saturated before and while control is measured.
    await eventually(
      () => total() >= 8 * 1024 * 1024,
      reason: 'channels did not saturate: ${total()} bytes',
    );
    final before = total();
    final started = Stopwatch()..start();

    final samples = <Duration>[];
    final watch = Stopwatch();
    for (var i = 0; i < 100; i++) {
      watch
        ..reset()
        ..start();
      await r.control();
      samples.add(watch.elapsed);
    }
    final elapsed = started.elapsed;
    final streamed = total() - before;

    samples.sort();
    final worst = samples.last.inMicroseconds / 1000;
    final median = samples[samples.length ~/ 2].inMicroseconds / 1000;
    // Recorded in the architecture's bounds table (task 10.1).
    // ignore: avoid_print
    print(
      'control round-trip under $channels saturating channels: '
      'worst ${worst.toStringAsFixed(1)} ms, '
      'median ${median.toStringAsFixed(1)} ms over 100 round-trips '
      '(${(streamed / (1024 * 1024)).toStringAsFixed(1)} MiB streamed in '
      '${elapsed.inMilliseconds} ms) on ${Platform.operatingSystem}',
    );

    expect(
      streamed,
      greaterThan(1024 * 1024),
      reason: 'the channels were not saturating during the measurement',
    );
    expect(worst, lessThanOrEqualTo(250), reason: 'worst control round-trip');
  });

  test(
    'stalled channel stops at credit; other channel and control flow',
    () async {
      final r = rig = await Rig.start(profile);
      final stalled = await r.open(paused: true);
      final flowing = await r.open();

      await expectStallAt(r, [stalled], _window);
      expect(stalled.received, 0, reason: 'a paused consumer took nothing');

      // The flowing channel kept streaming far past one window, and control
      // answers promptly while the other channel is stalled.
      await eventually(
        () => flowing.received >= 8 * _window,
        reason: 'flowing channel stalled at ${flowing.received}',
      );
      final worst = Stopwatch();
      for (var i = 0; i < 20; i++) {
        worst
          ..reset()
          ..start();
        await r.control();
        expect(worst.elapsed, lessThan(const Duration(milliseconds: 250)));
      }
      final progressed = flowing.received;
      await eventually(
        () => flowing.received > progressed,
        reason: 'flowing channel stopped after control calls',
      );

      expect(r.wire.sent[stalled.id], _window, reason: 'still at credit');
      expect(flowing.firstMismatch, isNull);
    },
  );

  test('resumed channel delivers every byte once in order', () async {
    final r = rig = await Rig.start(profile);
    final channel = await r.open(paused: true);
    await expectStallAt(r, [channel], _window);
    expect(channel.received, 0);

    channel.subscription.resume();

    // Three windows of stream after the stall, all checked as they arrive.
    const target = 3 * _window;
    await eventually(
      () => channel.received >= target,
      reason: 'resume delivered only ${channel.received} bytes',
    );
    expect(
      channel.firstMismatch,
      isNull,
      reason: 'byte at offset ${channel.firstMismatch} out of place',
    );

    // Pause again right at a boundary: delivery and the host's emission agree
    // (nothing lost, nothing sent twice), then resume once more.
    channel.subscription.pause();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final held = channel.received;
    expect(
      r.wire.sent[channel.id],
      lessThanOrEqualTo(held + _window),
      reason: 'host emitted past the credit it was granted',
    );
    channel.subscription.resume();
    await eventually(
      () => channel.received >= held + _window,
      reason: 'second resume stalled at ${channel.received}',
    );
    expect(channel.firstMismatch, isNull);
    expect(
      channel.received,
      lessThanOrEqualTo(r.wire.sent[channel.id]!),
      reason: 'consumer took bytes the host never sent',
    );
  });

  test('host buffered bytes per channel stay ≤ 256 KiB', () async {
    final r = rig = await Rig.start(profile);
    final stalled = await r.open(paused: true);
    final flowing = await r.open();
    final throttled = await r.open(rate: 1024 * 1024);
    final resumed = await r.open(paused: true);

    await expectStallAt(r, [stalled, resumed], _window);
    resumed.subscription.resume();
    await eventually(
      () => flowing.received >= 16 * _window && resumed.received >= 4 * _window,
      reason: 'channels did not stream: ${r.wire.sent}',
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));

    for (final c in [stalled, flowing, throttled, resumed]) {
      expect(
        r.wire.peak[c.id],
        lessThanOrEqualTo(_window),
        reason: 'channel ${c.id} had ${r.wire.peak[c.id]} bytes outstanding',
      );
    }
    // The stalled channel held exactly its window and no more.
    expect(r.wire.peak[stalled.id], _window);
    expect(stalled.received, 0);
  });

  test('host queues at most a window per channel for a source that '
      'over-produces', () async {
    final r = rig = await Rig.start(profile);
    // Each of the producer's writes is 1 MiB, four windows at once.
    const write = 4 * _window;
    final stalled = await r.open(paused: true, writeBytes: write);
    await expectStallAt(r, [stalled], _window);

    Future<TestChannelStatsResult> stats() async =>
        TestChannelStatsResult.fromJson(
          await r.connection.request(
            Method.testChannelStats,
            TestChannelStatsParams(stalled.id).toJson(),
          ) as Json,
        );
    final first = await stats();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final second = await stats();

    // A window on the wire, at most a window queued in the host's writer,
    // and the source stopped: it read one write and is waiting on it.
    expect(first.queuedBytes, lessThanOrEqualTo(_window));
    expect(second.queuedBytes, lessThanOrEqualTo(_window));
    expect(second.producedBytes, first.producedBytes);
    expect(second.producedBytes, write);

    // Resumed, every byte still arrives once, in order.
    stalled.subscription.resume();
    await eventually(
      () => stalled.received >= 2 * write,
      reason: 'resume delivered only ${stalled.received} bytes',
    );
    expect(stalled.firstMismatch, isNull);
    expect((await stats()).queuedBytes, lessThanOrEqualTo(_window));
  });

  test('33rd open refused with channel-cap; total buffering ≤ 8 MiB', () async {
    final r = rig = await Rig.start(profile);
    final channels = [
      for (var i = 0; i < maxChannels; i++) await r.open(paused: true),
    ];
    await expectStallAt(r, channels, _window);
    expect(r.wire.totalSent, maxChannels * _window);
    expect(r.wire.totalSent, lessThanOrEqualTo(8 * 1024 * 1024));

    // The 33rd is refused, the host starts nothing for it, and the
    // connection and the other channels are unaffected.
    expect(
      await failureReason(
        () => r.connection.request(
          Method.testChannelOpen,
          const TestChannelOpenParams(0).toJson(),
        ),
      ),
      ErrorCode.channelCap,
    );
    await r.control();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(r.wire.sent.length, maxChannels, reason: 'no 33rd channel streamed');
    expect(r.wire.totalSent, maxChannels * _window);
    expect(r.connection.isClosed, isFalse);

    // Closing one frees a slot; the replacement stalls at its own window, and
    // the open channels together still hold at most 8 MiB.
    final gone = channels.removeLast();
    await gone.subscription.cancel();
    Consumer? replacement;
    await eventually(() async {
      try {
        replacement = await r.open(paused: true);
        return true;
      } on RpcException catch (e) {
        expect(e.reason, ErrorCode.channelCap);
        return false;
      }
    }, reason: 'the freed slot was not reusable');
    channels.add(replacement!);
    await eventually(
      () => (r.wire.sent[replacement!.id] ?? 0) >= _window,
      reason: 'replacement did not stream',
    );
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final held = channels.fold<int>(0, (a, c) => a + r.wire.outstanding(c.id));
    expect(held, maxChannels * _window);
    expect(held, lessThanOrEqualTo(8 * 1024 * 1024));
    for (final c in channels) {
      expect(
        r.wire.peak[c.id],
        lessThanOrEqualTo(_window),
        reason: 'channel ${c.id}',
      );
    }
  });
}
