import 'dart:convert';
import 'dart:io';

import 'package:process_containment/process_containment.dart';

/// Independent, test-build-only MCP entry. It emits boolean environment facts,
/// never environment values; one fixed-size workspace report proves an actual
/// tool call and permits PID/start-time descendant settlement verification.
/// The report is rewritten at each stage (`started`, `initialized`, `listed`,
/// `called`), so a walk that never reaches the call still shows how far the
/// probe got, with boolean stage flags and its own identity only.
Future<int> runQualificationMcpProbe(List<String> args) async {
  if (args.length != 2 || args.first != '--report') return 64;
  final report = File(args[1]);
  final facts = <String, Object?>{
    'started': true,
    'pid': pid,
    'startTime': processStartTime(pid),
  };
  Future<void> record() =>
      report.writeAsString('${jsonEncode(facts)}\n', flush: true);
  await record();
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (utf8.encode(line).length > 16384) return 65;
    final request = jsonDecode(line) as Map<String, Object?>;
    final id = request['id'];
    if (id == null) continue;
    final method = request['method'];
    Object result;
    if (method == 'initialize') {
      facts['initialized'] = true;
      await record();
      result = {
        'protocolVersion': '2025-06-18',
        'capabilities': {'tools': <String, Object?>{}},
        'serverInfo': {'name': 'kumiko-qualification-probe', 'version': '1'},
      };
    } else if (method == 'tools/list') {
      facts['listed'] = true;
      await record();
      result = {
        'tools': [
          {
            'name': 'env_presence',
            'description': 'Return boolean secret-isolation facts only.',
            // It reads only environment presence. Without annotations,
            // Codex's default MCP approval mode treats a tool as destructive.
            'annotations': {
              'readOnlyHint': true,
              'destructiveHint': false,
              'openWorldHint': false,
            },
            'inputSchema': {
              'type': 'object',
              'properties': <String, Object?>{},
            },
          },
        ],
      };
    } else if (method == 'tools/call' &&
        (request['params'] as Map?)?['name'] == 'env_presence') {
      final called = {
        'called': true,
        'secretPresent': Platform.environment.containsKey('KUMIKO_TOOL_SECRET'),
        'endpointPresent': Platform.environment.containsKey(
          'KUMIKO_TOOL_ENDPOINT',
        ),
        'pid': facts['pid'],
        'startTime': facts['startTime'],
      };
      facts.addAll(called);
      await record();
      result = {
        'content': [
          {'type': 'text', 'text': jsonEncode(called)},
        ],
        'structuredContent': called,
      };
    } else if (method == 'ping') {
      result = <String, Object?>{};
    } else {
      stdout.writeln(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'error': {
            'code': -32601,
            'message': 'unsupported qualification request',
          },
        }),
      );
      continue;
    }
    stdout.writeln(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
    await stdout.flush();
  }
  return 0;
}
