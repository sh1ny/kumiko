import 'dart:async';

import 'package:domain/domain.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:host_protocol/host_protocol.dart';

import 'cleanup_controller.dart';
import 'cleanup_list_view.dart';
import 'terminal/profiles_dialog.dart';
import 'terminal/terminal_pane_view.dart';
import 'workbench_controller.dart';

const String _openFolderValue = '#open-folder';
const String _terminalValue = '#terminal';
const String _terminalProfileValue = '#terminal-profile';
const String _shellProfilesValue = '#shell-profiles';

/// The workbench: workspaces sidebar, a tab strip over the active tab's pane
/// tree, notices.
class WorkbenchPage extends StatefulWidget {
  const WorkbenchPage({super.key, required this.controller, this.cleanup});

  final WorkbenchController controller;

  /// The host's whole *cleanup unresolved* list, including entries for
  /// directories that are not (or no longer) workspaces.
  final CleanupController? cleanup;

  @override
  State<WorkbenchPage> createState() => _WorkbenchPageState();
}

class _WorkbenchPageState extends State<WorkbenchPage> {
  WorkbenchController get controller => widget.controller;
  CleanupController? get cleanup => widget.cleanup;

  @override
  void initState() {
    super.initState();
    // Early, so the shortcut runs before the focused terminal view's own key
    // handling, which would otherwise consume it.
    FocusManager.instance.addEarlyKeyEventHandler(_onKey);
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_onKey);
    super.dispose();
  }

  /// Ctrl+Shift+T (Cmd+T on macOS): New terminal.
  KeyEventResult _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.keyT) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final matches = defaultTargetPlatform == TargetPlatform.macOS
        ? keyboard.isMetaPressed &&
              !keyboard.isControlPressed &&
              !keyboard.isShiftPressed &&
              !keyboard.isAltPressed
        : keyboard.isControlPressed &&
              keyboard.isShiftPressed &&
              !keyboard.isAltPressed &&
              !keyboard.isMetaPressed;
    if (!matches || controller.layout == null) return KeyEventResult.ignored;
    unawaited(launchTerminalFlow(context, controller));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final layout = controller.layout;
          if (layout == null) {
            final error = controller.loadError;
            return Center(
              child: error != null
                  ? Text(error)
                  : const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 12),
                        Flexible(child: Text('Loading the workbench...')),
                      ],
                    ),
            );
          }
          return Column(
            children: [
              ..._notices(context),
              Expanded(
                child: Row(
                  children: [
                    if (layout.sidebarCollapsed)
                      _CollapsedStrip(controller: controller)
                    else
                      _Sidebar(controller: controller),
                    Expanded(child: _CentralArea(controller: controller)),
                  ],
                ),
              ),
              _StatusBar(controller: controller, cleanup: cleanup),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _notices(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final saver = controller.saver;
    return [
      if (controller.reconciling)
        _Banner(
          color: scheme.secondaryContainer,
          text: 'Cleaning up after the previous session...',
        ),
      if (controller.restoreNotice case final notice?)
        _Banner(
          color: scheme.tertiaryContainer,
          text: notice,
          actions: [
            IconButton(
              tooltip: 'Dismiss',
              icon: const Icon(Icons.close),
              onPressed: controller.dismissRestoreNotice,
            ),
          ],
        ),
      // Shown until a save succeeds, through later changes and Retry.
      if (saver.notice case final notice?)
        _Banner(
          color: scheme.errorContainer,
          text: notice,
          actions: [
            TextButton(
              key: const Key('retry-save'),
              onPressed: controller.retrySave,
              child: const Text('Retry'),
            ),
          ],
        ),
      if (controller.message case final message?)
        _Banner(
          color: scheme.errorContainer,
          text: message,
          actions: [
            IconButton(
              tooltip: 'Dismiss',
              icon: const Icon(Icons.close),
              onPressed: controller.dismissMessage,
            ),
          ],
        ),
    ];
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.color,
    required this.text,
    this.actions = const [],
  });

  final Color color;
  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Expanded(child: Text(text)),
            ...actions,
          ],
        ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.controller, required this.cleanup});

  final WorkbenchController controller;
  final CleanupController? cleanup;

  @override
  Widget build(BuildContext context) {
    final hello = controller.hello;
    if (hello == null) return const SizedBox.shrink();
    final cleanup = this.cleanup;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        children: [
          const Flexible(
            child: Text(
              'Host connected',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Protocol version ${hello.version}, host ${hello.hostVersion}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Always reachable, also with the sidebar collapsed and for
          // entries no workspace badge leads to.
          if (cleanup != null)
            Flexible(
              child: ListenableBuilder(
                listenable: cleanup,
                builder: (context, _) {
                  final workspaces = cleanup.unresolvedWorkspaces;
                  if (workspaces == 0) return const SizedBox.shrink();
                  final units = cleanup.unresolvedUnits;
                  return TextButton(
                    key: const Key('cleanup-all'),
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => _CleanupDialog.shared(cleanup),
                    ),
                    child: Text(
                      'Cleanup unresolved: $workspaces '
                      '${workspaces == 1 ? 'workspace' : 'workspaces'}, '
                      '$units ${units == 1 ? 'unit' : 'units'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

// --- sidebar -----------------------------------------------------------------

class _CollapsedStrip extends StatelessWidget {
  const _CollapsedStrip({required this.controller});

  final WorkbenchController controller;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      child: Align(
        alignment: Alignment.topCenter,
        child: IconButton(
          tooltip: 'Expand sidebar',
          icon: const Icon(Icons.chevron_right),
          onPressed: () => controller.setSidebarCollapsed(false),
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.controller});

  final WorkbenchController controller;

  @override
  Widget build(BuildContext context) {
    final layout = controller.layout!;
    final selected = layout.selectedWorkspace;
    final personalSelected = selected == null;
    return SizedBox(
      key: const Key('sidebar'),
      width: 260,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(left: 12),
                    child: Text('Kumiko'),
                  ),
                ),
                IconButton(
                  tooltip: 'Collapse sidebar',
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => controller.setSidebarCollapsed(true),
                ),
              ],
            ),
            ListTile(
              key: const Key('personal'),
              dense: true,
              selected: personalSelected,
              onTap: controller.selectPersonal,
              leading: const Icon(Icons.person_outline),
              title: const Text('Personal'),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('Workspaces'),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final w in controller.workspaces)
                    _WorkspaceTile(
                      key: ValueKey('ws-tile-${w.id}'),
                      controller: controller,
                      record: w,
                      selected: selected == w.id,
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: FilledButton.tonal(
                onPressed: () => controller.openFolder(),
                child: const Text('Open folder'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkspaceTile extends StatelessWidget {
  const _WorkspaceTile({
    super.key,
    required this.controller,
    required this.record,
    required this.selected,
  });

  final WorkbenchController controller;
  final WorkspaceRecord record;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bound = controller.isBound(record.id);
    final unavailable = record.availability == Availability.unavailable;
    return Material(
      key: Key('ws-${record.id}'),
      color: selected
          ? theme.colorScheme.secondaryContainer
          : Colors.transparent,
      child: InkWell(
        onTap: () => controller.selectWorkspace(record.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(record.label, style: theme.textTheme.titleSmall),
                        Text(
                          record.path,
                          style: theme.textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: Key('remove-${record.id}'),
                    tooltip: bound ? 'Close its panes first' : 'Remove',
                    iconSize: 18,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: bound
                        ? null
                        : () => controller.removeWorkspace(record.id),
                  ),
                ],
              ),
              if (bound)
                Text(
                  "${record.label}'s panes must be closed first.",
                  style: theme.textTheme.bodySmall,
                ),
              if (record.availability == Availability.checking)
                Text('Checking...', style: theme.textTheme.bodySmall),
              if (unavailable) ...[
                Text(
                  'Unavailable${record.reason == null ? '' : ': ${record.reason}'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
                TextButton(
                  key: Key('check-${record.id}'),
                  onPressed: () => controller.checkAgain(record.id),
                  child: const Text('Check again'),
                ),
              ],
              if (record.cleanup.groups > 0)
                InkWell(
                  key: Key('badge-${record.id}'),
                  onTap: () => showCleanupList(context, controller, record.id),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      'Cleanup unresolved',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens the *cleanup unresolved* list filtered to one workspace.
Future<void> showCleanupList(
  BuildContext context,
  WorkbenchController controller,
  String workspaceId,
) => showDialog<void>(
  context: context,
  builder: (_) => _CleanupDialog(
    create: () => controller.createCleanupController(workspaceId),
  ),
);

/// The cleanup list in a dialog: a list of its own (filtered to one
/// workspace, disposed with the dialog) or the host's shared whole list.
class _CleanupDialog extends StatefulWidget {
  const _CleanupDialog({required this.create}) : shared = null;

  const _CleanupDialog.shared(this.shared) : create = null;

  final CleanupController Function()? create;
  final CleanupController? shared;

  @override
  State<_CleanupDialog> createState() => _CleanupDialogState();
}

class _CleanupDialogState extends State<_CleanupDialog> {
  late final CleanupController _cleanup = widget.shared ?? widget.create!();

  @override
  void dispose() {
    if (widget.shared == null) _cleanup.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 640,
        height: 480,
        child: Column(
          children: [
            Row(
              children: [
                const Expanded(
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('Unresolved cleanup'),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ],
            ),
            Expanded(child: CleanupListView(controller: _cleanup)),
          ],
        ),
      ),
    );
  }
}

// --- central area ------------------------------------------------------------

/// The key combination for New terminal, as shown on the button.
String newTerminalShortcutLabel() =>
    defaultTargetPlatform == TargetPlatform.macOS ? 'Cmd+T' : 'Ctrl+Shift+T';

/// Runs a terminal launch (the launcher, New terminal, the shortcut, or a
/// pane's split) and the prompts it may need: a profile to choose, or none
/// to add.
Future<void> launchTerminalFlow(
  BuildContext context,
  WorkbenchController controller, {
  String? splitOf,
  SplitDirection direction = SplitDirection.horizontal,
  bool choose = false,
  String? profileId,
}) async {
  final result = splitOf == null
      ? await controller.launchTerminal(profileId: profileId, choose: choose)
      : await controller.splitWithTerminal(
          splitOf,
          direction,
          profileId: profileId,
          choose: choose,
        );
  if (!context.mounted) return;
  switch (result.kind) {
    case TerminalLaunchKind.opened ||
        TerminalLaunchKind.unavailable ||
        TerminalLaunchKind.failed:
      break;
    case TerminalLaunchKind.chooseProfile:
      final chosen = await showProfilePicker(
        context,
        result.profiles,
        missingDefault: result.missingDefault,
      );
      if (chosen != null && context.mounted) {
        await launchTerminalFlow(
          context,
          controller,
          splitOf: splitOf,
          direction: direction,
          profileId: chosen,
        );
      }
    case TerminalLaunchKind.noProfile:
      if (await showNoProfilePrompt(context) && context.mounted) {
        await showProfilesDialog(context, controller, startWithNew: true);
      }
  }
}

/// Closes [paneIds]; terminals that are running are confirmed first.
Future<void> _closePanes(
  BuildContext context,
  WorkbenchController controller,
  List<String> paneIds,
) => controller.requestClose(paneIds, (warnings) async {
  if (!context.mounted) return false;
  return showCloseWarning(context, warnings);
});

/// The tab strip over the active tab's pane tree, or the empty state.
class _CentralArea extends StatelessWidget {
  const _CentralArea({required this.controller});

  final WorkbenchController controller;

  @override
  Widget build(BuildContext context) {
    final layout = controller.layout!;
    final active = layout.active;
    return Column(
      key: const Key('central-area'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TabStrip(controller: controller),
        Expanded(
          child: active == null
              ? _EmptyState(controller: controller)
              // Every tab stays mounted, only the active one shown: a
              // terminal view keeps its scroll, selection and search while
              // its tab is in the background.
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    for (final t in layout.tabs)
                      KeyedSubtree(
                        key: ValueKey('tab-body-${t.id}'),
                        child: Offstage(
                          offstage: t.id != active.id,
                          child: TickerMode(
                            enabled: t.id == active.id,
                            child: ExcludeFocus(
                              excluding: t.id != active.id,
                              child: _NodeView(controller, t.root),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _TabStrip extends StatelessWidget {
  const _TabStrip({required this.controller});

  final WorkbenchController controller;

  @override
  Widget build(BuildContext context) {
    final layout = controller.layout!;
    final selected = layout.selectedWorkspace;
    final reason = controller.terminalsUnavailableReason;
    final suffix = reason == null ? '' : ' ($reason)';
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: SizedBox(
        key: const Key('tab-strip'),
        height: 36,
        child: Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final t in layout.tabs)
                      _TabChip(
                        controller: controller,
                        tab: t,
                        active: t.id == layout.activeTab,
                      ),
                  ],
                ),
              ),
            ),
            PopupMenuButton<String>(
              key: const Key('add-tab'),
              tooltip: 'New tab',
              icon: const Icon(Icons.add, size: 18),
              style: _compactButton,
              onSelected: (value) {
                switch (value) {
                  case _openFolderValue:
                    controller.openFolder();
                  case _terminalValue:
                    launchTerminalFlow(context, controller);
                  case _terminalProfileValue:
                    launchTerminalFlow(context, controller, choose: true);
                  case _shellProfilesValue:
                    showProfilesDialog(context, controller);
                  default:
                    controller.openView(value);
                }
              },
              itemBuilder: (_) => [
                for (final kind in launcherViews)
                  PopupMenuItem<String>(
                    key: Key('launch-${kind.id}'),
                    value: kind.id,
                    enabled: !kind.needsWorkspace || selected != null,
                    child: Text(
                      kind.needsWorkspace && selected == null
                          ? '${kind.label} (needs a workspace)'
                          : kind.label,
                    ),
                  ),
                const PopupMenuDivider(),
                PopupMenuItem<String>(
                  key: const Key('launch-terminal'),
                  value: _terminalValue,
                  enabled: reason == null,
                  child: Text('Terminal$suffix'),
                ),
                PopupMenuItem<String>(
                  key: const Key('launch-terminal-profile'),
                  value: _terminalProfileValue,
                  enabled: reason == null,
                  child: const Text('Terminal with profile...'),
                ),
                PopupMenuItem<String>(
                  key: const Key('shell-profiles'),
                  value: _shellProfilesValue,
                  enabled: reason == null,
                  child: const Text('Shell profiles...'),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem<String>(
                  key: Key('open-folder'),
                  value: _openFolderValue,
                  child: Text('Open folder...'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

final ButtonStyle _compactButton = IconButton.styleFrom(
  padding: EdgeInsets.zero,
  minimumSize: const Size(28, 28),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.controller,
    required this.tab,
    required this.active,
  });

  final WorkbenchController controller;
  final LayoutTabNode tab;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final movable = controller.canMoveIntoSplit(tab.id);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 220),
      child: Material(
        key: Key('tab-${tab.id}'),
        color: active
            ? theme.colorScheme.secondaryContainer
            : theme.colorScheme.surfaceContainerHighest,
        child: InkWell(
          onTap: () => controller.activateTab(tab.id),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    controller.tabTitle(tab),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (tab.paneCount > 1)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text(
                    '${tab.paneCount}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              PopupMenuButton<String>(
                key: Key('tab-menu-${tab.id}'),
                tooltip: 'Tab actions',
                icon: const Icon(Icons.more_vert, size: 14),
                style: _compactButton,
                onSelected: (value) {
                  switch (value) {
                    case 'right':
                      controller.moveTabIntoSplit(
                        tab.id,
                        SplitDirection.horizontal,
                      );
                    case 'below':
                      controller.moveTabIntoSplit(
                        tab.id,
                        SplitDirection.vertical,
                      );
                    case 'close':
                      _closePanes(
                        context,
                        controller,
                        controller.panesOfTab(tab.id),
                      );
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem<String>(
                    key: Key('move-split-right-${tab.id}'),
                    value: 'right',
                    enabled: movable,
                    child: const Text('Move into split right'),
                  ),
                  PopupMenuItem<String>(
                    key: Key('move-split-below-${tab.id}'),
                    value: 'below',
                    enabled: movable,
                    child: const Text('Move into split below'),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem<String>(
                    key: Key('close-tab-${tab.id}'),
                    value: 'close',
                    child: const Text('Close tab'),
                  ),
                ],
              ),
              IconButton(
                key: Key('close-${tab.id}'),
                tooltip: 'Close tab',
                icon: const Icon(Icons.close, size: 14),
                style: _compactButton,
                onPressed: () => _closePanes(
                  context,
                  controller,
                  controller.panesOfTab(tab.id),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// No tab is open: a short message and a prominent New terminal.
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.controller});

  final WorkbenchController controller;

  @override
  Widget build(BuildContext context) {
    final reason = controller.terminalsUnavailableReason;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            key: const Key('empty-state'),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('No tab is open.', textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  FilledButton(
                    key: const Key('new-terminal'),
                    onPressed: reason == null
                        ? () => launchTerminalFlow(context, controller)
                        : null,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'New terminal',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          newTerminalShortcutLabel(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (reason != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'A terminal cannot be started: $reason.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// --- pane tree ---------------------------------------------------------------

class _NodeView extends StatelessWidget {
  const _NodeView(this.controller, this.node);

  final WorkbenchController controller;
  final LayoutNode node;

  @override
  Widget build(BuildContext context) => switch (node) {
    final PaneNode p => _PaneView(
      key: ValueKey('pane-view-${p.id}'),
      controller: controller,
      pane: p,
    ),
    final SplitNode s => _SplitView(
      key: ValueKey('split-view-${s.id}'),
      controller: controller,
      node: s,
    ),
  };
}

class _SplitView extends StatelessWidget {
  const _SplitView({super.key, required this.controller, required this.node});

  final WorkbenchController controller;
  final SplitNode node;

  static const double _handle = 6;

  /// Moves the divider by [share] from the current ratio: several updates
  /// can arrive before the rebuild that would refresh [node].
  void _drag(double share) {
    final current = controller.layout?.splitNode(node.id)?.ratio ?? node.ratio;
    controller.setRatio(node.id, current + share);
  }

  @override
  Widget build(BuildContext context) {
    final horizontal = node.direction == SplitDirection.horizontal;
    return LayoutBuilder(
      builder: (context, constraints) {
        final total = horizontal ? constraints.maxWidth : constraints.maxHeight;
        final available = (total - _handle).clamp(1.0, double.infinity);
        final firstSize = available * node.ratio;
        final first = SizedBox(
          width: horizontal ? firstSize : null,
          height: horizontal ? null : firstSize,
          child: _NodeView(controller, node.first),
        );
        final handle = MouseRegion(
          cursor: horizontal
              ? SystemMouseCursors.resizeColumn
              : SystemMouseCursors.resizeRow,
          child: GestureDetector(
            key: Key('split-handle-${node.id}'),
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: horizontal
                ? (d) => _drag(d.delta.dx / available)
                : null,
            onVerticalDragUpdate: horizontal
                ? null
                : (d) => _drag(d.delta.dy / available),
            child: Container(
              width: horizontal ? _handle : null,
              height: horizontal ? null : _handle,
              color: Theme.of(context).dividerColor,
            ),
          ),
        );
        final second = Expanded(child: _NodeView(controller, node.second));
        return horizontal
            ? Row(children: [first, handle, second])
            : Column(children: [first, handle, second]);
      },
    );
  }
}

/// One pane: a thin header and the view, through one path for every kind.
class _PaneView extends StatelessWidget {
  const _PaneView({super.key, required this.controller, required this.pane});

  final WorkbenchController controller;
  final PaneNode pane;

  @override
  Widget build(BuildContext context) {
    final layout = controller.layout!;
    final focused = layout.focusedPane == pane.id;
    return Column(
      key: Key('pane-${pane.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PaneHeader(controller: controller, pane: pane, focused: focused),
        Expanded(
          child: ClipRect(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => controller.focusPane(pane.id),
              child: _PaneBody(controller: controller, pane: pane),
            ),
          ),
        ),
      ],
    );
  }
}

class _PaneHeader extends StatelessWidget {
  const _PaneHeader({
    required this.controller,
    required this.pane,
    required this.focused,
  });

  final WorkbenchController controller;
  final PaneNode pane;
  final bool focused;

  static const double _wideFrom = 200;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final workspace = pane.workspace == null
        ? null
        : controller.workspace(pane.workspace!);
    final unavailable = workspace?.availability == Availability.unavailable;
    final reason = controller.terminalsUnavailableReason;
    final tab = controller.layout!.tabOf(pane.id);
    final canMove = tab != null && tab.paneCount > 1;
    String splitTip(String label) =>
        reason == null ? label : '$label ($reason)';
    void split(SplitDirection direction) => launchTerminalFlow(
      context,
      controller,
      splitOf: pane.id,
      direction: direction,
    );
    void close() => _closePanes(context, controller, [pane.id]);

    final title = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => controller.focusPane(pane.id),
      child: Row(
        children: [
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                controller.paneTitle(pane),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium,
              ),
            ),
          ),
          if (unavailable)
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text(
                  'unavailable',
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    return Material(
      key: Key('pane-header-${pane.id}'),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          focused
              ? Container(
                  key: Key('focused-pane-${pane.id}'),
                  height: 2,
                  color: theme.colorScheme.primary,
                )
              : const SizedBox(height: 2),
          SizedBox(
            height: 26,
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth < _wideFrom) {
                  return Row(
                    children: [
                      Expanded(child: title),
                      PopupMenuButton<String>(
                        key: Key('pane-menu-${pane.id}'),
                        tooltip: 'Pane actions',
                        icon: const Icon(Icons.more_vert, size: 14),
                        style: _paneButtonStyle,
                        onSelected: (value) => switch (value) {
                          'right' => split(SplitDirection.horizontal),
                          'down' => split(SplitDirection.vertical),
                          'move' => controller.movePaneToNewTab(pane.id),
                          _ => close(),
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem<String>(
                            key: Key('split-right-${pane.id}'),
                            value: 'right',
                            enabled: reason == null,
                            child: Text(splitTip('Split right')),
                          ),
                          PopupMenuItem<String>(
                            key: Key('split-down-${pane.id}'),
                            value: 'down',
                            enabled: reason == null,
                            child: Text(splitTip('Split down')),
                          ),
                          PopupMenuItem<String>(
                            key: Key('move-${pane.id}'),
                            value: 'move',
                            enabled: canMove,
                            child: const Text('Move to new tab'),
                          ),
                          PopupMenuItem<String>(
                            key: Key('close-pane-${pane.id}'),
                            value: 'close',
                            child: const Text('Close pane'),
                          ),
                        ],
                      ),
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: title),
                    IconButton(
                      key: Key('split-right-${pane.id}'),
                      tooltip: splitTip('Split right'),
                      icon: const Icon(Icons.vertical_split, size: 14),
                      style: _paneButtonStyle,
                      onPressed: reason == null
                          ? () => split(SplitDirection.horizontal)
                          : null,
                    ),
                    IconButton(
                      key: Key('split-down-${pane.id}'),
                      tooltip: splitTip('Split down'),
                      icon: const Icon(Icons.horizontal_split, size: 14),
                      style: _paneButtonStyle,
                      onPressed: reason == null
                          ? () => split(SplitDirection.vertical)
                          : null,
                    ),
                    IconButton(
                      key: Key('move-${pane.id}'),
                      tooltip: 'Move to new tab',
                      icon: const Icon(Icons.open_in_new, size: 14),
                      style: _paneButtonStyle,
                      onPressed: canMove
                          ? () => controller.movePaneToNewTab(pane.id)
                          : null,
                    ),
                    IconButton(
                      key: Key('close-pane-${pane.id}'),
                      tooltip: 'Close pane',
                      icon: const Icon(Icons.close, size: 14),
                      style: _paneButtonStyle,
                      onPressed: close,
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

final ButtonStyle _paneButtonStyle = IconButton.styleFrom(
  padding: EdgeInsets.zero,
  minimumSize: const Size(26, 26),
  fixedSize: const Size(26, 26),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

class _PaneBody extends StatelessWidget {
  const _PaneBody({required this.controller, required this.pane});

  final WorkbenchController controller;
  final PaneNode pane;

  @override
  Widget build(BuildContext context) {
    if (pane.kind == workspaceOverviewKind) {
      return WorkspaceOverview(
        controller: controller,
        workspaceId: pane.workspace,
      );
    }
    if (pane.kind == terminalKind) {
      return TerminalPaneView(
        key: ValueKey('terminal-view-${pane.id}'),
        controller: controller,
        pane: pane,
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Text(
        'Unsupported view: this version of Kumiko does not know the view kind '
        '"${pane.kind}". It is kept as it is.',
      ),
    );
  }
}

/// The Workspace overview view (design D7): path, identity, availability,
/// cleanup state with a link to the filtered list, Check again.
class WorkspaceOverview extends StatelessWidget {
  const WorkspaceOverview({
    super.key,
    required this.controller,
    required this.workspaceId,
  });

  final WorkbenchController controller;
  final String? workspaceId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final id = workspaceId;
    final record = id == null ? null : controller.workspace(id);
    if (id == null || record == null) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text('This workspace is no longer listed.'),
      );
    }
    final availability = switch (record.availability) {
      Availability.available => 'available',
      Availability.checking => 'checking',
      Availability.unavailable =>
        'unavailable${record.reason == null ? '' : ' (${record.reason})'}',
    };
    return SingleChildScrollView(
      key: Key('overview-$id'),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(record.label, style: theme.textTheme.headlineSmall),
          Text(record.path),
          Text('Identity: ${record.identity}'),
          Text('Availability: $availability'),
          const SizedBox(height: 8),
          if (record.cleanup.groups > 0)
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'Cleanup unresolved: ${record.cleanup.groups} '
                  '${record.cleanup.groups == 1 ? 'group' : 'groups'}',
                ),
                TextButton(
                  onPressed: () => showCleanupList(context, controller, id),
                  child: const Text('Show cleanup list'),
                ),
              ],
            )
          else
            const Text('No unresolved cleanup'),
          const SizedBox(height: 8),
          OutlinedButton(
            key: Key('overview-check-$id'),
            onPressed: () => controller.checkAgain(id),
            child: const Text('Check again'),
          ),
        ],
      ),
    );
  }
}
