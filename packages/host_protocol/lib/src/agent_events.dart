import 'dart:convert';
import 'dart:typed_data';

import 'messages.dart';

const int maxAgentEventBytes = 256 * 1024;
const int maxAgentTextEventBytes = 64 * 1024;
const int maxAgentTextChunkBytes = 1024 * 1024;
const int maxAgentToolItemBytes = 64 * 1024;
const int maxAgentLocations = 64;
const int maxAgentPlanEntries = 256;
const int maxAgentPlanEntryBytes = 1024;
const int maxAgentEventFrameBytes = 64 * 1024;
const int maxAgentEventReassemblyBytes =
    maxAgentEventBytes + maxAgentEventFrameBytes;

enum AgentEventKind {
  user,
  agentText,
  thought,
  tool,
  toolUpdate,
  plan,
  notice,
  replay,
  turn,
}

enum AgentReplayPhase { start, end }

/// Normalized transcript event, independent of ACP. No session id is needed:
/// the channel identifies its session. Optional tool fields retain partial
/// updates; content and locations are JSON objects (text/diff/resource data).
/// Use [encodeAgentEvent], not [toJson], when writing to a channel: it applies
/// the host's size policy. [fromJson] validates a received wire event.
class AgentEvent {
  const AgentEvent._(this.kind, this._fields);

  factory AgentEvent.text(AgentEventKind kind, String text) {
    if (!_textKind(kind)) throw ArgumentError.value(kind, 'kind');
    return AgentEvent._(kind, {'text': text});
  }
  factory AgentEvent.tool({
    required String toolCallId,
    bool update = false,
    String? title,
    String? status,
    String? toolKind,
    List<Json>? content,
    List<Json>? locations,
  }) => AgentEvent._(update ? AgentEventKind.toolUpdate : AgentEventKind.tool, {
    'toolCallId': toolCallId,
    'title': ?title,
    'status': ?status,
    'toolKind': ?toolKind,
    'content': ?content,
    'locations': ?locations,
  });
  factory AgentEvent.plan(List<Json> entries) =>
      AgentEvent._(AgentEventKind.plan, {'entries': entries});
  factory AgentEvent.notice(String text) =>
      AgentEvent._(AgentEventKind.notice, {'text': text});
  factory AgentEvent.replay(AgentReplayPhase phase) =>
      AgentEvent._(AgentEventKind.replay, {'phase': phase.name});
  factory AgentEvent.turn(String stopReason) =>
      AgentEvent._(AgentEventKind.turn, {'stopReason': stopReason});

  factory AgentEvent.fromJson(Json json) {
    final name = json['kind'];
    final kind = AgentEventKind.values.where((k) => k.name == name).firstOrNull;
    if (kind == null) throw const FormatException('unknown agent event kind');
    void string(String key, {bool mandatory = true}) {
      if ((!mandatory && !json.containsKey(key)) || json[key] is String) return;
      throw FormatException('invalid agent event $key');
    }

    void objects(String key, {bool mandatory = true}) {
      if (!mandatory && !json.containsKey(key)) return;
      final value = json[key];
      if (value is! List<Object?> || value.any((e) => e is! Json)) {
        throw FormatException('invalid agent event $key');
      }
    }

    if (_textKind(kind) || kind == AgentEventKind.notice) string('text');
    if (kind == AgentEventKind.tool || kind == AgentEventKind.toolUpdate) {
      string('toolCallId');
      for (final key in ['title', 'status', 'toolKind']) {
        string(key, mandatory: false);
      }
      objects('content', mandatory: false);
      objects('locations', mandatory: false);
    }
    if (kind == AgentEventKind.plan) objects('entries');
    if (kind == AgentEventKind.turn) string('stopReason');
    if (kind == AgentEventKind.replay &&
        json['phase'] != 'start' &&
        json['phase'] != 'end') {
      throw const FormatException('invalid replay phase');
    }
    if (json.containsKey('truncated') && json['truncated'] is! bool) {
      throw const FormatException('invalid truncated marker');
    }
    if (json.containsKey('omittedItems') &&
        (json['omittedItems'] is! int || (json['omittedItems']! as int) < 0)) {
      throw const FormatException('invalid omittedItems');
    }
    final fields = Map<String, Object?>.of(json)..remove('kind');
    return AgentEvent._(kind, fields);
  }

  final AgentEventKind kind;
  final Json _fields;
  String? get text => _fields['text'] as String?;
  String? get toolCallId => _fields['toolCallId'] as String?;
  String? get title => _fields['title'] as String?;
  String? get status => _fields['status'] as String?;
  String? get toolKind => _fields['toolKind'] as String?;
  String? get stopReason => _fields['stopReason'] as String?;
  AgentReplayPhase? get phase => kind == AgentEventKind.replay
      ? AgentReplayPhase.values.byName(_fields['phase']! as String)
      : null;
  List<Json> get content =>
      (_fields['content'] as List<Object?>? ?? const []).cast<Json>();
  List<Json> get locations =>
      (_fields['locations'] as List<Object?>? ?? const []).cast<Json>();
  List<Json> get entries =>
      (_fields['entries'] as List<Object?>? ?? const []).cast<Json>();
  bool get truncated => _fields['truncated'] == true;
  int get omittedItems => _fields['omittedItems'] as int? ?? 0;
  Json toJson() => {'kind': kind.name, ..._fields};
}

