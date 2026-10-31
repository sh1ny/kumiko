import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:host/src/agent/acp/acp_client.dart';
import 'package:host_protocol/host_protocol.dart';

/// Injectable byte peer; production framing, parsing and state remain real.
class AcpPeer {
  AcpPeer({LargeLinePermit? permit}) {
    client = AcpClient(
      input: input.stream,
      write: (bytes) {
        writes.add(jsonDecode(utf8.decode(bytes)) as Json);
        return blockedWrite?.future ?? Future<void>.value();
      },
      largeLinePermit: permit,
    );
  }
  final input = StreamController<List<int>>();
  final writes = <Json>[];
  Completer<void>? blockedWrite;
  late final AcpClient client;
  void send(Json message) => input.add(utf8.encode('${jsonEncode(message)}\n'));
  void result(Object id, Json result) =>
      send({'jsonrpc': '2.0', 'id': id, 'result': result});
  void error(Object id, int code, String message) => send({
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  });
  void update(Json update) => send({
    'jsonrpc': '2.0',
    'method': 'session/update',
    'params': {'sessionId': 'native', 'update': update},
  });
  void permission(Object id, {String optionId = 'opaque/allow'}) => send({
    'jsonrpc': '2.0',
    'id': id,
    'method': 'session/request_permission',
    'params': {
      'sessionId': 'native',
      'toolCall': {'toolCallId': 'tool', 'title': 'Execute'},
      'options': [
        {'optionId': optionId, 'name': 'Allow', 'kind': 'allow_once'},
      ],
    },
  });
  Future<void> dispose() async {
    await client.close();
    blockedWrite?.complete();
    await input.close();
  }
}

/// A single event-loop barrier, not a wall-clock delay or polling loop.
Future<void> pumpAcp() => Future<void>(() {});

Uint8List largeUpdate(int textBytes) => utf8.encode(
  '${jsonEncode({
    'jsonrpc': '2.0',
    'method': 'session/update',
    'params': {
      'sessionId': 'native',
      'update': {
        'sessionUpdate': 'agent_message_chunk',
        'content': {'type': 'text', 'text': 'x' * textBytes},
      },
    },
  })}\n',
);

void addChunks(AcpPeer peer, List<int> bytes, {bool newline = true}) {
  final length = newline ? bytes.length : bytes.length - 1;
  for (var start = 0; start < length; start += 65536) {
    final end = start + 65536 < length ? start + 65536 : length;
    peer.input.add(Uint8List.sublistView(bytes as Uint8List, start, end));
  }
}
