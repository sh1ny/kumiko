import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:host_protocol/host_protocol.dart';

import 'src/folder_picker.dart';
import 'src/host_controller.dart';
import 'src/host_link.dart';
import 'src/host_location.dart';
import 'src/host_status_page.dart';
import 'src/launcher_link.dart';
import 'src/terminal/alacritty_surface.dart';
import 'src/terminal/terminal_surface.dart';
import 'src/workbench_controller.dart';
import 'src/workbench_page.dart';

/// Development only: `--dart-define=KUMIKO_HOST=<path>` replaces the bundled
/// host path.
const String _hostOverride = String.fromEnvironment('KUMIKO_HOST');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Without the engine the app still runs; terminals are disabled.
  TerminalSurfaceFactory? surfaceFactory;
  try {
    await AlacrittySurface.init();
    surfaceFactory = AlacrittySurface.new;
  } on Object catch (e) {
    debugPrint('The terminal engine did not load: $e');
  }
  final os = HostOs.current;
  final hostPath = resolveHostExecutable(
    override: _hostOverride,
    appExecutable: Platform.resolvedExecutable,
    os: os,
  );
  final homeVariable = os == HostOs.windows ? 'USERPROFILE' : 'HOME';
  final profileDir = defaultProfileDir(
    os: os,
    env: Platform.environment,
    home: Platform.environment[homeVariable] ?? '',
  );
  final connector = profileDir == null
      ? noProfileDirConnector(homeVariable)
      : launcherConnector(
          HostLauncher(
            executable: hostPath,
            profileDir: profileDir,
            capabilities: {
              Capability.workbench,
              if (surfaceFactory != null) Capability.terminal,
            },
          ),
        );
  runApp(
    KumikoApp(
      connector: connector,
      hostPath: hostPath,
      onExit: () => exit(0),
      surfaceFactory: surfaceFactory,
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
    this.folderPicker = const FileSelectorFolderPicker(),
    this.surfaceFactory,
  });

  final HostConnector connector;
  final String hostPath;
  final VoidCallback onExit;
  final FolderPicker folderPicker;

  /// Makes a terminal's surface; null when the engine is not available.
  final TerminalSurfaceFactory? surfaceFactory;

  @override
  State<KumikoApp> createState() => _KumikoAppState();
}

class _KumikoAppState extends State<KumikoApp> {
  late final HostController _controller = HostController(
    connector: widget.connector,
    onExit: widget.onExit,
  );
  late final WorkbenchController _workbench = WorkbenchController(
    picker: widget.folderPicker,
    surfaceFactory: widget.surfaceFactory,
  );
  late final AppLifecycleListener _lifecycle;
  HostLink? _attached;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        // Pending layout changes go out first (bounded); a failure only sets
        // the notice.
        await _workbench.flush();
        await _controller.shutdown();
        return AppExitResponse.exit;
      },
    );
    _controller.addListener(_syncWorkbench);
    _controller.start();
  }

  /// Follows the host: the workbench attaches to each connected link and
  /// keeps its in-memory layout across a lost host.
  void _syncWorkbench() {
    final link = _controller.link;
    if (link == _attached) return;
    _attached = link;
    if (link == null) {
      _workbench.detach();
    } else {
      _workbench.attach(link);
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _controller.removeListener(_syncWorkbench);
    _workbench.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kumiko',
      home: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) => _controller.phase == HostPhase.connected
            ? WorkbenchPage(
                controller: _workbench,
                cleanup: _controller.cleanup,
              )
            : HostStatusPage(
                controller: _controller,
                hostPath: widget.hostPath,
              ),
      ),
    );
  }
}
