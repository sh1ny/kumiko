import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';

import 'omp_session_file.dart';
import 'omp_tool_activity.dart';

/// Stages one native snapshot. No raw message or arbitrary extension payload
/// survives response decode. The same projection accepts child message entries.
final class OmpHistory {
  OmpHistory(String runId, {this.maxBytes = 1024 * 1024, this.attribute})
    : _tools = OmpToolActivity(cardPrefix: '$runId-history');

  static const pageSize = 50;
  static const maxPages = 32;
  final int maxBytes;
  final AgentEvent Function(AgentEvent)? attribute;
  final OmpToolActivity _tools;
  final _cursors = <String>{};
  final lines = <Uint8List>[];
  int? _total;
  int _seen = 0;
  int _bytes = 0;
  bool _omitted = false;

  static List<Uint8List>? childSnapshot(
    Object? data, {
    required String path,
    required int inspectedSize,
    required String root,
    required String child,
    required String token,
  }) {
    if (data is! Json ||
        data['sessionFile'] != path ||
        data['fromByte'] != 0 ||
        data['reset'] != false ||
        data['nextByte'] is! int ||
        data['entries'] is! List<Object?>) {
      return null;
    }
    final next = data['nextByte']! as int;
    final entries = data['entries']! as List<Object?>;
    if (next <= 0 || next > maxOmpChildHistoryBytes || entries.isEmpty) {
      return null;
    }
    final header = entries.first;
    if (header is! Json ||
        header['type'] != 'session' ||
        header['id'] is! String ||
        (header['id']! as String).isEmpty) {
      return null;
    }
    final snapshot = OmpHistory(
      '$child:$token',
      maxBytes: maxOmpChildHistoryBytes,
      attribute: (event) =>
          event.forOmpChild(rootId: root, childKey: child, viewToken: token),
    );
    if (!snapshot._append(AgentEvent.replay(AgentReplayPhase.start))) {
      return null;
    }
    for (var i = 1; i < entries.length; i++) {
      final entry = entries[i];
      if (entry is! Json || entry['type'] is! String) return null;
      if (entry['type'] == 'message' && !snapshot.add(entry['message'])) {
        return null;
      }
    }
    snapshot._omitted |= next < inspectedSize;
    return snapshot.finish() &&
            snapshot._append(AgentEvent.replay(AgentReplayPhase.end))
        ? snapshot.lines
        : null;
  }

  /// Null is an invalid page; a record containing a null cursor is complete.
  ({String? cursor})? page(Object? data) {
    if (data is! Json ||
        data['messages'] is! List<Object?> ||
        data['totalMessages'] is! int) {
      return null;
    }
    final messages = data['messages']! as List<Object?>;
    final total = data['totalMessages']! as int;
    final cursor = data['nextCursor'];
    _total ??= total;
    if (total != _total ||
        total < 0 ||
        total > maxPages * pageSize ||
        messages.length > pageSize ||
        (cursor != null &&
            (cursor is! String ||
                cursor.isEmpty ||
                cursor.length > 4096 ||
                jsonStringContentBytes(cursor) > 4096 ||
                !_cursors.add(cursor)))) {
      return null;
    }
    _seen += messages.length;
    if (cursor == null
        ? _seen != total
        : (messages.isEmpty || _seen >= total)) {
      return null;
    }
    for (final message in messages) {
      if (!add(message)) return null;
    }
    return (cursor: cursor as String?);
  }

  bool add(Object? message) {
    if (message is! Json) return false;
    final content = message['content'];
    switch (message['role']) {
      case 'user':
        if (!_finishToolCalls()) return false;
        if (content is String) return _text(AgentEventKind.user, content);
        return _blocks(content, AgentEventKind.user);
      case 'assistant':
        return _blocks(content, AgentEventKind.agentText);
      case 'toolResult':
        final error = message['isError'];
        if (error is! bool) {
          _omitted = true;
          return true;
        }
        return _tool('tool_execution_end', {
          'toolCallId': message['toolCallId'],
          'toolName': message['toolName'],
          'result': {'content': content},
          'isError': error,
        });
      default:
        _omitted = true;
        return true;
    }
  }

  bool _blocks(Object? value, AgentEventKind kind) {
    if (value is! List<Object?>) {
      _omitted = true;
      return true;
    }
    for (final block in value) {
      final ok = switch (block) {
        {'type': 'text', 'text': final String text} => _text(kind, text),
        {'type': 'thinking', 'thinking': final String text}
            when kind == AgentEventKind.agentText =>
          _text(AgentEventKind.thought, text),
        {'type': 'toolCall', 'id': final String id, 'name': final String name}
            when kind == AgentEventKind.agentText =>
          _tool('tool_execution_start', {
            'toolCallId': id,
            'toolName': name,
            if (block case {'arguments': final Object? args}) 'args': args,
          }),
        _ => _omit(),
      };
      if (!ok) return false;
    }
    return true;
  }

  bool _omit() => _omitted = true;

  bool _text(AgentEventKind kind, String text) =>
      text.isEmpty || _append(AgentEvent.text(kind, text));

  bool _tool(String type, Json wire) {
    final event = _tools.frame(type, wire, active: true);
    return event == null || _append(event);
  }

  bool _finishToolCalls() {
    for (final event in _tools.finish()) {
      if (!_append(event)) return false;
    }
    _tools.reset();
    return true;
  }

  bool finish() =>
      _finishToolCalls() &&
      (!_omitted ||
          _append(
            AgentEvent.notice('Some recorded OMP content could not be shown.'),
          ));

  bool _append(AgentEvent event) {
    for (final line in encodeAgentEvent(attribute?.call(event) ?? event)) {
      _bytes += line.length;
      if (_bytes > maxBytes) return false;
      lines.add(line);
    }
    return true;
  }
}
