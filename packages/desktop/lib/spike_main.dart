import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_alacritty/flutter_alacritty.dart' show RustLib;
import 'package:host_protocol/host_protocol.dart';

import 'src/host_location.dart';
import 'src/launcher_link.dart';
import 'src/spike/terminal_spike.dart';
import 'src/terminal/alacritty_surface.dart';

/// Development only: `--dart-define=KUMIKO_HOST=<path>` replaces the bundled
/// host path.
const String _hostOverride = String.fromEnvironment('KUMIKO_HOST');

/// The terminal engine spike (change `host-terminals`, group 6):
/// `flutter run -t lib/spike_main.dart`. Debug builds only; the release
/// entry point never imports this file (audit rule D10).
Future<void> main() async {
  if (kReleaseMode) {
    throw StateError('the terminal spike runs in debug builds only');
  }
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  final os = HostOs.current;
  final home =
      Platform.environment[os == HostOs.windows ? 'USERPROFILE' : 'HOME'] ?? '';
  final launcher = HostLauncher(
    executable: resolveHostExecutable(
      override: _hostOverride,
      appExecutable: Platform.resolvedExecutable,
      os: os,
    ),
    profileDir: defaultProfileDir(
      os: os,
      env: Platform.environment,
      home: home,
    ),
    capabilities: const {Capability.workbench, Capability.terminal},
  );
  runApp(
    TerminalSpikeApp(
      connector: launcherConnector(launcher),
      surfaceFactory: AlacrittySurface.new,
    ),
  );
}
