import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';

/// Authored test-only native wire peer. No installed executable or provider.
Future<int> runCodexFixture(List<String> args) async {
  final path = args[args.indexOf('--script') + 1];
  final script = jsonDecode(File(path).readAsStringSync()) as Json;
  final report = File(script['reportFile']! as String);
  void record(Json value) => report.writeAsStringSync(
    '${jsonEncode(value)}\n',
    mode: FileMode.append,
    flush: true,
  );
  final probe = args.contains('--probe');
  record({
    'launch': probe ? 'probe' : 'root',
    'cwd': Directory.current.path,
    'argv': args,
    'unit': Platform.environment['KUMIKO_UNIT'] != null,
    'profileCanary': Platform.environment.containsKey('CODEX_PROFILE_CANARY'),
    'parentCanary': Platform.environment.containsKey('CODEX_PARENT_CANARY'),
    'secret': Platform.environment.containsKey('KUMIKO_TOOL_SECRET'),
  });
  if (probe) {
    await Future<void>.delayed(
      Duration(milliseconds: script['probeDelayMs'] as int? ?? 0),
    );
    if (script['probeStderr'] case final String warning) {
      stderr.writeln(warning);
      await stderr.flush();
    }
    stdout.writeln(script['version'] ?? 'codex-cli 0.166.0');
    await stdout.flush();
    return script['probeExit'] as int? ?? 0;
  }
  var turns = 0;
  var initialized = false;
  final replies = <String, Completer<void>>{};
  final interrupts = <String, Completer<void>>{};
  Future<void> send(Json value) async {
    stdout.writeln(jsonEncode(value));
    await stdout.flush();
  }

  Object? expand(Object? value, String turn) => switch (value) {
    r'$thread' => 'root-thread',
    r'$turn' => turn,
    final List<Object?> values => [for (final v in values) expand(v, turn)],
    final Map<String, Object?> values => {
      for (final e in values.entries) e.key: expand(e.value, turn),
    },
    _ => value,
  };
  Future<void> actions(List<Object?> values, String turn) async {
    for (final raw in values) {
      final action = expand(raw, turn) as Json;
      if (action['delayMs'] case final int ms) {
        await Future<void>.delayed(Duration(milliseconds: ms));
      }
      if (action['waitInterrupt'] == true) {
        await (interrupts[turn] ??= Completer<void>()).future;
      }
      if (action['waitReply'] case final String id) {
        await (replies[id] ??= Completer<void>()).future;
      }
      if (action['send'] case final Json message) await send(message);
      if (action['closeStdout'] == true) await stdout.close();
    }
  }

  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final m = jsonDecode(line) as Json;
    record({'received': m});
    final method = m['method'];
    final id = m['id'];
    if (method == null) {
      final c = replies['$id'] ??= Completer<void>();
      if (!c.isCompleted) c.complete();
      continue;
    }
    switch (method) {
      case 'initialize':
        if (script['initializeHang'] == true) continue;
        if (script['initializeError'] case final Json error) {
          await send({'id': id, 'error': error});
        } else {
          await send({
            'id': id,
            'result':
                script['initialize'] ??
                {
                  'userAgent':
                      'kumiko/${(script['version'] as String? ?? 'codex-cli 0.166.0').substring(10)} (Windows 10.0; x86_64) WindowsTerminal (kumiko; 0)',
                  'platformFamily': 'windows',
                  'platformOs': 'windows',
                  'codexHome': '/fixture-native-home',
                },
          });
        }
      case 'initialized':
        initialized = true;
      case 'thread/start' || 'thread/resume':
        if (!initialized) return 72;
        if (script['startError'] case final Json error) {
          await send({'id': id, 'error': error});
        } else {
          await send({
            'id': id,
            'result': {
              'thread': {'id': 'root-thread'},
              'model': 'fixture',
              'modelProvider': 'fixture',
              'cwd': Directory.current.path,
              'approvalPolicy': script['approvalPolicy'] ?? 'untrusted',
              'approvalsReviewer': 'user',
              'sandbox': {'type': 'workspaceWrite'},
            },
          });
        }
      case 'turn/start':
        final turn = 'turn-${++turns}';
        final scripts = script['turns'] as List? ?? const [];
        final row = turns <= scripts.length
            ? scripts[turns - 1] as Json
            : <String, Object?>{};
        if (row['error'] case final Json error) {
          await send({'id': id, 'error': error});
          continue;
        }
        await actions(row['beforeResponse'] as List? ?? const [], turn);
        await send({
          'id': id,
          'result': {
            'turn': {
              'id': turn,
              'status': 'inProgress',
              'items': <Object?>[],
              'error': null,
            },
          },
        });
        unawaited(
          actions(
            row['actions'] as List? ??
                [
                  {
                    'send': {
                      'method': 'item/agentMessage/delta',
                      'params': {
                        'threadId': 'root-thread',
                        'turnId': turn,
                        'itemId': 'message-$turn',
                        'delta': 'native reply',
                      },
                    },
                  },
                  {
                    'send': {
                      'method': 'turn/completed',
                      'params': {
                        'threadId': 'root-thread',
                        'turn': {
                          'id': turn,
                          'status': 'completed',
                          'items': <Object?>[],
                          'error': null,
                        },
                      },
                    },
                  },
                ],
            turn,
          ),
        );
        if (script['noReadAfterTurn'] == true) await Completer<void>().future;
      case 'turn/interrupt':
        if (script['interruptNoAck'] == true) break;
        if (script['interruptError'] case final Json error) {
          await send({'id': id, 'error': error});
          break;
        }
        await send({
          'id': id,
          'result': script.containsKey('interruptResult')
              ? script['interruptResult']
              : {},
        });
        final turn = (m['params'] as Json)['turnId']! as String;
        final c = interrupts[turn] ??= Completer<void>();
        if (!c.isCompleted) c.complete();
      case 'turn/steer':
        if (script['steerNoAck'] == true) break;
        if (script['steerError'] case final Json error) {
          await send({'id': id, 'error': error});
        } else {
          await send({
            'id': id,
            'result': script.containsKey('steerResult')
                ? script['steerResult']
                : {'turnId': (m['params'] as Json)['expectedTurnId']},
          });
        }
      default:
        await send({
          'id': id,
          'error': {'code': -32601, 'message': 'fixture unsupported'},
        });
    }
  }
  return 0;
}
