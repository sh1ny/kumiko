import 'dart:collection';

import 'package:host_protocol/host_protocol.dart';

import '../runtime_driver.dart';
import 'omp_session_file.dart';
import 'omp_tool_activity.dart';

final _clippedIdentity = RegExp(
  r'…\[\d+ (?:chars|items) elided for RPC frame\]',
);

String? _identity(Object? value) =>
    value is String &&
        value.isNotEmpty &&
        value.length <= 256 &&
        jsonStringContentBytes(value) <= 256 &&
        !_clippedIdentity.hasMatch(value)
    ? value
    : null;

final class OmpChild {
  OmpChild({
    required this.id,
    required this.key,
    required this.ordinal,
    required this.file,
    required this.owner,
  });

  final String id, key;
  final int ordinal;
  String? file, owner;
  String status = 'running';
  bool conflicted = false;
  bool omitted = false;
  int activation = 1;
  bool get active => status == 'running';
  bool get cancellable => active && !conflicted && file != null;
  String get ticket => '$ordinal:$activation';
}

/// Lifecycle/roster facts from one private OMP connection. Neither a parent
/// tool call id nor a model-provided label establishes a parent relationship.
final class OmpChildren {
  OmpChildren(this.runId, {required this.views})
    : _tools = OmpToolActivity(cardPrefix: '$runId-child');

  static const _activeLimit = 16;
  static const _completedLimit = 64;
  final String runId;
  final bool views;
  final OmpToolActivity _tools;
  final _byNativeId = <String, OmpChild>{};
  final _completed = Queue<String>();
  final _endedBeforeSnapshot = <String>{};
  bool _bootstrapping = true;
  bool available = false;
  bool incomplete = false;
  bool attached = false;
  int active = 0;
  int _ordinal = 0;

  Iterable<OmpChild> get known => _byNativeId.values;
  OmpChild? byKey(String key) =>
      known.where((c) => c.key == key && !c.conflicted).firstOrNull;

  void unavailable() {
    available = false;
    incomplete = true;
    _finishBootstrap();
  }

  void settled() => incomplete = known.any((c) => c.active && c.conflicted);

  void _finishBootstrap() {
    _bootstrapping = false;
    _endedBeforeSnapshot.clear();
  }

  /// One active snapshot after subscription. Events processed while its
  /// reply was pending take priority; a stale row cannot revive a tombstone.
  void seed(Object? value) {
    if (value case {'subagents': final List<Object?> rows}) {
      available = true;
      if (rows.length > _activeLimit) incomplete = true;
      for (final row in rows.take(_activeLimit)) {
        if (row is! Json) {
          incomplete = true;
          continue;
        }
        final id = _identity(row['id']);
        final status = row['status'];
        if (id == null || (status != 'running' && status != 'pending')) {
          incomplete = true;
          continue;
        }
        if (_endedBeforeSnapshot.contains(id) ||
            _byNativeId[id]?.active == false) {
          continue;
        }
        _observe(id, row, allowRevive: false);
      }
      _finishBootstrap();
    } else {
      unavailable();
    }
  }

  AgentEvent lifecycle(OmpChild child) => AgentEvent.ompChildLifecycle(
    rootId: runId,
    childKey: child.key,
    ordinal: child.ordinal,
    status: child.conflicted ? 'unknown' : child.status,
  );

  Iterable<AgentEvent> receive(
    String type,
    Object? body,
    void Function(String key, String ticket, RuntimeTurnResult result) onEnded,
  ) sync* {
    if (body is! Json) {
      incomplete = true;
      return;
    }
    final progress = body['progress'];
    final id = _identity(
      type == 'subagent_progress' && progress is Json
          ? progress['id']
          : body['id'],
    );
    if (id == null) {
      incomplete = true;
      return;
    }
    if (type == 'subagent_event') {
      // Old peers deliberately receive no child content or optional identity.
      if (!views) return;
      final child = _byNativeId[id];
      if (child == null || child.conflicted) {
        incomplete = true;
      } else if (child.active && attached) {
        yield* _content(child, body['event']);
      }
      return;
    }
    if (type == 'subagent_progress') {
      if (progress is! Json) {
        incomplete = true;
        return;
      }
      final wasKnown = _byNativeId.containsKey(id);
      if (wasKnown ||
          progress['status'] == 'running' ||
          progress['status'] == 'pending') {
        final child = _observe(id, body, allowRevive: false);
        if (views &&
            attached &&
            child != null &&
            (!wasKnown || child.conflicted)) {
          yield lifecycle(child);
        }
      } else {
        incomplete = true;
      }
      return;
    }
    final status = body['status'];
    if (status == 'started') {
      _endedBeforeSnapshot.remove(id);
      final child = _observe(id, body, allowRevive: true);
      if (views && attached && child != null) yield lifecycle(child);
      return;
    }
    if (status != 'aborted' && status != 'completed' && status != 'failed') {
      incomplete = true;
      return;
    }
    final child = _byNativeId[id];
    if (child == null) {
      if (_bootstrapping && _endedBeforeSnapshot.length < _completedLimit) {
        _endedBeforeSnapshot.add(id);
      } else {
        incomplete = true;
      }
      return;
    }
    if (!child.active || !_mergeIdentity(child, body)) return;
    final ticket = child.ticket;
    child.status = status! as String;
    active--;
    _completed.add(id);
    if (_completed.length > _completedLimit) {
      _byNativeId.remove(_completed.removeFirst());
    }
    if (views && attached) {
      for (final event in _tools.finish(scope: child.key)) {
        yield event.forOmpChild(rootId: runId, childKey: child.key);
      }
      yield lifecycle(child);
    }
    _tools.retireScope(child.key);
    onEnded(child.key, ticket, switch (status) {
      'aborted' => const RuntimeTurnResult('cancelled', isCancelled: true),
      'failed' => RuntimeTurnResult(
        'error',
        error: StateError('An OMP subagent failed.'),
      ),
      _ => const RuntimeTurnResult('completed'),
    });
  }