bool _textKind(AgentEventKind kind) =>
    kind == AgentEventKind.user ||
    kind == AgentEventKind.agentText ||
    kind == AgentEventKind.thought;

int _rawRuneBytes(int rune) => rune < 0x80
    ? 1
    : rune < 0x800
    ? 2
    : rune < 0x10000
    ? 3
    : 4;
int _jsonRuneBytes(int rune) {
  if (rune == 34 ||
      rune == 92 ||
      rune == 8 ||
      rune == 9 ||
      rune == 10 ||
      rune == 12 ||
      rune == 13) {
    return 2;
  }
  if (rune < 32 || (rune >= 0xd800 && rune <= 0xdfff)) return 6;
  return _rawRuneBytes(rune);
}

Uint8List _line(Json json) => utf8.encoder.convert('${jsonEncode(json)}\n');
final Json _tooLarge = {
  'kind': 'notice',
  'text': 'An event was too large to show.',
  'truncated': true,
};

/// Host normalization and NDJSON encoding. Bounds exclude the LF delimiter.
/// Text splits without loss below the 1 MiB source cap. Tool/plan items retain
/// their order; shortened items and omissions are visible. Oversized metadata
/// becomes a notice, never a session failure. Work is linear in source size:
/// items are bounded/encoded once and totals are accumulated before one final
/// event serialization.
Iterable<Uint8List> encodeAgentEvent(AgentEvent event) sync* {
  if (_textKind(event.kind)) {
    final source = event.text!;
    final text = clampUtf8(source, maxAgentTextChunkBytes);
    final truncated = event.truncated || text.length != source.length;
    final overhead = utf8
        .encode(
          jsonEncode({'kind': event.kind.name, 'text': '', 'truncated': true}),
        )
        .length;
    final budget = maxAgentTextEventBytes - overhead;
    var start = 0;
    var end = 0;
    var size = 0;
    for (final rune in text.runes) {
      final cost = _jsonRuneBytes(rune);
      if (size + cost > budget) {
        yield _line({
          'kind': event.kind.name,
          'text': text.substring(start, end),
        });
        start = end;
        size = 0;
      }
      size += cost;
      end += rune > 0xffff ? 2 : 1;
    }
    yield _line({
      'kind': event.kind.name,
      'text': text.substring(start, end),
      if (truncated) 'truncated': true,
    });
    return;
  }
  var json = event.toJson();
  if (event.kind == AgentEventKind.tool ||
      event.kind == AgentEventKind.toolUpdate ||
      event.kind == AgentEventKind.plan) {
    final plan = event.kind == AgentEventKind.plan;
    final key = plan ? 'entries' : 'content';
    final input = plan ? event.entries : event.content;
    var truncated = event.truncated;
    if (!plan && json.containsKey('locations')) {
      if (event.locations.length > maxAgentLocations) {
        json['locations'] = event.locations.take(maxAgentLocations).toList();
        truncated = true;
      }
    }
    final hasItems = plan || json.containsKey(key);
    final base = {...json, if (hasItems) key: <Json>[]}
      ..remove('truncated')
      ..remove('omittedItems');
    final baseBytes = utf8.encode(jsonEncode(base)).length;
    final candidates = <Json>[];
    final prefixBytes = <int>[0];
    final prefixTruncated = <bool>[truncated];
    final count = plan && input.length > maxAgentPlanEntries
        ? maxAgentPlanEntries
        : input.length;
    for (var i = 0; i < count; i++) {
      final bounded = _boundItem(
        input[i],
        plan ? maxAgentPlanEntryBytes : maxAgentToolItemBytes,
      );
      if (bounded == null) break;
      final itemBytes = utf8.encode(jsonEncode(bounded)).length;
      candidates.add(bounded);
      prefixBytes.add(prefixBytes.last + itemBytes + (i == 0 ? 0 : 1));
      prefixTruncated.add(
        prefixTruncated.last || !identical(bounded, input[i]),
      );
      // Once even the marker-free prefix exceeds the cap, later items cannot
      // make it fit. Keep this one candidate for exact prefix selection below.
      if (baseBytes + prefixBytes.last > maxAgentEventBytes) break;
    }
    int omittedAt(int n) => input.length - n + event.omittedItems;
    int sizeAt(int n) {
      final omitted = omittedAt(n);
      return baseBytes +
          prefixBytes[n] +
          (prefixTruncated[n] || omitted > 0 ? ',"truncated":true'.length : 0) +
          (omitted > 0 ? ',"omittedItems":$omitted'.length : 0);
    }

    var selected = 0;
    // In particular, don't reserve loss markers when the complete event fits
    // exactly: doing so would introduce loss below the stated bound.
    if (candidates.length == input.length &&
        sizeAt(candidates.length) <= maxAgentEventBytes) {
      selected = candidates.length;
    } else {
      for (var n = 1; n <= candidates.length; n++) {
        if (sizeAt(n) > maxAgentEventBytes) break;
        selected = n;
      }
    }
    final omitted = omittedAt(selected);
    truncated = prefixTruncated[selected] || omitted > 0;
    json = {
      ...base,
      if (hasItems)
        key: selected == candidates.length
            ? candidates
            : candidates.sublist(0, selected),
      if (truncated) 'truncated': true,
      if (omitted > 0) 'omittedItems': omitted,
    };
  }
  final line = _line(json);
  yield line.length - 1 <= maxAgentEventBytes ? line : _line(_tooLarge);
}

