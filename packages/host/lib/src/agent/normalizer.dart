import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';

/// Reviewed ACP v1 updates only. The shared event codec is the single source
/// of truncation/encoded-byte policy. Text is snapshotted and raw-bounded
/// synchronously, before ACP releases its large-line permit. Its wire encoding
/// is lazy: escaping must not retain a multi-MiB list behind stalled credit.
/// Tool/plan normalization eagerly finishes their single bounded event.
Iterable<Uint8List> normalizeAcpUpdate(Json update) {
  AgentEvent? event;
  final kind = update['sessionUpdate'];
  if (kind == 'user_message_chunk' ||
      kind == 'agent_message_chunk' ||
      kind == 'agent_thought_chunk') {
    final content = update['content'];
    if (content is Json &&
        content['type'] == 'text' &&
        content['text'] is String) {
      final source = content['text']! as String;
      final text = clampUtf8(source, maxAgentTextChunkBytes);
      final eventKind = kind == 'user_message_chunk'
          ? AgentEventKind.user
          : kind == 'agent_message_chunk'
          ? AgentEventKind.agentText
          : AgentEventKind.thought;
      return encodeAgentEvent(
        AgentEvent.fromJson({
          'kind': eventKind.name,
          'text': text,
          if (text.length != source.length) 'truncated': true,
        }),
      );
    }
  } else if (kind == 'tool_call' || kind == 'tool_call_update') {
    final id = update['toolCallId'];
    if (id is! String) return const [];
    final content = update['content'];
    final locations = update['locations'];
    event = AgentEvent.tool(
      toolCallId: id,
      update: kind == 'tool_call_update',
      title: update['title'] as String?,
      status: update['status'] as String?,
      toolKind: update['kind'] as String?,
      content: content is List
          ? [
              for (final item in content)
                if (item is Json) ..._toolContent(item),
            ]
          : null,
      locations: locations is List
          ? [
              for (final location in locations)
                if (location is Json)
                  {'path': ?location['path'], 'line': ?location['line']},
            ]
          : null,
    );
  } else if (kind == 'plan') {
    final entries = update['entries'];
    if (entries is List) {
      event = AgentEvent.plan([
        for (final entry in entries)
          if (entry is Json)
            {
              'content': ?entry['content'],
              'priority': ?entry['priority'],
              'status': ?entry['status'],
            },
      ]);
    }
  }
  return event == null ? const [] : encodeAgentEvent(event).toList();
}

Iterable<Json> _toolContent(Json item) sync* {
  switch (item['type']) {
    case 'content':
      final content = item['content'];
      if (content is Json &&
          content['type'] == 'text' &&
          content['text'] is String) {
        yield {
          'type': 'content',
          'content': {'type': 'text', 'text': content['text']},
        };
      }
    case 'diff':
      yield {
        'type': 'diff',
        'path': ?item['path'],
        'oldText': ?item['oldText'],
        'newText': ?item['newText'],
      };
    case 'terminal':
      yield {'type': 'terminal', 'terminalId': ?item['terminalId']};
  }
}
