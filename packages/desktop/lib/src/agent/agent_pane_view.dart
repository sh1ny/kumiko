import 'package:flutter/material.dart';
import 'package:host_protocol/host_protocol.dart';

import 'agent_controller.dart';

class AgentStatusChip extends StatelessWidget {
  const AgentStatusChip(this.label, {super.key, this.compact = false});
  final String label;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final icon = switch (label) {
      'Waiting for approval' => Icons.front_hand_outlined,
      'Running' => Icons.play_arrow,
      'Idle' => Icons.check_circle_outline,
      'Starting' || 'Stopping' || 'Closing' => Icons.hourglass_top,
      'Failed' => Icons.error_outline,
      'Saved, not running' => Icons.history,
      _ => Icons.stop_circle_outlined,
    };
    return Tooltip(message: label, child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: compact ? 12 : 16), const SizedBox(width: 4),
      Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall)),
    ]));
  }
}

class AgentPaneView extends StatefulWidget {
  const AgentPaneView({super.key, required this.controller, required this.paneId, required this.focused});
  final AgentController controller;
  final String paneId;
  final bool focused;
  @override
  State<AgentPaneView> createState() => _AgentPaneViewState();
}

class _AgentPaneViewState extends State<AgentPaneView> {
  final ScrollController _scroll = ScrollController();
  bool _followScheduled = false;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_follow);
  }
  @override
  void didUpdateWidget(AgentPaneView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_follow);
      widget.controller.addListener(_follow);
    }
  }
  void _follow() {
    if (_followScheduled || (_scroll.hasClients && _scroll.position.extentAfter > 80)) return;
    _followScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followScheduled = false;
      if (mounted && _scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }
  @override
  void dispose() {
    widget.controller.removeListener(_follow);
    _scroll.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final link = widget.controller.linkOf(widget.paneId);
      if (link == null) return const SizedBox();
      final entries = link.transcript.entries.toList(growable: false);
      final hiddenApprovals = link.hiddenPendingPermissions.toList(growable: false);
      final id = widget.paneId;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.all(8), child: Row(children: [
          Expanded(child: AgentStatusChip(link.statusLabel, key: Key('agent-status-$id'))),
          if (link.adapter != null) Flexible(child: Text('${link.adapter!.name} ${link.adapter!.version}', overflow: TextOverflow.ellipsis)),
        ])),
        if (link.transcript.hiddenEntries > 0) Text(
          'Earlier messages hidden (${link.transcript.hiddenEntries} entries)', key: Key('agent-hidden-$id'),
        ),
        Expanded(child: ListView.builder(
          key: Key('agent-transcript-$id'), controller: _scroll, padding: const EdgeInsets.all(12),
          itemCount: entries.length + hiddenApprovals.length,
          itemBuilder: (context, index) => index < entries.length
              ? _entry(link, entries[index])
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Pending approval (earlier entry hidden)'),
                  _permission(link, hiddenApprovals[index - entries.length]),
                ]),
        )),
        if (link.error != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 140),
          child: SingleChildScrollView(child: SelectableText(
            '${link.errorCode == ErrorCode.authRequired ? '$agentAuthGuidance\n' : ''}${link.error}',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          )),
        )),
        if (link.stopLabel != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: SelectableText(
          '${link.stopLabel}${link.stopResult?.message == null ? '' : ': ${link.stopResult!.message}'}', key: Key('agent-stop-result-$id'),
        )),
        if (link.phase == AgentLinkPhase.ended) Padding(padding: const EdgeInsets.all(8), child: Wrap(spacing: 8, children: [
          if (link.canContinue) FilledButton(
            key: Key('agent-continue-$id'), onPressed: () => widget.controller.continueSession(id), child: const Text('Continue'),
          ),
          if (link.canNewSession) OutlinedButton(
            key: Key('agent-new-$id'), onPressed: () => widget.controller.newSession(id), child: const Text('New session'),
          ),
        ])),
        if (link.canRetry) Align(alignment: Alignment.centerLeft, child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: FilledButton(
            key: Key('agent-retry-$id'), onPressed: () => widget.controller.retry(id), child: const Text('Retry'),
          ),
        )),
        if (link.adapter != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(
          'Load: ${link.capabilities.contains('load') ? 'available' : 'unavailable for ${link.adapter!.version}'} · Resume: ${link.capabilities.contains('resume') ? 'available' : 'unavailable for ${link.adapter!.version}'}',
          style: Theme.of(context).textTheme.bodySmall,
        )),
        Padding(padding: const EdgeInsets.all(8), child: LayoutBuilder(builder: (context, constraints) {
          final prompt = TextField(
            key: Key('agent-prompt-$id'), controller: link.prompt, focusNode: link.promptFocus,
            autofocus: widget.focused, minLines: 1, maxLines: 5,
            decoration: const InputDecoration(hintText: 'Message Claude Code', border: OutlineInputBorder()),
          );
          final actions = Wrap(spacing: 4, children: [
            FilledButton(key: Key('agent-send-$id'), onPressed: link.canSend ? () => widget.controller.send(id, link.prompt.text) : null, child: const Text('Send')),
            OutlinedButton(key: Key('agent-stop-$id'), onPressed: link.canStop ? () => widget.controller.stop(id) : null, child: const Text('Stop')),
          ]);
          return constraints.maxWidth < 360
              ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [prompt, actions])
              : Row(crossAxisAlignment: CrossAxisAlignment.end, children: [Expanded(child: prompt), const SizedBox(width: 8), actions]);
        })),
      ]);
    },
  );

  Widget _entry(AgentLink link, AgentTranscriptEntry entry) {
    final permission = entry.permission;
    if (permission != null) return _permission(link, permission);
    final fields = entry.fields;
    if (entry.kind == AgentEventKind.tool || entry.kind == AgentEventKind.toolUpdate) {
      return Card(key: ValueKey(entry), child: Padding(padding: const EdgeInsets.all(8), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          SelectableText('${fields['title'] ?? 'Tool'} · ${fields['toolKind'] ?? 'tool'}'),
          Text(entry.statuses.join(' → ')),
          for (final location in (fields['locations'] as List? ?? const [])) SelectableText('${(location as Map)['path']}${location['line'] == null ? '' : ':${location['line']}'}'),
          for (final content in (fields['content'] as List? ?? const [])) _toolContent((content as Map).cast<String, Object?>()),
          if (fields['truncated'] == true) Text('truncated${fields['omittedItems'] == null ? '' : ' · ${fields['omittedItems']} items omitted'}'),
        ],
      )));
    }
    if (entry.kind == AgentEventKind.plan) {
      return Card(child: Padding(padding: const EdgeInsets.all(8), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Plan'),
          for (final value in (fields['entries'] as List? ?? const [])) SelectableText(
            '${(value as Map)['status'] ?? ''} · ${value['priority'] ?? ''} · ${value['content'] ?? ''}',
          ),
          if (fields['truncated'] == true) const Text('truncated'),
        ],
      )));
    }
    if (entry.kind == AgentEventKind.turn && fields['stopReason'] == 'end_turn') return const SizedBox();
    return Padding(padding: const EdgeInsets.only(bottom: 8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (entry.kind == AgentEventKind.user) const Text('You'),
      if (entry.kind == AgentEventKind.thought) const Text('Thinking', style: TextStyle(fontStyle: FontStyle.italic)),
      AgentPlainText(entry.plainText),
      if (fields['truncated'] == true) const Text('truncated'),
    ]));
  }

  Widget _toolContent(Json content) => switch (content['type']) {
    'diff' => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SelectableText('Diff · ${content['path'] ?? ''}'),
      SelectableText('- ${content['oldText'] ?? ''}\n+ ${content['newText'] ?? ''}', style: const TextStyle(fontFamily: 'monospace')),
    ]),
    'terminal' => SelectableText('Terminal · ${content['terminalId'] ?? ''}'),
    'content' => AgentPlainText(((content['content'] as Map?)?['text'] ?? '').toString()),
    _ => AgentPlainText((content['text'] ?? '').toString()),
  };

  Widget _permission(AgentLink link, AgentPermission permission) {
    final request = permission.request;
    return Card(child: Padding(padding: const EdgeInsets.all(8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SelectableText(request.title),
      if (request.preview != null) AgentPlainText(request.preview!),
      Text(permission.label),
      if (request.truncated) const Text('truncated'),
      Wrap(spacing: 8, children: [
        for (final option in request.options) OutlinedButton(
          key: Key('agent-option-${link.paneId}-${request.requestId}-${option.optionId}'),
          onPressed: link.connected && link.live && !link.closeRequested && permission.pending && !permission.replying
              ? () => widget.controller.replyPermission(link.paneId, request.requestId, option.optionId) : null,
          child: Text(option.name),
        ),
      ]),
    ])));
  }
}

/// Plain text only; fenced regions use monospace without a Markdown engine.
class AgentPlainText extends StatelessWidget {
  const AgentPlainText(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) {
    final parts = text.split('```');
    if (parts.length == 1) return SelectableText(text);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var i = 0; i < parts.length; i++) if (parts[i].isNotEmpty)
        SelectableText(i.isOdd && parts[i].contains('\n') ? parts[i].substring(parts[i].indexOf('\n') + 1) : parts[i],
          style: i.isOdd ? const TextStyle(fontFamily: 'monospace') : null),
    ]);
  }
}
