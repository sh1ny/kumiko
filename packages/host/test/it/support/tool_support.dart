import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:process_containment/process_containment.dart';

import 'harness.dart';

/// A local client of the tool endpoint: a unix socket on POSIX, a named pipe
/// on Windows. It reads newline-delimited text.
class ToolClient {
  ToolClient._(this._write, this._closeTransport, Stream<List<int>> source) {
    _sub = source.listen(
      _onData,
      onError: (Object _) => _eof(),
      onDone: _eof,
      cancelOnError: true,
    );
  }

  final void Function(List<int>) _write;
  final Future<void> Function() _closeTransport;
  late final StreamSubscription<List<int>> _sub;
  final _partial = BytesBuilder();
  final _lines = <String>[];
  final _waiters = <Completer<void>>[];
  final _ended = Completer<void>();
  bool get ended => _ended.isCompleted;

  static Future<ToolClient> connect(String endpoint) async {
    if (Platform.isWindows) {
      final pipe = await openWindowsPipe(endpoint);
      return ToolClient._(
        (b) => pipe.add(b).ignore(),
        pipe.close,
        pipe.incoming,
      );
    }
    final socket = await Socket.connect(
      InternetAddress(endpoint, type: InternetAddressType.unix),
      0,
    );
    // A write to a connection the host closed fails on done; tests observe
    // the close through reads, as on Windows.
    socket.done.ignore();
    return ToolClient._(
      socket.add,
      () async => socket.destroy(),
      socket.cast<List<int>>(),
    );
  }

  void _onData(List<int> data) {
    for (final b in data) {
      if (b == 10) {
        _lines.add(utf8.decode(_partial.takeBytes()));
      } else {
        _partial.addByte(b);
      }
    }
    _wake();
  }

  void _eof() {
    if (!_ended.isCompleted) _ended.complete();
    _wake();
  }

  void _wake() {
    for (final w in _waiters.toList()) {
      if (!w.isCompleted) w.complete();
    }
    _waiters.clear();
  }

  /// Sends one line; JSON-encodes anything that is not a string.
  void send(Object message) {
    final text = message is String ? message : jsonEncode(message);
    _write(utf8.encode('$text\n'));
  }

  /// The next line, or null when the connection ended first.
  Future<String?> readLine({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (_lines.isEmpty) {
      if (ended) return null;
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        throw TimeoutException('no line from the endpoint', timeout);
      }
      final w = Completer<void>();
      _waiters.add(w);
      await w.future.timeout(left, onTimeout: () {});
    }
    return _lines.removeAt(0);
  }

  Future<Map<String, Object?>?> readJson({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final line = await readLine(timeout: timeout);
    return line == null ? null : jsonDecode(line) as Map<String, Object?>;
  }

  /// Whether the host closed the connection within [within].
  Future<bool> closedByHost({
    Duration within = const Duration(seconds: 10),
  }) async {
    await _ended.future.timeout(within, onTimeout: () {});
    return ended;
  }

  Future<void> close() async {
    await _sub.cancel();
    try {
      await _closeTransport();
    } on Object {
      // Already closed.
    }
  }

  /// Sends the bridge preamble for [secret].
  void authenticate(String secret) =>
      send({'kumikoBridge': 1, 'secret': secret});
}

/// Whether the process [pid] listens on a TCP port or holds a UDP socket.
Future<List<String>> networkListeners(int pid) async {
  if (Platform.isWindows) {
    final out = <String>[];
    for (final proto in ['tcp', 'udp']) {
      final r = await Process.run('netstat', ['-ano', '-p', proto]);
      for (final line in LineSplitter.split('${r.stdout}')) {
        final cols = line.trim().split(RegExp(r'\s+'));
        if (cols.isNotEmpty &&
            cols.last == '$pid' &&
            (proto == 'udp' || line.contains('LISTENING'))) {
          out.add(line.trim());
        }
      }
    }
    return out;
  }
  final r = await Process.run('lsof', ['-nP', '-a', '-p', '$pid', '-i']);
  return [
    for (final line in LineSplitter.split('${r.stdout}'))
      if (line.trim().isNotEmpty && !line.startsWith('COMMAND')) line.trim(),
  ];
}

/// The host's `test/tools.state`.
Future<Map<String, Object?>> toolState(Desktop desktop) async =>
    (await desktop.connection.request('test/tools.state', {}))!
        as Map<String, Object?>;

/// Registers a grant on the host's tool service; [bind] also binds it to a
/// session record the way `AgentService` will at `onCreated`.
Future<({String id, String secret})> newGrant(
  Desktop desktop, {
  bool bind = true,
  String? target,
}) async {
  final r =
      (await desktop.connection.request('test/tools.grant', {
            'bind': bind,
            'target': ?target,
          }))!
          as Map<String, Object?>;
  return (id: r['id']! as String, secret: r['secret']! as String);
}

Future<void> grantCall(Desktop desktop, String op, String id) =>
    desktop.connection.request('test/tools.$op', {'id': id});

/// The endpoint address once the host's tool service is up.
Future<String> endpointOf(Desktop desktop) async {
  final s = await toolState(desktop);
  if (s['available'] != true) failNow('endpoint unavailable: ${s['reason']}');
  return s['endpoint']! as String;
}

Never failNow(String message) => throw StateError(message);

String socketPathIn(Directory profile) => joinPath(profile.path, 'tools.sock');
