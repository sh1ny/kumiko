import 'dart:async';
import 'dart:io';

import 'package:host/src/agent/tools/transport_tool_connection.dart';
import 'package:test/test.dart';

void main() {
  test('a burst of writes to a socket arrives whole and in order', () async {
    // IOSink rejects add while a flush is pending; the POSIX endpoint writes
    // each reply with add+flush, so a burst (a binding releasing parked
    // calls) must queue instead of dropping replies.
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final received = <int>[];
    final gotAll = Completer<void>();
    server.listen((s) {
      s.listen((data) {
        received.addAll(data);
        if (received.length >= 8 && !gotAll.isCompleted) gotAll.complete();
      });
    });
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    addTearDown(socket.destroy);
    final write = serializedSinkWriter(socket);
    final writes = [
      for (var i = 0; i < 8; i++) write([48 + i]),
    ];
    await Future.wait(writes);
    await gotAll.future.timeout(const Duration(seconds: 10));
    expect(String.fromCharCodes(received), '01234567');
  });

  test(
    'a failed write fails its own future and later writes still run',
    () async {
      final sink = _FailingOnceSink();
      final write = serializedSinkWriter(sink);
      final first = write([1]);
      final second = write([2]);
      await expectLater(first, throwsA(isA<SocketException>()));
      await second;
      expect(sink.added, [
        [2],
      ]);
    },
  );
}

class _FailingOnceSink implements IOSink {
  final added = <List<int>>[];
  bool _failed = false;

  @override
  void add(List<int> data) {
    if (!_failed) {
      _failed = true;
      throw const SocketException('broken pipe');
    }
    added.add(data);
  }

  @override
  Future<void> flush() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
