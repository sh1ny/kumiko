import 'dart:io';

import 'package:host/src/agent/adapter_detector.dart';
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

AdapterDetectionResult blockedProbe(AdapterDetectionConfig config) {
  sleep(const Duration(seconds: 5));
  return const AdapterDetectionResult(reason: 'late');
}

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('kumiko_adapter_'));
  tearDown(() => root.deleteSync(recursive: true));
  String file(String path) {
    final f = File(path)..createSync(recursive: true);
    if (!Platform.isWindows) chmodPath(f.path, 0x1c0);
    return f.absolute.path;
  }

  AdapterDetectionConfig config({
    String? os,
    List<String>? path,
    List<String> known = const [],
  }) => AdapterDetectionConfig(
    os: os ?? Platform.operatingSystem,
    pathDirs: path ?? [root.path],
    wellKnownDirs: known,
  );

  test('Windows npm layout (fixture dir with claude-agent-acp.cmd, node_modules/.../dist/index.js, node.exe) yields node.exe + absolute index.js', () async {
    file('${root.path}/claude-agent-acp.cmd');
    final node = file('${root.path}/node.exe');
    final script = file(
      '${root.path}/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js',
    );
    final result = await AdapterDetector(config(os: 'windows')).detect();
    final p = result.profile!;
    expect(p.name, 'Claude Code');
    expect(p.runtimeKind, 'claude-code');
    expect(p.isBuiltin, isTrue);
    expect(p.executable, node);
    expect(p.args, [script]);
    expect(p.env, isEmpty);
    expect(result.reason, isNull);
  });
  test(
    'POSIX npm layout (bin symlink to dist/index.js, node beside it) yields absolute node + absolute index.js',
    () async {
      final bin = Directory('${root.path}/bin')..createSync();
      final node = file('${bin.path}/node');
      final script = file(
        '${root.path}/lib/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js',
      );
      Link('${bin.path}/claude-agent-acp').createSync(script);
      final result = await AdapterDetector(config(path: [bin.path])).detect();
      expect(result.profile!.executable, node);
      expect(result.profile!.args, [File(script).resolveSymbolicLinksSync()]);
      expect(result.profile!.env, isEmpty);
    },
    skip: Platform.isWindows
        ? 'POSIX npm symlink layout, pending three-OS CI'
        : false,
  );
  test('PATH without the install dir still finds the adapter in a well-known directory (fixture home)', () async {
    file('${root.path}/claude-agent-acp.cmd');
    final node = file('${root.path}/node.exe');
    file(
      '${root.path}/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js',
    );
    final result = await AdapterDetector(
      config(os: 'windows', path: [], known: [root.path]),
    ).detect();
    expect(result.profile!.executable, node);
  });
  test(
    'POSIX minimal PATH still finds the npm symlink and Node in a well-known directory',
    () async {
      final bin = Directory('${root.path}/bin')..createSync();
      final node = file('${bin.path}/node');
      final script = file(
        '${root.path}/lib/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js',
      );
      Link('${bin.path}/claude-agent-acp').createSync(script);
      final result = await AdapterDetector(config(path: [], known: [bin.path]))
          .detect();
      expect(result.profile!.executable, node);
      expect(result.profile!.args, [File(script).resolveSymbolicLinksSync()]);
      expect(result.profile!.env, isEmpty);
      expect(result.reason, isNull);
    },
    skip: Platform.isWindows
        ? 'Native POSIX well-known npm layout, pending 11.3 CI'
        : false,
  );
  test(
    'missing package script offers no built-in with the missing path reason',
    () async {
      file('${root.path}/claude-agent-acp.cmd');
      file('${root.path}/node.exe');
      final result = await AdapterDetector(config(os: 'windows')).detect();
      expect(result.profile, isNull);
      expect(result.reason, contains('dist/index.js'));
    },
  );
  test('node beside shim precedes PATH and PATH node is used when absent beside shim', () async {
    file('${root.path}/shim/claude-agent-acp.cmd');
    file(
      '${root.path}/shim/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js',
    );
    final onPath = file('${root.path}/path/node.exe');
    final local = file('${root.path}/shim/node.exe');
    final c = config(
      os: 'windows',
      path: ['${root.path}/path', '${root.path}/shim'],
    );
    expect((await AdapterDetector(c).detect()).profile!.executable, local);
    File(local).deleteSync();
    expect((await AdapterDetector(c).detect()).profile!.executable, onPath);
    File(onPath).deleteSync();
    expect((await AdapterDetector(c).detect()).reason, contains('node'));
  });
  test('not installed reason names npm package and Node 22', () async {
    final result = await AdapterDetector(config(path: [])).detect();
    expect(result.profile, isNull);
    expect(
      result.reason,
      allOf(contains('@agentclientprotocol/claude-agent-acp'), contains('22')),
    );
  });
  test(
    '2 s overall cap kills a blocked off-isolate probe without blocking caller',
    () async {
      final clock = Stopwatch()..start();
      final result = await AdapterDetector(
        config(),
        probe: blockedProbe,
      ).detect();
      expect(result.profile, isNull);
      expect(result.reason, contains('2 s'));
      expect(clock.elapsed, lessThan(const Duration(milliseconds: 2600)));
    },
  );
}
