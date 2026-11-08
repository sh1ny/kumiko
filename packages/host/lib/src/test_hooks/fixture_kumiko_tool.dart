import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';

/// What an ACP adapter does with the `kumiko` MCP entry in `mcpServers`, as
/// Claude does: spawn the entry's command with a reduced environment plus the
/// entry's `env`, speak MCP to it over stdio, and call a tool.
///
/// Script key `kumikoTool` (all optional):
/// - `when`: `session/new` (start the bridge and call during `session/new`,
///   without holding its result), `prompt` (start and call at the start of
///   each prompt, awaited), or `never` (default: do nothing).
/// - `call`: the tool to call, e.g. `kumiko_session_info`; absent or null
///   means no `tools/call`.
/// - `list`: send `tools/list` (default true).
/// - `authenticate`: false spawns the bridge with a wrong secret (default
///   true).
/// - `arguments`: the call's arguments (default `{}`).
///
/// Reports: `kumikoTool` (`no-entry`, `spawned`, `bridge-exited`),
/// `kumikoBridgePid`, `kumikoToolListed` (names), `kumikoToolResult` (the
/// full JSON-RPC response) and `kumikoBridgeExit` (code, stderr).
class KumikoToolDriver {
  KumikoToolDriver(this.config, this._report);

  final Json config;
  final void Function(Json) _report;

  String get when => config['when'] as String? ?? 'never';

  Process? _bridge;
  StreamIterator<String>? _lines;
  final _stderr = StringBuffer();
  var _nextId = 1;
  var _initialized = false;
  var _dead = false;

  /// Runs the configured steps against [mcpServers] from the last
  /// `session/new`, `session/load` or `session/resume`.
  Future<void> run(Object? mcpServers) async {
    final entry = _entry(mcpServers);
    if (entry == null) {
      _report({'kumikoTool': 'no-entry'});
      return;
    }
    if (_bridge == null) await _spawn(entry);
    if (_dead) return;
    try {
      if (!_initialized) {
        final init = await _rpc('initialize', {
          'protocolVersion': '2025-06-18',
          'capabilities': <String, Object?>{},
          'clientInfo': {'name': 'fixture-adapter', 'version': '0'},
        });
        if (init == null) return;
        _notify('notifications/initialized');
        _initialized = true;
      }
      if (config['list'] != false) {
        final listed = await _rpc('tools/list');
        if (listed == null) return;
        final tools = (listed['result'] as Json?)?['tools'];
        _report({
          'kumikoToolListed': [
            if (tools is List)
              for (final t in tools)
                if (t is Json) t['name'],
          ],
        });
      }
      final name = config['call'];
      if (name is String) {
        final result = await _rpc('tools/call', {
          'name': name,
          'arguments': config['arguments'] ?? <String, Object?>{},
        });
        if (result != null) _report({'kumikoToolResult': result});
      }
    } on TimeoutException {
      _report({'kumikoTool': 'timeout'});
    }
  }

  Json? _entry(Object? servers) {
    if (servers is! List) return null;
    for (final s in servers) {
      if (s is Json && s['name'] == 'kumiko') return s;
    }
    return null;
  }

  Future<void> _spawn(Json entry) async {
    final env = <String, String>{
      // A reduced environment, as MCP clients launch stdio servers.
      for (final name in const ['SystemRoot', 'SYSTEMROOT', 'TEMP', 'TMP'])
        if (Platform.environment[name] case final String v) name: v,
      for (final e in (entry['env'] as List? ?? const []))
        if (e is Json) e['name'] as String: e['value'] as String,
    };
    if (config['authenticate'] == false) {
      env['KUMIKO_TOOL_SECRET'] = 'A' * 43;
    }
    final process = _bridge = await Process.start(
      entry['command'] as String,
      [for (final a in (entry['args'] as List? ?? const [])) a as String],
      environment: env,
      includeParentEnvironment: false,
    );
    process.stdin.done.catchError((Object _) {});
    _report({'kumikoTool': 'spawned', 'kumikoBridgePid': process.pid});
    _lines = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    process.stderr.transform(utf8.decoder).listen(_stderr.write);
    unawaited(
      process.exitCode.then((code) {
        _dead = true;
        _report({'kumikoBridgeExit': code, 'stderr': _stderr.toString()});
      }),
    );
  }

  void _notify(String method) =>
      _bridge!.stdin.writeln(jsonEncode({'jsonrpc': '2.0', 'method': method}));

  Future<Json?> _rpc(String method, [Json? params]) async {
    final id = _nextId++;
    try {
      _bridge!.stdin.writeln(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': ?params,
        }),
      );
    } on Object {
      _report({'kumikoTool': 'bridge-exited'});
      return null;
    }
    final lines = _lines!;
    final more = await lines.moveNext().timeout(const Duration(seconds: 60));
    if (!more) {
      _report({'kumikoTool': 'bridge-exited'});
      return null;
    }
    return jsonDecode(lines.current) as Json;
  }
}

/// The `KUMIKO_TOOL_SECRET` of the `kumiko` entry in [mcpServers], or `-`.
String kumikoSecret(Object? mcpServers) {
  if (mcpServers is List) {
    for (final s in mcpServers) {
      if (s is Json && s['name'] == 'kumiko') {
        for (final e in (s['env'] as List? ?? const [])) {
          if (e is Json && e['name'] == 'KUMIKO_TOOL_SECRET') {
            return e['value'] as String;
          }
        }
      }
    }
  }
  return '-';
}
