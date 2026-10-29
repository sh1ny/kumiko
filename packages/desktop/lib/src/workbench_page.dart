import 'package:domain/domain.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:host_protocol/host_protocol.dart';

import 'cleanup_controller.dart';
import 'cleanup_list_view.dart';
import 'layout_saver.dart';
import 'workbench_controller.dart';

const String _openFolderValue = '#open-folder';

/// The workbench: workspaces sidebar, split tab groups, notices.
class WorkbenchPage extends StatelessWidget {
  const WorkbenchPage({super.key, required this.controller});

  final WorkbenchController controller;

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
                        Text('Loading the workbench...'),
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
                    Expanded(child: _NodeView(controller, layout.root)),
                  ],
                ),
              ),
              _StatusBar(controller: controller),
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
      if (saver.state == SaveState.failed && saver.notice != null)
        _Banner(
          color: scheme.errorContainer,
          text: saver.notice!,
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
  const _Banner({required this.color, required this.text, this.actions = const []});

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
  const _StatusBar({required this.controller});

  final WorkbenchController controller;

  @override
  Widget build(BuildContext context) {
    final hello = controller.hello;
    if (hello == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        children: [
          const Text('Host connected'),
          const SizedBox(width: 12),
          Text('Protocol version ${hello.version}, host ${hello.hostVersion}'),
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
    final focused = layout.group(layout.focusedGroup);
    final personalSelected = focused?.context == null;
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
              dense: true,
              selected: personalSelected,
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
                      selected: focused?.context == w.id,
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
      color: selected ? theme.colorScheme.secondaryContainer : Colors.transparent,
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
                    tooltip: bound ? 'Close its tabs first' : 'Remove',
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
                  "${record.label}'s tabs must be closed first.",
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
  builder: (_) => _CleanupDialog(controller: controller, workspaceId: workspaceId),
);

class _CleanupDialog extends StatefulWidget {
  const _CleanupDialog({required this.controller, required this.workspaceId});

  final WorkbenchController controller;
  final String workspaceId;

  @override
  State<_CleanupDialog> createState() => _CleanupDialogState();
}

class _CleanupDialogState extends State<_CleanupDialog> {
  late final CleanupController _cleanup = widget.controller
      .createCleanupController(widget.workspaceId);

  @override
  void dispose() {
    _cleanup.dispose();
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

// --- split tree --------------------------------------------------------------

class _NodeView extends StatelessWidget {
  const _NodeView(this.controller, this.node);

  final WorkbenchController controller;
  final LayoutNode node;

  @override
  Widget build(BuildContext context) => switch (node) {
    final TabGroup g => _GroupView(
      key: ValueKey('group-view-${g.id}'),
      controller: controller,
      group: g,
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
                ? (d) => controller.setRatio(
                    node.id,
                    node.ratio + d.delta.dx / available,
                  )
                : null,
            onVerticalDragUpdate: horizontal
                ? null
                : (d) => controller.setRatio(
                    node.id,
                    node.ratio + d.delta.dy / available,
                  ),
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

class _GroupView extends StatelessWidget {
  const _GroupView({super.key, required this.controller, required this.group});

  final WorkbenchController controller;
  final TabGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final focused = controller.layout!.focusedGroup == group.id;
    LayoutTab? active;
    for (final t in group.tabs) {
      if (t.id == group.active) active = t;
    }
    return DragTarget<String>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) => controller.moveTab(d.data, group.id),
      builder: (context, candidates, _) => Listener(
        onPointerDown: (_) => controller.focusGroup(group.id),
        child: Container(
          key: Key('group-${group.id}'),
          decoration: BoxDecoration(
            border: Border.all(
              color: candidates.isNotEmpty
                  ? theme.colorScheme.tertiary
                  : focused
                  ? theme.colorScheme.primary
                  : theme.dividerColor,
              width: focused || candidates.isNotEmpty ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _GroupHeader(controller: controller, group: group),
              Expanded(
                child: active == null
                    ? const Center(
                        child: Text('No tabs. Use + to open a view.'),
                      )
                    : _TabBody(controller: controller, tab: active),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.controller, required this.group});

  final WorkbenchController controller;
  final TabGroup group;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: Row(
        children: [
          Expanded(
            child: ScrollConfiguration(
              // Dragging a tab must not scroll the strip; the wheel still does.
              behavior: ScrollConfiguration.of(
                context,
              ).copyWith(dragDevices: <PointerDeviceKind>{}),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final t in group.tabs)
                      _TabChip(
                        controller: controller,
                        tab: t,
                        active: t.id == group.active,
                      ),
                  ],
                ),
              ),
            ),
          ),
          PopupMenuButton<String>(
            key: Key('add-${group.id}'),
            tooltip: 'New tab',
            icon: const Icon(Icons.add, size: 18),
            padding: EdgeInsets.zero,
            onSelected: (value) {
              if (value == _openFolderValue) {
                controller.openFolder(groupId: group.id);
              } else {
                controller.openView(group.id, value);
              }
            },
            itemBuilder: (_) => [
              for (final kind in registeredViews)
                PopupMenuItem<String>(
                  value: kind.id,
                  enabled: !kind.needsWorkspace || group.context != null,
                  child: Text(
                    kind.needsWorkspace && group.context == null
                        ? '${kind.label} (needs a workspace)'
                        : kind.label,
                  ),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem<String>(
                value: _openFolderValue,
                child: Text('Open folder...'),
              ),
            ],
          ),
          _SmallButton(
            key: Key('split-h-${group.id}'),
            tooltip: 'Split right',
            icon: Icons.vertical_split,
            onPressed: () =>
                controller.split(group.id, SplitDirection.horizontal),
          ),
          _SmallButton(
            key: Key('split-v-${group.id}'),
            tooltip: 'Split down',
            icon: Icons.horizontal_split,
            onPressed: () =>
                controller.split(group.id, SplitDirection.vertical),
          ),
        ],
      ),
    );
  }
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    icon: Icon(icon, size: 18),
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: 32, height: 32),
    onPressed: onPressed,
  );
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.controller,
    required this.tab,
    required this.active,
  });

  final WorkbenchController controller;
  final LayoutTab tab;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kind = viewKindOf(tab.kind);
    final workspace = tab.workspace == null
        ? null
        : controller.workspace(tab.workspace!);
    final unavailable = workspace?.availability == Availability.unavailable;
    final title = kind == null
        ? 'Unsupported view'
        : workspace == null
        ? kind.label
        : '${kind.label} · ${workspace.label}';
    final chip = Material(
      color: active
          ? theme.colorScheme.secondaryContainer
          : theme.colorScheme.surfaceContainerHighest,
      child: InkWell(
        onTap: () => controller.activateTab(tab.id),
        child: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Row(
            children: [
              Text(title),
              if (unavailable) ...[
                const SizedBox(width: 6),
                Text(
                  'unavailable',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              IconButton(
                key: Key('close-${tab.id}'),
                tooltip: 'Close tab',
                icon: const Icon(Icons.close, size: 14),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                onPressed: () => controller.closeTab(tab.id),
              ),
            ],
          ),
        ),
      ),
    );
    return Draggable<String>(
      key: Key('tab-${tab.id}'),
      data: tab.id,
      feedback: Material(
        elevation: 4,
        child: Padding(padding: const EdgeInsets.all(8), child: Text(title)),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: chip),
      child: chip,
    );
  }
}

// --- tab bodies --------------------------------------------------------------

class _TabBody extends StatelessWidget {
  const _TabBody({required this.controller, required this.tab});

  final WorkbenchController controller;
  final LayoutTab tab;

  @override
  Widget build(BuildContext context) {
    if (tab.kind == workspaceOverviewKind) {
      return WorkspaceOverview(controller: controller, workspaceId: tab.workspace);
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        'Unsupported view: this version of Kumiko does not know the view kind '
        '"${tab.kind}". It is kept as it is.',
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
        padding: EdgeInsets.all(16),
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
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(record.label, style: theme.textTheme.headlineSmall),
          Text(record.path),
          Text('Identity: ${record.identity}'),
          Text('Availability: $availability'),
          const SizedBox(height: 8),
          if (record.cleanup.groups > 0)
            Row(
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
