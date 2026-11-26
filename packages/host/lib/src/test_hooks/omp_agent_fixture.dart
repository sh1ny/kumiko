import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:host_protocol/host_protocol.dart';

/// Test-host-only native peer. Its script controls frame ordering, not actions
/// or external commands. Literal strings are sent verbatim to exercise framing.
Future<int> runOmpFixture(List<String> args) async {
  final scriptIndex = args.indexOf('--script');
  if (scriptIndex < 0 || scriptIndex + 1 == args.length) return 64;
  final script =
      jsonDecode(File(args[scriptIndex + 1]).readAsStringSync()) as Json;
  final reportPath = script['reportFile']! as String;
  final report = File(
    script['isolateReports'] == true ? '$reportPath.$pid' : reportPath,
  );
  void record(Json value) => report.writeAsStringSync(
    '${jsonEncode(value)}\n',
    mode: FileMode.append,
    flush: true,
  );

  final probe = args.contains('--version');
  record({
    'launch': probe ? 'probe' : 'root',
    'argv': args,
    'cwd': Directory.current.path,
    'parentCanary': ?Platform.environment['OMP_PARENT_CANARY'],
    'profileCanary': ?Platform.environment['OMP_PROFILE_CANARY'],
    'hasToolSecret': Platform.environment.containsKey('KUMIKO_TOOL_SECRET'),
  });
  if (probe) {
    if (script['probeDelayMs'] case final int milliseconds) {
      await Future<void>.delayed(Duration(milliseconds: milliseconds));
    }
    if (script['probeStderr'] case final String warning) {
      stderr.writeln(warning);
      await stderr.flush();
    }
    stdout.writeln(script['versionOutput'] ?? 'omp/18.20.1');
    await stdout.flush();
    return script['probeExit'] as int? ?? 0;
  }

  if (script['startupStderr'] case final String warning) {
    stderr.writeln(warning);
    await stderr.flush();
  }
  final commands = script['commands'] as Json? ?? const {};
  final counts = <String, int>{};
  String? promptId;
  Object? substitute(Object? value, String? commandId) => switch (value) {
    r'$id' => commandId,
    r'$prompt' => promptId,
    final Json map => {
      for (final entry in map.entries)
        entry.key: substitute(entry.value, commandId),
    },
    final List<Object?> list => [
      for (final element in list) substitute(element, commandId),
    ],
    _ => value,
  };

  Future<int?> play(List<Object?> frames, {String? commandId}) async {
    for (final frame in frames) {
      if (frame is String) {
        stdout.writeln(frame);
      } else if (frame case {'delayMs': final int milliseconds}) {
        await Future<void>.delayed(Duration(milliseconds: milliseconds));
        continue;
      } else if (frame case {'exit': final int status}) {
        return status;
      } else {
        stdout.writeln(jsonEncode(substitute(frame, commandId)));
      }
      await stdout.flush();
    }
    return null;
  }

  final startup =
      script['startup'] as List<Object?>? ??
      [
        {
          'type': 'ready',
          'supportedProtocolVersions': [1],
        },
      ];
  if (await play(startup) case final int status) return status;
  final input = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in input) {
    final command = jsonDecode(line) as Json;
    record({'received': command});
    final type = command['type'] as String;
    final id = command['id'] as String?;
    if (type == 'prompt') promptId = id;
    if (commands[type] case final List<Object?> batches) {
      final index = counts.update(type, (n) => n + 1, ifAbsent: () => 0);
      if (index < batches.length) {
        final frames = batches[index] as List<Object?>;
        if (await play(frames, commandId: id) case final int status) {
          return status;
        }
      }
    } else if (type == 'set_event_filter' ||
        type == 'get_state' ||
        type == 'set_subagent_subscription' ||
        type == 'get_subagents' ||
        type == 'set_host_tools') {
      final response = {
        'type': 'response',
        'id': id,
        'command': type,
        'success': true,
        if (type == 'get_state')
          'data': {
            'sessionId': 'fixture-session',
            'isSettled': true,
            'hasPendingAsyncWork': false,
          },
        if (type == 'set_subagent_subscription')
          'data': {'level': command['level']},
        if (type == 'get_subagents') 'data': {'subagents': <Object?>[]},
        if (type == 'set_host_tools')
          'data': {
            'toolNames': [
              for (final tool in (command['tools']! as List).cast<Json>())
                tool['name'],
            ],
          },
      };
      stdout.writeln(jsonEncode(response));
      await stdout.flush();
    }
  }
  record({'stdin': 'eof'});
  if (script['holdEof'] == true) {
    final hold = ReceivePort();
    try {
      // Only containment can release this scripted process, not a timer.
      await hold.first;
    } finally {
      hold.close();
    }
  }
  if (script['eofFrames'] case final List<Object?> frames) {
    if (await play(frames) case final int status) return status;
  }
  return script['eofExit'] as int? ?? 0;
}
