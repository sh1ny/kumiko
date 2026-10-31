import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/sinks.dart';

Uint8List _bytes(int n, int seed) =>
    Uint8List.fromList([for (var i = 0; i < n; i++) (i + seed) % 251]);

Matcher _channelLimit() => throwsA(
  isA<RpcException>().having((e) => e.reason, 'reason', ErrorCode.channelLimit),
);

void main() {
  test('maxChannels is 160 (two per terminal at the unit cap, plus room)', () {
    expect(maxChannels, 160);
  });

  test('reserveChannels(2) is atomic at the limit', () {
    final connection = Connection(
      input: const Stream<List<int>>.empty(),
      output: RecordingSink(),
    );
    for (var i = 0; i < maxChannels - 1; i++) {
      connection.openOutbound();
    }
    // One slot left: the pair does not fit, and nothing is taken.
    expect(() => connection.reserveChannels(2), _channelLimit());
    // The single slot is still there, so the failed attempt reserved none.
    final one = connection.reserveChannels(1);
    expect(one.ids, hasLength(1));
    expect(() => connection.reserveChannels(1), _channelLimit());
    // Releasing frees the slot again.
    one.release();
    connection.reserveChannels(1);
  });

  test('a reservation counts against the cap until released', () {
    final connection = Connection(
      input: const Stream<List<int>>.empty(),
      output: RecordingSink(),
    );
    final held = [
      for (var i = 0; i < maxChannels ~/ 2; i++) connection.reserveChannels(2),
    ];
    expect(connection.openOutbound, throwsA(isA<RpcException>()));
    held.first.release();
    held.first.release(); // idempotent
    connection.openOutbound();
    connection.openOutbound();
    expect(connection.openOutbound, throwsA(isA<RpcException>()));
  });

  test('concurrent opens get unique ids and each channel gets only its own '
      'bytes', () async {
    final (desktop, host) = connectedPair();
    await desktop.hello();

    final reservations = [for (var i = 0; i < 4; i++) host.reserveChannels(2)];
    final ids = [for (final r in reservations) ...r.ids];
    expect(ids.toSet(), hasLength(8), reason: 'every id is unique');

    final received = <int, List<int>>{};
    final writers = <int, ChannelWriter>{};
    for (final r in reservations) {
      final output = r.ids[0];
      final input = r.ids[1];
      // Desktop side: output inbound, input outbound.
      desktop
          .attachInbound(output)
          .listen((b) => (received[output] ??= []).addAll(b));
      final inputWriter = desktop.attachOutbound(input);
      // Host side: output outbound, input inbound.
      writers[output] = host.attachOutbound(output);
      host
          .attachInbound(input)
          .listen((b) => (received[input] ??= []).addAll(b));
      writers[input] = inputWriter;
    }
    await settle();

    final sent = <int, Uint8List>{};
    for (final r in reservations) {
      for (final id in r.ids) {
        sent[id] = _bytes(1000 + id, id);
        await writers[id]!.write(sent[id]!);
      }
    }
    await settle();
    for (final id in ids) {
      expect(received[id], sent[id], reason: 'channel $id');
    }
    expect(desktop.isClosed, isFalse);
    expect(host.isClosed, isFalse);
  });

  test('reserving and allocating sends no frames', () async {
    final output = RecordingSink();
    final connection = Connection(
      input: const Stream<List<int>>.empty(),
      output: output,
    );
    connection.reserveChannels(2);
    await settle();
    expect(output.writes, isEmpty);
  });

  test(
    'a frame for an allocated but unattached channel is a violation',
    () async {
      final input = StreamController<List<int>>();
      final connection = Connection(
        input: input.stream,
        output: RecordingSink(),
      );
      final reservation = connection.reserveChannels(2);
      input.add(encodeCredit(reservation.ids[0], 1024));
      expect((await connection.closed).kind, CloseReason.protocolViolation);
      await input.close();
    },
  );

  test('inbound attach without an initial grant sends no credit until '
      'grantInitial', () async {
    final input = StreamController<List<int>>();
    final output = RecordingSink();
    final connection = Connection(input: input.stream, output: output);
    connection.attachInbound(7, grantInitial: false).listen((_) {});
    await settle();
    expect(output.frames, isEmpty);

    connection.grantInitial(7);
    await settle();
    final grant = output.frames.single;
    expect(grant.kind, FrameKind.credit);
    expect(grant.channel, 7);
    expect(grant.creditBytes, channelWindow);
    await connection.close();
    await input.close();
  });

  test('attach handshake: result and the frames after attach in one read '
      'keep the connection open', () async {
    final input = StreamController<List<int>>();
    final output = RecordingSink();
    final desktop = Connection(input: input.stream, output: output);

    // The open result names the host-allocated channels.
    final open = desktop.request('terminal/open', {});
    input.add(_response(1, {'outputChannel': 11, 'inputChannel': 12}));
    await open;

    // The desktop registers both, grants nothing yet, then attaches.
    final received = <int>[];
    desktop.attachInbound(11, grantInitial: false).listen(received.addAll);
    final inputWriter = desktop.attachOutbound(12);
    final attach = desktop.request('terminal/attach', {'terminalId': 't'});
    await settle();
    expect(
      output.frames.where((f) => f.kind == FrameKind.credit),
      isEmpty,
      reason: 'no credit before the desktop grants',
    );

    // One read: the attach answer, the input credit and first output.
    final data = _bytes(100, 3);
    input.add([
      ..._response(2, {}),
      ...encodeCredit(12, channelWindow),
      ...encodeFrame(11, FrameKind.data, data),
    ]);
    await attach;
    await settle();

    expect(desktop.isClosed, isFalse);
    expect(inputWriter.credit, channelWindow);
    expect(received, data);

    desktop.grantInitial(11);
    await settle();
    expect(
      output.frames.where((f) => f.kind == FrameKind.credit && f.channel == 11),
      hasLength(1),
    );
    await desktop.close();
    await input.close();
  });
}

List<int> _response(int id, Object result) {
  final json = jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result});
  return [
    for (final f in encodeMessageFrames(controlChannel, utf8.encode(json)))
      ...f,
  ];
}
