import 'dart:convert';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

List<AgentEvent> _round(AgentEvent event) {
  final decoder = AgentEventDecoder();
  final result = [
    for (final bytes in encodeAgentEvent(event)) ...decoder.add(bytes),
  ];
  decoder.close();
  return result;
}

void main() {
  test(
    'newline-delimited JSON round-trip of each kind without loss below bounds',
    () {
      final events = [
        AgentEvent.text(AgentEventKind.user, 'prompt\n😀'),
        AgentEvent.text(AgentEventKind.agentText, 'hello'),
        AgentEvent.text(AgentEventKind.thought, 'thinking'),
        AgentEvent.tool(
          toolCallId: 't',
          title: 'read',
          status: 'pending',
          content: [
            {'type': 'text', 'text': 'value'},
          ],
          locations: [
            {'path': '/a', 'line': 2},
          ],
        ),
        AgentEvent.tool(
          toolCallId: 't',
          update: true,
          status: 'completed',
          content: [
            {'type': 'diff', 'path': '/a', 'oldText': 'a', 'newText': 'b'},
          ],
        ),
        AgentEvent.plan([
          {'content': 'one', 'priority': 'high', 'status': 'pending'},
        ]),
        AgentEvent.notice('warning'),
        AgentEvent.replay(AgentReplayPhase.start),
        AgentEvent.replay(AgentReplayPhase.end),
        AgentEvent.turn('end_turn'),
      ];
      for (final event in events) {
        final encoded = encodeAgentEvent(event).toList();
        expect(encoded.single.last, 10);
        expect(_round(event).single.toJson(), event.toJson());
      }
    },
  );

  test(
    'text over64KiB encoded splits on code points with escaping counted',
    () {
      for (final unit in ['😀值', '"\n\t\u0000\\']) {
        final text = unit * 20000;
        final event = AgentEvent.text(AgentEventKind.agentText, text);
        final frames = encodeAgentEvent(event).toList();
        expect(frames.length, greaterThan(1));
        for (final line in frames) {
          expect(line.length - 1, lessThanOrEqualTo(64 * 1024));
          expect(utf8.decode(line), isNot(contains('�')));
        }
        expect(_round(event).map((e) => e.text).join(), text);
      }
    },
  );

  test('all text kinds preserve empty and exact boundary chunks', () {
    for (final kind in [
      AgentEventKind.user,
      AgentEventKind.agentText,
      AgentEventKind.thought,
    ]) {
      for (final text in ['', 'a' * 65536, '值' * 20000]) {
        final events = _round(AgentEvent.text(kind, text));
        expect(events.map((e) => e.text).join(), text);
        expect(events.any((e) => e.truncated), isFalse);
      }
    }
  });

  test('one adapter text chunk capped at1MiB with truncated marker', () {
    final result = _round(
      AgentEvent.text(AgentEventKind.thought, '😀' * (300 * 1024)),
    );
    expect(utf8.encode(result.map((e) => e.text).join()).length, 1024 * 1024);
    expect(result.last.truncated, isTrue);
    expect(result.every((e) => e.kind == AgentEventKind.thought), isTrue);
  });

  test('tool content over the bound is truncated with truncated true within256KiB encoded', () {
    final event = AgentEvent.tool(
      toolCallId: 't',
      title: 'output',
      content: [
        for (var i = 0; i < 10; i++)
          {'type': 'text', 'text': '$i${'"\n😀' * 40000}'},
      ],
      locations: [
        for (var i = 0; i < 70; i++) {'path': '/$i'},
      ],
    );
    final lines = encodeAgentEvent(event).toList();
    expect(lines.single.length - 1, lessThanOrEqualTo(256 * 1024));
    final back = _round(event).single;
    expect(back.truncated, isTrue);
    expect(back.toJson()['contentTruncated'], isTrue);
    expect(back.toJson()['locationsTruncated'], isTrue);
    expect(back.omittedItems, greaterThan(0));
    expect(back.content.length + back.omittedItems, 10);
    for (var i = 0; i < back.content.length; i++) {
      expect(
        utf8.encode(jsonEncode(back.content[i])).length,
        lessThanOrEqualTo(64 * 1024),
      );
      expect(back.content[i]['text'] as String, startsWith('$i'));
    }
    expect(back.locations, hasLength(64));
    expect(_round(AgentEvent.notice('later')).single.text, 'later');
  });

  test('locations-only truncation stays distinct from complete content through re-encoding', () {
    final back = _round(AgentEvent.tool(
      toolCallId: 'located',
      content: [{'type': 'text', 'text': 'complete content'}],
      locations: [for (var i = 0; i < 65; i++) {'path': 'file-$i.dart'}],
    )).single;
    expect(back.locations, hasLength(64));
    expect(back.content.single['text'], 'complete content');
    expect(back.truncated, isTrue);
    expect(back.toJson()['locationsTruncated'], isTrue);
    expect(back.toJson()['contentTruncated'], isNot(true));
    expect(back.omittedItems, 0);
    expect(_round(back).single.toJson(), back.toJson());
  });

  test(
    'exactly fitting tool event does not reserve unnecessary loss markers',
    () {
      final empty = AgentEvent.tool(
        toolCallId: 't',
        title: '',
        content: [
          {'type': 'text', 'text': 'keep'},
        ],
      );
      final padding =
          maxAgentEventBytes - utf8.encode(jsonEncode(empty.toJson())).length;
      final event = AgentEvent.tool(
        toolCallId: 't',
        title: 'a' * padding,
        content: [
          {'type': 'text', 'text': 'keep'},
        ],
      );
      final encoded = encodeAgentEvent(event).single;
      expect(encoded.length - 1, maxAgentEventBytes);
      final back = _round(event).single;
      expect(back.kind, AgentEventKind.tool);
      expect(back.content.single['text'], 'keep');
      expect(back.truncated, isFalse);
      expect(back.omittedItems, 0);
    },
  );

  test('plan clamps256 entries of1KiB and cuts under total cap in order', () {
    final back = _round(
      AgentEvent.plan([
        for (var i = 0; i < 300; i++)
          {'content': '$i${'"\n' * 1024}', 'status': 'pending'},
      ]),
    ).single;
    expect(back.entries.length, lessThanOrEqualTo(256));
    expect(back.entries.length + back.omittedItems, 300);
    expect(back.truncated, isTrue);
    for (var i = 0; i < back.entries.length; i++) {
      expect(
        utf8.encode(jsonEncode(back.entries[i])).length,
        lessThanOrEqualTo(1024),
      );
      expect(back.entries[i]['content'] as String, startsWith('$i'));
      expect(back.entries[i]['status'], 'pending');
    }
    expect(
      encodeAgentEvent(back).single.length - 1,
      lessThanOrEqualTo(256 * 1024),
    );
  });

  test('oversized metadata becomes bounded notice never session failure', () {
    for (final event in [
      AgentEvent.tool(toolCallId: 'x' * (300 * 1024), content: const []),
      AgentEvent.tool(
        toolCallId: 't',
        locations: [
          {'path': 'x' * (300 * 1024)},
        ],
      ),
      AgentEvent.turn('x' * (300 * 1024)),
    ]) {
      final back = _round(event).single;
      expect(back.kind, AgentEventKind.notice);
      expect(back.text, contains('too large'));
      expect(back.truncated, isTrue);
    }
  });

  test('decoder handles partial lines UTF8 and multiple events per frame', () {
    final bytes = [
      ...encodeAgentEvent(AgentEvent.text(AgentEventKind.user, '😀\n值')).single,
      ...encodeAgentEvent(AgentEvent.turn('cancelled')).single,
    ];
    final decoder = AgentEventDecoder();
    final events = <AgentEvent>[];
    for (final byte in bytes) {
      events.addAll(decoder.add([byte]));
    }
    decoder.close();
    expect(events.map((e) => e.kind), [
      AgentEventKind.user,
      AgentEventKind.turn,
    ]);
    expect(events.first.text, '😀\n值');
  });

  test('desktop decoder rejects malformed unknown and incomplete events', () {
    for (final line in [
      '[]\n',
      '{}\n',
      '{"kind":"alien"}\n',
      '{"kind":"agentText","text":3}\n',
      '{"kind":"tool","toolCallId":"t","contentTruncated":"yes"}\n',
      '{"kind":"toolUpdate","toolCallId":"t","locationsTruncated":1}\n',
      'not json\n',
    ]) {
      expect(
        () => AgentEventDecoder().add(utf8.encode(line)),
        throwsFormatException,
      );
    }
    expect(() => AgentEventDecoder().add([0xff, 10]), throwsFormatException);
    final partial = AgentEventDecoder()..add(utf8.encode('{"kind":'));
    expect(partial.close, throwsFormatException);
  });

  test(
    'desktop decoder rejects host violations of per-kind normalized bounds',
    () {
      for (final json in <Json>[
        {'kind': 'agentText', 'text': 'a' * 65536},
        {
          'kind': 'tool',
          'toolCallId': 't',
          'content': [
            {'text': 'a' * 65536},
          ],
        },
        {
          'kind': 'toolUpdate',
          'toolCallId': 't',
          'locations': List.filled(65, {'path': '/a'}),
        },
        {
          'kind': 'plan',
          'entries': List.filled(257, {'content': 'a'}),
        },
        {
          'kind': 'plan',
          'entries': [
            {'content': 'a' * 1024},
          ],
        },
        {'kind': 'notice', 'text': 'x', 'truncated': 'yes'},
        {
          'kind': 'tool',
          'toolCallId': 't',
          'content': [3],
        },
      ]) {
        expect(
          () => AgentEventDecoder().add(utf8.encode('${jsonEncode(json)}\n')),
          throwsFormatException,
        );
      }
    },
  );

  test('desktop decoder refuses oversized line with bounded reassembly', () {
    final decoder = AgentEventDecoder();
    decoder.add(utf8.encode(' ' * (256 * 1024)));
    expect(
      () => decoder.add(List.filled(64 * 1024, 32)),
      throwsFormatException,
    );
    expect(decoder.bufferedBytes, lessThanOrEqualTo(256 * 1024 + 64 * 1024));
    final oversized = utf8.encode(
      '${jsonEncode({'kind': 'notice', 'text': 'a' * (256 * 1024)})}\n',
    );
    expect(() => AgentEventDecoder().add(oversized), throwsFormatException);
  });
}
