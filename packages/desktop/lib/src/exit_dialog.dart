import 'package:flutter/material.dart';

import 'exit_coordinator.dart';

/// The exit dialog (app-exit): every affected item with its own **Stop**,
/// **Stop processes and close** with its consequences, and **Cancel**. It
/// follows the coordinator's live list.
class ExitDialog extends StatelessWidget {
  const ExitDialog({super.key, required this.coordinator});

  final ExitCoordinator coordinator;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: coordinator,
      builder: (context, _) {
        if (coordinator.phase == ExitPhase.quitting) {
          return const AlertDialog(
            key: Key('exit-dialog'),
            title: Text('Quitting…'),
            content: Text(
              'Saving the workbench and ending the host.',
              key: Key('exit-quitting'),
            ),
          );
        }
        final items = coordinator.items;
        return AlertDialog(
          key: const Key('exit-dialog'),
          title: const Text('Quit Kumiko?'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (coordinator.hostLost)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'The host was lost; the processes it ran have ended.',
                      key: Key('exit-host-lost'),
                    ),
                  ),
                Text(
                  items.isEmpty
                      ? 'Nothing is left to stop.'
                      : 'These items are still running or unsaved:',
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final item in items)
                          _ItemRow(coordinator: coordinator, item: item),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  coordinator.consequences,
                  key: const Key('exit-consequences'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              key: const Key('exit-cancel'),
              focusNode: coordinator.dialogFocus,
              autofocus: true,
              onPressed: coordinator.cancel,
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('exit-stop-all'),
              onPressed: coordinator.stopAllAndClose,
              child: const Text('Stop processes and close'),
            ),
          ],
        );
      },
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.coordinator, required this.item});

  final ExitCoordinator coordinator;
  final ExitItem item;

  @override
  Widget build(BuildContext context) {
    final failure = item.failure;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        key: Key('exit-item-${item.paneId}'),
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (item.work case final work?)
                  Text('${item.kindLabel}: $work'),
                if (failure != null)
                  Text(
                    '${item.kindLabel}: $failure — cleanup unresolved',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (item.draft case final draft?) Text(draft),
              ],
            ),
          ),
          if (item.canStop)
            TextButton(
              key: Key('exit-stop-${item.paneId}'),
              onPressed: () => coordinator.stop(item.paneId),
              child: const Text('Stop'),
            ),
        ],
      ),
    );
  }
}