/// Truncate string values without changing keys, arrays or scalar metadata.
/// Structural metadata that alone exceeds the budget cannot be represented;
/// the caller omits this item and everything after it. A full event's metadata
/// is handled separately by the notice fallback.
Json? _boundItem(Json item, int limit) {
  final original = utf8.encode(jsonEncode(item));
  if (original.length <= limit) return item;
  // Retain discriminators and statuses even when earlier text is enormous;
  // otherwise a plan/tool item's meaning would depend on JSON key order.
  bool metadata(String? key) =>
      key == 'type' ||
      key == 'status' ||
      key == 'priority' ||
      key == 'mimeType';
  Object? skeleton(Object? value, [String? key]) {
    if (value is String) return metadata(key) ? value : '';
    if (value is Json) {
      return {for (final e in value.entries) e.key: skeleton(e.value, e.key)};
    }
    if (value is List<Object?>) return [for (final e in value) skeleton(e)];
    return value;
  }

  final empty = skeleton(item) as Json;
  var remaining = limit - utf8.encode(jsonEncode(empty)).length;
  if (remaining < 0) return null;
  Object? fill(Object? value, [String? key]) {
    if (value is String) {
      if (metadata(key)) return value;
      final text = clampJsonString(value, remaining);
      // Only the bounded prefix is serialized, never the entire source again.
      remaining -= utf8.encode(jsonEncode(text)).length - 2;
      return text;
    }
    if (value is Json) {
      return {for (final e in value.entries) e.key: fill(e.value, e.key)};
    }
    if (value is List<Object?>) return [for (final e in value) fill(e)];
    return value;
  }

  return fill(item) as Json;
}

/// Desktop incremental NDJSON decoder. Input may contain partial UTF-8 or
/// multiple lines. No unbounded append: one fixed 256 KiB event buffer is
/// retained, with the caller's current 64 KiB channel frame as the only extra
/// live input. Oversize/malformed input and EOF mid-line throw FormatException;
/// the controller must fail/close the affected session, not the connection.
class AgentEventDecoder {
  final Uint8List _buffer = Uint8List(maxAgentEventBytes);
  int _length = 0;
  bool _closed = false;
  int get bufferedBytes => _length;

  List<AgentEvent> add(List<int> bytes) {
    if (_closed) throw StateError('agent event decoder is closed');
    final result = <AgentEvent>[];
    for (final byte in bytes) {
      if (byte == 10) {
        final decoded = jsonDecode(
          utf8.decode(Uint8List.sublistView(_buffer, 0, _length)),
        );
        if (decoded is! Json) {
          throw const FormatException('agent event must be an object');
        }
        final event = AgentEvent.fromJson(decoded);
        _validateBounds(event, _length);
        result.add(event);
        _length = 0;
      } else {
        if (_length == maxAgentEventBytes) {
          throw const FormatException('agent event too large');
        }
        if (byte < 0 || byte > 255) {
          throw const FormatException('invalid event byte');
        }
        _buffer[_length++] = byte;
      }
    }
    return result;
  }

  void close() {
    _closed = true;
    if (_length != 0) throw const FormatException('incomplete agent event');
  }
}

void _validateBounds(AgentEvent event, int bytes) {
  void require(bool valid) {
    if (!valid) {
      throw const FormatException('agent event exceeds normalized bounds');
    }
  }

  if (_textKind(event.kind)) require(bytes <= maxAgentTextEventBytes);
  if (event.kind == AgentEventKind.tool ||
      event.kind == AgentEventKind.toolUpdate) {
    require(event.locations.length <= maxAgentLocations);
    for (final item in event.content) {
      require(utf8.encode(jsonEncode(item)).length <= maxAgentToolItemBytes);
    }
  }
  if (event.kind == AgentEventKind.plan) {
    require(event.entries.length <= maxAgentPlanEntries);
    for (final item in event.entries) {
      require(utf8.encode(jsonEncode(item)).length <= maxAgentPlanEntryBytes);
    }
  }
}
