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
  _Chunk(this.channel, this.bytes);
  final int channel;
  final Uint8List bytes;
  final Completer<void> done = Completer();
  int offset = 0;
  int get remaining => bytes.length - offset;
}

/// The sending half of a data channel. Writes wait for credit and for the
/// wire, so a producer that awaits them stops reading its source when the
/// receiver grants nothing. At most [channelWindow] bytes are held here
/// unsent: a write waits until there is room, larger writes are taken a
/// window at a time, and writes are queued in call order.
///
/// A waiting write keeps the caller's buffer. A producer that must bound
/// all of its unsent bytes awaits [ready] and reads at most [room] bytes
/// from its source before each write, which is then queued at once.
class ChannelWriter {
  ChannelWriter._(this.id, this._writer);

  final int id;
  final FairWriter _writer;
  final Queue<_Chunk> _chunks = Queue();
  int _credit = 0;
  bool _closed = false;
  int _queued = 0;
  int _sentBytes = 0;

  /// Writes waiting for room, and the end of their FIFO chain.
  int _waiting = 0;
  Future<void> _admission = Future.value();
  Completer<void>? _space;

  /// Bytes the receiver has granted and this side has not yet sent.
  int get credit => _credit;

  /// Bytes accepted by [write] and not yet on the wire, at most
  /// [channelWindow].
  int get queuedBytes => _queued;

  /// Bytes of this channel on the wire so far.
  int get sentBytes => _sentBytes;

  /// Bytes a write may add now and be queued at once.
  int get room => _closed || _waiting > 0 ? 0 : channelWindow - _queued;

  /// Completes once [room] is above zero; fails once the channel is closed.
  Future<void> get ready async {
    while (!_closed && room == 0) {
      await (_space ??= Completer<void>()).future;
    }
    if (_closed) throw ChannelClosedException(id);
  }

  /// Completes once every byte of [data] has been handed to the sink and
  /// flushed.
  Future<void> write(List<int> data) {
    if (_closed) return Future.error(ChannelClosedException(id));
    if (data.isEmpty) return Future.value();
    // With nobody waiting, what fits is queued at once.
    var start = 0;
    Future<void>? last;
    while (_waiting == 0 && start < data.length) {
      final end = math.min(start + channelWindow, data.length);
      if (_queued + end - start > channelWindow) break;
      last = _enqueue(data, start, end);
      start = end;
    }
    if (start == data.length) return last!;
    last?.ignore();
    _waiting++;
    final flushed = Completer<void>();
    _admission = _admission.then((_) => _admit(data, start, flushed));
    return flushed.future;
  }

  /// Queues [data] from [from] a window at a time, each part once there is
  /// room for it. Completes when all of it is queued; [flushed] follows the
  /// last part.
  Future<void> _admit(List<int> data, int from, Completer<void> flushed) async {
    try {
      Future<void>? last;
      for (var start = from; start < data.length; start += channelWindow) {
        final end = math.min(start + channelWindow, data.length);
        while (!_closed && _queued + end - start > channelWindow) {
          await (_space ??= Completer<void>()).future;
        }
        if (_closed) throw ChannelClosedException(id);
        last = _enqueue(data, start, end)..ignore();
      }
      flushed.complete(last);
    } on Object catch (e, s) {
      flushed.completeError(e, s);
    } finally {
      _waiting--;
      _wake();
    }
  }

  Future<void> _enqueue(List<int> data, int start, int end) {
    final bytes = Uint8List(end - start)..setRange(0, end - start, data, start);
    final chunk = _Chunk(id, bytes);
    _chunks.add(chunk);
    _queued += bytes.length;
    _writer._kick();
    return chunk.done.future;
  }

  /// [bytes] of the queue went on the wire.
  void _sent(int bytes) {
    _queued -= bytes;
    _sentBytes += bytes;
    _wake();
  }

  /// Lets writes and [ready] waiting for room look again.
  void _wake() {
    final space = _space;
    _space = null;
    space?.complete();
  }

  /// Adds receiver credit.
  void grant(int bytes) {
    _credit += bytes;
    _writer._kick();
  }

  void _close() {
    _closed = true;
    _queued = 0;
    _wake();
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
  final List<Completer<void>> _drainWaiters = [];

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
    _releaseDrainWaiters();
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

  /// Completes when every control frame queued so far has been written and
  /// flushed (or the writer died). A host uses it to send a last reply before
  /// it exits.
  Future<void> drain() {
    if (_dead || (_control.isEmpty && !_pumping)) return Future.value();
    final waiter = Completer<void>();
    _drainWaiters.add(waiter);
    return waiter.future;
  }

  void _releaseDrainWaiters() {
    if (_pumping && !_dead) return;
    if (!_dead && _control.isNotEmpty) return;
    for (final w in _drainWaiters) {
      w.complete();
    }
    _drainWaiters.clear();
  }

  void _kick() {
    if (!_pumping && !_dead) unawaited(_pump());
  }

  Future<void> _pump() async {
    _pumping = true;
    // The chunk whose last frame is being written. It has already left its
    // channel's queue, so a failed write must fail it here.
    _Chunk? finished;
    try {
      while (!_dead) {
        finished = null;
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
      if (finished != null && !finished.done.isCompleted) {
        finished.done.completeError(ChannelClosedException(finished.channel));
      }
      _fatal(CloseReason(CloseReason.writeFailed, '$error'));
    } finally {
      _pumping = false;
      _releaseDrainWaiters();
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
      channel._sent(size);
      _cursor = index + 1;
      if (chunk.remaining > 0) return (frame, null);
      channel._chunks.removeFirst();
      return (frame, chunk);
    }
    return null;
  }
}
