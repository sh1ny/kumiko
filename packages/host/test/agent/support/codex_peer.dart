import 'dart:async';
import 'dart:convert';

import 'package:host/src/agent/acp/acp_client.dart' show LargeLinePermit;
import 'package:host/src/agent/codex/codex_client.dart';
import 'package:host_protocol/host_protocol.dart';

/// Scripted in-memory byte peer. This fixture is test-package-only and cannot
/// add a mode to the release host or discover an installed runtime.
class CodexPeer {
  CodexPeer({LargeLinePermit? permit, Duration? configReadTimeout}) {
    client = _PeerClient(
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
      configReadTimeout: configReadTimeout,
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

class _PeerClient extends CodexClient {
  _PeerClient({
    required super.input,
    required super.write,
    super.largeLinePermit,
    this.configReadTimeout,
  });
  final Duration? configReadTimeout;
  @override
  Future<T> request<T>(
    String method,
    Json params, {
    required T Function(Object? result) decodeResult,
    Duration timeout = const Duration(seconds: 60),
    bool requireAdmission = false,
    List<Json> preceding = const [],
    bool pauseForOutput = true,
  }) => super.request(
    method,
    params,
    decodeResult: decodeResult,
    timeout: method == 'config/read' ? configReadTimeout ?? timeout : timeout,
    requireAdmission: requireAdmission,
    preceding: preceding,
    pauseForOutput: pauseForOutput,
  );
}

Future<void> pumpCodex() => Future<void>(() {});
