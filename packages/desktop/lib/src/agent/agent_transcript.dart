import 'dart:collection';
import 'dart:convert';

import 'package:host_protocol/host_protocol.dart';

const maxTranscriptEntries = 2000;
const maxTranscriptBytes = 8 * 1024 * 1024;

class AgentPermission {
  AgentPermission(this.request);
  final AgentPermissionRequestedParams request;
  AgentPermissionResolvedParams? resolution;
  bool unavailable = false;
  bool replying = false;
  bool get pending => resolution == null && !unavailable;
  String get label {
    final answer = resolution;
    if (answer == null) return unavailable ? 'Unanswerable: host or session ended' : 'Waiting for approval';
    if (answer.outcome == AgentPermissionOutcome.cancelled) return 'Cancelled';
    final option = request.options.where((o) => o.optionId == answer.optionId).firstOrNull;
    return 'Answered: ${option?.name ?? answer.optionId}';
  }
}

/// Mutable display entry. Text is accumulated without copying the preceding
/// stream on every chunk; materialization happens only when the UI reads it.
/// A text entry is capped at 64 KiB so continuous output can evict old text too.
class AgentTranscriptEntry {
  AgentTranscriptEntry(this.kind, this.fields, {this.permission});
  final AgentEventKind kind;
  final Json fields;
  final AgentPermission? permission;
  final List<String> statuses = [];
  final StringBuffer _text = StringBuffer();
  int bytes = 0;
  int textBytes = 0;
  String? _rendered;
  String get text => _rendered ??= _text.toString();
  void append(String text, int bytes) {
    _text.write(text);
    _rendered = null;
    textBytes += bytes;
    this.bytes += bytes;
  }
  String get plainText {
    if (permission case final p?) return '${p.request.title}\n${p.label}';
    if (kind == AgentEventKind.replay) return 'Replay ${fields['phase']}';
    if (textBytes > 0 || fields.containsKey('text')) return text;
    if (kind == AgentEventKind.turn) {
      final reason = fields['stopReason'];
      return reason == 'end_turn' ? '' : 'Turn ended: $reason';
    }
    return jsonEncode(fields);
  }
}

/// Memory-only display copy, never serialized into the layout or a log.
class AgentTranscript {
  final Queue<AgentTranscriptEntry> _entries = Queue();
  final Map<String, AgentTranscriptEntry> _tools = {};
  Iterable<AgentTranscriptEntry> get entries => _entries;
  int bytes = 0;
  int hiddenEntries = 0;
  int get retainedTools => _tools.length;
  String get plainText => _entries.map((e) => e.plainText).join();

  void add(AgentEvent event) {
    final fields = event.toJson()..remove('kind');
    final text = event.text;
    final isText = event.kind == AgentEventKind.user ||
        event.kind == AgentEventKind.agentText || event.kind == AgentEventKind.thought;
    if (text != null && isText) {
      final size = utf8.encode(text).length;
      final tail = _entries.lastOrNull;
      if (tail != null && tail.permission == null && tail.kind == event.kind &&
          tail.textBytes + size <= maxAgentTextEventBytes && tail.fields['truncated'] != true) {
        tail.append(text, size);
        if (event.truncated) tail.fields['truncated'] = true;
        bytes += size;
        _evict();
        return;
      }
    }
    final toolId = event.toolCallId;
    final prior = toolId == null ? null : _tools[toolId];
    if (prior != null) {
      bytes -= prior.bytes;
      // Sparse tool updates replace only supplied fields, not absent content.
      if (fields.containsKey('content')) {
        prior.fields
          ..remove('contentTruncated')
          ..remove('omittedItems');
      }
      if (fields.containsKey('locations')) prior.fields.remove('locationsTruncated');
      prior.fields.addAll(fields);
      if (prior.fields['contentTruncated'] == true || prior.fields['locationsTruncated'] == true) {
        prior.fields['truncated'] = true;
      } else {
        prior.fields.remove('truncated');
      }
      if (event.status case final status? when prior.statuses.lastOrNull != status) {
        prior.statuses.add(status);
        // Runtime status history is display metadata and is bounded too.
        if (prior.statuses.length > 32) prior.statuses.removeAt(0);
      }
      prior.bytes = utf8.encode(jsonEncode(prior.fields)).length +
          prior.statuses.fold<int>(0, (n, s) => n + utf8.encode(s).length);
      bytes += prior.bytes;
      _evict();
      return;
    }
    final entry = AgentTranscriptEntry(event.kind, fields);
    if (text != null) {
      entry.append(text, utf8.encode(text).length);
      // Text lives in the accumulator, not a second retained JSON copy.
      entry.fields['text'] = '';
    } else {
      entry.bytes = utf8.encode(jsonEncode(fields)).length;
    }
    if (event.status case final status?) entry.statuses.add(status);
    _entries.add(entry);
    if (toolId != null) _tools[toolId] = entry;
    bytes += entry.bytes;
    _evict();
  }

  void addPermission(AgentPermission permission) {
    final entry = AgentTranscriptEntry(AgentEventKind.notice, {}, permission: permission);
    entry.bytes = utf8.encode(jsonEncode(permission.request.toJson())).length;
    _entries.add(entry);
    bytes += entry.bytes;
    _evict();
  }

  void _evict() {
    while (_entries.length > maxTranscriptEntries || bytes > maxTranscriptBytes) {
      final entry = _entries.removeFirst();
      bytes -= entry.bytes;
      final id = entry.fields['toolCallId'];
      if (id is String && identical(_tools[id], entry)) _tools.remove(id);
      hiddenEntries++;
    }
  }

  void clear() {
    _entries.clear();
    _tools.clear();
    bytes = 0;
    hiddenEntries = 0;
  }
}
