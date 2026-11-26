import 'package:domain/domain.dart';
import 'package:host_protocol/host_protocol.dart';

import 'agent_transcript.dart';

const ompChildKind = 'omp-child';

/// Memory-only child display. Layout supplies identity and placement, never
/// a live binding. Only an explicit open on the parent can set a view token.
final class OmpChildView {
  OmpChildView(PaneNode pane)
    : rootSessionId = _key(pane.state['rootSessionId']),
      childKey = _key(pane.state['childKey']);

  static String? _key(Object? value) =>
      value is String &&
          value.isNotEmpty &&
          value.length <= maxAgentChildKeyBytes &&
          jsonStringContentBytes(value) <= maxAgentChildKeyBytes
      ? value
      : null;

  final String? rootSessionId, childKey;
  String? runId, viewToken;
  String status = '';
  bool ended = false;
  String? historyError;
  AgentTranscript? _staging;
  AgentTranscript? history;
  final live = AgentTranscript();

  String? get availability => ended
      ? 'The parent OMP run ended. Displayed content is kept here.'
      : runId == null
      ? 'This subagent view is from an earlier run.'
      : null;

  String? get historyStatus => history != null
      ? null
      : historyError ??
            (runId == null || ended
                ? 'History unavailable for this run.'
                : 'Reading earlier history…');

  void end() {
    ended = true;
    viewToken = null;
    _staging = null;
  }

  void failHistory(String message) {
    _staging = null;
    viewToken = null;
    historyError = 'History unavailable: $message';
  }

  void add(AgentEvent event) {
    if (ended) return;
    final token = event.viewToken;
    if (token != null) {
      if (token != viewToken || history != null) return;
      switch (event.phase) {
        case AgentReplayPhase.start:
          _staging = AgentTranscript();
        case AgentReplayPhase.end:
          history = _staging;
          _staging = null;
          if (history == null) failHistory('the snapshot was incomplete.');
        case null:
          _staging?.add(event);
      }
    } else if (event.kind == AgentEventKind.child) {
      status = event.status ?? '';
    } else {
      live.add(event);
    }
    final earlier = history ?? _staging;
    if (earlier != null) {
      // Native history is earlier than this view's subscription. Evict its
      // oldest entries first when the two sections exceed a single budget.
      while (earlier.length + live.length > maxTranscriptEntries ||
          earlier.bytes + live.bytes > maxTranscriptBytes) {
        earlier.dropOldest();
      }
    }
  }
}
