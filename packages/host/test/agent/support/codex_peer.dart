import 'dart:async';
import 'dart:convert';

import 'package:host/src/agent/acp/acp_client.dart' show LargeLinePermit;
import 'package:host/src/agent/codex/codex_client.dart';
import 'package:host_protocol/host_protocol.dart';

/// Scripted in-memory byte peer. This fixture is test-package-only and cannot
/// add a mode to the release host or discover an installed runtime.
class CodexPeer {
  CodexPeer({LargeLinePermit? permit}) {
    client = CodexClient(
      input: input.stream,
      write: (bytes) {
        for (final line in const LineSplitter().convert(utf8.decode(bytes))) {
          final message = jsonDecode(line) as Json;
          writes.add(message);
          onWrite?.call(message);
        }
        return blockedWrite?.future ?? Future.value();
      },
      largeLinePermit: permit,
    );
  }
  final input = StreamController<List<int>>();
  final writes = <Json>[];
  Completer<void>? blockedWrite;
  void Function(Json message)? onWrite;
  late final CodexClient client;
  void send(Json message) => input.add(utf8.encode('${jsonEncode(message)}\n'));
  void result(Object id, Json result) => send({'id': id, 'result': result});
  void event(String method, Json params) =>
      send({'method': method, 'params': params});
  Future<void> dispose() async {
    await client.close();
    if (blockedWrite case final block? when !block.isCompleted) {
      block.complete();
    }
    if (!input.isClosed) await input.close();
  }
}

Future<void> pumpCodex() => Future<void>(() {});
