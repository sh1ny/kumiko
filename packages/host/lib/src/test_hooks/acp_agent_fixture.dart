import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';

/// Actual stdio ACP fixture. The JSON environment script is test data, never
/// provider qualification. Only explicitly named environment values are
/// reported; neither inherited credentials nor full environment are dumped.
Future<int> runAcpAgentFixture(List<String> args) async {
  final scriptIndex = args.indexOf('--script');
  final script = jsonDecode(
    scriptIndex >= 0
        ? File(args[scriptIndex + 1]).readAsStringSync()
        : Platform.environment['KUMIKO_TEST_ACP_SCRIPT'] ?? '{}',
  ) as Json;
  final sink = stdout.nonBlocking;
  return runAcpAgentScript(
    script: script,
    args: ['--test-fixture', 'acp-agent', ...args],
    input: stdin,
    write: (bytes) async {
      sink.add(bytes);
      await sink.flush();
    },
    closeOutput: sink.close,
    writeError: stderr.writeln,
    environment: Platform.environment,
    cwd: Directory.current.path,
    report: (value) {
      final path = script['reportFile'];
      if (path is String) {
        File(path).writeAsStringSync(
          '${jsonEncode({'executable': Platform.resolvedExecutable, ...value})}\n',
          mode: FileMode.append,
          flush: true,
        );
      }
    },
    spawnTree: () async {
      final child = await Process.start(Platform.resolvedExecutable, [
        '--test-fixture',
        'tree',
      ]);
      child.stdout.drain<void>().ignore();
      child.stderr.drain<void>().ignore();
      child.exitCode.ignore();
    },
    spawnPipeHolder: () async {
      final child = await Process.start(Platform.resolvedExecutable, [
        '--test-fixture',
        'sleeper',
      ], mode: ProcessStartMode.inheritStdio);
      child.exitCode.ignore();
    },
  );
}