  OmpChild? _observe(String id, Json facts, {required bool allowRevive}) {
    final existing = _byNativeId[id];
    if (existing != null) {
      if (!existing.active && !allowRevive) return null;
      final formerFile = existing.file;
      if (!_mergeIdentity(existing, facts)) return existing;
      if (existing.active) return existing;
      // An id alone is not proof a later activation is the same child.
      if (formerFile == null ||
          !sameOmpSessionPath(formerFile, facts['sessionFile'])) {
        _conflict(existing);
        return existing;
      }
      if (active >= _activeLimit) {
        incomplete = true;
        return null;
      }
      _completed.remove(id);
      existing.status = 'running';
      existing.activation++;
      existing.omitted = false;
      active++;
      return existing;
    }
    if (active >= _activeLimit) {
      incomplete = true;
      return null;
    }
    final raw = facts['sessionFile'];
    final owner = _identity(facts['parentToolCallId']);
    final file = ompSessionPath(raw);
    final ordinal = ++_ordinal;
    final child = OmpChild(
      id: id,
      key: '$runId:child:$ordinal',
      ordinal: ordinal,
      file: file == null ? null : raw as String,
      owner: owner,
    );
    _byNativeId[id] = child;
    active++;
    if ((raw != null && file == null) ||
        (facts['parentToolCallId'] != null && owner == null)) {
      _conflict(child);
    }
    return child;
  }

  bool _mergeIdentity(OmpChild child, Json facts) {
    if (child.conflicted) return false;
    final raw = facts['sessionFile'];
    final normalized = ompSessionPath(raw);
    final owner = _identity(facts['parentToolCallId']);
    if ((raw != null &&
            (normalized == null ||
                (child.file != null &&
                    !sameOmpSessionPath(child.file!, raw)))) ||
        (facts['parentToolCallId'] != null &&
            (owner == null || (child.owner != null && child.owner != owner)))) {
      _conflict(child);
      return false;
    }
    child.file ??= raw as String?;
    child.owner ??= owner;
    return true;
  }

  void _conflict(OmpChild child) {
    child.conflicted = true;
    _tools.retireScope(child.key);
    incomplete = true;
  }

  Iterable<AgentEvent> _content(OmpChild child, Object? raw) sync* {
    if (raw is! Json) {
      incomplete = true;
      return;
    }
    AgentEvent tag(AgentEvent event) =>
        event.forOmpChild(rootId: runId, childKey: child.key);
    final type = raw['type'];
    if (type == 'tool_execution_start' ||
        type == 'tool_execution_update' ||
        type == 'tool_execution_end') {
      final event = _tools.frame(
        type! as String,
        raw,
        active: true,
        scope: child.key,
      );
      if (event != null) yield tag(event);
    } else if (type == 'message_end') {
      final message = raw['message'];
      if (message is! Json) {
        incomplete = true;
        return;
      }
      final role = message['role'];
      if (role != 'assistant' && role != 'user') return;
      final content = message['content'];
      if (content is String && role == 'user') {
        if (content.isNotEmpty) {
          yield tag(AgentEvent.text(AgentEventKind.user, content));
        }
        return;
      }
      var omitted = content is! List<Object?>;
      if (content is List<Object?>) {
        // Charge fragment metadata as well as text to bound one delivery even
        // for messages made of many tiny native blocks.
        var budget =
            maxAgentTextChunkBytes - 512; // omission and split metadata
        for (final block in content) {
          final (kind, text) = switch (block) {
            {'type': 'text', 'text': final String text} => (
              role == 'user' ? AgentEventKind.user : AgentEventKind.agentText,
              text,
            ),
            {'type': 'thinking', 'thinking': final String text}
                when role == 'assistant' =>
              (AgentEventKind.thought, text),
            {'type': 'toolCall'} when role == 'assistant' => (null, ''),
            _ => (null, null),
          };
          if (text == null) {
            omitted = true;
          } else if (kind != null && text.isNotEmpty) {
            const overhead = 512;
            if (budget <= overhead) {
              omitted = true;
              break;
            }
            final bounded = clampJsonString(text, budget - overhead);
            omitted |= bounded.length != text.length;
            budget -= overhead + jsonStringContentBytes(bounded);
            if (bounded.isNotEmpty) yield tag(AgentEvent.text(kind, bounded));
          }
        }
      }
      if (omitted && !child.omitted) {
        child.omitted = true;
        yield tag(
          AgentEvent.notice('Some subagent content could not be shown.'),
        );
      }
    }
  }
}
