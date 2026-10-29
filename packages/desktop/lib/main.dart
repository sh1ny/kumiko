import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:host_protocol/host_protocol.dart';

import 'src/host_controller.dart';
import 'src/host_link.dart';
import 'src/host_location.dart';
import 'src/host_status_page.dart';
import 'src/launcher_link.dart';

/// Development only: `--dart-define=KUMIKO_HOST=<path>` replaces the bundled
/// host path.
const String _hostOverride = String.fromEnvironment('KUMIKO_HOST');

void main() {
  final os = HostOs.current;
  final hostPath = resolveHostExecutable(
    override: _hostOverride,
    appExecutable: Platform.resolvedExecutable,
    os: os,
  );
  final home =
      Platform.environment[os == HostOs.windows ? 'USERPROFILE' : 'HOME'] ?? '';
  final launcher = HostLauncher(
    executable: hostPath,
    profileDir: defaultProfileDir(
      os: os,
      env: Platform.environment,
      home: home,
    ),
  );
  runApp(
    KumikoApp(
      connector: launcherConnector(launcher),
      hostPath: hostPath,
      onExit: () => exit(0),
    ),
  );
}

/// The Kumiko desktop app: the host status window over a [HostConnector].
class KumikoApp extends StatefulWidget {
  const KumikoApp({
    super.key,
    required this.connector,
    required this.hostPath,
    required this.onExit,
  });

  final HostConnector connector;
  final String hostPath;
  final VoidCallback onExit;

  @override
  State<KumikoApp> createState() => _KumikoAppState();
}

class _KumikoAppState extends State<KumikoApp> {
  late final HostController _controller = HostController(
    connector: widget.connector,
    onExit: widget.onExit,
  );
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await _controller.shutdown();
        return AppExitResponse.exit;
      },
    );
    _controller.start();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kumiko',
      home: HostStatusPage(controller: _controller, hostPath: widget.hostPath),
    );
  }
}
