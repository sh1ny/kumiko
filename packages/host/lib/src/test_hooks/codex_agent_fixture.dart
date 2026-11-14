import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:path/path.dart' as p;

import 'fixture_kumiko_tool.dart';

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
  if (args.contains('--environment-audit')) {
    stdout.writeln(jsonEncode(Platform.environment));
    await stdout.flush();
    return 0;
  }
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
  var resumed = false;
  var historyPage = 0;
  final toolConfig = script['kumikoTool'];
  final tool = toolConfig is Json ? KumikoToolDriver(toolConfig, record) : null;
  final peerTools = <KumikoToolDriver>[
    if (script['kumikoPeers'] case final List<Object?> peers)
      for (var i = 0; i < peers.length; i++)
        KumikoToolDriver(
          peers[i] as Json,
          (event) => record({'peerIndex': i, ...event}),
        ),
  ];
  Object? nativeServers;
  Json? currentNativeEntry;
  // Independently authored wire-fixture model: ordered dotted-key writes replace
  // the value at their destination, including a whole table at a root key.
  Json configuration(Iterable<MapEntry<String, Object?>> overrides) {
    final result = <String, Object?>{};
    for (final override in overrides) {
      final segments = override.key.split('.');
      var target = result;
      for (final segment in segments.take(segments.length - 1)) {
        final existing = target[segment];
        if (existing is! Json) target[segment] = <String, Object?>{};
        target = target[segment]! as Json;
      }
      target[segments.last] = jsonDecode(jsonEncode(override.value));
    }
    return result;
  }

  final cliOverrides = [
    for (final row in script['cliOverrides'] as List? ?? const [])
      MapEntry((row as Json)['key']! as String, row['value']),
  ];
  Future<void> runTools(String when) async {
    if (tool?.when == when) await tool!.run(nativeServers);
    for (final peer in peerTools) {
      if (peer.when == when) await peer.run(nativeServers);
    }
  }

  Future<void> auditTools(Json? nativeEntry) async {
    final audit = script['toolsAudit'];
    if (audit is! Json || nativeEntry == null) return;
    final env = nativeEntry['env'];
    final secret = env is Json ? env['KUMIKO_TOOL_SECRET'] : null;
    if (secret is! String || secret.isEmpty) return;
    Future<bool> inspectEnvironment(Json extra) async {
      final child = await Process.run(
        Platform.resolvedExecutable,
        [
          '--test-fixture',
          'codex-agent',
          '--script',
          path,
          '--environment-audit',
        ],
        environment: {
          for (final name in const ['SystemRoot', 'SYSTEMROOT', 'TEMP', 'TMP'])
            if (Platform.environment[name] case final String value) name: value,
          for (final e in extra.entries) e.key: e.value! as String,
        },
        includeParentEnvironment: false,
      );
      return child.exitCode == 0 &&
          !(child.stdout as String).contains(secret) &&
          !(child.stderr as String).contains(secret);
    }

    final commandIsolated = await inspectEnvironment(const {});
    final otherMcpIsolated = await inspectEnvironment(
      audit['otherEnv'] as Json? ?? const {'OTHER_MCP_ENTRY': 'unrelated'},
    );
    final auditHome =
        script['toolsAuditHome'] as String? ??
        p.join(report.parent.path, 'fixture-native-home');
    for (final relative in const [
      ['sessions', 'session.jsonl'],
      ['logs', 'native.log'],
      ['state', 'native.state'],
    ]) {
      final artifact = File(p.joinAll([auditHome, ...relative]));
      await artifact.parent.create(recursive: true);
      await artifact.writeAsString(
        'authored native fixture state; no private configuration\n',
      );
    }
    if (script['persistSecretForScanTest'] == true) {
      final canary = File(p.join(auditHome, 'state', 'canary.txt'));
      await canary.writeAsString(secret);
    }
    // Synthetic persistence at fixture-chosen relative paths, so selection
    // tests can place the run secret in caches, unclassified directories and
    // protected leaves of an owned native home.
    for (final relative in script['persistSecretPaths'] as List? ?? const []) {
      final artifact = File(
        p.joinAll([auditHome, ...(relative as String).split('/')]),
      );
      await artifact.parent.create(recursive: true);
      await artifact.writeAsString(secret);
    }
    var secretFound = false;
    var scannedFiles = 0;
    var errorCount = 0;
    final scanErrors = <Json>[];
    for (final raw in audit['scanRoots'] as List? ?? [report.parent.path]) {
      final root = Directory(raw! as String);
      if (!root.existsSync()) {
        errorCount++;
        continue;
      }
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        try {
          // Windows can exclusively lock an empty regular file. There are no
          // bytes to inspect when two metadata observations agree it is empty;
          // account it without opening a read handle. Nonempty read failures
          // remain incomplete scans.
          final before = await entity.stat();
          // A Unix-domain socket (the host's tools.sock on POSIX) is listed
          // as a file but holds no bytes that could contain the secret.
          if (before.type == FileSystemEntityType.unixDomainSock) {
            scannedFiles++;
            continue;
          }
          if (before.type == FileSystemEntityType.file && before.size == 0) {
            final after = await entity.stat();
            if (after.type == FileSystemEntityType.file &&
                after.size == 0 &&
                after.modified == before.modified &&
                after.changed == before.changed) {
              scannedFiles++;
              continue;
            }
          }
          final bytes = await entity.readAsBytes();
          scannedFiles++;
          secretFound |= utf8
              .decode(bytes, allowMalformed: true)
              .contains(secret);
        } on FileSystemException catch (error) {
          errorCount++;
          if (scanErrors.length < 8) {
            int? length;
            try {
              length = entity.lengthSync();
            } on FileSystemException {
              /* Still incomplete. */
            }
            scanErrors.add({
              'path': entity.path,
              'osErrorCode': error.osError?.errorCode,
              'length': length,
            });
          }
        }
      }
    }
    record({
      'toolsAudit': true,
      'bridgeEntryHasSecret': true,
      'parentEnvironmentIsolated': !Platform.environment.values.contains(
        secret,
      ),
      'commandEnvironmentIsolated': commandIsolated,
      'otherMcpEnvironmentIsolated': otherMcpIsolated,
      'secretFound': secretFound,
      'scannedFiles': scannedFiles,
      'scanComplete': errorCount == 0,
      'errorCount': errorCount,
      'scanErrors': scanErrors,
    });
  }

  final replies = <String, Completer<void>>{};
  final interrupts = <String, Completer<void>>{};
  // A batch may unblock scripted turn output while the input loop acknowledges
  // another addressed interrupt. Give each fixture line exclusive sink access.
  var outputReady = Future<void>.value();
  Future<void> send(Json value) => outputReady = outputReady.then((_) async {
    stdout.writeln(jsonEncode(value));
    await stdout.flush();
  });

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
      if (action['waitInterrupt'] case final String addressedTurn) {
        await (interrupts[addressedTurn] ??= Completer<void>()).future;
      }
      if (action['waitReply'] case final String id) {
        await (replies[id] ??= Completer<void>()).future;
      }
      if (action['waitFile'] case final String path) {
        while (!File(path).existsSync()) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }
      if (action['spawnTree'] == true) {
        final child = await Process.start(Platform.resolvedExecutable, [
          '--test-fixture',
          'tree',
        ]);
        child.stdout.drain<void>().ignore();
        child.stderr.drain<void>().ignore();
        child.exitCode.ignore();
      }
      if (action['send'] case final Json message) await send(message);
      if (action['stderr'] case final String message) {
        stderr.write(message);
        await stderr.flush();
      }
      if (action['closeStdout'] == true) await stdout.close();
    }
  }

  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final m = jsonDecode(line) as Json;
    // Native stdin configuration is private. Reports retain structure and
    // presence, never credentials; behavioral bridge calls prove delivery.
    Object? safe(Object? value, [String? key]) {
      if (key == 'KUMIKO_TOOL_SECRET') return '<redacted>';
      if (value is Json) {
        return {for (final e in value.entries) e.key: safe(e.value, e.key)};
      }
      if (value is List) return [for (final v in value) safe(v)];
      return value;
    }

    record({'received': safe(m)});
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
        resumed = method == 'thread/resume';
        final params = m['params'] as Json;
        final config = params['config'];
        final effective = configuration([
          ...cliOverrides,
          if (config is Json) ...config.entries,
        ]);
        final servers = effective['mcp_servers'];
        if (script.containsKey('cliOverrides')) {
          record({
            'mcpConfiguration': {
              'method': method,
              'entries': servers is Json ? servers.keys.toList() : <String>[],
              'privateEnvironmentOnlyInKumiko':
                  servers is Json &&
                  servers.entries.every(
                    (entry) =>
                        entry.key == 'kumiko' ||
                        entry.value is Json &&
                            !((entry.value as Json)['env'] as Json? ?? const {})
                                .keys
                                .any((key) => key.startsWith('KUMIKO_')),
                  ),
              'probe': servers is Json ? servers['unrelated_probe'] : null,
              'kumikoHasPrivateEnvironment':
                  servers is Json &&
                  servers['kumiko'] is Json &&
                  ((servers['kumiko'] as Json)['env'] as Json? ?? const {}).keys
                      .toSet()
                      .containsAll(const [
                        'KUMIKO_TOOL_ENDPOINT',
                        'KUMIKO_TOOL_SECRET',
                        'KUMIKO_UNIT',
                      ]),
            },
          });
        }
        final entry = servers is Json ? servers['kumiko'] : null;
        currentNativeEntry = entry is Json ? entry : null;
        nativeServers = [
          if (entry is Json)
            {
              'name': 'kumiko',
              'command': entry['command'],
              'args': entry['args'],
              'env': [
                if (entry['env'] case final Json env)
                  for (final e in env.entries)
                    {'name': e.key, 'value': e.value},
              ],
            },
        ];
        unawaited(runTools('session/new'));
        await actions(script['newActions'] as List? ?? const [], 'old-turn');
        if (resumed) {
          await actions(
            script['resumeActions'] as List? ?? const [],
            'old-turn',
          );
        }
        await auditTools(entry is Json ? entry : null);
        if (script['startError'] case final Json error) {
          await send({'id': id, 'error': error});
        } else {
          await send({
            'id': id,
            'result': {
              'thread': method == 'thread/resume'
                  ? script['resumeThread'] ?? {'id': 'root-thread'}
                  : {'id': 'root-thread'},
              'model': 'fixture',
              'modelProvider': 'fixture',
              'cwd': Directory.current.path,
              'approvalPolicy': script['approvalPolicy'] ?? 'untrusted',
              'approvalsReviewer': 'user',
              'sandbox': {'type': 'workspaceWrite'},
            },
          });
        }
      case 'thread/read':
        await send({
          'id': id,
          if (script['readError'] case final Json error)
            'error': error
          else
            'result': {
              'thread':
                  (resumed ? script['afterReadThread'] : null) ??
                  script['readThread'] ??
                  {
                    'id': 'root-thread',
                    'status': {'type': resumed ? 'idle' : 'notLoaded'},
                    'historyMode': 'legacy',
                  },
            },
        });
      case 'thread/items/list':
        final pages = script['historyPages'] as List? ?? const [];
        final page = historyPage < pages.length
            ? pages[historyPage++]
            : {'data': <Object?>[], 'nextCursor': null};
        await actions(
          script['historyBeforePage'] as List? ?? const [],
          'old-turn',
        );
        await send({'id': id, 'result': page});
      case 'config/read':
        await send({
          'id': id,
          if (script['configReadError'] case final Json error)
            'error': error
          else
            'result':
                script['configReadResult'] ??
                script['effectiveConfig'] ??
                {
                  'config': configuration(cliOverrides),
                  'origins': <String, Object?>{},
                  'layers': <Object?>[],
                },
        });
      case 'account/read':
        // Absent script keys keep the method unsupported (fail-open preflight).
        if (script['accountReadHang'] == true) continue;
        await send({
          'id': id,
          if (script['accountReadError'] case final Json error)
            'error': error
          else if (script.containsKey('accountRead'))
            'result': script['accountRead']
          else
            'error': {'code': -32601, 'message': 'fixture unsupported'},
        });
      case 'turn/start':
        await runTools('prompt');
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
          ).then((_) => auditTools(currentNativeEntry)),
        );
        if (script['noReadAfterTurn'] == true) await Completer<void>().future;
      case 'turn/interrupt':
        final addressedThread = (m['params'] as Json)['threadId'];
        if (script['unsupportedInterruptThreads'] case final List<Object?> ids
            when ids.contains(addressedThread)) {
          await send({
            'id': id,
            'error': {
              'code': -32601,
              'message': 'child interruption unsupported',
            },
          });
          break;
        }
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
