import 'dart:convert';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';

/// Normalizes root tool snapshots without retaining native argument or result
/// objects. Reset at each terminal result or refused admission; card IDs never
/// repeat during the run.
final class OmpToolActivity {
  OmpToolActivity({this.cardPrefix = 'omp'});

  final String cardPrefix;
  static const _maxOpen = 16;
  static const _maxClosed = 256;
  static const _identityBytes = 256;
  static const _argumentBytes = 4096;
  static final _encoder = JsonUtf8Encoder(null, null, 512);
  static final _elision = RegExp(
    r'…\[\d+ (?:chars|items) elided for RPC frame\]',
  );

  final _open = <String, _Tool>{};
  final _closed = <String>{};
  int _nextCard = 0;
  bool _noted = false;
  bool _notedIdle = false;

  AgentEvent? omitted({required bool active}) {
    if (!active) {
      if (_notedIdle) return null;
      _notedIdle = true;
      return AgentEvent.notice(
        'OMP tool activity outside a prompt was omitted.',
      );
    }
    if (_noted) return null;
    _noted = true;
    return AgentEvent.notice(
      'Some OMP tool activity is incomplete or was omitted.',
    );
  }

  AgentEvent? frame(String type, Json frame, {required bool active}) {
    if (frame.containsKey('childSessionId') ||
        frame.containsKey('subagentId') ||
        frame.containsKey('parentToolCallId')) {
      return null;
    }
    if (!active) return omitted(active: false);
    final id = frame['toolCallId'];
    final name = frame['toolName'];
    if (!_validIdentity(id) || !_validIdentity(name)) {
      return omitted(active: true);
    }
    final key = id! as String;
    final toolName = name! as String;
    final existing = _open[key];
    if (type == 'tool_execution_start') {
      if (existing != null ||
          _closed.contains(key) ||
          _open.length >= _maxOpen) {
        return omitted(active: true);
      }
      final (arguments, clipped) = frame.containsKey('args')
          ? _arguments(frame['args'])
          : (null, false);
      final tool = _Tool(
        '$cardPrefix-tool-${++_nextCard}',
        toolName,
        arguments,
        clipped,
      );
      _open[key] = tool;
      return _snapshot(tool);
    }
    if (existing == null || existing.name != toolName) {
      return omitted(active: true);
    }
    if (type == 'tool_execution_update') {
      return _snapshot(existing, update: true, result: frame['partialResult']);
    }
    final error = frame['isError'];
    if (!frame.containsKey('result') ||
        (frame.containsKey('isError') && error is! bool)) {
      return omitted(active: true);
    }
    _open.remove(key);
    _closed.add(key);
    if (_closed.length > _maxClosed) _closed.remove(_closed.first);
    return _snapshot(
      existing,
      update: true,
      status: error == true ? 'failed' : 'completed',
      result: frame['result'],
    );
  }

  static bool _validIdentity(Object? value) =>
      value is String &&
      value.isNotEmpty &&
      value.length <= _identityBytes &&
      jsonStringContentBytes(value) <= _identityBytes &&
      !_elision.hasMatch(value);

  static (Json?, bool) _arguments(Object? value) {
    final sink = _ArgumentPrefix(_argumentBytes);
    var clipped = false;
    try {
      _encoder.startChunkedConversion(sink).add(value);
    } on _PreviewFull {
      clipped = true;
    } on StackOverflowError {
      // A recursively nested argument can exceed the stringifier's stack.
      return (null, true);
    }
    final text = utf8.decode(sink.bytes.takeBytes(), allowMalformed: true);
    return (_text('Input: $text'), clipped || _elision.hasMatch(text));
  }

  static Json _text(String value) => {'type': 'text', 'text': value};

  static AgentEvent _snapshot(
    _Tool tool, {
    bool update = false,
    String status = 'in_progress',
    Object? result,
  }) {
    final args = tool.arguments;
    final content = <Json>[?args];
    var clipped = tool.clipped;
    var omitted = 0;
    if (update) {
      final blocks = result is Json ? result['content'] : null;
      if (blocks is! List<Object?>) {
        clipped = true;
      } else {
        var remaining = maxAgentEventBytes - _argumentBytes * 2 - 1024;
        const overhead = 32; // text block keys, discriminator and separator
        for (var i = 0; i < blocks.length; i++) {
          final block = blocks[i];
          if (block is! Json ||
              block['type'] != 'text' ||
              block['text'] is! String) {
            omitted++;
            continue;
          }
          if (remaining <= overhead) {
            omitted += blocks.length - i;
            break;
          }
          final text = block['text']! as String;
          final bounded = clampJsonString(
            text,
            (remaining - overhead).clamp(0, maxAgentToolItemBytes - overhead),
          );
          clipped |= bounded.length < text.length || _elision.hasMatch(bounded);
          content.add(_text(bounded));
          remaining -= jsonStringContentBytes(bounded) + overhead;
        }
      }
    }
    final event = AgentEvent.tool(
      toolCallId: tool.card,
      update: update,
      title: update ? null : tool.name,
      status: status,
      content: content,
    );
    if (!clipped && omitted == 0) return event;
    return AgentEvent.fromJson({
      ...event.toJson(),
      'contentTruncated': true,
      'truncated': true,
      if (omitted != 0) 'omittedItems': omitted,
    });
  }

  Iterable<AgentEvent> finish() sync* {
    for (final tool in _open.values) {
      // Keep the last snapshot and do not assert a native outcome.
      yield AgentEvent.tool(
        toolCallId: tool.card,
        update: true,
        status: 'incomplete',
      );
    }
  }

  void reset() {
    _open.clear();
    _closed.clear();
    _noted = false;
    _notedIdle = false;
  }
}

final class _Tool {
  const _Tool(this.card, this.name, this.arguments, this.clipped);
  final String card, name;
  final Json? arguments;
  final bool clipped;
}

final class _PreviewFull implements Exception {
  const _PreviewFull();
}

/// Throw from the chunked stringifier at the first byte past the bound.
final class _ArgumentPrefix implements Sink<List<int>> {
  _ArgumentPrefix(this.limit);
  final int limit;
  final bytes = BytesBuilder();

  @override
  void add(List<int> data) {
    final remaining = limit - bytes.length;
    if (data.length <= remaining) {
      bytes.add(data);
    } else {
      if (remaining != 0) bytes.add(data.sublist(0, remaining));
      throw const _PreviewFull();
    }
  }

  @override
  void close() {}
}
