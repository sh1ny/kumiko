import 'dart:async';
import 'dart:convert';

import 'package:host/src/agent/omp/omp_client.dart';
import 'package:host_protocol/host_protocol.dart';

class OmpPeer {
  OmpPeer() {
    client = OmpClient(
      input: input.stream,
      write: (bytes) {
        writes.add(jsonDecode(utf8.decode(bytes)) as Json);
        return blockedWrite?.future ?? Future.value();
      },
    );
  }

  final input = StreamController<List<int>>();
  final writes = <Json>[];
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
