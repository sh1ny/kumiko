import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';

/// Records every frame handed to it. While [blocking], `flush()` waits for
/// [release], so a test controls exactly when a write "completes".
class RecordingSink implements ByteSink {
  RecordingSink({this.blocking = false});

  bool blocking;
  final List<Uint8List> writes = [];
  final Queue<Completer<void>> _flushes = Queue();
  int _unflushed = 0;

  /// The most frames ever submitted without an intervening completed flush.
  int maxUnflushed = 0;

  @override
  void add(List<int> data) {
    writes.add(Uint8List.fromList(data));
    _unflushed++;
    if (_unflushed > maxUnflushed) maxUnflushed = _unflushed;
  }

  @override
  Future<void> flush() {
    if (!blocking) {
      _unflushed = 0;
      return Future.value();
    }
    final completer = Completer<void>();
    _flushes.add(completer);
    return completer.future.then((_) => _unflushed = 0);
  }

  /// Completes the oldest blocked flush.
  void release() => _flushes.removeFirst().complete();

  void releaseAll() {
    blocking = false;
    while (_flushes.isNotEmpty) {
      release();
    }
  }

  List<Frame> get frames {
    final decoder = FrameDecoder();
    return [for (final w in writes) ...decoder.add(w)];
  }
}

/// A sink feeding another connection's input through memory.
class PipeSink implements ByteSink {
  final StreamController<List<int>> controller = StreamController();

  Stream<List<int>> get stream => controller.stream;

  @override
  void add(List<int> data) => controller.add(Uint8List.fromList(data));

  @override
  Future<void> flush() => Future.value();
}

/// Lets queued events and microtasks run.
Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Two connections wired to each other. B answers `hello`.
(Connection, Connection) connectedPair({
  VersionRange versionsA = const VersionRange(1, 1),
  VersionRange versionsB = const VersionRange(1, 1),
  Set<String> capabilitiesA = const {},
  Set<String> capabilitiesB = const {},
  HelloHandler? onHelloB,
  RequestHandler? onRequestB,
  RequestHandler? onRequestA,
}) {
  final aToB = PipeSink();
  final bToA = PipeSink();
  final a = Connection(
    input: bToA.stream,
    output: aToB,
    versions: versionsA,
    capabilities: capabilitiesA,
    onRequest: onRequestA,
  );
  final b = Connection(
    input: aToB.stream,
    output: bToA,
    versions: versionsB,
    capabilities: capabilitiesB,
    onHello: onHelloB ?? (params, negotiated) => HelloInfo.ready('host-1'),
    onRequest: onRequestB,
  );
  return (a, b);
}
