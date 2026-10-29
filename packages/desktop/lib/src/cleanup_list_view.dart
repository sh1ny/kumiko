import 'package:flutter/material.dart';
import 'package:host_protocol/host_protocol.dart';

import 'cleanup_controller.dart';

String _plural(int n, String one, String many) => '$n ${n == 1 ? one : many}';

/// The *cleanup unresolved* list with counts, paging, Retry cleanup and
/// Confirm processes are gone.
class CleanupListView extends StatelessWidget {
  const CleanupListView({super.key, required this.controller});

  final CleanupController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.reconciling) {
          return const Center(
            child: Text('Cleaning up after the previous session...'),
          );
        }
        final workspaces = controller.workspaces;
        final empty = controller.loaded && workspaces.isEmpty;
        return ListView(
          children: [
            if (controller.message != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  controller.message!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (empty)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text('No unresolved cleanup'),
              )
            else if (workspaces.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  '${_plural(controller.unresolvedWorkspaces, 'workspace', 'workspaces')}, '
                  '${_plural(controller.unresolvedUnits, 'unit', 'units')} need cleanup',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  'Cleaned means no recorded or marked process remains.',
                ),
              ),
              for (final w in workspaces)
                WorkspaceTile(
                  key: ValueKey(w.targetIdentity),
                  workspace: w,
                  busy: controller.isBusy(w.targetIdentity),
                  units: controller.unitsOf(w),
                  hasMoreUnits: controller.hasMoreUnits(w),
                  loadingUnits: controller.isLoadingUnits(w.targetIdentity),
                  onMoreUnits: () => controller.loadMoreUnits(w.targetIdentity),
                  onRetry: () => controller.retry(w.targetIdentity),
                  onConfirm: () => controller.confirm(w.targetIdentity),
                ),
              if (controller.hasMore)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: OutlinedButton(
                    onPressed: controller.loading ? null : controller.loadMore,
                    child: const Text('Show more workspaces'),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

/// One *cleanup unresolved* workspace: its path, unit count, its units with
/// their reasons (the first ten, then pages on request), and the two actions.
/// Both actions act on every unit of the workspace, whatever was shown.
class WorkspaceTile extends StatelessWidget {
  const WorkspaceTile({
    super.key,
    required this.workspace,
    required this.busy,
    required this.units,
    required this.hasMoreUnits,
    required this.loadingUnits,
    required this.onMoreUnits,
    required this.onRetry,
    required this.onConfirm,
  });

  final CleanupWorkspace workspace;
  final bool busy;

  /// The units shown so far.
  final List<CleanupUnit> units;
  final bool hasMoreUnits;
  final bool loadingUnits;
  final VoidCallback onMoreUnits;
  final VoidCallback onRetry;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              workspace.targetPath,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(_plural(workspace.unitCount, 'unit', 'units')),
            for (final u in units)
              Text(
                '${u.kind}${u.pid == null ? '' : ' (pid ${u.pid})'}: '
                '${u.reason ?? 'unresolved'}',
              ),
            if (hasMoreUnits)
              TextButton(
                onPressed: loadingUnits ? null : onMoreUnits,
                child: const Text('Show more units'),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: busy ? null : onRetry,
                  child: const Text('Retry cleanup'),
                ),
                OutlinedButton(
                  onPressed: busy ? null : onConfirm,
                  child: const Text('Confirm processes are gone'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
