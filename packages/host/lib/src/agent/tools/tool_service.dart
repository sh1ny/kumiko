import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'tool_catalog.dart';
import 'tool_connection.dart';

export 'tool_catalog.dart' show ToolRole;
export 'tool_connection.dart' show ToolConnection;

/// Resource bounds (design: Resource Bounds).
const _maxUnauthenticated = 16;
const _maxAuthenticatedPerGrant = 4;
const _maxAuthenticatedTotal = 256;
const _maxPreambleBytes = 512;
const _maxLineBytes = 1024 * 1024;
const _maxInFlightPerConnection = 8;

const _supportedProtocolVersions = ['2025-06-18', '2025-03-26', '2024-11-05'];

/// Compares two byte sequences without exiting early on the first
/// difference. Differing lengths compare unequal.
bool constantTimeEquals(List<int> a, List<int> b) {
  var diff = a.length ^ b.length;
  final n = min(a.length, b.length);
  for (var i = 0; i < n; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// The facts `kumiko_session_info` reports, from the grant's own slot.
class _Bound {
  _Bound(this.sessionId);
  final String sessionId;
}

class _SessionUnavailable implements Exception {
  const _SessionUnavailable();
}

/// Authority for one live session run. Created by [ToolService.register]
/// before the adapter is launched; it first holds a pending slot, then is
/// bound to the session record once that exists.
///
/// Only `AgentService` on the host isolate calls [setAdapter], [bind], [fail]
/// and [revoke].
class ToolGrant {
  ToolGrant._(
    this._service,
    this.secret,
    this._secretBytes,
    this.role,
    this.target,
    this.runtime,
    this.profile,
    this.onAuthenticated,
    this.onCallSucceeded,
    this.onConnectionLimit,
  ) {
    // Waiting calls observe a failure; nobody else has to.
    _binding.future.ignore();
  }

  final ToolService _service;
  final Uint8List _secretBytes;
  final _binding = Completer<_Bound>();

  /// One per call waiting for the binding; settled by [bind] or [fail], or
  /// dropped by its connection's close, so nothing outlives the connection.
  final _waiters = <Completer<_Bound>>{};
  final _connections = <_Conn>{};
  bool _live = true;
  String? _adapterName;
  String? _adapterVersion;

  /// base64url (no padding) of 32 random bytes. Deliver only through the
  /// run's Kumiko MCP entry environment; never log it.
  final String secret;
  final ToolRole role;

  /// Absolute workspace path captured at start.
  final String target;

  /// Runtime kind, e.g. `claude-code`.
  final String runtime;
  final String profile;

  /// Called on every successful bridge authentication for this grant.
  void Function()? onAuthenticated;

  /// Called after every successful `tools/call` for this grant.
  void Function()? onCallSucceeded;

  /// Called once when an authenticated bridge exceeds connection capacity.
  void Function()? onConnectionLimit;
  bool _connectionLimitReached = false;
  bool get connectionLimitReached => _connectionLimitReached;

  bool _everAuthenticated = false;
  bool _everCalled = false;

  /// True once any bridge authenticated with this secret, including during
  /// `session/new` (before the session exists).
  bool get everAuthenticated => _everAuthenticated;

  /// True once any `tools/call` succeeded.
  bool get everCalled => _everCalled;
  bool get isLive => _live;

  /// Calls still waiting for the binding (tests).
  int get pendingBindingWaiters => _waiters.length;

  /// A waiter for the binding, or null once it has settled.
  Completer<_Bound>? _waitBinding() {
    if (_binding.isCompleted) return null;
    final waiter = Completer<_Bound>();
    _waiters.add(waiter);
    return waiter;
  }

  bool get isBound => _boundValue != null;
  _Bound? _boundValue;

  /// Sets the adapter identity after `initialize` answered.
  void setAdapter(String name, String version) {
    _adapterName = name;
    _adapterVersion = version;
  }

  /// Binds the slot to the Kumiko session record id. Releases waiting calls.
  /// Ignored when already bound, failed or revoked.
  void bind(String recordId) {
    if (!_live || _binding.isCompleted) return;
    final bound = _boundValue = _Bound(recordId);
    _binding.complete(bound);
    for (final waiter in _waiters) {
      waiter.complete(bound);
    }
    _waiters.clear();
  }

  /// The attempt failed before binding: waiting calls answer *session
  /// unavailable*. [reason] is for the caller's own log, never sent to peers.
  void fail(String reason) {
    if (_binding.isCompleted) return;
    _binding.completeError(const _SessionUnavailable());
    for (final waiter in _waiters) {
      waiter.completeError(const _SessionUnavailable());
    }
    _waiters.clear();
  }

  /// Ends the run: answers in-flight calls with an error, closes this
  /// grant's connections and stops the secret from authenticating.
  void revoke() {
    if (!_live) return;
    _live = false;
    fail('revoked');
    _service._grants.remove(this);
    for (final c in _connections.toList()) {
      c.failInFlight();
      _service._closeConn(c);
    }
  }

  Map<String, Object?> _info(_Bound b) => {
    'sessionId': b.sessionId,
    'role': role.wire,
    'runtime': runtime,
    'adapter': {
      'name': _adapterName ?? 'unknown',
      'version': _adapterVersion ?? 'unknown',
    },
    'target': {'path': target},
  };
}

class _Call {
  bool done = false;

  /// Cancelled by the client while still running: its result is dropped,
  /// but it counts against the in-flight cap until it settles.
  bool cancelled = false;
}

class _Conn {
  _Conn(this.transport);

  final ToolConnection transport;
  final buffer = BytesBuilder(copy: false);
  final inFlight = <Object, _Call>{};

  /// Cancelled calls that are still running (awaiting the binding).
  int cancelledRunning = 0;

  /// Binding waiters of this connection's running calls.
  final waiters = <Completer<_Bound>>{};
  StreamSubscription<List<int>>? sub;
  Timer? deadline;
  ToolGrant? grant;
  bool countedUnauthenticated = true;
  bool closing = false;
  Future<void>? closedFuture;

  bool get authenticated => grant != null;

  void send(Map<String, Object?> message) {
    if (closing) return;
    try {
      transport.add(utf8.encode('${jsonEncode(message)}\n'));
    } on Object {
      // The peer is gone; the input stream reports it.
    }
  }

  void failInFlight() {
    for (final entry in inFlight.entries.toList()) {
      if (entry.value.done) continue;
      entry.value.done = true;
      send(_error(entry.key, -32000, 'session unavailable'));
    }
    inFlight.clear();
  }
}

Map<String, Object?> _error(Object? id, int code, String message) => {
  'jsonrpc': '2.0',
  'id': id,
  'error': {'code': code, 'message': message},
};

Map<String, Object?> _result(Object id, Map<String, Object?> result) => {
  'jsonrpc': '2.0',
  'id': id,
  'result': result,
};

/// In-memory tool service: grants, the handshake and a small MCP server.
///
/// Transport-neutral: connections arrive through [accept] as
/// [ToolConnection]s. Everything here reads memory only and never waits on
/// the desktop, so ADR 0002 control is not delayed.
class ToolService {
  ToolService({
    Duration preambleDeadline = const Duration(seconds: 5),
    Random? random,
    void Function(String message)? log,
  }) : _deadline = preambleDeadline,
       _random = random ?? Random.secure(),
       _log = log ?? ((_) {});

  final Duration _deadline;
  final Random _random;
  final void Function(String) _log;
  final _grants = <ToolGrant>{};
  final _conns = <_Conn>{};
  int _unauthenticated = 0;
  int _authenticated = 0;
  int _authFailures = 0;
  bool _closed = false;

  String? _endpoint;
  String? _unavailableReason;

  /// Whether the host's endpoint is up. Sessions started while it is false
  /// get no `kumiko` MCP entry and show tools as unavailable
  /// ([unavailableReason]).
  bool get endpointAvailable => _endpoint != null;

  /// The endpoint address for the bridge's `KUMIKO_TOOL_ENDPOINT`: a unix
  /// socket path or a Windows pipe name. Null while unavailable.
  String? get endpoint => _endpoint;

  /// `endpoint-unavailable: <cause>` once the endpoint failed; null while it
  /// is up or not yet started.
  String? get unavailableReason => _unavailableReason;

  /// Called by the endpoint when it is listening.
  void markEndpointAvailable(String endpoint) {
    _endpoint = endpoint;
    _unavailableReason = null;
  }

  /// Called by the endpoint when it could not be created or died.
  void markEndpointUnavailable(String cause) {
    _endpoint = null;
    _unavailableReason = 'endpoint-unavailable: $cause';
  }

  /// Connections still in the unauthenticated stage (not yet fully closed).
  int get unauthenticatedCount => _unauthenticated;
  int get authenticatedCount => _authenticated;

  /// Calls admitted by bridges still waiting for their native run binding.
  int get pendingBindingCount =>
      _grants.fold(0, (count, grant) => count + grant.pendingBindingWaiters);

  /// Authentication failures so far (a counter; secrets are never logged).
  int get authFailureCount => _authFailures;

  /// Registers a grant on a pending slot. Call before launching the adapter.
  ToolGrant register({
    required String target,
    required ToolRole role,
    required String runtime,
    required String profile,
    void Function()? onAuthenticated,
    void Function()? onCallSucceeded,
    void Function()? onConnectionLimit,
  }) {
    final bytes = Uint8List.fromList([
      for (var i = 0; i < 32; i++) _random.nextInt(256),
    ]);
    final grant = ToolGrant._(
      this,
      base64Url.encode(bytes).replaceAll('=', ''),
      bytes,
      role,
      target,
      runtime,
      profile,
      onAuthenticated,
      onCallSucceeded,
      onConnectionLimit,
    );
    _grants.add(grant);
    return grant;
  }

  /// Takes ownership of a new connection and runs the handshake.
  void accept(ToolConnection transport) {
    final c = _Conn(transport);
    if (_closed || _unauthenticated >= _maxUnauthenticated) {
      c.closing = true;
      unawaited(transport.close());
      return;
    }
    _unauthenticated++;
    _conns.add(c);
    c.deadline = Timer(_deadline, () {
      if (!c.authenticated) _closeConn(c);
    });
    c.sub = transport.input.listen(
      (chunk) => _onData(c, chunk),
      onError: (Object _) => _closeConn(c),
      onDone: () => _closeConn(c),
      cancelOnError: true,
    );
  }

  /// Revokes every grant and closes every connection.
  Future<void> close() async {
    _closed = true;
    for (final g in _grants.toList()) {
      g.revoke();
    }
    final pending = [for (final c in _conns.toList()) _closeConn(c)];
    await Future.wait(pending);
  }

  // Closes [c] once; the returned future completes when the transport is
  // fully closed and its slot has been released.
  Future<void> _closeConn(_Conn c) {
    final existing = c.closedFuture;
    if (existing != null) return existing;
    c.closing = true;
    c.deadline?.cancel();
    unawaited(c.sub?.cancel());
    for (final call in c.inFlight.values) {
      call.done = true;
    }
    c.inFlight.clear();
    // Calls still waiting for the binding end now, not when it settles.
    for (final waiter in c.waiters.toList()) {
      c.grant?._waiters.remove(waiter);
      if (!waiter.isCompleted) {
        waiter.completeError(const _SessionUnavailable());
      }
    }
    c.waiters.clear();
    return c.closedFuture = c.transport.close().catchError((Object _) {}).then((
      _,
    ) {
      if (c.countedUnauthenticated) {
        c.countedUnauthenticated = false;
        _unauthenticated--;
      }
      if (c.grant != null) {
        _authenticated--;
        c.grant!._connections.remove(c);
      }
      _conns.remove(c);
    });
  }

  void _onData(_Conn c, List<int> chunk) {
    var start = 0;
    while (!c.closing) {
      final nl = chunk.indexOf(10, start);
      final end = nl < 0 ? chunk.length : nl;
      final limit = c.authenticated ? _maxLineBytes : _maxPreambleBytes;
      if (c.buffer.length + (end - start) > limit) {
        _log(
          c.authenticated
              ? 'tool endpoint: MCP line over bound, closing'
              : 'tool endpoint: preamble over bound, closing',
        );
        _closeConn(c);
        return;
      }
      c.buffer.add(
        start == 0 && end == chunk.length ? chunk : chunk.sublist(start, end),
      );
      if (nl < 0) return;
      start = nl + 1;
      final line = c.buffer.takeBytes();
      if (c.authenticated) {
        _onMcpLine(c, line);
      } else {
        _onPreamble(c, line);
      }
    }
  }

  void _onPreamble(_Conn c, Uint8List line) {
    Object? parsed;
    try {
      parsed = jsonDecode(utf8.decode(line));
    } on FormatException {
      _authFailures++;
      _closeConn(c);
      return;
    }
    if (parsed is! Map ||
        parsed['kumikoBridge'] != 1 ||
        parsed['secret'] is! String) {
      _authFailures++;
      _closeConn(c);
      return;
    }
    Uint8List? presented;
    try {
      final s = parsed['secret'] as String;
      presented = base64Url.decode(base64Url.normalize(s));
    } on FormatException {
      presented = null;
    }
    // Compare against every grant so the work does not depend on a match.
    ToolGrant? match;
    for (final g in _grants) {
      if (presented != null &&
          constantTimeEquals(presented, g._secretBytes) &&
          g._live) {
        match = g;
      }
    }
    if (match == null) {
      _authFailures++;
      _log('tool endpoint: unauthenticated connection ($_authFailures)');
      c.send({'ok': false, 'error': 'unauthenticated'});
      _closeConn(c);
      return;
    }
    if (match._connections.length >= _maxAuthenticatedPerGrant ||
        _authenticated >= _maxAuthenticatedTotal) {
      if (!match._connectionLimitReached) {
        match._connectionLimitReached = true;
        match.onConnectionLimit?.call();
      }
      c.send({'ok': false, 'error': 'busy'});
      _closeConn(c);
      return;
    }
    c.deadline?.cancel();
    c.grant = match;
    match._connections.add(c);
    _authenticated++;
    c.countedUnauthenticated = false;
    _unauthenticated--;
    c.send({'ok': true});
    match._everAuthenticated = true;
    match.onAuthenticated?.call();
  }

  void _onMcpLine(_Conn c, Uint8List line) {
    final Object? message;
    try {
      message = jsonDecode(utf8.decode(line));
    } on FormatException {
      c.send(_error(null, -32700, 'parse error'));
      return;
    }
    if (message is! Map) {
      c.send(_error(null, -32600, 'invalid request'));
      return;
    }
    final method = message['method'];
    if (method is! String) return; // A response from the client; ignored.
    final params = message['params'];
    if (!message.containsKey('id')) {
      _onNotification(c, method, params);
      return;
    }
    final Object? rawId = message['id'];
    if (rawId is! String && rawId is! num) {
      c.send(_error(null, -32600, 'invalid request'));
      return;
    }
    final Object id = rawId!;
    switch (method) {
      case 'initialize':
        final asked = params is Map ? params['protocolVersion'] : null;
        c.send(
          _result(id, {
            'protocolVersion': _supportedProtocolVersions.contains(asked)
                ? asked
                : _supportedProtocolVersions.first,
            'capabilities': {
              'tools': {'listChanged': false},
            },
            'serverInfo': {'name': 'kumiko', 'version': '1'},
          }),
        );
      case 'ping':
        c.send(_result(id, {}));
      case 'tools/list':
        c.send(
          _result(id, {
            'tools': [
              for (final t in ToolCatalog.toolsFor(c.grant!.role)) t.toJson(),
            ],
          }),
        );
      case 'tools/call':
        _onCall(c, id, params);
      default:
        c.send(_error(id, -32601, 'method not found: $method'));
    }
  }

  void _onNotification(_Conn c, String method, Object? params) {
    if (method != 'notifications/cancelled' || params is! Map) return;
    final call = c.inFlight.remove(params['requestId']);
    if (call == null || call.done) return;
    // Its result is dropped when it completes; until then it still holds a
    // slot, so call/cancel cycles cannot pile up work before the binding.
    call
      ..done = true
      ..cancelled = true;
    c.cancelledRunning++;
  }

  void _onCall(_Conn c, Object id, Object? params) {
    final grant = c.grant!;
    if (c.inFlight.length + c.cancelledRunning >= _maxInFlightPerConnection) {
      c.send(_error(id, -32000, 'too many concurrent calls'));
      return;
    }
    if (!grant._live) {
      c.send(_error(id, -32000, 'session unavailable'));
      return;
    }
    final name = params is Map ? params['name'] : null;
    if (name is! String) {
      c.send(_error(id, -32602, 'invalid params: missing tool name'));
      return;
    }
    final tool = ToolCatalog.find(grant.role, name);
    if (tool == null) {
      c.send(_error(id, -32602, 'tool $name is not available'));
      return;
    }
    final invalid = tool.validate((params as Map)['arguments']);
    if (invalid != null) {
      c.send(_error(id, -32602, 'invalid arguments: $invalid'));
      return;
    }
    if (c.inFlight.containsKey(id)) {
      // Replacing the entry would orphan the running call and its slot.
      c.send(_error(id, -32600, 'invalid request: request id already in use'));
      return;
    }
    final call = _Call();
    c.inFlight[id] = call;
    unawaited(_runCall(c, grant, id, call));
  }

  Future<void> _runCall(_Conn c, ToolGrant grant, Object id, _Call call) async {
    Map<String, Object?> reply;
    var succeeded = false;
    try {
      // Only tool in M1: kumiko_session_info. The result comes from the
      // grant's own slot, never from an argument.
      final waiter = grant._waitBinding();
      if (waiter != null) c.waiters.add(waiter);
      final _Bound bound;
      try {
        bound = await (waiter?.future ?? grant._binding.future);
      } finally {
        if (waiter != null) c.waiters.remove(waiter);
      }
      final info = grant._info(bound);
      reply = _result(id, {
        'content': [
          {'type': 'text', 'text': jsonEncode(info)},
        ],
        'structuredContent': info,
      });
      succeeded = true;
    } on _SessionUnavailable {
      reply = _error(id, -32000, 'session unavailable');
    } finally {
      if (call.cancelled) c.cancelledRunning--; // Settled: its slot is free.
    }
    if (call.done || c.closing) return; // Cancelled, revoked or gone.
    call.done = true;
    c.inFlight.remove(id);
    c.send(reply);
    if (succeeded) {
      grant._everCalled = true;
      grant.onCallSucceeded?.call();
    }
  }
}
