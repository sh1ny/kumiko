import 'dart:async';
import 'dart:io';

import 'package:desktop/src/host_link.dart';
import 'package:desktop/src/host_location.dart';
import 'package:desktop/src/launcher_link.dart';
import 'package:desktop/src/terminal/terminal_surface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_alacritty/flutter_alacritty.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:host_protocol/host_protocol.dart';

import 'probe.dart';
import 'vttest.dart' show gridRows;

/// The real bundled host behind the engine bar tests: one host per test,
/// with a fresh profile directory, found through `KUMIKO_HOST`.
final class BarHost {
  final HostOs os = HostOs.current;
  late Directory profileDir;
  late HostLink link;

  /// Registers the per-file and per-test setup and teardown.
  void install() {
    setUpAll(() async {
      await RustLib.init();
      debugPrint('BAR engine: ${BarProbe.create().engine}');
    });

    setUp(() async {
      profileDir = Directory.systemTemp.createTempSync('kumiko_bar_');
      link = await launcherConnector(
        HostLauncher(
          executable: resolveHostExecutable(
            override: const String.fromEnvironment('KUMIKO_HOST'),
            appExecutable: Platform.resolvedExecutable,
            os: os,
          ),
          profileDir: profileDir.path,
          capabilities: const {Capability.workbench, Capability.terminal},
        ),
      )();
    });

    tearDown(() async {
      await link.quit();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      try {
        profileDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort: the host may still be releasing its log file.
      }
    });
  }

  /// Saves [executable] with [args] as a profile and opens it at
  /// [cols]x[rows], relaying output into [surface] and its input back.
  Future<Opened> open(
    TerminalSurface surface,
    String executable,
    List<String> args, {
    int cols = 80,
    int rows = 24,
  }) async {
    final profile = await link.saveProfile(
      ShellProfile(
        id: 'bar-${DateTime.now().microsecondsSinceEpoch}',
        name: 'bar',
        executable: executable,
        args: args,
      ),
    );
    final channels = await link.openTerminal(
      TerminalOpenParams(profileId: profile.id, cols: cols, rows: rows),
    );
    final opened = Opened(channels);
    opened.subscriptions
      ..add(
        channels.output.listen((bytes) {
          opened.received += bytes.length;
          opened.lastOutput = DateTime.now();
          surface.feed(bytes);
        }),
      )
      ..add(surface.input.listen(channels.write))
      ..add(
        link.terminalExits
            .where((e) => e.terminalId == channels.terminalId)
            .listen(opened.exited.complete),
      );
    return opened;
  }
}

/// One open terminal of a bar test.
final class Opened {
  Opened(this.channels);

  final TerminalChannels channels;
  int received = 0;
  DateTime lastOutput = DateTime.now();
  final Completer<TerminalExited> exited = Completer();
  final List<StreamSubscription<Object?>> subscriptions = [];

  Future<void> close(HostLink link) async {
    if (!exited.isCompleted) {
      await link.closeTerminal(channels.terminalId);
      await exited.future.timeout(const Duration(seconds: 30));
    }
    for (final s in subscriptions) {
      await s.cancel();
    }
  }
}

Future<void> until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 60),
  String Function()? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(
        'condition not met${reason == null ? '' : ':\n${reason()}'}',
        timeout,
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// The grid's non-blank rows, for failure messages.
String screenText(BarProbe grid) => [
  for (final (y, row) in gridRows(grid).indexed)
    if (row.trim().isNotEmpty) '${y + 1}: ${row.trimRight()}',
].join('\n');
