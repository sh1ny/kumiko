import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'close_reason.dart';
import 'frame_codec.dart';

/// Where frames go: an `IOSink`-like add plus flush.
abstract interface class ByteSink {
  void add(List<int> data);
  Future<void> flush();
}

/// A write on a channel that closed, or on a connection that ended.
class ChannelClosedException implements Exception {
  ChannelClosedException(this.channel);
  final int channel;

  @override
  String toString() => 'ChannelClosedException: channel $channel is closed';
}

class _Chunk {
  _Chunk(this.bytes);
  final Uint8List bytes;
  final Completer<void> done = Completer();
  int offset = 0;
  int get remaining => bytes.length - offset;
}

/// The sending half of a data channel. Writes wait for credit and for the
/// wire, so a producer that awaits them stops reading its source when the
/// receiver grants nothing.
class ChannelWriter {
  ChannelWriter._(this.id, this._writer);

  final int id;
  final FairWriter _writer;
  final Queue<_Chunk> _chunks = Queue();
  int _credit = 0;
  bool _closed = false;

  /// Bytes the receiver has granted and this side has not yet sent.
  int get credit => _credit;

  /// Completes once every byte of [data] has been handed to the sink and
  /// flushed.
  Future<void> write(List<int> data) {
    if (_closed) return Future.error(ChannelClosedException(id));
    if (data.isEmpty) return Future.value();
    final chunk = _Chunk(Uint8List.fromList(data));
    _chunks.add(chunk);
    _writer._kick();
    return chunk.done.future;
  }

  /// Adds receiver credit.
  void grant(int bytes) {
    _credit += bytes;
    _writer._kick();
  }

  void _close() {
    _closed = true;
    for (final chunk in _chunks) {
      chunk.done.completeError(ChannelClosedException(id));
    }
    _chunks.clear();
  }
}

/// Decides, per frame, what goes on the wire next: every pending control frame
/// first, then one frame from the next data channel that has data and credit,
/// round-robin. Exactly one frame is submitted to the sink at a time and its
/// flush is awaited before the next choice, so a control message waits for at
/// most the one data frame already being written (design D7).
class FairWriter {
  FairWriter(
    this._sink, {
    required this.onFatal,
    int maxPendingControlBytes = maxPendingControl,
  }) : _maxPendingControl = maxPendingControlBytes;

  final ByteSink _sink;

  /// Called once when the writer can no longer be trusted: control overflow or
  /// a failed write.
  final void Function(CloseReason) onFatal;
  final int _maxPendingControl;
  final Queue<Uint8List> _control = Queue();
  final List<ChannelWriter> _channels = [];
  int _pendingControl = 0;
  int _cursor = 0;
  bool _pumping = false;
  bool _dead = false;

  int get channelCount => _channels.length;

  bool hasChannel(int id) => _channels.any((c) => c.id == id);

  ChannelWriter openChannel(int id) {
    final channel = ChannelWriter._(id, this);
    _channels.add(channel);
    return channel;
  }

  void closeChannel(int id) {
    final index = _channels.indexWhere((c) => c.id == id);
    if (index < 0) return;
    _channels.removeAt(index)._close();
    if (index < _cursor) _cursor--;
  }

  /// Credit for a channel opened here; false when it is not (or no longer).
  bool grant(int id, int bytes) {
    for (final c in _channels) {
      if (c.id == id) {
        c.grant(bytes);
        return true;
      }
    }
    return false;
  }

  /// Queues a control message, fragmented into frames.
  void sendControl(List<int> message) {
    if (message.length > maxControlMessage) {
      throw ArgumentError.value(message.length, 'message', 'over 1 MiB');
    }
    for (final frame in encodeMessageFrames(controlChannel, message)) {
      _enqueueControl(frame);
    }
  }

  /// Tells the sender of [channel] it may send [bytes] more.
  void sendCredit(int channel, int bytes) =>
      _enqueueControl(encodeCredit(channel, bytes));

  void _enqueueControl(Uint8List frame) {
    if (_dead) return;
    _control.add(frame);
    _pendingControl += frame.length;
    if (_pendingControl > _maxPendingControl) {
      _fatal(
        CloseReason(
          CloseReason.controlOverflow,
          'pending control exceeds $_maxPendingControl bytes',
        ),
      );
      return;
    }
    _kick();
  }

  void close() {
    _dead = true;
    _control.clear();
    for (final c in _channels) {
      c._close();
    }
    _channels.clear();
  }

  void _fatal(CloseReason reason) {
    if (_dead) return;
    close();
    onFatal(reason);
  }

  void _kick() {
    if (!_pumping && !_dead) unawaited(_pump());
  }

  Future<void> _pump() async {
    _pumping = true;
    try {
      while (!_dead) {
        _Chunk? finished;
        final Uint8List frame;
        if (_control.isNotEmpty) {
          frame = _control.removeFirst();
          _pendingControl -= frame.length;
        } else {
          final next = _nextDataFrame();
          if (next == null) break;
          frame = next.$1;
          finished = next.$2;
        }
        _sink.add(frame);
        await _sink.flush();
        if (finished != null && !finished.done.isCompleted) {
          finished.done.complete();
        }
      }
    } on Object catch (error) {
      _fatal(CloseReason(CloseReason.writeFailed, '$error'));
    } finally {
      _pumping = false;
    }
  }

  /// The next data frame, round-robin, and the chunk it completes (if any).
  (Uint8List, _Chunk?)? _nextDataFrame() {
    final count = _channels.length;
    for (var i = 0; i < count; i++) {
      final index = (_cursor + i) % count;
      final channel = _channels[index];
      if (channel._chunks.isEmpty || channel._credit == 0) continue;
      final chunk = channel._chunks.first;
      final size = math.min(
        math.min(chunk.remaining, channel._credit),
        maxFramePayload,
      );
      final frame = encodeFrame(
        channel.id,
        FrameKind.data,
        Uint8List.sublistView(chunk.bytes, chunk.offset, chunk.offset + size),
      );
      chunk.offset += size;
      channel._credit -= size;
      _cursor = index + 1;
      if (chunk.remaining > 0) return (frame, null);
      channel._chunks.removeFirst();
      return (frame, chunk);
    }
    return null;
  }
}