/// Script format (all optional): agentInfo, agentCapabilities, protocolVersion,
/// nativeSessionId; errors maps ACP method -> {code,message,data?};
/// afterNew actions run after the session/new result has been written.
/// prompt/load/resume are ordered action arrays; cancel is honour|ignore|race;
/// holdPrompt waits for cancel; reportLaunch + reportEnv:[names] report only
/// requested metadata; reportFile receives test reports, never host logs.
/// beforeInitializeExit:{status,stderr}, exitStatus ends after a prompt.
/// Actions: update:{sessionUpdate,...}, permission:{toolCall,options} with
/// optional rpcId (the exact native JSON-RPC request identifier),
/// stderr:string, report:true, oversizedBytes:int, exit:int, spawnTree:true,
/// spawnPipeHolder:true (a sleeper inheriting the actual ACP output handles),
/// stallStdin:true, flood:{count,update,indexPrefix?}, waitCancel:true,
/// stopReason:string, gatedUpdate:{update,prefixBytes,releaseFile},
/// waitFile:path, closeStdout:true (close output while remaining alive).
/// An indexed flood prepends `<indexPrefix><index>:` to each text update.
/// A gated update flushes its prefix, reports prefixWritten, then waits for the
/// owned release file before writing the rest of the same actual ACP line.
/// Permission actions wait for their actual JSON-RPC outcomes before advancing;
/// waitPermission:false permits a batch of outstanding requests (cap tests).
/// Permission outcomes are reported when their responses are read, in wire
/// order with cancellation, not when an action's asynchronous wait resumes.
/// blockedWriteAfterMs arms an external report during an unaccepted write;
/// its matching writeCompleted report distinguishes a completed write.
/// Injected bytes are for cheap fixture-contract tests; production smoke uses
/// the same runner with real stdio inside a real containment unit.
Future<int> runAcpAgentScript({
  required Json script,
  required List<String> args,
  required Stream<List<int>> input,
  required Future<void> Function(List<int>) write,
  required void Function(String) writeError,
  required void Function(Json) report,
  Map<String, String> environment = const {},
  String cwd = '',
  Future<void> Function()? spawnTree,
  Future<void> Function()? spawnPipeHolder,
  Future<void> Function()? closeOutput,
}) async {
  final reader = StreamIterator<String>(
    input.transform(utf8.decoder).transform(const LineSplitter()),
  );
  final pending = <Object, Completer<Json>>{};
  final tasks = <Future<void>>{};
  final closed = Completer<void>();
  var ended = false;
  var stalled = false;
  var status = 0;
  var nextId = 1;
  Object? promptId;
  var native = script['nativeSessionId'] as String? ?? 'fixture-native';
  Completer<void>? cancelled;
  var cancelledTurn = false;
  void stop(int code) {
    if (ended) return;
    status = code;
    ended = true;
    if (!closed.isCompleted) closed.complete();
    reader.cancel().ignore();
  }

  Future<void> bytes(List<int> data) async {
    if (ended) return;
    Timer? timer;
    final millis = script['blockedWriteAfterMs'];
    if (millis is int) {
      timer = Timer(
        Duration(milliseconds: millis),
        () => report({'blockedWrite': true, 'bytes': data.length}),
      );
    }
    try {
      await write(data);
    } finally {
      timer?.cancel();
    }
    if (!ended && millis is int) {
      report({'writeCompleted': true, 'bytes': data.length});
    }
  }

  // Request handlers run concurrently so they can still receive cancellation
  // and permission replies. Give each complete line exclusive ownership until
  // every write/flush finishes, including intentionally fragmented lines.
  // Keep failures on the chain: later lines must not bypass a failed write.
  var writeTail = Future<void>.value();
  Future<void> writeLine(Future<void> Function() action) {
    return writeTail = writeTail.then((_) => action());
  }

  Future<void> send(Json value) {
    final data = utf8.encode('${jsonEncode(value)}\n');
    return writeLine(() => bytes(data));
  }

  Future<void> result(Object id, Json value) =>
      send({'jsonrpc': '2.0', 'id': id, 'result': value});
  Json updateMessage(Json value) => {
    'jsonrpc': '2.0',
    'method': 'session/update',
    'params': {'sessionId': native, 'update': value},
  };
  Future<void> update(Json value) => send(updateMessage(value));

  Future<void> waitForRelease(File file) async {
    if (file.existsSync()) {
      return;
    }
    final released = Completer<void>();
    // Poll a real file predicate, not elapsed time: EOF also releases the
    // action so a gated child cannot keep its fixture runner alive.
    final poll = Timer.periodic(const Duration(milliseconds: 10), (_) {
      if (!released.isCompleted && file.existsSync()) {
        released.complete();
      }
    });
    try {
      await Future.any([released.future, closed.future]);
    } finally {
      poll.cancel();
    }
  }

  Future<void> gatedUpdate(Json gate) {
    final data = utf8.encode(
      '${jsonEncode(updateMessage(gate['update'] as Json))}\n',
    );
    final prefix = gate['prefixBytes'] as int;
    return writeLine(() async {
      await bytes(Uint8List.sublistView(data, 0, prefix));
      if (ended) {
        return;
      }
      report({'prefixWritten': true, 'bytes': prefix});
      await waitForRelease(File(gate['releaseFile'] as String));
      if (!ended) {
        await bytes(Uint8List.sublistView(data, prefix));
      }
    });
  }

  Json launchReport() => {
    'argv': args,
    'cwd': cwd,
    'env': {
      for (final name in script['reportEnv'] as List? ?? const [])
        if (name is String && environment.containsKey(name))
          name: environment[name],
    },
  };
  Future<String?> actions(Object? source) async {
    if (source is! List) return null;
    for (final value in source) {
      if (ended) return null;
      final action = value as Json;
      if (action['update'] case final Json value) await update(value);
      if (action['gatedUpdate'] case final Json gate) {
        await gatedUpdate(gate);
      }
      if (action['stderr'] case final String value) writeError(value);
      if (action['writeFile'] case final Json value) {
        File(value['path'] as String)
            .writeAsStringSync(value['text'] as String);
      }
      if (action['report'] == true) report(launchReport());
      if (action['waitFile'] case final String path) {
        await waitForRelease(File(path));
      }
      if (action['closeStdout'] == true) {
        if (closeOutput == null) {
          throw StateError('closeStdout requires an output-close callback');
        }
        await closeOutput();
        report({'stdoutClosed': true});
        // EOF must not be confused with leader exit. Keep reading native
        // stdin until containment or the test closes the fixture's input.
        await closed.future;
        return null;
      }
      if (action['spawnTree'] == true) {
        if (spawnTree == null) {
          throw StateError('spawnTree requires a process fixture');
        }
        await spawnTree();
        report({'spawnedTree': true});
      }
      if (action['spawnPipeHolder'] == true) {
        if (spawnPipeHolder == null) {
          throw StateError('spawnPipeHolder requires a process fixture');
        }
        await spawnPipeHolder();
        report({'spawnedPipeHolder': true});
      }
      if (action['permission'] case final Json permission) {
        final id = action['rpcId'] ?? 'fixture-permission-${nextId++}';
        final response = Completer<Json>();
        pending[id] = response;
        await send({
          'jsonrpc': '2.0',
          'id': id,
          'method': 'session/request_permission',
          'params': {'sessionId': native, ...permission},
        });
        if (action['waitPermission'] != false) {
          await response.future;
        }
      }
      if (action['oversizedBytes'] case final int count) {
        await writeLine(() async {
          // Deliberately invalid oversized line without allocating it all.
          var left = count;
          final chunk = Uint8List(65536)..fillRange(0, 65536, 120);
          while (left > 0 && !ended) {
            final n = left < chunk.length ? left : chunk.length;
            await bytes(Uint8List.sublistView(chunk, 0, n));
            left -= n;
          }
          await bytes([10]);
        });
      }
      if (action['flood'] case final Json flood) {
        final count = flood['count'] as int;
        final value = flood['update'] as Json;
        final prefix = flood['indexPrefix'] as String?;
        for (var i = 0; i < count && !ended; i++) {
          if (prefix == null) {
            await update(value);
          } else {
            final content = value['content'] as Json;
            await update({
              ...value,
              'content': {...content, 'text': '$prefix$i:${content['text']}'},
            });
          }
          report({'writtenUpdates': i + 1});
        }
      }
      if (action['waitCancel'] == true) await cancelled!.future;
      if (action['stallStdin'] == true) {
        stalled = true;
        report({'stdinStalled': true});
        await closed.future;
      }
      if (action['exit'] case final int code) {
        stop(code);
        return null;
      }
      if (action['stopReason'] case final String reason) return reason;
    }
    return null;
  }

  Future<void> handle(Json message) async {
    final id = message['id'];
    final method = message['method'];
    final params = message['params'] as Json? ?? {};
    if (method == null && id != null) {
      final response = pending.remove(id);
      if (response != null) {
        final answer = message['result'] as Json? ?? {};
        // The next line may already be buffered. Observe receipt before
        // completing the future: its action can still be awaiting send/flush.
        report({'permissionOutcome': answer['outcome']});
        response.complete(answer);
      }
      return;
    }
    if (method == 'session/cancel') {
      report({'cancelReceived': true});
      final mode = script['cancel'] as String? ?? 'honour';
      if (mode != 'ignore') {
        cancelledTurn = true;
        if (cancelled != null && !cancelled!.isCompleted) cancelled!.complete();
      }
      return;
    }
    if (id == null) return;
    final errors = script['errors'];
    final error = errors is Json ? errors[method] : null;
    if (error is Json) {
      await send({'jsonrpc': '2.0', 'id': id, 'error': error});
      return;
    }
    switch (method) {
      case 'initialize':
        if (script['reportLaunch'] == true) report(launchReport());
        await actions(script['initialize']);
        await result(id, {
          'protocolVersion': script['protocolVersion'] ?? 1,
          'agentInfo':
              script['agentInfo'] ??
              {'name': 'scripted-acp', 'version': 'test-only'},
          'agentCapabilities': script['agentCapabilities'] ?? {},
        });
      case 'session/new':
        report({'newCwd': params['cwd'], 'mcpServers': params['mcpServers']});
        await actions(script['new']);
        await result(id, {'sessionId': native});
        await actions(script['afterNew']);
      case 'session/load' || 'session/resume':
        native = params['sessionId'] as String;
        report({'method': method, ...params});
        await actions(script[method == 'session/load' ? 'load' : 'resume']);
        await result(id, {});
      case 'session/prompt':
        if (promptId != null) {
          await send({
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': -32000, 'message': 'turn already running'},
          });
          return;
        }
        promptId = id;
        native = params['sessionId'] as String;
        cancelled = Completer<void>();
        cancelledTurn = false;
        report({'prompt': params['prompt'], 'sessionId': native});
        final reason = await actions(script['prompt']);
        if (script['holdPrompt'] == true && !cancelledTurn) {
          await cancelled!.future;
        }
        if (!ended) {
          await result(id, {
            'stopReason': cancelledTurn
                ? (script['cancel'] == 'race' ? 'end_turn' : 'cancelled')
                : reason ?? script['stopReason'] ?? 'end_turn',
          });
        }
        promptId = null;
        if (script['exitStatus'] case final int code) stop(code);
      default:
        await send({
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32601, 'message': 'method not found'},
        });
    }
  }

  try {
    final early = script['beforeInitializeExit'];
    if (early is Json) {
      if (early['stderr'] is String) writeError(early['stderr']! as String);
      stop(early['status'] as int? ?? 1);
    }
    while (!ended && await reader.moveNext()) {
      if (stalled) {
        await closed.future;
        break;
      }
      final message = jsonDecode(reader.current) as Json;
      // Do not await a prompt here: permission responses and cancellation must
      // still be read while scripted turn work is pending.
      late final Future<void> task;
      task = handle(message)
          .catchError((Object error) {
            writeError('$error');
            stop(1);
          })
          .whenComplete(() => tasks.remove(task));
      tasks.add(task);
      if (stalled) await closed.future;
    }
  } finally {
    ended = true;
    if (!closed.isCompleted) closed.complete();
    if (cancelled != null && !cancelled!.isCompleted) cancelled!.complete();
    for (final response in pending.values) {
      if (!response.isCompleted) {
        response.complete({
          'outcome': {'outcome': 'cancelled'},
        });
      }
    }
    pending.clear();
    await reader.cancel();
    await Future.wait(tasks.toList());
  }
  return status;
}
