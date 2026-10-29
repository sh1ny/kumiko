import 'dart:typed_data';

/// Header: u32 payload length, u32 channel, u8 kind, u8 flags (big-endian).
const int frameHeaderSize = 10;

/// Largest payload one frame may carry (design D6).
const int maxFramePayload = 64 * 1024;

/// Largest assembled control (channel 0) message.
const int maxControlMessage = 1024 * 1024;

/// Per-channel credit window, granted in full at open.
const int channelWindow = 256 * 1024;

/// Open data channels per connection: two per terminal for the unit cap of
/// 64, plus room for session channels (design D4).
const int maxChannels = 160;

/// Pending outbound control bytes per side before the peer counts as lost.
const int maxPendingControl = 4 * 1024 * 1024;

/// Concurrent inbound control requests before `busy` answers.
const int maxInboundRequests = 256;

/// The control channel carries JSON-RPC; it has no credit.
const int controlChannel = 0;

/// Flag bit 0: last fragment of a control message.
const int flagEndOfMessage = 1;

enum FrameKind {
  data(0),
  credit(1);

  const FrameKind(this.wire);
  final int wire;

  static FrameKind? fromWire(int value) {
    for (final kind in values) {
      if (kind.wire == value) return kind;
    }
    return null;
  }
}

/// A peer broke the wire contract. The connection closes with the detail.
class ProtocolViolation implements Exception {
  ProtocolViolation(this.detail);
  final String detail;

  @override
  String toString() => 'ProtocolViolation: $detail';
}

class Frame {
  const Frame(this.channel, this.kind, this.flags, this.payload);
  final int channel;
  final FrameKind kind;
  final int flags;
  final Uint8List payload;

  bool get endOfMessage => flags & flagEndOfMessage != 0;

  /// The bytes granted by a credit frame.
  int get creditBytes => ByteData.sublistView(payload).getUint32(0);
}

Uint8List encodeFrame(
  int channel,
  FrameKind kind,
  List<int> payload, {
  int flags = 0,
}) {
  if (payload.length > maxFramePayload) {
    throw ArgumentError.value(payload.length, 'payload', 'over frame limit');
  }
  final out = Uint8List(frameHeaderSize + payload.length);
  ByteData.sublistView(out)
    ..setUint32(0, payload.length)
    ..setUint32(4, channel);
  out[8] = kind.wire;
  out[9] = flags;
  out.setRange(frameHeaderSize, out.length, payload);
  return out;
}

Uint8List encodeCredit(int channel, int bytes) {
  final payload = Uint8List(4);
  ByteData.sublistView(payload).setUint32(0, bytes);
  return encodeFrame(channel, FrameKind.credit, payload);
}

/// Splits [message] into DATA frames of at most [maxFramePayload]; the last
/// carries the end-of-message flag.
List<Uint8List> encodeMessageFrames(int channel, List<int> message) {
  final frames = <Uint8List>[];
  var offset = 0;
  do {
    final end = offset + maxFramePayload < message.length
        ? offset + maxFramePayload
        : message.length;
    frames.add(
      encodeFrame(
        channel,
        FrameKind.data,
        message.sublist(offset, end),
        flags: end == message.length ? flagEndOfMessage : 0,
      ),
    );
    offset = end;
  } while (offset < message.length);
  return frames;
}

/// Incremental decoder. Lengths and kinds are validated from the header alone,
/// before any payload is buffered.
class FrameDecoder {
  Uint8List _buffer = Uint8List(0);

  /// Frames completed by [chunk]. Iterate fully; a violation throws from the
  /// iteration, after the frames that preceded it.
  Iterable<Frame> add(List<int> chunk) sync* {
    if (_buffer.isEmpty) {
      _buffer = Uint8List.fromList(chunk);
    } else {
      _buffer =
          (BytesBuilder(copy: false)
                ..add(_buffer)
                ..add(chunk))
              .takeBytes();
    }
    var pos = 0;
    while (_buffer.length - pos >= frameHeaderSize) {
      final header = ByteData.sublistView(_buffer, pos, pos + frameHeaderSize);
      final length = header.getUint32(0);
      if (length > maxFramePayload) {
        throw ProtocolViolation(
          'frame length $length exceeds $maxFramePayload',
        );
      }
      final kind = FrameKind.fromWire(_buffer[pos + 8]);
      if (kind == null) {
        throw ProtocolViolation('unknown frame kind ${_buffer[pos + 8]}');
      }
      if (kind == FrameKind.credit && length != 4) {
        throw ProtocolViolation('credit frame payload is $length bytes');
      }
      final end = pos + frameHeaderSize + length;
      if (_buffer.length < end) break;
      final frame = Frame(
        header.getUint32(4),
        kind,
        _buffer[pos + 9],
        Uint8List.sublistView(_buffer, pos + frameHeaderSize, end),
      );
      pos = end;
      yield frame;
    }
    _buffer = pos == 0 ? _buffer : Uint8List.sublistView(_buffer, pos);
  }
}

/// Reassembles channel 0 DATA frames into messages.
class MessageAssembler {
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  /// The finished message when [frame] ends one, else null.
  Uint8List? add(Frame frame) {
    if (_bytes.length + frame.payload.length > maxControlMessage) {
      throw ProtocolViolation('control message exceeds $maxControlMessage');
    }
    _bytes.add(frame.payload);
    return frame.endOfMessage ? _bytes.takeBytes() : null;
  }
}
