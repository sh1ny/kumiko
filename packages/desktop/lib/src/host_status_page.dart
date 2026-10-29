import 'package:flutter/material.dart';
import 'package:host_protocol/host_protocol.dart';

import 'cleanup_list_view.dart';
import 'host_controller.dart';

/// The host status window. It offers no action that needs the host; the only
/// actions are Restart host, Dismiss, and the cleanup list's.
class HostStatusPage extends StatelessWidget {
  const HostStatusPage({
    super.key,
    required this.controller,
    required this.hostPath,
  });

  final HostController controller;

  /// Where the desktop expects the bundled host, for the start error.
  final String hostPath;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Kumiko')),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) =>
            Padding(padding: const EdgeInsets.all(16), child: _body(context)),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final title = Theme.of(context).textTheme.headlineSmall;
    final error = controller.error;
    switch (controller.phase) {
      case HostPhase.idle:
      case HostPhase.starting:
        return Row(
          children: [
            const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            const Text('Starting the host...'),
          ],
        );
      case HostPhase.connected:
        final hello = controller.hello!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Host connected', style: title),
            Text(
              'Protocol version ${hello.version}, host ${hello.hostVersion}',
            ),
            const SizedBox(height: 16),
            Expanded(child: CleanupListView(controller: controller.cleanup!)),
          ],
        );
      case HostPhase.startError:
        final timeout = error?.kind == HostStartFailure.helloTimeout;
        return _Problem(
          title: 'Host start error',
          lines: [
            if (error?.kind == HostStartFailure.spawnFailed)
              'The host could not be started. Expected host: $hostPath',
            if (timeout)
              'The host did not answer the handshake before the timeout. '
                  'It was terminated.',
            if (error != null) error.message,
          ],
          stderr: error?.stderr ?? '',
          onRestart: controller.start,
        );
      case HostPhase.incompatible:
        return _Problem(
          title: 'Incompatible host',
          lines: [
            'This Kumiko and its host speak no common protocol version.',
            if (error != null) error.message,
          ],
          onRestart: controller.start,
        );
      case HostPhase.alreadyRunning:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Kumiko is already running', style: title),
            const Text('Another Kumiko is using this profile.'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: controller.dismissAlreadyRunning,
              child: const Text('Dismiss'),
            ),
          ],
        );
      case HostPhase.storeError:
        return _Problem(
          title: 'Store error',
          lines: [if (error != null) error.message],
          onRestart: controller.start,
        );
      case HostPhase.hostLost:
        final loss = controller.loss;
        return _Problem(
          title: 'Host lost',
          lines: [
            'The host stopped or the connection to it was lost.',
            'Nothing is running: units the host ran are stopped or unknown.',
            if (loss?.exitCode != null) 'Host exit code: ${loss!.exitCode}',
          ],
          stderr: loss?.stderr ?? '',
          onRestart: controller.start,
        );
    }
  }
}

class _Problem extends StatelessWidget {
  const _Problem({
    required this.title,
    required this.lines,
    required this.onRestart,
    this.stderr = '',
  });

  final String title;
  final List<String> lines;
  final String stderr;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          for (final line in lines) Text(line),
          if (stderr.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text('Host output:'),
            SelectableText(stderr),
          ],
          const SizedBox(height: 16),
          FilledButton(onPressed: onRestart, child: const Text('Restart host')),
        ],
      ),
    );
  }
}
