import 'dart:convert';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/sinks.dart';

Uint8List _frames(int n) => Uint8List(n * maxFramePayload);

void main() {
  late RecordingSink sink;
  late FairWriter writer;
  final fatal = <CloseReason>[];

  setUp(() {
    fatal.clear();
    sink = RecordingSink(blocking: true);
    writer = FairWriter(sink, onFatal: fatal.add);
  });

  test('at most one data frame precedes control enqueued mid-write', () async {
    final channel = writer.openChannel(1)..grant(10 * maxFramePayload);
    final done = channel.write(_frames(5));

    // The first data frame is in flight; four more are pending.
    expect(sink.writes, hasLength(1));
    writer.sendControl(utf8.encode('{"jsonrpc":"2.0","method":"x"}'));

    sink.release();
    await settle();
    expect(sink.writes, hasLength(2));

    sink.releaseAll();
    await done;

    final channels = sink.frames.map((f) => f.channel).toList();
    expect(channels.indexOf(controlChannel), lessThanOrEqualTo(1));
    expect(channels.where((c) => c == 1), hasLength(5));
    // The sink never held more than one submitted frame.
    expect(sink.maxUnflushed, 1);
  });

  test('drain completes once queued control is flushed', () async {
    var drained = false;
    writer.sendControl(utf8.encode('{"jsonrpc":"2.0","method":"x"}'));
    final done = writer.drain().then((_) => drained = true);

    await settle();
    expect(drained, isFalse, reason: 'the flush is still blocked');
    sink.releaseAll();
    await done;
    expect(drained, isTrue);
    expect(sink.writes, hasLength(1));
    await writer.drain(); // idle: completes at once
  });

  test('round-robin between busy channels', () async {
    final a = writer.openChannel(1)..grant(8 * maxFramePayload);
    final b = writer.openChannel(2)..grant(8 * maxFramePayload);
    final done = [
      a.write(_frames(2)),
      b.write(_frames(2)),
      a.write(_frames(2)),
      b.write(_frames(2)),
    ];

    sink.releaseAll();
    await Future.wait(done);

    expect(sink.frames.map((f) => f.channel), [1, 2, 1, 2, 1, 2, 1, 2]);
  });

  test('a channel without credit is skipped and resumes on grant', () async {
    sink.blocking = false;
    final starved = writer.openChannel(1);
    final fed = writer.openChannel(2)..grant(maxFramePayload);
    var starvedDone = false;
    starved.write(Uint8List(100)).then((_) => starvedDone = true).ignore();
    await fed.write(Uint8List(maxFramePayload));
    expect(sink.frames.map((f) => f.channel), [2]);
    expect(starvedDone, isFalse);

    starved.grant(100);
    await settle();
    expect(starvedDone, isTrue);
    expect(sink.frames.last.channel, 1);
    expect(sink.frames.last.payload.length, 100);
  });

  test('control past 4 MiB marks the peer lost', () {
    for (var i = 0; i < 8 && fatal.isEmpty; i++) {
      writer.sendControl(Uint8List(maxControlMessage));
    }
    expect(fatal.single.kind, CloseReason.controlOverflow);
  });

  test('a failing flush is fatal', () async {
    final w = FairWriter(_FailingSink(), onFatal: fatal.add);
    w.sendControl(utf8.encode('{}'));
    await settle();
    expect(fatal.single.kind, CloseReason.writeFailed);
  });
}

class _FailingSink implements ByteSink {
  @override
  void add(List<int> data) {}

  @override
  Future<void> flush() => Future.error(StateError('pipe closed'));
}
