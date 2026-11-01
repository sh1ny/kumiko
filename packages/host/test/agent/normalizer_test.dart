import 'dart:convert';

import 'package:host/src/agent/normalizer.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

List<AgentEvent> events(Json update) => [
  for (final bytes in normalizeAcpUpdate(update))
    AgentEvent.fromJson(jsonDecode(utf8.decode(bytes)) as Json),
];
void main() {
  for (final entry in {
    'user_message_chunk': AgentEventKind.user,
    'agent_message_chunk': AgentEventKind.agentText,
    'agent_thought_chunk': AgentEventKind.thought,
  }.entries) {
    test('${entry.key} maps text including load replay', () {
      final result = events({
        'sessionUpdate': entry.key,
        'content': {'type': 'text', 'text': '猫'},
        'future': true,
      });
      expect(result.single.kind, entry.value);
      expect(result.single.text, '猫');
    });
  }
  test(
    'tool_call then updates map to tool/toolUpdate with status and diff',
    () {
      final tool = events({
        'sessionUpdate': 'tool_call',
        'toolCallId': 'opaque',
        'title': 'Edit lib/a.dart',
        'kind': 'edit',
        'status': 'pending',
        'rawInput': {'ignored': 'not reviewed'},
        'locations': [
          {'path': 'lib/a.dart', 'line': 1},
        ],
      }).single;
      final update = events({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'opaque',
        'status': 'completed',
        'content': [
          {
            'type': 'content',
            'content': {'type': 'text', 'text': 'done'},
          },
          {
            'type': 'diff',
            'path': 'lib/a.dart',
            'oldText': 'old',
            'newText': 'new',
          },
          {'type': 'terminal', 'terminalId': 'opaque-terminal'},
        ],
      }).single;
      expect(tool.kind, AgentEventKind.tool);
      expect(tool.title, 'Edit lib/a.dart');
      expect(tool.locations.single['path'], 'lib/a.dart');
      expect(update.kind, AgentEventKind.toolUpdate);
      expect(update.toolCallId, tool.toolCallId);
      expect(update.status, 'completed');
      expect(update.content.map((e) => e['type']), [
        'content',
        'diff',
        'terminal',
      ]);
      expect(update.content[1]['newText'], 'new');
      expect(update.toJson().containsKey('title'), isFalse);
      expect(update.toJson().containsKey('locations'), isFalse);
      expect(tool.toJson().containsKey('rawInput'), isFalse);
    },
  );
  test('plan entries retain content priority status', () {
    final entry = {'content': 'Check', 'priority': 'high', 'status': 'pending'};
    expect(
      events({
        'sessionUpdate': 'plan',
        'entries': [entry],
      }).single.entries,
      [entry],
    );
  });
  test(
    'an unknown sessionUpdate kind yields no event; later chunks still arrive',
    () {
      expect(events({'sessionUpdate': 'future', 'blob': 'ignored'}), isEmpty);
      expect(
        events({
          'sessionUpdate': 'agent_message_chunk',
          'content': {'type': 'text', 'text': 'later'},
        }).single.text,
        'later',
      );
    },
  );
  test('escaped text preserves the raw cap encoded event limits and truncation marker', () {
    final content = <String, Object?>{
      'type': 'text',
      'text': '\u0001' * (maxAgentTextChunkBytes + 1),
    };
    final normalized = normalizeAcpUpdate({
      'sessionUpdate': 'agent_message_chunk',
      'content': content,
    });
    final decoder = AgentEventDecoder();
    var textBytes = 0;
    AgentEvent? last;
    for (final line in normalized) {
      expect(line.length, lessThanOrEqualTo(maxAgentTextEventBytes + 1));
      for (final event in decoder.add(line)) {
        expect(event.text!.runes.every((r) => r == 1), isTrue);
        textBytes += event.text!.length;
        last = event;
      }
    }
    decoder.close();
    expect(textBytes, maxAgentTextChunkBytes);
    expect(last!.truncated, isTrue);
  });
  test('codec bounds split text truncate tool content and plans', () {
    final text = events({
      'sessionUpdate': 'agent_message_chunk',
      'content': {'type': 'text', 'text': 'x' * (maxAgentTextChunkBytes + 1)},
    });
    expect(text.map((e) => e.text!).join().length, maxAgentTextChunkBytes);
    expect(text.last.truncated, isTrue);
    final tool = events({
      'sessionUpdate': 'tool_call',
      'toolCallId': 't',
      'content': [
        {
          'type': 'content',
          'content': {'type': 'text', 'text': '\u0000' * 100000},
        },
      ],
    }).single;
    expect(tool.truncated, isTrue);
    expect(
      utf8.encode(jsonEncode(tool.content.single)).length,
      lessThanOrEqualTo(maxAgentToolItemBytes),
    );
    final plan = events({
      'sessionUpdate': 'plan',
      'entries': List.generate(
        257,
        (_) => {'content': 'x', 'priority': 'high', 'status': 'pending'},
      ),
    }).single;
    expect(plan.entries, hasLength(256));
    expect(plan.omittedItems, 1);
  });
}
