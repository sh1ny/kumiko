import 'dart:io';

import 'package:desktop/main.dart';
import 'package:desktop/src/host_link.dart';
import 'package:desktop/src/host_location.dart';
import 'package:desktop/src/launcher_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:integration_test/integration_test.dart';

/// Number of running `kumiko_host` processes.
Future<int> _hostProcessCount(HostOs os) async {
  if (os == HostOs.windows) {
    final out = await Process.run('tasklist', [
      '/FI',
      'IMAGENAME eq kumiko_host.exe',
      '/NH',
    ]);
    return RegExp('kumiko_host.exe').allMatches('${out.stdout}').length;
  }
  // Matched on the executable path at the start of the command line: the
  // Dart runtime renames its main thread (`dart:kumiko_hos` on Linux), so the
  // process name does not match.
  final out = await Process.run('pgrep', ['-f', '^[^ ]*kumiko_host( |\$)']);
  return '${out.stdout}'.trim().split('\n').where((l) => l.isNotEmpty).length;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('launch', () {
    late Directory profile;
    HostLink? link;

    setUp(() => profile = Directory.systemTemp.createTempSync('kumiko_it_'));

    tearDown(() async {
      // The app's quit path ends the host; the test does the same, then
      // removes its temporary profile.
      await link?.quit();
      link = null;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      try {
        profile.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort: the host may still be releasing its log file.
      }
    });

    testWidgets('normal launch connects one child host', (tester) async {
      final os = HostOs.current;
      // The real bundled layout: <dir of the app executable>/host/bin/...
      final hostPath = resolveHostExecutable(
        override: const String.fromEnvironment('KUMIKO_HOST'),
        appExecutable: Platform.resolvedExecutable,
        os: os,
      );
      final before = await _hostProcessCount(os);
      final launcher = HostLauncher(
        executable: hostPath,
        profileDir: profile.path,
        capabilities: const {Capability.workbench},
      );
      final connect = launcherConnector(launcher);

      await tester.pumpWidget(
        KumikoApp(
          connector: () async => link = await connect(),
          hostPath: hostPath,
          onExit: () {},
        ),
      );
      for (
        var i = 0;
        i < 300 && find.text('Host connected').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }

      expect(find.text('Host connected'), findsOneWidget);
      expect(
        find.textContaining(RegExp(r'host \d+\.\d+\.\d+')),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(await tester.runAsync(() => _hostProcessCount(os)), before + 1);
    });
  });
}
