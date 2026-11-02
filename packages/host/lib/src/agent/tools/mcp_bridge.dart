import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:process_containment/process_containment.dart';

/// Exit codes of `kumiko_host --mcp-bridge`.
abstract final class BridgeExit {
  /// stdin or the endpoint ended normally.
  static const int ok = 0;

  /// Could not start: variables missing, no endpoint, or the secret refused.
  static const int cannotStart = 2;

  /// A write failed or the endpoint errored after the handshake.
  static const int relayFailed = 1;
}

const _handshakeTimeout = Duration(seconds: 10);
const _maxAnswerBytes = 512;

/// `kumiko_host --mcp-bridge` (design D3, D9): authenticates to the host's
/// tool endpoint, then copies bytes stdin to endpoint and endpoint to stdout
/// without parsing MCP. It touches no host state: no ledger, no profile lock,
/// no log, no store, no disk. `KUMIKO_UNIT` (a containment marker) is
/// ignored.
///
/// Exits on stdin EOF, endpoint EOF or error, and any write failure. Before
/// the handshake it never reads stdin.
Future<int> runMcpBridge(Map<String, String> environment) async {
  final endpoint = environment['KUMIKO_TOOL_ENDPOINT'];
  final secret = environment['KUMIKO_TOOL_SECRET'];
  if (endpoint == null ||
      endpoint.isEmpty ||
      secret == null ||
      secret.isEmpty) {
    stderr.writeln(
      'kumiko mcp-bridge: KUMIKO_TOOL_ENDPOINT and KUMIKO_TOOL_SECRET '
      'are required',
    );
    return BridgeExit.cannotStart;
  }

  final _Link link;
  try {
    link = await _connect(endpoint);
  } on Object catch (e) {
    stderr.writeln('kumiko mcp-bridge: cannot connect to the endpoint: $e');
    return BridgeExit.cannotStart;
  }
  return _Bridge(link).run(secret);
}

/// One connected endpoint, whatever the transport.
class _Link {
  _Link(this.incoming, this.write, this.close);
  final Stream<List<int>> incoming;

  /// Completes when the transport accepted the bytes.
  final Future<void> Function(List<int>) write;
  final Future<void> Function() close;
}

Future<_Link> _connect(String endpoint) async {
  if (Platform.isWindows) {
    final pipe = await openWindowsPipe(endpoint);
    return _Link(pipe.incoming, pipe.add, pipe.close);
  }
  final socket = await Socket.connect(
    InternetAddress(endpoint, type: InternetAddressType.unix),
    0,
  );
  return _Link(socket, (bytes) {
    socket.add(bytes);
    return socket.flush();
  }, () async => socket.destroy());
}

class _Bridge {
  _Bridge(this._link);

  final _Link _link;
  final _exit = Completer<int>();
  final _answer = BytesBuilder(copy: false);
  StreamSubscription<List<int>>? _endpoint;
  StreamSubscription<List<int>>? _stdin;
  bool _relaying = false;
  Timer? _handshakeTimer;

  Future<int> run(String secret) async {
    _handshakeTimer = Timer(_handshakeTimeout, () {
      _finish(BridgeExit.cannotStart, message: 'the host did not answer');
    });
    _endpoint = _link.incoming.listen(
      _onEndpointData,
      onError: (Object e) => _finish(
        _relaying ? BridgeExit.relayFailed : BridgeExit.cannotStart,
        message: "endpoint error: $e",
      ),
      onDone: () => _finish(
        _relaying ? BridgeExit.ok : BridgeExit.cannotStart,
        message: _relaying ? null : 'the endpoint closed during the handshake',
      ),
      cancelOnError: true,
    );
    try {
      await _link.write(
        utf8.encode('${jsonEncode({'kumikoBridge': 1, 'secret': secret})}\n'),
      );
    } on Object catch (e) {
      _finish(BridgeExit.cannotStart, message: 'cannot send the secret: $e');
    }
    return _exit.future;
  }

  bool _failedLogged = false;

  void _finish(int code, {String? message}) {
    if (_exit.isCompleted) return;
    if (message != null && !_failedLogged) {
      _failedLogged = true;
      stderr.writeln('kumiko mcp-bridge: $message');
    }
    _handshakeTimer?.cancel();
    unawaited(_stdin?.cancel());
    unawaited(_endpoint?.cancel());
    unawaited(_link.close().catchError((Object _) {}));
    _exit.complete(code);
  }

  void _onEndpointData(List<int> data) {
    if (!_relaying) {
      _onHandshakeData(data);
      return;
    }
    _toStdout(data);
  }

  void _onHandshakeData(List<int> data) {
    final nl = data.indexOf(10);
    final end = nl < 0 ? data.length : nl;
    if (_answer.length + end > _maxAnswerBytes) {
      _finish(BridgeExit.cannotStart, message: 'the host answered nonsense');
      return;
    }
    _answer.add(end == data.length ? data : data.sublist(0, end));
    if (nl < 0) return;
    Object? answer;
    try {
      answer = jsonDecode(utf8.decode(_answer.takeBytes()));
    } on FormatException {
      _finish(BridgeExit.cannotStart, message: 'the host answered nonsense');
      return;
    }
    if (answer is! Map || answer['ok'] != true) {
      final why = answer is Map ? answer['error'] : null;
      _finish(
        BridgeExit.cannotStart,
        message:
            'the host refused the connection'
            '${why is String ? ' ($why)' : ''}',
      );
      return;
    }
    _relaying = true;
    _handshakeTimer?.cancel();
    _startStdin();
    if (nl + 1 < data.length) _toStdout(data.sublist(nl + 1));
  }

  void _startStdin() {
    _stdin = stdin.listen(
      (data) {
        final sub = _stdin!;
        sub.pause();
        _link
            .write(data)
            .then((_) {
              if (!_exit.isCompleted) sub.resume();
            })
            .catchError((Object e) {
              _finish(BridgeExit.relayFailed, message: 'write failed: $e');
            });
      },
      onError: (Object _) => _finish(BridgeExit.relayFailed),
      onDone: () => _finish(BridgeExit.ok),
      cancelOnError: true,
    );
  }

  void _toStdout(List<int> data) {
    final sub = _endpoint!;
    sub.pause();
    try {
      stdout.add(data);
      stdout
          .flush()
          .then((_) {
            if (!_exit.isCompleted) sub.resume();
          })
          .catchError((Object e) {
            _finish(BridgeExit.relayFailed, message: 'write failed: $e');
          });
    } on Object catch (e) {
      _finish(BridgeExit.relayFailed, message: 'write failed: $e');
    }
  }
}
