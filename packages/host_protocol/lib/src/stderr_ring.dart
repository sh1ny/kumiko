import 'dart:convert';
import 'dart:typed_data';

/// The most bytes the desktop keeps of the host's stderr (design D6 and the
/// resource-bounds table).
const int stderrRingCapacity = 64 * 1024;

/// A fixed-size ring that keeps the last [capacity] bytes written to it. The
/// oldest bytes are dropped first, so the memory is bounded however much the
/// host writes before it takes the profile lock.
class StderrRing {
  StderrRing([this.capacity = stderrRingCapacity])
    : _buffer = Uint8List(capacity);

  final int capacity;
  final Uint8List _buffer;

  /// Next write position.
  int _head = 0;
  int _length = 0;

  int get length => _length;

  void add(List<int> chunk) {
    // Only the last [capacity] bytes of a chunk can survive.
    final start = chunk.length > capacity ? chunk.length - capacity : 0;
    for (var i = start; i < chunk.length; i++) {
      _buffer[_head] = chunk[i];
      _head = (_head + 1) % capacity;
    }
    _length = _length + (chunk.length - start);
    if (_length > capacity) _length = capacity;
  }

  /// The retained bytes, oldest first.
  Uint8List get bytes {
    final out = Uint8List(_length);
    final first = (_head - _length) % capacity;
    for (var i = 0; i < _length; i++) {
      out[i] = _buffer[(first + i) % capacity];
    }
    return out;
  }

  /// The retained bytes as text; a character cut at the start is replaced.
  String get text => utf8.decode(bytes, allowMalformed: true);
}
