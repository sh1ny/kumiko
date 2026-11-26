import 'dart:async';
import 'dart:convert';

import 'package:host/src/agent/omp/omp_client.dart';
import 'package:host_protocol/host_protocol.dart';

class OmpPeer {
  OmpPeer() {
    client = OmpClient(
      input: input.stream,
      write: (bytes) {
        for (final line in const LineSplitter().convert(utf8.decode(bytes))) {
          final command = jsonDecode(line) as Json;
          writes.add(command);
          _writeSignals.remove(writes.length - 1)?.complete(command);
        }
        return blockedWrite?.future ?? Future.value();
      },
    );
  }

  final input = StreamController<List<int>>();
  final writes = <Json>[];
  final _writeSignals = <int, Completer<Json>>{};

  Future<Json> commandAt(int index) => index < writes.length
      ? Future.value(writes[index])
      : (_writeSignals[index] ??= Completer<Json>()).future;
  Completer<void>? blockedWrite;
  late final OmpClient client;

  void send(Json value) => input.add(utf8.encode('${jsonEncode(value)}\n'));

  void result(String id, [Object? data]) =>
      send({'type': 'response', 'id': id, 'success': true, 'data': ?data});

  Future<void> dispose() async {
    await client.close();
    blockedWrite?.complete();
    await input.close();
  }
}
