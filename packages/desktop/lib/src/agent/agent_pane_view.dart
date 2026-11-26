import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:host_protocol/host_protocol.dart';

import '../terminal/profiles_dialog.dart';
import 'agent_controller.dart';
import 'native_question_form.dart';

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
    return Tooltip(
      message: label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: compact ? 12 : 16),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ],
      ),
    );
  }
}

class AgentPaneView extends StatefulWidget {
  const AgentPaneView({
    super.key,
    required this.controller,
    required this.paneId,
    required this.focused,
    this.chooseRuntimeProfile,
  });
  final AgentController controller;
  final String paneId;
  final bool focused;
  final Future<String?> Function(RuntimeListResult profiles)?
  chooseRuntimeProfile;
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
    if (_followScheduled ||
        (_scroll.hasClients && _scroll.position.extentAfter > 80)) {
      return;
    }
    _followScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followScheduled = false;
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
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
      final hiddenApprovals = link.hiddenPendingPermissions.toList(
        growable: false,
      );
      final id = widget.paneId;
      final children = link.ompChildren;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: AgentStatusChip(
                    link.statusLabel,
                    key: Key('agent-status-$id'),
                  ),
                ),
                if (link.adapter != null)
                  Flexible(
                    child: Text(
                      '${link.adapter!.name} ${link.adapter!.version}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
          if (link.delegatedLabel case final label?)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(label, key: Key('agent-delegated-$id')),
            ),
          if (link.toolsLabel case final label?)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(label, key: Key('agent-tools-$id')),
            ),
          if (link.runtimeKind == 'omp')
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                'OMP settings decide when tools ask. Kumiko only answers '
                'supported one-shot approvals and does not sandbox OMP.',
              ),
            ),
          if (link.transcript.hiddenEntries > 0)
            Text(
              'Earlier messages hidden (${link.transcript.hiddenEntries} entries)',
              key: Key('agent-hidden-$id'),
            ),
          if (children.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 80),
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Wrap(
                  children: [
                    for (final child in children)
                      TextButton(
                        key: Key('omp-open-child-${child.threadId}'),
                        onPressed:
                            link.live &&
                                !link.closeRequested &&
                                link.runId == child.rootThreadId
                            ? () => widget.controller.openOmpChild(link, child)
                            : null,
                        child: Text(
                          'Subagent ${child.childOrdinal} · ${_ompChildStatus(child.status)}',
                        ),
                      ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: ListView.builder(
              key: Key('agent-transcript-$id'),
              controller: _scroll,
              padding: const EdgeInsets.all(12),
              itemCount: entries.length + hiddenApprovals.length,
              itemBuilder: (context, index) => index < entries.length
                  ? _entry(link, entries[index])
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Pending approval (earlier entry hidden)'),
                        _permission(
                          link,
                          hiddenApprovals[index - entries.length],
                        ),
                      ],
                    ),
            ),
          ),
          if (link.questions.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final question in link.questions.values)
                      NativeQuestionForm(
                        key: ObjectKey(question),
                        question: question,
                        submit: (answers) => widget.controller.answerQuestion(
                          id,
                          question,
                          answers,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          if (link.error != null || link.requiresAuthentication)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 140),
                child: SingleChildScrollView(
                  child: SelectableText(
                    link.error == null
                        ? link.authGuidance
                        : '${link.requiresAuthentication ? '${link.authGuidance}\n' : ''}${link.error}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
            ),
          if (link.known &&
              link.phase == AgentLinkPhase.ended &&
              link.continueUnavailable != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(link.continueUnavailable!),
            ),
          if (link.historyWarning case final warning?)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(warning),
            ),
          if (link.stopLabel != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SelectableText(
                '${link.stopLabel}${link.stopResult?.message == null ? '' : ': ${link.stopResult!.message}'}',
                key: Key('agent-stop-result-$id'),
              ),
            ),
          if (link.phase == AgentLinkPhase.ended)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Wrap(
                spacing: 8,
                children: [
                  if (link.canContinue)
                    FilledButton(
                      key: Key('agent-continue-$id'),
                      onPressed: () => widget.controller.continueSession(
                        id,
                        chooseProfile: widget.chooseRuntimeProfile,
                      ),
                      child: const Text('Continue'),
                    ),
                  if (link.canNewSession)
                    OutlinedButton(
                      key: Key('agent-new-$id'),
                      onPressed: () => widget.controller.newSession(
                        id,
                        chooseProfile: widget.chooseRuntimeProfile,
                        confirmDraftLoss: (paneId, reason) =>
                            showCloseWarning(context, [
                              (
                                paneId: paneId,
                                title: 'Agent chat',
                                reason: reason,
                              ),
                            ]),
                      ),
                      child: const Text('New session'),
                    ),
                ],
              ),
            ),
          if (link.canRetry)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: FilledButton(
                  key: Key('agent-retry-$id'),
                  onPressed: () => widget.controller.retry(
                    id,
                    chooseProfile: widget.chooseRuntimeProfile,
                  ),
                  child: const Text('Retry'),
                ),
              ),
            ),
          if (link.adapter != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                'Load: ${link.capabilities.contains('load') ? 'available' : 'unavailable for ${link.adapter!.version}'} · Resume: ${link.capabilities.contains('resume') ? 'available' : 'unavailable for ${link.adapter!.version}'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (link.draftNotice case final notice?)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                notice,
                key: Key('agent-draft-notice-$id'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (widget.controller.draftsDisabled && !link.composerHidden)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton(
                    key: Key('agent-draft-reset-$id'),
                    onPressed: () => widget.controller.resetDraftStorage(
                      id,
                      () => _confirmReset(context),
                    ),
                    child: const Text('Reset draft storage'),
                  ),
                  if (widget.controller.draftResetError case final error?)
                    Text(
                      'Reset failed: $error',
                      key: Key('agent-draft-reset-error-$id'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          if (link.composerHidden)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                'This session is open in another pane.',
                key: Key('agent-composer-elsewhere-$id'),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.all(8),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  Future<void> send() =>
                      widget.controller.send(id, link.prompt.text);
                  final prompt = Focus(
                    canRequestFocus: false,
                    onKeyEvent: (_, event) =>
                        _handleComposerKey(link, event, send),
                    child: TextField(
                      key: Key('agent-prompt-$id'),
                      controller: link.prompt,
                      focusNode: link.promptFocus,
                      autofocus: widget.focused,
                      minLines: 1,
                      maxLines: 5,
                      decoration: InputDecoration(
                        hintText: switch (link.runtimeKind) {
                          'codex' => 'Message Codex',
                          'omp' => 'Message OMP',
                          _ => 'Message Claude Code',
                        },
                        border: OutlineInputBorder(),
                      ),
                    ),
                  );
                  final actions = Wrap(
                    spacing: 4,
                    children: [
                      FilledButton(
                        key: Key('agent-send-$id'),
                        onPressed: link.canSend ? send : null,
                        child: const Text('Send'),
                      ),
                      if (link.runtimeKind == 'codex')
                        OutlinedButton(
                          key: Key('agent-steer-$id'),
                          onPressed: link.canSteer
                              ? () => widget.controller.steer(
                                  id,
                                  link.prompt.text,
                                )
                              : null,
                          child: const Text('Steer'),
                        ),
                      OutlinedButton(
                        key: Key('agent-stop-$id'),
                        onPressed: link.canStop
                            ? () => widget.controller.stop(id)
                            : null,
                        child: const Text('Stop'),
                      ),
                    ],
                  );
                  return constraints.maxWidth < 360
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [prompt, actions],
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(child: prompt),
                            const SizedBox(width: 8),
                            actions,
                          ],
                        );
                },
              ),
            ),
        ],
      );
    },
  );

  KeyEventResult _handleComposerKey(
    AgentLink link,
    KeyEvent event,
    VoidCallback send,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final enter =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    if (!enter && key != LogicalKeyboardKey.arrowUp) {
      return KeyEventResult.ignored;
    }

    final prompt = link.prompt;
    final value = prompt.value;
    if (value.composing.isValid) {
      // The Windows engine already consumes IME-processed keys. A raw Enter
      // left unhandled here would reach its multiline newline fallback.
      return enter && defaultTargetPlatform == TargetPlatform.windows
          ? KeyEventResult.handled
          : KeyEventResult.skipRemainingHandlers;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }

    if (enter) {
      if (event is KeyDownEvent) {
        if (keyboard.isShiftPressed) {
          final text = value.text;
          final selection = value.selection;
          final start = selection.isValid ? selection.start : text.length;
          final end = selection.isValid ? selection.end : start;
          prompt.value = TextEditingValue(
            text: text.replaceRange(start, end, '\n'),
            selection: TextSelection.collapsed(offset: start + 1),
          );
        } else {
          send();
        }
      }
      return KeyEventResult.handled;
    }
    final previous = link.lastAcceptedPrompt;
    if (event is KeyDownEvent &&
        !keyboard.isShiftPressed &&
        value.text.isEmpty &&
        previous != null) {
      prompt.value = TextEditingValue(
        text: previous,
        selection: TextSelection.collapsed(offset: previous.length),
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<bool> _confirmReset(BuildContext context) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: const Key('draft-reset-confirm'),
          title: const Text('Reset draft storage?'),
          content: const Text(
            'Every stored draft will be lost. Text in open composers is '
            'stored again.',
          ),
          actions: [
            TextButton(
              key: const Key('draft-reset-cancel'),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('draft-reset-ok'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Reset draft storage'),
            ),
          ],
        ),
      ) ??
      false;

  Widget _entry(AgentLink link, AgentTranscriptEntry entry) {
    final permission = entry.permission;
    if (permission != null) return _permission(link, permission);
    final fields = entry.fields;
    if (fields['parentThreadId'] != null) {
      if (entry.kind != AgentEventKind.child) return const SizedBox.shrink();
      return Text(
        'Child ${fields['threadId']}: ${fields['status']}${entry.text.isEmpty ? '' : ': ${entry.text}'}',
      );
    }
    return _readOnlyEntry(entry);
  }

  Widget _permission(AgentLink link, AgentPermission permission) {
    final request = permission.request;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(request.title),
            // Literal text: the transcript fence renderer would drop and
            // restyle parts of a command or native decision preview.
            if (request.preview != null) SelectableText(request.preview!),
            Text(permission.label),
            if (request.truncated) const Text('truncated'),
            Wrap(
              spacing: 8,
              children: [
                for (final option in request.options)
                  OutlinedButton(
                    key: Key(
                      'agent-option-${link.paneId}-${request.requestId}-${option.optionId}',
                    ),
                    onPressed:
                        link.connected &&
                            link.live &&
                            !link.closeRequested &&
                            permission.pending &&
                            !permission.replying
                        ? () => widget.controller.replyPermission(
                            link.paneId,
                            request.requestId,
                            option.optionId,
                          )
                        : null,
                    child: Text(option.name),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _ompChildStatus(String? status) => switch (status) {
  'running' => 'Running',
  'completed' => 'Completed',
  'failed' => 'Failed',
  'cancelled' || 'aborted' => 'Interrupted',
  _ => 'Activity unconfirmed',
};

class OmpChildPaneView extends StatelessWidget {
  const OmpChildPaneView({
    super.key,
    required this.controller,
    required this.paneId,
  });

  final AgentController controller;
  final String paneId;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final view = controller.childViewOf(paneId);
      if (view == null) return const SizedBox();
      final history = view.history?.entries.toList(growable: false) ?? const [];
      final live = view.live.entries.toList(growable: false);
      final hidden =
          (view.history?.hiddenEntries ?? 0) + view.live.hiddenEntries;
      final headings = <Widget>[
        if (view.status.isNotEmpty) Text(_ompChildStatus(view.status)),
        if (view.availability case final label?) Text(label),
        if (hidden != 0) Text('Earlier messages hidden ($hidden entries)'),
        const Text('Earlier history'),
        if (view.historyStatus case final label?) Text(label),
      ];
      final liveStart = headings.length + history.length;
      return ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: liveStart + 1 + live.length,
        itemBuilder: (context, index) {
          if (index < headings.length) return headings[index];
          if (index < liveStart) {
            return _readOnlyEntry(
              history[index - headings.length],
              userLabel: 'Input',
            );
          }
          if (index == liveStart) return const Text('Live activity');
          return _readOnlyEntry(
            live[index - liveStart - 1],
            userLabel: 'Input',
          );
        },
      );
    },
  );
}

Widget _readOnlyEntry(AgentTranscriptEntry entry, {String userLabel = 'You'}) {
  final fields = entry.fields;
  if (entry.kind == AgentEventKind.tool ||
      entry.kind == AgentEventKind.toolUpdate) {
    final title = fields['title'] ?? 'Tool';
    final kind = fields['toolKind'];
    return Card(
      key: ValueKey(entry),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(kind == null ? '$title' : '$title · $kind'),
            Text(entry.statuses.join(' → ')),
            for (final location in (fields['locations'] as List? ?? const []))
              SelectableText(
                '${(location as Map)['path']}${location['line'] == null ? '' : ':${location['line']}'}',
              ),
            for (final content in (fields['content'] as List? ?? const []))
              _toolContent((content as Map).cast<String, Object?>()),
            if (fields['truncated'] == true)
              Text(
                'truncated${fields['omittedItems'] == null ? '' : ' · ${fields['omittedItems']} items omitted'}',
              ),
          ],
        ),
      ),
    );
  }
  if (entry.kind == AgentEventKind.plan) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Plan'),
            for (final value in (fields['entries'] as List? ?? const []))
              SelectableText(
                '${(value as Map)['status'] ?? ''} · ${value['priority'] ?? ''} · ${value['content'] ?? ''}',
              ),
            if (fields['truncated'] == true) const Text('truncated'),
          ],
        ),
      ),
    );
  }
  if (entry.kind == AgentEventKind.turn && fields['stopReason'] == 'end_turn') {
    return const SizedBox();
  }
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (entry.kind == AgentEventKind.user) Text(userLabel),
        if (entry.kind == AgentEventKind.thought)
          const Text('Thinking', style: TextStyle(fontStyle: FontStyle.italic)),
        AgentPlainText(entry.plainText),
        if (fields['truncated'] == true) const Text('truncated'),
      ],
    ),
  );
}

Widget _toolContent(Json content) => switch (content['type']) {
  'diff' => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SelectableText('Diff · ${content['path'] ?? ''}'),
      SelectableText(
        '- ${content['oldText'] ?? ''}\n+ ${content['newText'] ?? ''}',
        style: const TextStyle(fontFamily: 'monospace'),
      ),
    ],
  ),
  'terminal' => SelectableText('Terminal · ${content['terminalId'] ?? ''}'),
  'content' => AgentPlainText(
    ((content['content'] as Map?)?['text'] ?? '').toString(),
  ),
  _ => AgentPlainText((content['text'] ?? '').toString()),
};

/// Plain text only; fenced regions use monospace without a Markdown engine.
class AgentPlainText extends StatelessWidget {
  const AgentPlainText(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) {
    final parts = text.split('```');
    if (parts.length == 1) return SelectableText(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < parts.length; i++)
          if (parts[i].isNotEmpty)
            SelectableText(
              i.isOdd && parts[i].contains('\n')
                  ? parts[i].substring(parts[i].indexOf('\n') + 1)
                  : parts[i],
              style: i.isOdd ? const TextStyle(fontFamily: 'monospace') : null,
            ),
      ],
    );
  }
}
