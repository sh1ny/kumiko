import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/windows_close_records.dart';
import 'support/windows_test_window.dart';

void main() {
  test(
    'Windows title-bar Close waits for a pending agent permission',
    () => _exerciseNativeClose(openPicker: true),
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 5)),
  );
  test(
    'Windows title-bar Close also coordinates quit without a folder picker',
    () => _exerciseNativeClose(openPicker: false),
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Future<void> _exerciseNativeClose({required bool openPicker}) async {
  final path = Platform.environment['KUMIKO_WINDOWS_CLOSE_FIXTURE'];
  if (path == null || !File(path).isAbsolute) {
    fail(
      'KUMIKO_WINDOWS_CLOSE_FIXTURE must be the absolute debug fixture executable',
    );
  }
  final root = await Directory.systemTemp.createTemp('kumiko-windows-close-');
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final connected = server.first;
  Process? desktop;
  Socket? socket;
  var hostHandle = 0;
  try {
    final executable = File(path);
    desktop = await Process.start(executable.path, [
      '${server.port}',
      root.path,
      if (openPicker) '--open-picker',
    ], workingDirectory: executable.parent.path);
    unawaited(desktop.stdout.drain<void>());
    final stderr = desktop.stderr.transform(utf8.decoder).join();
    final exit = desktop.exitCode;
    final channel = socket = await Future.any<Socket?>([
      connected,
      exit.then((_) => null),
    ]);
    if (channel == null) {
      fail('Fixture exited before connecting: ${await stderr}');
    }
    final records = <String>[];
    var window = 0;
    String? windowClasses;
    await for (final line
        in channel
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.startsWith('ready ')) {
        final ready = jsonDecode(line.substring(6)) as Map<String, dynamic>;
        window = ready['window'] as int;
        windowClasses = ready['classes'] as String;
        hostHandle = openProcessForExit(readCloseRecords(root).pid);
        channel.writeln('close');
        await channel.flush();
      } else {
        records.add(line);
      }
    }
    final code = await exit;
    if (hostHandle != 0) await waitForProcessExit(hostHandle);
    expect(
      window,
      isNot(0),
      reason:
          'Fixture did not reach pending permission: $records\n${await stderr}',
    );
    expect(windowExists(window), isFalse);
    expect(code, 0, reason: '$records');
    final host = readCloseRecords(root);
    expect(
      records,
      [
        'affected work shown',
        'repeat focused the same warning',
        'cancel preserved the unit',
        'new warning shown',
        'host quit before window destruction',
      ],
      reason:
          'Runner windows: $windowClasses; host exit kind: ${host.exitKind}',
    );
    expect(host.exitKind, 'quit');
    expect(host.agentCount, 0);
  } finally {
    await server.close();
    socket?.destroy();
    if (desktop != null) {
      desktop.kill();
      await desktop.exitCode;
    }
    if (hostHandle != 0) {
      await waitForProcessExit(hostHandle);
      closeProcessHandle(hostHandle);
    }
    await root.delete(recursive: true);
  }
}
