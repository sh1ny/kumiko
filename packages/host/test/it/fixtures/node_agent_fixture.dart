import 'dart:convert';
import 'dart:io';

import 'package:host/src/test_hooks/acp_agent_fixture.dart';
import 'package:host_protocol/host_protocol.dart';

/// A native ACP executable installed as node[.exe] in a synthetic npm layout.
/// No JavaScript, installed Node, adapter, or provider is involved.
Future<void> main(List<String> args) async {
  if (args.length == 1 && args.single == '--path-probe') {
    stdout.writeln(jsonEncode({'executable': Platform.resolvedExecutable}));
    return;
  }
  final script = jsonDecode(File(args.single).readAsStringSync()) as Json;
  final report = File(script['reportFile'] as String);
  final probe = await Process.run(Platform.isWindows ? 'node.exe' : 'node', [
    '--path-probe',
  ]);
  if (probe.exitCode != 0) {
    stderr.write(probe.stderr);
    exitCode = probe.exitCode;
    return;
  }
  report.writeAsStringSync(
    '${jsonEncode({'nativePath': Platform.environment['PATH'] ?? Platform.environment['Path'], 'nodeProbe': jsonDecode(probe.stdout as String)})}\n',
    mode: FileMode.append,
    flush: true,
  );
  exitCode = await runAcpAgentFixture(['--script', args.single]);
}
