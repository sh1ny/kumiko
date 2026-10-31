import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:host_protocol/host_protocol.dart';

import '../workbench_controller.dart';
import 'profiles_dialog.dart';
import 'terminal_controller.dart';

/// A terminal pane's body: the surface with a line about the link above it,
/// or *Ended, not restored* for a pane restored from the layout.
class TerminalPaneView extends StatelessWidget {
  const TerminalPaneView({
    super.key,
    required this.controller,
    required this.pane,
  });

  final WorkbenchController controller;
  final PaneNode pane;

  @override
  Widget build(BuildContext context) {
    final link = controller.terminals.linkOf(pane.id);
    if (link == null) {
      final state = pane.state;
      return _EndedView(
        controller: controller,
        pane: pane,
        profileId: state['profileId'] is String
            ? state['profileId']! as String
            : null,
        profileName: state['profileName'] is String
            ? state['profileName']! as String
            : null,
        lines: const ['Ended, not restored'],
      );
    }
    return ListenableBuilder(
      listenable: link,
      builder: (context, _) => LayoutBuilder(
        builder: (context, box) {
          final ended = link.status == TerminalStatus.ended;
          // The banner takes at most half the pane; the grid gets the rest.
          final maxBanner = box.hasBoundedHeight ? box.maxHeight / 2 : 200.0;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (ended)
                // A banner is only as tall as its text, up to half the pane, and
                // scrolls beyond that. It is not flexible: a flex child would
                // be given half of the room whatever it needs.
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxBanner),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      _EndedView(
                        controller: controller,
                        pane: pane,
                        profileId: link.profileId,
                        profileName: link.profileName,
                        lines: _lines(link),
                        compact: true,
                      ),
                    ],
                  ),
                )
              else if (_lines(link) case final lines when lines.isNotEmpty)
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxBanner),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      Material(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHigh,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [for (final l in lines) Text(l)],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              // Mounted from the start: the first layout gives the open its
              // size. The global key keeps the view when the pane moves in the
              // tree (a split, a move into a split).
              Expanded(
                child: KeyedSubtree(
                  key: GlobalObjectKey(link),
                  child: link.surface.view,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// What to say about a link besides its surface.
  static List<String> _lines(TerminalLink link) {
    final exit = link.exit;
    return [
      switch (link.status) {
        TerminalStatus.starting => 'Starting…',
        TerminalStatus.closing => 'Closing…',
        TerminalStatus.ended when exit != null =>
          '${exit.status == null ? 'The shell ended (${exit.reason.wire})' : 'The shell ended (exit status ${exit.status})'}.'
              '${exit.outputComplete ? '' : ' The output may be incomplete.'}',
        TerminalStatus.ended when link.error == null => 'The shell ended.',
        _ => '',
      },
      ?link.error,
      ?link.notice,
      if (link.inputPaused) 'Input paused: the shell is not reading.',
    ].where((l) => l.isNotEmpty).toList();
  }
}

/// A terminal that is not running: restored, ended or never started.
class _EndedView extends StatelessWidget {
  const _EndedView({
    required this.controller,
    required this.pane,
    required this.profileId,
    required this.profileName,
    required this.lines,
    this.compact = false,
  });

  final WorkbenchController controller;
  final PaneNode pane;
  final String? profileId;
  final String? profileName;
  final List<String> lines;

  /// A strip above a surface rather than the whole body.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final profiles = controller.profiles;
    final id = profileId;
    // Unknown until the host has listed them: assume it is still there.
    final gone =
        id == null ||
        (profiles != null && !profiles.profiles.any((p) => p.id == id));
    ShellProfile? fallback;
    if (profiles != null && profiles.defaultAvailable) {
      for (final p in profiles.profiles) {
        if (p.id == profiles.defaultId) fallback = p;
      }
    }
    final reason = controller.terminalsUnavailableReason;
    final label = gone && fallback != null
        ? 'Start shell with ${fallback.name}'
        : gone
        ? 'Choose a profile'
        : 'Start shell';
    final VoidCallback? onPressed = reason != null
        ? null
        : () async {
            var start = gone ? fallback?.id : id;
            if (start == null) {
              final list = profiles?.profiles ?? const <ShellProfile>[];
              start = await showProfilePicker(context, list);
            }
            if (start != null) await controller.startShell(pane.id, start);
          };
    final children = [
      for (final l in lines) Text(l),
      if (profileName != null && !compact) Text('Profile: $profileName'),
      if (gone && profileName != null)
        Text('The profile "$profileName" no longer exists.'),
      if (reason != null) Text('A shell cannot be started: $reason.'),
      FilledButton.tonal(
        key: Key('start-shell-${pane.id}'),
        onPressed: onPressed,
        child: Text(label, textAlign: TextAlign.center),
      ),
    ];
    final content = Column(
      crossAxisAlignment: compact
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final c in children)
          Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: c),
      ],
    );
    if (compact) {
      return Material(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: content,
        ),
      );
    }
    // Scrolls when the pane is too small to show everything.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(padding: const EdgeInsets.all(8), child: content),
          ),
        ),
      ),
    );
  }
}
