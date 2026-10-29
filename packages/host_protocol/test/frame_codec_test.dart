import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

Uint8List _header(int length, {int channel = 1, int kind = 0, int flags = 0}) {
  final bytes = Uint8List(frameHeaderSize);
  ByteData.sublistView(bytes)
    ..setUint32(0, length)
    ..setUint32(4, channel);
  bytes[8] = kind;
  bytes[9] = flags;
  return bytes;
}

void main() {
  test('payload over 64 KiB split and reassembled in order', () {
    final message = Uint8List.fromList([
      for (var i = 0; i < 200000; i++) i % 251,
    ]);
    final frames = encodeMessageFrames(controlChannel, message);

    expect(frames.length, 4);
    for (final f in frames) {
      expect(f.length - frameHeaderSize, lessThanOrEqualTo(maxFramePayload));
    }

    // Feed the wire in awkward 7-byte chunks, as a pipe may deliver it.
    final wire = Uint8List.fromList([for (final f in frames) ...f]);
    final decoder = FrameDecoder();
    final assembler = MessageAssembler();
    Uint8List? assembled;
    for (var i = 0; i < wire.length; i += 7) {
      final end = i + 7 < wire.length ? i + 7 : wire.length;
      for (final frame in decoder.add(wire.sublist(i, end))) {
        expect(frame.channel, controlChannel);
        assembled = assembler.add(frame) ?? assembled;
      }
    }
    expect(assembled, message);
  });

  test('header is ten big-endian bytes', () {
    final bytes = encodeFrame(0x01020304, FrameKind.data, [9], flags: 1);
    expect(bytes.sublist(0, frameHeaderSize), [0, 0, 0, 1, 1, 2, 3, 4, 0, 1]);
    expect(bytes.last, 9);
    expect(encodeCredit(5, 258).sublist(10), [0, 0, 1, 2]);
  });

  test('oversize length is a violation', () {
    final decoder = FrameDecoder();
    // Only the header: the violation is declared before the payload arrives.
    expect(
      () => decoder.add(_header(maxFramePayload + 1)).toList(),
      throwsA(isA<ProtocolViolation>()),
    );
  });

  test('exact limit is accepted', () {
    final wire = [..._header(maxFramePayload), ...Uint8List(maxFramePayload)];
    final frames = FrameDecoder().add(wire).toList();
    expect(frames.single.payload.length, maxFramePayload);
  });

  test('unknown kind is a violation', () {
    expect(
      () => FrameDecoder().add(_header(0, kind: 2)).toList(),
      throwsA(isA<ProtocolViolation>()),
    );
  });

  test('credit frame with the wrong payload size is a violation', () {
    expect(
      () => FrameDecoder().add(_header(3, kind: 1)).toList(),
      throwsA(isA<ProtocolViolation>()),
    );
  });

  test('control message over 1 MiB is a violation', () {
    final assembler = MessageAssembler();
    final chunk = Frame(0, FrameKind.data, 0, Uint8List(maxFramePayload));
    expect(() {
      for (var i = 0; i <= maxControlMessage ~/ maxFramePayload; i++) {
        assembler.add(chunk);
      }
    }, throwsA(isA<ProtocolViolation>()));
  });
}
