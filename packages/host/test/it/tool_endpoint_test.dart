import 'dart:io';

import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/harness.dart';
import 'support/tool_support.dart';

void main() {
  setUpAll(buildTestHost);

  late Directory profile;
  setUp(() => profile = tempDir('toolep_'));
  tearDown(() => deleteTree(profile));

  final posixOnly = Platform.isWindows
      ? 'POSIX socket; the Windows pipe is covered by pipe_server_windows_test'
      : null;

  Future<Desktop> started([Map<String, String>? environment]) async {
    final desktop = await Desktop.start(profile, environment: environment);
    addTearDown(desktop.dispose);
    await desktop.waitState();
    return desktop;
  }

  test(
    'endpoint accepts a same-user connection and opens no TCP/UDP port',
    () async {
      final desktop = await started();
      final endpoint = await endpointOf(desktop);
      if (!Platform.isWindows) {
        expect(endpoint, socketPathIn(profile));
      } else {
        expect(endpoint, startsWith(r'\\.\pipe\kumiko-tools-'));
      }

      final client = await ToolClient.connect(endpoint);
      addTearDown(client.close);
      // The host serves it: a wrong secret is answered, not ignored.
      client.authenticate('A' * 43);
      expect(await client.readJson(), {
        'ok': false,
        'error': 'unauthenticated',
      });

      expect(await networkListeners(desktop.session.pid), isEmpty);
    },
  );

  test('socket dir owner-only and socket mode 0600', () async {
    final desktop = await started();
    await endpointOf(desktop);
    expect(FileStat.statSync(profile.path).mode & 0x1ff, 0x1c0);
    final sock = socketPathIn(profile);
    expect(
      FileSystemEntity.typeSync(sock),
      FileSystemEntityType.unixDomainSock,
    );
    expect(FileStat.statSync(sock).mode & 0x1ff, 0x180);
  }, skip: posixOnly);

  test('over-long socket path leaves the host running, logs the reason, '
      'sessions show unavailable', () async {
    // A real over-long path on POSIX; on Windows the fault is injected.
    if (!Platform.isWindows) {
      final deep = Directory(joinPath(profile.path, 'd' * 120))
        ..createSync(recursive: true);
      profile = deep;
    }
    final desktop = await started({
      if (Platform.isWindows)
        'KUMIKO_TEST_TOOL_ENDPOINT_FAULT': 'socket path is too long',
    });
    final state = await toolState(desktop);
    expect(state['available'], isFalse);
    expect(state['reason'], startsWith('endpoint-unavailable: '));
    final logged = readHostLog(profile)
        .where((e) => e['op'] == 'tool-endpoint-failed');
    expect(logged, hasLength(1));
    expect(logged.single['code'], state['reason']);
    // The host still serves the desktop.
    expect((await desktop.listWorkspaces()).workspaces, isEmpty);
    expect(File(socketPathIn(profile)).existsSync(), isFalse);
  });

  test('endpoint is gone after the desktop disconnects', () async {
    final desktop = await started();
    final endpoint = await endpointOf(desktop);
    final probe = await ToolClient.connect(endpoint);
    await probe.close();

    final quit = await desktop.session.quit();
    expect(quit.exitCode, 0);

    if (Platform.isWindows) {
      await expectLater(
        openWindowsPipe(endpoint),
        throwsA(isA<WindowsPipeException>()),
      );
    } else {
      expect(
        FileSystemEntity.typeSync(endpoint),
        FileSystemEntityType.notFound,
      );
    }
  });

  test('stale tools.sock is replaced and accepts connections', () async {
    // A host killed while serving leaves its socket file behind.
    profile.createSync(recursive: true);
    final stale = socketPathIn(profile);
    final server = await ServerSocket.bind(
      InternetAddress(stale, type: InternetAddressType.unix),
      0,
    );
    await server.close();
    if (FileSystemEntity.typeSync(stale) == FileSystemEntityType.notFound) {
      File(stale).writeAsStringSync('stale');
    }

    final desktop = await started();
    final endpoint = await endpointOf(desktop);
    expect(endpoint, stale);
    final client = await ToolClient.connect(endpoint);
    addTearDown(client.close);
    client.authenticate('A' * 43);
    expect(await client.readJson(), {'ok': false, 'error': 'unauthenticated'});
  }, skip: posixOnly);
}
