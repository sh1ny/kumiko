import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';

import 'acp/acp_client.dart';
import 'codex/codex_auth_signal.dart';
import 'codex/codex_client.dart';
import 'qualification.dart';
import 'qualified_adapters.dart';
import 'runtime_transport.dart';

class RuntimeIdentity {
  RuntimeIdentity(this.name, this.version, this.claims);
  final String name, version;
  final AdapterClaims claims;
}

class RuntimeChoice {
  RuntimeChoice(this.label, this.result, this.kind, {this.generated = false});
  final String label, kind;

  /// The label is Kumiko's indexed placeholder for a native JSON object,
  /// not a native string; a display name equal to it would be ambiguous.
  final bool generated;
  final Json result;
}

class RuntimePermission {
  RuntimePermission(
    this.id,
    this.turnId,
    this.title,
    this.preview,
    this.choices,
    this.cancellation, {
    this.threadId,
    this.parentThreadId,
  });
  final Object id;
  final String turnId, title;
  final String? preview;
  final List<RuntimeChoice> choices;
  final Json cancellation;
  final String? threadId, parentThreadId;
}

class RuntimeQuestion {
  RuntimeQuestion(
    this.id,
    this.turnId,
    this.questions, {
    this.asyncItem = false,
    this.threadId,
    this.parentThreadId,
  });
  final bool asyncItem;
  final Object id;
  final String turnId;
  final List<AgentQuestion> questions;
  final String? threadId, parentThreadId;
}

class RuntimeRetired {
  RuntimeRetired(this.threadId, this.turnId);
  final String? threadId, turnId;
}

class NativeChild {
  NativeChild(this.id, this.parent, {this.task = ''});
  final String id, parent;
  String task, status = 'unknown';
  String? turn;

  /// Recently ended or replaced turns, newest last; bounded to 32.
  final ended = <String>[];
  void end(String id) {
    ended.remove(id);
    ended.add(id);
    if (ended.length > 32) ended.removeAt(0);
  }

  bool get active => turn != null || status == 'running' || status == 'unknown';
}

class _UnknownNative {
  _UnknownNative(this.method, this.raw, this.bytes);
  final String method;
  final Json raw;
  final int bytes;
}

class RuntimeReply {
  RuntimeReply(this.id, this.result);
  final Object id;
  final Json result;
}

class RuntimeUpdate {
  RuntimeUpdate(
    this.kind,
    this.text, {
    this.truncated = false,
    this.event,
    this.question,
    this.optionalNotice,
  });
  final RuntimeQuestion? question;
  final String? optionalNotice;
  final bool truncated;
  final AgentEvent? event;
  final AgentEventKind kind;
  final String text;
}

class RuntimeTurnResult {
  const RuntimeTurnResult(
    this.stopReason, {
    this.isCancelled = false,
    this.truncated = false,
    this.error,
  });
  final String stopReason;
  final Object? error;
  final bool isCancelled, truncated;
}

/// Operation mapping only. Service owns units/records/drafts; AgentSession owns
/// root state and interaction records. No parallel lifecycle or raw event queue.
abstract class RuntimeDriver implements RuntimeTransport {
  RuntimeTransport get transport;
  AcpClient? get acp => null;
  String? get turnId => null;
  void observeExit() {}
  Object? Function(RuntimeUpdate)? normalizeUpdate;
  bool Function(int)? reserveEarly;
  void Function(int)? releaseEarly;
  void Function()? onTurnIdentity;
  Object? Function(RuntimePermission)? onPermission;
  Object? Function(RuntimeQuestion)? onQuestion;
  void Function(Object?)? onRetired;
  void Function()? onDelegatedChanged;
  void Function(String, String, RuntimeTurnResult)? onNativeTurnEnded;
  AgentDelegated? get delegated => null;
  Map<String, String> get activeNativeTurns => const {};
  String? get interruptionReason => null;
  void checkCanSteer(String expectedTurn) => throw RpcException(
    ErrorCode.methodNotAvailable,
    'native steering unavailable',
  );
  Future<void> steer(String thread, String expectedTurn, String text) =>
      throw RpcException(
        ErrorCode.methodNotAvailable,
        'native steering unavailable',
      );
  bool get largeLineOwned;
  bool get largeLineWaiting;
  Future<RuntimeIdentity> initialize();
  Future<String?> prepareTools(
    String cwd, {
    required List<Json> mcpServers,
  }) async => null;
  Future<String> newSession(
    String cwd, {
    List<Json> mcpServers = const [],
    void Function(String)? onCreated,
  });
  Future<void> loadSession(
    String id,
    String cwd, {
    List<Json> mcpServers = const [],
  });
  Future<void> resumeSession(
    String id,
    String cwd, {
    List<Json> mcpServers = const [],
  });
  Future<RuntimeTurnResult> prompt(String id, String text);
  Future<void> cancel(String id);
  Future<void> cancelWithPermissions(String id, Iterable<Object> requests);
  Future<void> reply(Object id, Json result);
  @override
  bool get isClosed => transport.isClosed;
  @override
  Object? get failure => transport.failure;
  @override
  Future<void> get done => transport.done;
  @override
  set onFailure(void Function(Object)? handler) =>
      transport.onFailure = handler;
  @override
  set consumeNotification(FutureOr<void> Function(Object)? handler) =>
      transport.consumeNotification = handler;
  @override
  Future<void> close() => transport.close();
}

class AcpRuntimeDriver extends RuntimeDriver {
  AcpRuntimeDriver(this.client, {this.qualified = qualifiedAdapters});
  final AcpClient client;
  final List<(String, String, List<String>)> qualified;
  @override
  AcpClient get acp => client;
  @override
  RuntimeTransport get transport => client;
  @override
  bool get largeLineOwned => client.largeLineOwned;
  @override
  bool get largeLineWaiting => client.largeLineWaiting;
  @override
  Future<RuntimeIdentity> initialize() async {
    final i = await client.initialize();
    return RuntimeIdentity(
      i.adapterName,
      i.adapterVersion ?? '',
      qualifyAdapter(i, qualified: qualified),
    );
  }

  @override
  Future<String> newSession(
    String cwd, {
    List<Json> mcpServers = const [],
    void Function(String)? onCreated,
  }) => client.newSession(cwd, mcpServers: mcpServers, onCreated: onCreated);
  @override
  Future<void> loadSession(
    String id,
    String cwd, {
    List<Json> mcpServers = const [],
  }) async {
    await client.loadSession(id, cwd, mcpServers: mcpServers);
  }

  @override
  Future<void> resumeSession(
    String id,
    String cwd, {
    List<Json> mcpServers = const [],
  }) async {
    await client.resumeSession(id, cwd, mcpServers: mcpServers);
  }

  @override
  Future<RuntimeTurnResult> prompt(String id, String text) => client
      .prompt(id, text)
      .then(
        (r) => RuntimeTurnResult(
          r.stopReason,
          isCancelled: r.isCancelled,
          truncated: r.truncated,
        ),
      );
  @override
  Future<void> cancel(String id) => client.cancel(id);
  @override
  Future<void> cancelWithPermissions(String id, Iterable<Object> requests) =>
      client.cancelWithPermissions(id, requests);
  @override
  Future<void> reply(Object id, Json result) => client.reply(id, result);
}

class RuntimeDelivery {
  RuntimeDelivery(this.lines, this.bytes, this._release, this.after);
  final Iterable<Uint8List> lines;
  final int bytes;
  final void Function(int)? _release;
  final void Function()? after;
  bool released = false;
  void release() {
    if (released) return;
    released = true;
    _release?.call(bytes);
  }
}

class _ToolOutput {
  String text = '';
  int emitted = 0;
  bool lossy = false;
  bool capped = false;
}

class _EarlyNative {
  _EarlyNative(
    this.turn,
    this.bytes, {
    this.update,
    this.terminal,
    this.interaction,
  });
  final String turn;
  final int bytes;
  final Object? interaction;
  final RuntimeUpdate? update;
  final RuntimeTurnResult? terminal;
}

class CodexRuntimeDriver extends RuntimeDriver {
  CodexRuntimeDriver(this.client, this.version, {this.authSignals = const {}}) {
    client.normalizeNotification = _dispatchNotification;
    client.onRequest = _request;
    client.takeBuffered = _takeBuffered;
    client.onUnsupported = (feature, reason) => normalizeUpdate?.call(
      RuntimeUpdate(AgentEventKind.notice, '$feature unavailable: $reason'),
    );
    client.onFailure = (error) {
      _retireMapping(error);
      _onFailure?.call(error);
    };
  }
  final CodexClient client;
  final String version;

  /// Confirmed Codex sign-in signals; an unconfirmed signal never classifies.
  final Set<CodexAuthSignal> authSignals;
  Json? _privateToolConfig;
  @override
  Future<String?> prepareTools(
    String cwd, {
    required List<Json> mcpServers,
  }) async {
    _privateToolConfig = null;
    if (mcpServers.isEmpty) return null;
    try {
      final reason = await client.request<String?>(
        'config/read',
        {'cwd': cwd, 'includeLayers': true},
        decodeResult: (result) {
          if (result is! Json || result['config'] is! Json) {
            return 'Codex config/read cannot verify effective kumiko MCP absence';
          }
          final effective = result['config']! as Json;
          String? unsupportedProfileMcp(Json config) {
            final profiles = config['profiles'];
            if (profiles == null) return null;
            if (profiles is! Json) {
              return 'Codex profile configuration is malformed; kumiko MCP absence cannot be verified';
            }
            for (final profile in profiles.values) {
              if (profile is! Json || profile.containsKey('mcp_servers')) {
                return 'Codex profile MCP configuration is unsupported; kumiko MCP absence cannot be verified';
              }
            }
            return null;
          }

          final profileReason = unsupportedProfileMcp(effective);
          if (profileReason != null) return profileReason;
          final servers = effective['mcp_servers'];
          if (servers != null && servers is! Json) {
            return 'Codex config/read returned an invalid effective MCP configuration';
          }
          if (servers is Json && servers.containsKey('kumiko')) {
            return 'Codex effective configuration already defines kumiko MCP';
          }
          final layers = result['layers'];
          if (layers is! List) {
            return 'Codex config/read omitted raw layers; kumiko MCP absence cannot be verified';
          }
          for (final layer in layers) {
            if (layer is! Json || layer['config'] is! Json) {
              return 'Codex config/read has incomplete raw layers; kumiko MCP absence cannot be verified';
            }
            final profileReason = unsupportedProfileMcp(
              layer['config']! as Json,
            );
            if (profileReason != null) return profileReason;
            final layerServers = (layer['config']! as Json)['mcp_servers'];
            if (layerServers != null && layerServers is! Json) {
              return 'Codex config/read has invalid MCP layers; kumiko MCP absence cannot be verified';
            }
            if (layerServers is Json && layerServers.containsKey('kumiko')) {
              return 'Codex user or workspace configuration already defines kumiko MCP';
            }
          }
          return null;
        },
      );
      if (reason != null) return reason;
      if (mcpServers.length != 1 || mcpServers.single['name'] != 'kumiko') {
        return 'Codex private MCP delivery requires exactly one kumiko entry';
      }
      final entry = mcpServers.single;
      final environment = <String, Object?>{};
      for (final value in entry['env']! as List) {
        final pair = value as Json;
        final name = pair['name']! as String;
        if (!const [
              'KUMIKO_TOOL_ENDPOINT',
              'KUMIKO_TOOL_SECRET',
              'KUMIKO_UNIT',
            ].contains(name) ||
            environment.containsKey(name)) {
          return 'Codex private kumiko entry environment is invalid';
        }
        environment[name] = pair['value'];
      }
      if (environment.length != 3) {
        return 'Codex private kumiko entry environment is incomplete';
      }
      _privateToolConfig = {
        // Thread config uses ordered dotted-key replacements. Replacing the
        // root table would discard unrelated servers supplied by native CLI.
        'mcp_servers.kumiko': {
          'command': entry['command'],
          'args': entry['args'],
          'env': environment,
        },
      };
      return null;
    } on CodexRemoteException catch (error) {
      return 'Codex config/read unavailable (native code ${error.code}); kumiko MCP absence cannot be verified';
    } on TimeoutException {
      if (client.isClosed || client.failure != null) rethrow;
      return 'Codex config/read timed out; private kumiko MCP delivery unavailable';
    } on CodexOptionalUnsupported {
      return 'Codex config/read unsupported; private kumiko MCP delivery unavailable';
    }
  }

  String? root;
  String? _turnId;
  String? _earlyId;
  bool _unknownChildNoticed = false;
  final _children = <String, NativeChild>{};
  bool _childrenIncomplete = false;
  // Parentless threads announced before the thread/start response; they are
  // classified once that response names the root.
  final _startupThreads = <String>{};
  final _unknownNative = <_UnknownNative>[];
  int _unknownBytes = 0;
  Timer? _unknownDeadline;
  bool _drainingUnknown = false;
  int _resolvedUnknownBytes = 0;
  RuntimeDelivery? _unknownDelivery, _expiredUnknownDelivery;
  bool _childrenDisconnected = false;

  /// Streamed command output per tool, oldest first. The desktop replaces a
  /// tool's content on each update, so every delta carries the bounded output
  /// so far. That also lets stateless redaction see a secret split across
  /// deltas. Emission per tool is bounded so tiny deltas cannot amplify.
  final _toolOutput = <String, _ToolOutput>{};
  static const _maxStreamedTools = 32;
  // Tools whose accumulated output was evicted while still streaming; their
  // later output is marked lossy. Bounded, oldest first.
  final _evictedTools = <String>{};
  static const _maxEvictedTools = 256;
  static const _maxToolOutputEmitted = 1024 * 1024;
  Object? _dispatchNotification(String method, Object? raw) {
    try {
      final result = _notification(method, raw);
      if (_resolvedUnknownBytes == 0) return result;
      final bytes = _resolvedUnknownBytes;
      _resolvedUnknownBytes = 0;
      final lines = result is Iterable<Uint8List>
          ? result.toList()
          : <Uint8List>[];
      if (lines.fold<int>(0, (n, line) => n + line.length) > bytes) {
        releaseEarly?.call(bytes);
        throw CodexProtocolException(
          'attributed output exceeds shared reservation',
        );
      }
      late final RuntimeDelivery delivery;
      delivery = RuntimeDelivery(lines, bytes, releaseEarly, () {
        if (identical(_unknownDelivery, delivery)) _unknownDelivery = null;
      });
      return _unknownDelivery = delivery;
    } on Object {
      releaseEarly?.call(_resolvedUnknownBytes);
      _resolvedUnknownBytes = 0;
      rethrow;
    }
  }

  String? _interruptionReason;
  @override
  String? get interruptionReason {
    if (_interruptionReason != null) return _interruptionReason;
    final unknown = _children.values
        .where((c) => c.active && c.turn == null)
        .firstOrNull;
    return unknown == null
        ? null
        : 'Child ${unknown.id} turn identity unavailable; interruption cannot be confirmed.';
  }

  @override
  AgentDelegated get delegated => AgentDelegated(
    activeChildren: _children.values.where((c) => c.active).length,
    incomplete: _childrenIncomplete || _unknownNative.isNotEmpty,
  );
  @override
  Map<String, String> get activeNativeTurns => {
    if (root != null && _turnId != null) root!: _turnId!,
    for (final c in _children.values)
      if (c.turn != null) c.id: c.turn!,
  };

  Iterable<Uint8List> _childNotice(String text) {
    final result = normalizeUpdate?.call(
      RuntimeUpdate(AgentEventKind.notice, text),
    );
    return result is Iterable<Uint8List> ? result : const [];
  }

  Iterable<Uint8List> _incomplete(String reason) {
    _childrenIncomplete = true;
    onDelegatedChanged?.call();
    if (_unknownChildNoticed) return const [];
    _unknownChildNoticed = true;
    return _childNotice(reason);
  }

  Iterable<Uint8List> _holdUnknown(String method, Json raw) {
    final bytes = _boundedJsonBytes(raw, 256 * 1024) + 16 * 1024;
    if (_unknownNative.length >= 32 ||
        _unknownBytes + bytes > 256 * 1024 ||
        !(reserveEarly?.call(bytes) ?? true)) {
      return _incomplete(
        'Codex unknown child activity withheld; attribution capacity exceeded.',
      );
    }
    _unknownNative.add(_UnknownNative(method, raw, bytes));
    _unknownBytes += bytes;
    onDelegatedChanged?.call();
    _unknownDeadline ??= Timer(const Duration(seconds: 5), () {
      _unknownDeadline = null;
      final charge = _unknownBytes;
      _unknownBytes = 0;
      _unknownNative.clear();
      final lines = _incomplete(
        'Codex unknown child activity withheld; relationship unavailable after attribution deadline.',
      );
      late final RuntimeDelivery delivery;
      delivery = RuntimeDelivery(lines, charge, releaseEarly, () {
        if (identical(_expiredUnknownDelivery, delivery)) {
          _expiredUnknownDelivery = null;
        }
      });
      _expiredUnknownDelivery = delivery;
      Future<void>.sync(() => client.consumeNotification?.call(delivery))
          .catchError((Object error) {
            delivery.release();
            _onFailure?.call(error);
          });
    });
    if (!_unknownChildNoticed) {
      _unknownChildNoticed = true;
      return _childNotice(
        'Codex unknown child activity pending attribution; content withheld until relationship is available.',
      );
    }
    return const [];
  }

  Iterable<Uint8List> _drainUnknown() {
    if (_drainingUnknown) return const [];
    _drainingUnknown = true;
    final lines = <Uint8List>[];
    try {
      var progress = true;
      while (progress) {
        progress = false;
        for (final pending in _unknownNative.toList()) {
          final thread = pending.raw['thread'];
          final ready = pending.method == 'thread/started' && thread is Json
              ? thread['parentThreadId'] == root ||
                    _children.containsKey(thread['parentThreadId'])
              : _children.containsKey(pending.raw['threadId']);
          if (!ready) continue;
          _unknownNative.remove(pending);
          _unknownBytes -= pending.bytes;
          _resolvedUnknownBytes += pending.bytes;
          final value = _notification(pending.method, pending.raw);
          if (value is Iterable<Uint8List>) lines.addAll(value);
          progress = true;
        }
      }
      if (_unknownNative.isEmpty) {
        _unknownDeadline?.cancel();
        _unknownDeadline = null;
      }
      onDelegatedChanged?.call();
    } finally {
      _drainingUnknown = false;
    }
    return lines;
  }

  /// Reclassifies activity held while the root was still unknown. Root
  /// notifications held then carry no delegated activity and are dropped;
  /// held child announcements under the now known root are attributed.
  void _reclassifyHeld() {
    for (final pending in _unknownNative.toList()) {
      if (pending.method == 'thread/started' ||
          pending.raw['threadId'] != root) {
        continue;
      }
      _unknownNative.remove(pending);
      _unknownBytes -= pending.bytes;
      releaseEarly?.call(pending.bytes);
    }
    final lines = _drainUnknown().toList();
    final bytes = _resolvedUnknownBytes;
    _resolvedUnknownBytes = 0;
    if (bytes == 0) return;
    if (lines.fold<int>(0, (n, line) => n + line.length) > bytes) {
      releaseEarly?.call(bytes);
      throw CodexProtocolException(
        'attributed output exceeds shared reservation',
      );
    }
    late final RuntimeDelivery delivery;
    delivery = RuntimeDelivery(lines, bytes, releaseEarly, () {
      if (identical(_unknownDelivery, delivery)) _unknownDelivery = null;
    });
    _unknownDelivery = delivery;
    Future<void>.sync(() => client.consumeNotification?.call(delivery))
        .catchError((Object error) {
          delivery.release();
          _onFailure?.call(error);
        });
  }

  Iterable<Uint8List> _registerChild(
    String id,
    String parent, {
    String task = '',
    String? status,
  }) {
    if (id == root ||
        parent == id ||
        (parent != root && !_children.containsKey(parent))) {
      return _incomplete(
        'Codex unknown child $id activity withheld; relationship unavailable.',
      );
    }
    final existing = _children[id];
    if (existing != null && existing.parent != parent) {
      return _incomplete(
        'Codex child $id relationship changed; delegated activity incomplete.',
      );
    }
    if (existing == null && _children.length >= 64) {
      return _incomplete(
        'Codex delegated activity incomplete: 64 child identities tracked; extra content withheld.',
      );
    }
    final child = _children.putIfAbsent(
      id,
      () => NativeChild(id, parent, task: clampUtf8(task, 4096)),
    );
    // thread/started registers a child without its task; a later spawn item
    // for the same, already validated parent supplies it.
    if (child.task.isEmpty && task.isNotEmpty) {
      child.task = clampUtf8(task, 4096);
    }
    if (status != null) child.status = status;
    onDelegatedChanged?.call();
    final result = normalizeUpdate?.call(
      RuntimeUpdate(
        AgentEventKind.child,
        '',
        event: AgentEvent.fromJson({
          'kind': 'child',
          'rootThreadId': root,
          'threadId': id,
          'parentThreadId': parent,
          'status': child.status,
          'text': child.task,
        }),
      ),
    );
    return (result is Iterable<Uint8List> ? result : const <Uint8List>[])
        .followedBy(_drainUnknown());
  }

  Iterable<Uint8List> _relationshipItem(Json item, String sender) {
    if (sender.isEmpty || clampJsonString(sender, 4096) != sender) {
      return _incomplete(
        'Codex collaboration relationship unavailable; delegated activity incomplete.',
      );
    }
    if (sender != root && !_children.containsKey(sender)) {
      return _holdUnknown('item/completed', {
        'threadId': sender,
        'turnId': 'relationship',
        'item': item,
      });
    }
    final receivers = item['receiverThreadIds'];
    final states = item['agentsStates'];
    if (item['senderThreadId'] != sender ||
        receivers is! List ||
        receivers.length > 64 ||
        (states != null && states is! Json)) {
      return _incomplete(
        'Codex collaboration relationship unavailable; delegated activity incomplete.',
      );
    }
    final ids = <String>[];
    // Validate optional shapes before any callbacks or registry mutation.
    for (final id in receivers) {
      if (id is! String || id.isEmpty || clampJsonString(id, 4096) != id) {
        return _incomplete(
          'Codex child metadata unavailable; delegated activity incomplete.',
        );
      }
      ids.add(id);
    }
    final lines = <Uint8List>[];
    for (final id in ids) {
      if (item['tool'] == 'spawnAgent') {
        lines.addAll(
          _registerChild(
            id,
            sender,
            task: item['prompt'] is String ? item['prompt']! as String : '',
          ),
        );
      }
      final child = _children[id];
      final state = states is Json ? states[id] : null;
      final status = state is Json ? state['status'] : null;
      if (child == null) {
        lines.addAll(
          _incomplete(
            'Codex child relationship unavailable; delegated activity incomplete.',
          ),
        );
        continue;
      }
      if (child.turn != null || child.ended.isNotEmpty) {
        // A snapshot carries no child turn identity, so it may be older than
        // the live child turn or than an observed turn end. Native turn
        // events settle the child; only a new turn/started revives it. A
        // shutdown report only marks delegated activity incomplete.
        if (status == 'shutdown') _childrenIncomplete = true;
      } else if (status == 'completed' ||
          status == 'interrupted' ||
          status == 'errored' ||
          status == 'shutdown') {
        child.status = status == 'completed'
            ? 'completed'
            : status == 'interrupted'
            ? 'interrupted'
            : status == 'errored'
            ? 'error'
            : 'disconnected';
        if (status == 'shutdown') _childrenIncomplete = true;
      } else if (status == 'running' || status == 'pendingInit') {
        child.status = 'running';
      } else if (status != null || _historyLoading) {
        child.status = 'unknown';
        _childrenIncomplete = true;
      }
      onDelegatedChanged?.call();
      final event = normalizeUpdate?.call(
        RuntimeUpdate(
          AgentEventKind.child,
          '',
          event: AgentEvent.fromJson({
            'kind': 'child',
            'rootThreadId': root,
            'threadId': child.id,
            'parentThreadId': child.parent,
            'status': child.status,
            'text': child.task,
          }),
        ),
      );
      if (event is Iterable<Uint8List>) lines.addAll(event);
    }
    return lines;
  }

  bool _nativeExited = false;
  @override
  void observeExit() {
    _nativeExited = true;
  }

  bool _steeringUnavailable = false;
  final _itemFlags = <String, int>{};
  bool _identityOmissionPending = false;
  bool _identityOmissionShown = false;
  bool _seenItem(String key, int mask) => ((_itemFlags[key] ?? 0) & mask) != 0;
  void _markItem(String key, int mask) {
    if (!_itemFlags.containsKey(key) && _itemFlags.length >= 4096) {
      _itemFlags.remove(_itemFlags.keys.first);
      if (!_identityOmissionShown) _identityOmissionPending = true;
    }
    _itemFlags[key] = (_itemFlags[key] ?? 0) | mask;
  }

  Completer<RuntimeTurnResult>? _turn;
  final _early = <_EarlyNative>[];
  int _earlyBytes = 0;
  RuntimeDelivery? _delivery;
  // The root turn's end, parsed from the buffer while its transcript delivery
  // still waits for credit; Stop settles from it without waiting.
  (String, RuntimeTurnResult)? _bufferedEnd;
  void Function(Object)? _onFailure;
  @override
  set onFailure(void Function(Object)? handler) => _onFailure = handler;
  @override
  String? get turnId => _turnId;
  @override
  RuntimeTransport get transport => client;
  @override
  bool get largeLineOwned => client.largeLineOwned;
  @override
  bool get largeLineWaiting => client.largeLineWaiting;
  @override
  Future<RuntimeIdentity> initialize() async {
    final i = await client.initialize();
    if (i.version != null && i.version != version) {
      throw CodexProtocolException('Codex initialization version mismatch');
    }
    return RuntimeIdentity(
      'codex-app-server',
      version,
      AdapterClaims(const [
        'prompt',
        'streaming',
        'tools',
        'permissions',
        'cancel',
        'steer',
        'questions',
        'load',
      ], null),
    );
  }

  /// Start-only `account-unauthenticated` preflight. It holds only when the
  /// effective provider for [cwd] is absent or OpenAI, no account is signed in
  /// and OpenAI authentication is required. Every other answer, error or
  /// timeout fails open: the start continues and nothing is recorded.
  Future<bool> _signedOutOfOpenAi(String cwd) async {
    if (!authSignals.contains(CodexAuthSignal.accountUnauthenticated)) {
      return false;
    }
    const timeout = Duration(seconds: 10);
    try {
      final openAi = await client.request<bool>(
        'config/read',
        {'cwd': cwd},
        timeout: timeout,
        decodeResult: (result) {
          if (result is! Json || result['config'] is! Json) return false;
          final config = result['config']! as Json;
          return !config.containsKey('model_provider') ||
              config['model_provider'] == 'openai';
        },
      );
      if (!openAi) return false;
      return await client.request<bool>(
        'account/read',
        {'refreshToken': false},
        timeout: timeout,
        decodeResult: (result) =>
            result is Json &&
            result.containsKey('account') &&
            result['account'] == null &&
            result['requiresOpenaiAuth'] == true,
      );
    } on CodexRemoteException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  @override
  Future<String> newSession(
    String cwd, {
    List<Json> mcpServers = const [],
    void Function(String)? onCreated,
  }) async {
    if (await _signedOutOfOpenAi(cwd)) {
      throw CodexRemoteException(
        null,
        'Codex is not signed in',
        isAuthenticationRequired: true,
      );
    }
    return _startThread(cwd, onCreated);
  }

  Future<String> _startThread(String cwd, void Function(String)? onCreated) =>
      client.request(
        'thread/start',
        {'cwd': cwd, 'config': ?_privateToolConfig},
        decodeResult: (result) {
          if (result is! Json || result['thread'] is! Json) {
            throw CodexProtocolException('invalid thread/start');
          }
          final id = _identity(result['thread']! as Json, 'id');
          for (final key in [
            'model',
            'modelProvider',
            'cwd',
            'approvalsReviewer',
          ]) {
            if (result[key] is! String) {
              throw CodexProtocolException('invalid thread/start $key');
            }
          }
          final policy = result['approvalPolicy'];
          if (policy is! String &&
              !(policy is Json && policy['granular'] is Json)) {
            throw CodexProtocolException('invalid thread/start approvalPolicy');
          }
          if (result['sandbox'] is! Json) {
            throw CodexProtocolException('invalid thread/start sandbox');
          }
          root = id;
          if (_startupThreads.any((thread) => thread != id)) {
            _childrenIncomplete = true;
            onDelegatedChanged?.call();
          }
          _startupThreads.clear();
          _reclassifyHeld();
          onCreated?.call(id);
          return id;
        },
      );
  @override
  Future<void> loadSession(
    String id,
    String cwd, {
    List<Json> mcpServers = const [],
  }) async {
    root = id;
    _historyLoading = true;
    _historyFailure = null;
    final active = Stopwatch()..start();
    Future<T> read<T>(
      String method,
      Json params, {
      required T Function(Object?) decodeResult,
    }) {
      final remaining = const Duration(seconds: 60) - active.elapsed;
      if (remaining <= Duration.zero) {
        _historyUnavailable('native history active deadline exceeded');
      }
      return client.request<T>(
        method,
        params,
        decodeResult: decodeResult,
        timeout: remaining,
      );
    }

    Future<void> deliver(RuntimeDelivery delivery) async {
      active.stop();
      try {
        await client.consumeNotification?.call(delivery);
      } finally {
        delivery.release();
        if (identical(_historyPending, delivery)) _historyPending = null;
        active.start();
      }
    }

    try {
      final mode = await read<String>(
        'thread/read',
        {'threadId': id, 'includeTurns': false},
        decodeResult: (result) =>
            _historyMetadata(result, id, beforeResume: true),
      );
      final history = await read<RuntimeDelivery>(
        'thread/resume',
        {
          'threadId': id,
          'cwd': cwd,
          'excludeTurns': mode == 'paginated',
          'config': ?_privateToolConfig,
        },
        decodeResult: (result) {
          final actualMode = _historyMetadata(result, id);
          if (actualMode != mode) {
            _historyUnavailable('native history mode changed');
          }
          if (mode == 'paginated') return _reserveHistoryPage(const []);
          final thread = (result! as Json)['thread']! as Json;
          final turns = thread['turns'];
          if (turns is! List) _historyUnavailable('native history was omitted');
          if (turns.isEmpty) _historyUnavailable('native history is empty');
          final output = <Uint8List>[];
          var count = 0;
          for (final turn in turns) {
            if (turn is! Json ||
                turn['items'] is! List ||
                (turn['itemsView'] != null && turn['itemsView'] != 'full') ||
                !const [
                  'completed',
                  'interrupted',
                  'failed',
                ].contains(turn['status'])) {
              _historyUnavailable('native history is incomplete or active');
            }
            final turnId = _identity(turn, 'id');
            for (final item in turn['items'] as List) {
              count++;
              output.addAll(_historyItem(turnId, item));
              _checkHistoryDisplay(output);
            }
          }
          if (count == 0) _historyUnavailable('native history is empty');
          return _reserveHistoryPage(output);
        },
      );
      await deliver(history);
      if (mode == 'paginated') {
        String? cursor;
        var count = 0;
        do {
          final page = await read<(RuntimeDelivery, String?)>(
            'thread/items/list',
            {
              'threadId': id,
              'limit': 50,
              'sortDirection': 'asc',
              'cursor': ?cursor,
            },
            decodeResult: (result) {
              if (result is! Json || result['data'] is! List) {
                _historyUnavailable('native item history was omitted');
              }
              final data = result['data']! as List;
              if (data.length > 50) {
                _historyUnavailable(
                  'native history exceeded requested page size',
                );
              }
              final output = <Uint8List>[];
              for (final entry in data) {
                if (entry is! Json) {
                  _historyUnavailable('invalid native history entry');
                }
                count++;
                output.addAll(
                  _historyItem(_identity(entry, 'turnId'), entry['item']),
                );
                _checkHistoryDisplay(output);
              }
              final next = result['nextCursor'];
              if (next != null &&
                  (next is! String ||
                      next.isEmpty ||
                      next == cursor ||
                      clampJsonString(next, 4096) != next)) {
                _historyUnavailable('native history cursor is invalid');
              }
              if (data.isEmpty && next != null) {
                _historyUnavailable('native history cursor has no progress');
              }
              return (_reserveHistoryPage(output), next as String?);
            },
          );
          await deliver(page.$1);
          cursor = page.$2;
        } while (cursor != null);
        if (count == 0) _historyUnavailable('native history is empty');
      }
      await read<String>('thread/read', {
        'threadId': id,
        'includeTurns': false,
      }, decodeResult: (result) => _historyMetadata(result, id));
      for (final key in _historyLiveKeys) {
        if (!_seenItem(key.$1, 2)) {
          _historyUnavailable('native history changed during replay');
        }
      }
      if (_historyFailure case final reason?) _historyUnavailable(reason);
    } on CodexRemoteException catch (error) {
      _historyUnavailable('native history request failed: ${error.message}');
    } finally {
      active.stop();
      _historyPending?.release();
      _historyPending = null;
      _historyLoading = false;
      _historyLiveKeys.clear();
      releaseEarly?.call(_historyLiveBytes);
      _historyLiveBytes = 0;
    }
  }

  bool _historyLoading = false;
  RuntimeDelivery? _historyPending;
  RuntimeDelivery _reserveHistoryPage(List<Uint8List> lines) {
    final bytes = lines.fold<int>(0, (total, line) => total + line.length);
    final transferred = _resolvedUnknownBytes;
    final additional = bytes > transferred ? bytes - transferred : 0;
    if (!(reserveEarly?.call(additional) ?? true)) {
      _historyUnavailable('native history exceeded shared relay capacity');
    }
    _resolvedUnknownBytes = 0;
    return _historyPending = RuntimeDelivery(
      lines,
      bytes > transferred ? bytes : transferred,
      releaseEarly,
      null,
    );
  }

  String? _historyFailure;
  final _historyLiveKeys = <(String, int)>[];
  int _historyLiveBytes = 0;
  Never _historyUnavailable(String reason) {
    if (_historyLoading) _historyFailure ??= reason;
    throw CodexOptionalUnsupported('native history', reason);
  }

  String _historyMetadata(
    Object? result,
    String expected, {
    bool beforeResume = false,
  }) {
    if (result is! Json || result['thread'] is! Json) {
      _historyUnavailable('native thread metadata was omitted');
    }
    final thread = result['thread']! as Json;
    if (thread['id'] != expected) {
      _historyUnavailable('native thread identity changed');
    }
    final status = thread['status'];
    if (status is! Json ||
        !(beforeResume ? const ['notLoaded', 'idle'] : const ['idle']).contains(
          status['type'],
        )) {
      _historyUnavailable(
        'native thread is active or its idle state is unavailable',
      );
    }
    final mode = thread['historyMode'] ?? 'legacy';
    if (mode != 'legacy' && mode != 'paginated') {
      _historyUnavailable('unsupported native history mode');
    }
    return mode as String;
  }

  void _checkHistoryDisplay(List<Uint8List> output) {
    if (output.fold<int>(0, (n, line) => n + line.length) > 256 * 1024) {
      _historyUnavailable(
        'native history page exceeds shared display capacity',
      );
    }
  }

  Iterable<Uint8List> _historyItem(String turn, Object? raw) {
    if (raw is! Json) _historyUnavailable('invalid native history item');
    final id = _identity(raw, 'id');
    final key = _nativeKey([root, turn, id]);
    for (var i = _historyLiveKeys.length - 1; i >= 0; i--) {
      final pending = _historyLiveKeys[i];
      if (pending.$1 != key) continue;
      _historyLiveKeys.removeAt(i);
      _historyLiveBytes -= pending.$2;
      releaseEarly?.call(pending.$2);
    }
    if (raw['type'] == 'collabAgentToolCall') {
      // Same snapshot/live identity accounting as other items; relationships
      // are still rebuilt from every snapshot record.
      _markItem(key, 2);
      return _relationshipItem(
        raw,
        raw['senderThreadId'] is String ? raw['senderThreadId']! as String : '',
      );
    }
    if (_seenItem(key, 2)) return const [];
    RuntimeUpdate? update;
    if (raw['type'] == 'userMessage') {
      final content = raw['content'];
      if (content is! List) _historyUnavailable('invalid native user history');
      final text = StringBuffer();
      for (final part in content) {
        if (part is! Json ||
            part['type'] != 'text' ||
            part['text'] is! String) {
          _historyUnavailable('unsupported native user history content');
        }
        if (text.length + (part['text']! as String).length >
            maxAgentTextChunkBytes) {
          _historyUnavailable('native user history exceeds display capacity');
        }
        text.write(part['text']);
      }
      update = RuntimeUpdate(AgentEventKind.user, text.toString());
    } else {
      update = _item('item/completed', {'turnId': turn, 'item': raw});
    }
    _markItem(key, 2);
    Iterable<Uint8List> prefix = const [];
    if (_identityOmissionPending) {
      _identityOmissionPending = false;
      _identityOmissionShown = true;
      final notice = normalizeUpdate?.call(
        RuntimeUpdate(
          AgentEventKind.notice,
          'Native item identity history truncated at 4096 keys; older duplicate identities are no longer retained.',
        ),
      );
      if (notice is Iterable<Uint8List>) prefix = notice;
    }
    final output = update == null ? null : normalizeUpdate?.call(update);
    return output is Iterable<Uint8List> ? prefix.followedBy(output) : prefix;
  }

  @override
  Future<void> resumeSession(
    String id,
    String cwd, {
    List<Json> mcpServers = const [],
  }) => throw RpcException(
    ErrorCode.resumeUnavailable,
    'native history unavailable',
  );
  @override
  Future<RuntimeTurnResult> prompt(String id, String text) {
    if (_turn != null) {
      throw RpcException(
        ErrorCode.turnRunning,
        'native turn is already active',
      );
    }
    final completion = Completer<RuntimeTurnResult>();
    _turn = completion;
    _turnId = null;
    _earlyId = null;
    Future<String> accepted;
    try {
      accepted = client.request(
        'turn/start',
        {
          'threadId': id,
          'input': [
            {'type': 'text', 'text': text},
          ],
        },
        requireAdmission: true,
        decodeResult: (result) {
          if (result is! Json || result['turn'] is! Json) {
            throw CodexProtocolException('invalid turn/start');
          }
          final native = result['turn']! as Json;
          final turn = _identity(native, 'id');
          if (native['status'] is! String || native['items'] is! List) {
            throw CodexProtocolException('invalid turn/start state');
          }
          _turnId = turn;
          onTurnIdentity?.call();
          return turn;
        },
      );
    } on Object {
      _turn = null;
      rethrow;
    }
    accepted.then<void>(
      (_) {},
      onError: (Object error, StackTrace st) {
        if (identical(_turn, completion)) {
          _retireMapping(error);
          if (error is TimeoutException) {
            client.close().ignore();
            _onFailure?.call(error);
          }
        }
      },
    );
    return completion.future;
  }

  void _retireMapping(Object error) {
    final c = _turn;
    _turn = null;
    _turnId = null;
    _earlyId = null;
    releaseEarly?.call(_earlyBytes);
    _earlyBytes = 0;
    _early.clear();
    _delivery?.release();
    _delivery = null;
    _historyPending?.release();
    _historyPending = null;
    releaseEarly?.call(_historyLiveBytes);
    _historyLiveBytes = 0;
    _historyLiveKeys.clear();
    _unknownDeadline?.cancel();
    _unknownDeadline = null;
    releaseEarly?.call(_unknownBytes);
    _unknownBytes = 0;
    _unknownNative.clear();
    releaseEarly?.call(_resolvedUnknownBytes);
    _resolvedUnknownBytes = 0;
    _unknownDelivery?.release();
    _unknownDelivery = null;
    _expiredUnknownDelivery?.release();
    _expiredUnknownDelivery = null;
    if (_children.isNotEmpty && !_childrenDisconnected) {
      _childrenDisconnected = true;
      _childrenIncomplete = true;
      final lines = <Uint8List>[];
      for (final child in _children.values) {
        if (!child.active) continue;
        child.status = 'disconnected';
        final output = normalizeUpdate?.call(
          RuntimeUpdate(
            AgentEventKind.child,
            '',
            event: AgentEvent.fromJson({
              'kind': 'child',
              'rootThreadId': root,
              'threadId': child.id,
              'parentThreadId': child.parent,
              'status': 'disconnected',
              'text': child.task,
            }),
          ),
        );
        if (output is Iterable<Uint8List>) lines.addAll(output);
      }
      onDelegatedChanged?.call();
      final bytes = lines.fold<int>(0, (n, line) => n + line.length);
      if (lines.isNotEmpty && (reserveEarly?.call(bytes) ?? true)) {
        final delivery = RuntimeDelivery(lines, bytes, releaseEarly, null);
        Future<void>.sync(() => client.consumeNotification?.call(delivery))
            .catchError((Object error) {
              delivery.release();
            });
      }
    }
    if (c != null && !c.isCompleted) c.completeError(error);
  }

  @override
  Future<void> close() async {
    _retireMapping(CodexProtocolException('native transport closed'));
    await client.close();
  }

  void _complete(RuntimeTurnResult result) {
    final completedTurn = _turnId;
    final c = _turn;
    _bufferedEnd = null;
    _turn = null;
    _turnId = null;
    _earlyId = null;
    onRetired?.call(RuntimeRetired(root, completedTurn));
    if (c != null && !c.isCompleted) c.complete(result);
  }

  void _stage(
    String turn, {
    RuntimeUpdate? update,
    RuntimeTurnResult? terminal,
    Object? interaction,
    int? charge,
  }) {
    final value =
        update?.event?.toJson() ??
        {
          'kind': update?.kind.name,
          'text': update?.text,
          'truncated': update?.truncated,
          if (update?.question != null)
            'questions': [
              for (final q in update!.question!.questions) q.toJson(),
            ],
        };
    final bytes =
        charge ??
        (update == null ? 256 : _boundedJsonBytes(value, 256 * 1024) + 1024);
    if (_early.length >= 64 ||
        _earlyBytes + bytes > 256 * 1024 ||
        !(reserveEarly?.call(bytes) ?? true)) {
      throw CodexProtocolException(
        'early native correlation capacity exceeded',
      );
    }
    _earlyBytes += bytes;
    _early.add(
      _EarlyNative(
        turn,
        bytes,
        update: update,
        terminal: terminal,
        interaction: interaction,
      ),
    );
  }

  Object? _takeBuffered() {
    if (_turnId == null || _early.isEmpty) return null;
    final lines = <Uint8List>[];
    RuntimeTurnResult? terminal;
    // A turn whose completion is already buffered never offers its requests:
    // they are retired now, not after the transcript delivery drains.
    final ended = _early.any((r) => r.turn == _turnId && r.terminal != null);
    for (final record in _early) {
      if (record.turn != _turnId || (ended && record.interaction != null)) {
        if (record.interaction case final RuntimePermission p) {
          client.replyAdmitted(p.id, p.cancellation).ignore();
        }
        if (record.interaction case final RuntimeQuestion q) {
          client.replyAdmitted(q.id, {'answers': {}}).ignore();
        }
        continue;
      }
      Object? interactionResult;
      if (record.interaction case final RuntimePermission p) {
        interactionResult = onPermission?.call(p);
      }
      if (record.interaction case final RuntimeQuestion q) {
        interactionResult = onQuestion?.call(q);
      }
      if (interactionResult is Iterable<Uint8List>) {
        lines.addAll(interactionResult);
      }
      if (record.update case final update?) {
        final normalized = normalizeUpdate?.call(update);
        if (normalized is Iterable<Uint8List>) lines.addAll(normalized);
      }
      terminal ??= record.terminal;
    }
    final turn = _turnId!;
    final bytes = _earlyBytes;
    _early.clear();
    _earlyBytes = 0;
    if (lines.fold<int>(0, (n, line) => n + line.length) > bytes) {
      throw CodexProtocolException(
        'early normalized output exceeds reserved credit',
      );
    }
    late final RuntimeDelivery delivery;
    delivery = RuntimeDelivery(lines, bytes, releaseEarly, () {
      if (identical(_delivery, delivery)) _delivery = null;
      // A buffered terminal settles Stop exactly like a live one: Stop may
      // have been admitted after the turn identity was published.
      if (terminal case final terminal?) {
        onNativeTurnEnded?.call(root!, turn, terminal);
        _complete(terminal);
      }
    });
    _delivery = delivery;
    if (terminal != null) _bufferedEnd = (turn, terminal);
    return delivery;
  }

  Object? _notification(String method, Object? raw) {
    if (_historyLoading &&
        raw is Json &&
        raw['threadId'] == root &&
        (method.startsWith('item/') ||
            method == 'turn/started' ||
            method == 'turn/completed')) {
      final item = raw['item'];
      if (method != 'item/completed' || item is! Json) {
        _historyUnavailable('native work changed during history replay');
      }
      final key = _nativeKey([
        root,
        _identity(raw, 'turnId'),
        _identity(item, 'id'),
      ]);
      if (_seenItem(key, 2)) return null;
      final bytes = _boundedJsonBytes(raw, 256 * 1024) + 128;
      if (_historyLiveKeys.length >= 64 ||
          _historyLiveBytes + bytes > 256 * 1024 ||
          !(reserveEarly?.call(bytes) ?? true)) {
        _historyUnavailable('native history live buffer capacity exceeded');
      }
      _historyLiveBytes += bytes;
      _historyLiveKeys.add((key, bytes));
      return null;
    }
    if (method == 'serverRequest/resolved' && raw is Json) {
      _identity(raw, 'threadId');
      if (raw['requestId'] is! String && raw['requestId'] is! int) {
        throw CodexProtocolException('invalid resolved request identity');
      }
      if (raw['threadId'] == root || _children.containsKey(raw['threadId'])) {
        // A request still staged before turn/start answered is retired here
        // too, so it is never published and never answered natively.
        _early.removeWhere((record) {
          final staged = switch (record.interaction) {
            final RuntimePermission p => p.id,
            final RuntimeQuestion q => q.id,
            _ => null,
          };
          if (staged == null || staged != raw['requestId']) return false;
          _earlyBytes -= record.bytes;
          releaseEarly?.call(record.bytes);
          return true;
        });
        onRetired?.call(raw['requestId']);
      }
      return null;
    }
    if (method == 'thread/started') {
      if (raw is! Json || raw['thread'] is! Json) {
        return _incomplete(
          'Codex unknown child activity withheld; relationship metadata unavailable.',
        );
      }
      final thread = raw['thread']! as Json;
      final id = thread['id'];
      if (id == root) return null;
      final source = thread['source'];
      final subagent = source is Json ? source['subAgent'] : null;
      final spawn = subagent is Json ? subagent['thread_spawn'] : null;
      final parent =
          thread['parentThreadId'] ??
          (spawn is Json ? spawn['parent_thread_id'] : null);
      if (root == null &&
          parent == null &&
          id is String &&
          id.isNotEmpty &&
          clampJsonString(id, 4096) == id &&
          _startupThreads.length < 8) {
        // The root may announce itself before thread/start answers.
        _startupThreads.add(id);
        return null;
      }
      if (id is! String ||
          id.isEmpty ||
          clampJsonString(id, 4096) != id ||
          parent is! String ||
          parent.isEmpty ||
          clampJsonString(parent, 4096) != parent) {
        return _incomplete(
          'Codex unknown child activity withheld; relationship metadata unavailable.',
        );
      }
      if (parent != root && !_children.containsKey(parent)) {
        return _holdUnknown(method, {
          'thread': {...thread, 'parentThreadId': parent},
        });
      }
      final status = thread['status'];
      return _registerChild(
        id,
        parent,
        status: status is Json && status['type'] == 'active'
            ? 'running'
            : 'unknown',
      );
    }
    if (raw is Json &&
        raw['threadId'] is String &&
        raw['threadId'] != root &&
        !_children.containsKey(raw['threadId'])) {
      return _holdUnknown(method, raw);
    }
    const core = {
      'turn/started',
      'turn/completed',
      'item/agentMessage/delta',
      'item/reasoning/summaryTextDelta',
      'item/started',
      'item/completed',
      'item/commandExecution/outputDelta',
      'item/fileChange/outputDelta',
    };
    if (!core.contains(method)) return null;
    if (raw is! Json) throw CodexProtocolException('invalid $method');
    _identity(raw, 'threadId');
    final turnData = raw['turn'];
    final turn = method == 'turn/completed' || method == 'turn/started'
        ? (turnData is Json
              ? _identity(turnData, 'id')
              : throw CodexProtocolException('invalid turn event'))
        : _identity(raw, 'turnId');
    RuntimeTurnResult? terminal;
    RuntimeUpdate? update;
    final owner = _children[raw['threadId']];
    if (owner != null &&
        method != 'turn/started' &&
        method != 'turn/completed' &&
        owner.turn != turn &&
        owner.ended.contains(turn)) {
      // A child item from a turn that already ended or was replaced must not
      // publish output or recreate controls.
      return null;
    }
    if (raw['item'] case final Json item
        when item['type'] == 'collabAgentToolCall') {
      return _relationshipItem(
        item,
        item['senderThreadId'] is String
            ? item['senderThreadId']! as String
            : '',
      );
    }
    if (method == 'turn/completed') {
      final data = turnData! as Json;
      final status = data['status'];
      if (!const ['completed', 'interrupted', 'failed'].contains(status)) {
        throw CodexProtocolException('invalid native terminal status');
      }
      final nativeError = data['error'];
      if (nativeError != null &&
          (nativeError is! Json || nativeError['message'] is! String)) {
        throw CodexProtocolException('invalid terminal error');
      }
      terminal = RuntimeTurnResult(
        status == 'interrupted'
            ? 'cancelled'
            : status == 'failed'
            ? 'error'
            : 'end_turn',
        isCancelled: status == 'interrupted',
        error: status == 'failed'
            ? CodexRemoteException(
                null,
                nativeError is Json
                    ? nativeError['message']! as String
                    : 'Native turn failed',
                isAuthenticationRequired:
                    authSignals.contains(CodexAuthSignal.turnHttp401) &&
                    _isHttp401(nativeError),
              )
            : null,
      );
    } else if (method == 'item/agentMessage/delta') {
      final itemId = _identity(raw, 'itemId');
      _markItem(_nativeKey([raw['threadId'] as String, turn, itemId]), 1);
      final text = raw['delta'];
      if (text is! String) {
        throw CodexProtocolException('invalid message delta');
      }
      final bounded = clampUtf8(text, maxAgentTextChunkBytes);
      update = RuntimeUpdate(
        AgentEventKind.agentText,
        bounded,
        truncated: bounded.length != text.length,
      );
    } else if (method == 'item/reasoning/summaryTextDelta') {
      // Thinking streams as reasoning summary deltas; the completed reasoning
      // item adds nothing once a delta was shown.
      final itemId = _identity(raw, 'itemId');
      final text = raw['delta'];
      if (text is! String) return null;
      _markItem(_nativeKey([raw['threadId'] as String, turn, itemId]), 1);
      final bounded = clampUtf8(text, maxAgentTextChunkBytes);
      update = RuntimeUpdate(
        AgentEventKind.thought,
        bounded,
        truncated: bounded.length != text.length,
      );
    } else if (method == 'turn/started') {
      if (turnData is! Json || turnData['status'] is! String) {
        throw CodexProtocolException('invalid turn/started');
      }
    } else {
      // Item mapping is reduced to bounded typed updates before leaving the
      // host-wide native line permit, including when the run has become idle.
      update = _item(method, raw);
    }
    final child = _children[raw['threadId']];
    if (child != null) {
      if (method == 'turn/started') {
        if (child.turn != null && child.turn != turn) {
          child.end(child.turn!);
          onRetired?.call(RuntimeRetired(child.id, child.turn));
        }
        child.turn = turn;
        child.status = 'running';
        onDelegatedChanged?.call();
      }
      if (terminal != null) {
        if (child.turn != turn) return null;
        child.end(turn);
        child.turn = null;
        child.status = terminal.error != null
            ? 'error'
            : terminal.isCancelled
            ? 'interrupted'
            : 'completed';
        onRetired?.call(RuntimeRetired(child.id, turn));
        onNativeTurnEnded?.call(child.id, turn, terminal);
        onDelegatedChanged?.call();
      }
      final identity = {
        'rootThreadId': root,
        'threadId': child.id,
        'parentThreadId': child.parent,
      };
      if (update != null) {
        var notice = update.optionalNotice;
        if (_identityOmissionPending) {
          _identityOmissionPending = false;
          _identityOmissionShown = true;
          notice =
              'Native item identity history truncated at 4096 keys; older duplicate identities are no longer retained. ${notice ?? ''}';
        }
        final event =
            update.event ??
            AgentEvent.fromJson({
              'kind': update.kind.name,
              'text': update.text,
              if (update.truncated) 'truncated': true,
            });
        return normalizeUpdate?.call(
          RuntimeUpdate(
            update.kind,
            '',
            optionalNotice: notice,
            event: AgentEvent.fromJson({...event.toJson(), ...identity}),
            question: update.question == null
                ? null
                : RuntimeQuestion(
                    update.question!.id,
                    update.question!.turnId,
                    update.question!.questions,
                    asyncItem: update.question!.asyncItem,
                    threadId: child.id,
                    parentThreadId: child.parent,
                  ),
          ),
        );
      }
      return normalizeUpdate?.call(
        RuntimeUpdate(
          AgentEventKind.child,
          '',
          event: AgentEvent.fromJson({
            'kind': 'child',
            ...identity,
            'status': child.status,
            'text': child.task,
          }),
        ),
      );
    }
    if (raw['threadId'] != root || _turn == null) return null;
    if (update != null &&
        _identityOmissionPending &&
        (_turnId == null || turn == _turnId)) {
      _identityOmissionPending = false;
      _identityOmissionShown = true;
      update = RuntimeUpdate(
        update.kind,
        update.text,
        truncated: update.truncated,
        event: update.event,
        question: update.question,
        optionalNotice:
            'Native item identity history truncated at 4096 keys. ${update.optionalNotice ?? ''}',
      );
    }

    if (_turnId == null) {
      if (update != null || terminal != null) {
        _stage(turn, update: update, terminal: terminal);
      }
      return null;
    }
    if (turn != _turnId) return null;
    if (terminal != null) {
      onNativeTurnEnded?.call(root!, turn, terminal);
      _complete(terminal);
      return null;
    }
    return update == null ? null : normalizeUpdate?.call(update);
  }

  RuntimeUpdate? _item(String method, Json raw) {
    if (method.endsWith('outputDelta')) {
      final id = _identity(raw, 'itemId');
      final delta = raw['delta'];
      if (delta is! String) throw CodexProtocolException('invalid tool delta');
      final key = _nativeKey([raw['threadId'] as String? ?? root, id]);
      var output = _toolOutput.remove(key);
      if (output == null) {
        output = _ToolOutput()..lossy = _evictedTools.remove(key);
        if (_toolOutput.length >= _maxStreamedTools) {
          final evicted = _toolOutput.keys.first;
          _toolOutput.remove(evicted);
          _evictedTools.add(evicted);
          if (_evictedTools.length > _maxEvictedTools) {
            _evictedTools.remove(_evictedTools.first);
          }
        }
      }
      _toolOutput[key] = output;
      if (output.emitted >= _maxToolOutputEmitted) {
        if (output.capped) return null;
        output.capped = true;
        output.lossy = true;
      } else {
        final joined = '${output.text}$delta';
        output.text = clampUtf8(joined, maxAgentToolItemBytes);
        output.lossy |= output.text != joined;
      }
      output.emitted += output.text.length;
      return RuntimeUpdate(
        AgentEventKind.toolUpdate,
        '',
        event: _toolWithLoss(
          AgentEvent.tool(
            toolCallId: key,
            update: true,
            content: [
              {
                'type': 'content',
                'content': {'type': 'text', 'text': output.text},
              },
            ],
          ),
          truncated: output.lossy,
        ),
      );
    }
    final item = raw['item'];
    if (item is! Json) throw CodexProtocolException('invalid native item');
    final id = _identity(item, 'id');
    final type = item['type'];
    if (type is! String) throw CodexProtocolException('missing item type');
    final completed = method == 'item/completed';
    if (type == 'agentMessage') {
      final text = item['text'];
      if (text is! String) {
        throw CodexProtocolException('invalid agent message item');
      }
      if (!completed) return null;
      final key = _nativeKey([
        raw['threadId'] as String? ?? root,
        raw['turnId'] as String,
        id,
      ]);
      if (_seenItem(key, 2)) return null;
      _markItem(key, 2);
      RuntimeQuestion? question;
      String? optionalNotice;
      final nativeQuestions = item['questions'];
      if (nativeQuestions != null) {
        try {
          if (_steeringUnavailable) {
            throw const FormatException('native steering unavailable');
          }
          if (nativeQuestions is! List ||
              _boundedJsonBytes(nativeQuestions, 64 * 1024) > 64 * 1024) {
            throw const FormatException('invalid async questions');
          }
          final questions = <AgentQuestion>[];
          for (var i = 0; i < nativeQuestions.length; i++) {
            final q = nativeQuestions[i];
            if (q is! Json || q['title'] is! String) {
              throw const FormatException('invalid async question');
            }
            final options = q['options'];
            if (options != null &&
                (options is! List || options.any((o) => o is! String))) {
              throw const FormatException('invalid async options');
            }
            questions.add(
              AgentQuestion(
                id: 'async-$i',
                header: 'Question',
                text: q['title']! as String,
                allowOther: options == null,
                options: [
                  if (options is List)
                    for (final option in options)
                      AgentQuestionOption(
                        id: option! as String,
                        label: option as String,
                      ),
                ],
              ),
            );
          }
          if (questions.isNotEmpty) {
            question = RuntimeQuestion(
              'item:$id',
              _identity(raw, 'turnId'),
              questions,
              asyncItem: true,
            );
          }
        } on Object {
          optionalNotice =
              'Async questions unavailable: unsupported optional shape.';
        }
      }
      final content = _seenItem(key, 1) ? '' : text;
      final bounded = clampUtf8(content, maxAgentTextChunkBytes);
      return RuntimeUpdate(
        AgentEventKind.agentText,
        bounded,
        truncated: content.length != bounded.length,
        question: question,
        optionalNotice: optionalNotice,
      );
    }
    if (type == 'collabAgentToolCall') {
      final lines = _relationshipItem(
        item,
        raw['threadId'] as String? ?? root!,
      );
      if (lines.isNotEmpty) {
        return RuntimeUpdate(
          AgentEventKind.notice,
          'Delegated relationships updated.',
        );
      }
      return null;
    }
    if (type == 'reasoning') return _reasoning(raw, item, id, completed);
    if (type == 'mcpToolCall') return _mcpToolCall(raw, item, id, completed);
    if (type == 'plan' && item['text'] is String) {
      final text = item['text']! as String;
      return RuntimeUpdate(
        AgentEventKind.plan,
        '',
        event: AgentEvent.plan([
          {
            'content': clampUtf8(text, 1024),
            'status': completed ? 'completed' : 'in_progress',
          },
        ]),
      );
    }
    if (type != 'commandExecution' && type != 'fileChange') return null;
    final status = item['status'];
    if (status is! String) throw CodexProtocolException('invalid tool status');
    String title;
    List<Json>? content;
    var truncated = false;
    var omitted = 0;
    if (type == 'commandExecution') {
      if (item['command'] is! String ||
          item['commandActions'] is! List ||
          item['cwd'] is! String) {
        throw CodexProtocolException('invalid command item');
      }
      title = clampUtf8(item['command']! as String, 4096);
      final output = item['aggregatedOutput'];
      if (output != null && output is! String) {
        throw CodexProtocolException('invalid command output');
      }
      if (output is String) {
        final bounded = clampUtf8(output, maxAgentToolItemBytes);
        truncated = bounded != output;
        content = [
          {
            'type': 'content',
            'content': {'type': 'text', 'text': bounded},
          },
        ];
      }
    } else {
      final changes = item['changes'];
      if (changes is! List) {
        throw CodexProtocolException('invalid file change item');
      }
      title = 'File changes';
      content = [];
      var bytes = 0;
      for (final change in changes) {
        if (change is! Json ||
            change['path'] is! String ||
            change['diff'] is! String ||
            change['kind'] is! Json) {
          throw CodexProtocolException('invalid file change path/diff/kind');
        }
        final kind = change['kind']! as Json;
        if (!const ['add', 'delete', 'update'].contains(kind['type']) ||
            (kind['type'] == 'update' &&
                kind['move_path'] != null &&
                kind['move_path'] is! String)) {
          throw CodexProtocolException('invalid file change kind');
        }
        // Validate every known core entry even after the display prefix fills.
        // Retained values share the existing encoded event/item budget.
        if (content.length >= 64) {
          omitted++;
          truncated = true;
          continue;
        }
        final path = clampUtf8(change['path']! as String, 4096);
        final diff = clampUtf8(
          change['diff']! as String,
          maxAgentToolItemBytes,
        );
        final bounded = <String, Object?>{
          'type': 'diff',
          'path': path,
          'newText': diff,
        };
        final size = _boundedJsonBytes(bounded, maxAgentEventBytes);
        if (bytes + size > maxAgentEventBytes - 16 * 1024) {
          omitted++;
          truncated = true;
          continue;
        }
        bytes += size;
        content.add(bounded);
        truncated |= path != change['path'] || diff != change['diff'];
      }
    }
    if (completed) {
      final toolKey = _nativeKey([raw['threadId'] as String? ?? root, id]);
      _toolOutput.remove(toolKey);
      _evictedTools.remove(toolKey);
    }
    return RuntimeUpdate(
      completed ? AgentEventKind.toolUpdate : AgentEventKind.tool,
      '',
      event: _toolWithLoss(
        AgentEvent.tool(
          toolCallId: _nativeKey([raw['threadId'] as String? ?? root, id]),
          update: completed,
          title: title,
          status: status,
          toolKind: type,
          content: content,
        ),
        truncated: truncated,
        omitted: omitted,
      ),
    );
  }

  /// A completed reasoning item shows its summary (or, without one, its
  /// content) as thinking, unless its summary already streamed. A shape this
  /// version does not match is ignored like an unknown item.
  RuntimeUpdate? _reasoning(Json raw, Json item, String id, bool completed) {
    if (!completed) return null;
    final key = _nativeKey([
      raw['threadId'] as String? ?? root,
      raw['turnId'] as String,
      id,
    ]);
    if (_seenItem(key, 2)) return null;
    _markItem(key, 2);
    if (_seenItem(key, 1)) return null;
    String joined(Object? parts) =>
        parts is List ? parts.whereType<String>().join('\n\n') : '';
    var text = joined(item['summary']);
    if (text.isEmpty) text = joined(item['content']);
    if (text.isEmpty) return null;
    final bounded = clampUtf8(text, maxAgentTextChunkBytes);
    return RuntimeUpdate(
      AgentEventKind.thought,
      bounded,
      truncated: bounded.length != text.length,
    );
  }

  /// An MCP tool call, Kumiko's own tools included, is a tool card titled
  /// `server.tool` with its native status and its text result or error. A
  /// shape this version does not match is ignored like an unknown item.
  RuntimeUpdate? _mcpToolCall(Json raw, Json item, String id, bool completed) {
    final server = item['server'], tool = item['tool'];
    final status = item['status'];
    if (server is! String || tool is! String || status is! String) {
      return null;
    }
    final parts = <String>[];
    if (item['result'] case {'content': final List<Object?> blocks}) {
      for (final block in blocks) {
        if (block case {'type': 'text', 'text': final String text}) {
          parts.add(text);
        }
      }
    }
    if (item['error'] case {'message': final String message}) {
      parts.add(message);
    }
    final text = parts.join('\n');
    final bounded = clampUtf8(text, maxAgentToolItemBytes);
    final key = _nativeKey([raw['threadId'] as String? ?? root, id]);
    return RuntimeUpdate(
      completed ? AgentEventKind.toolUpdate : AgentEventKind.tool,
      '',
      event: _toolWithLoss(
        AgentEvent.tool(
          toolCallId: key,
          update: completed,
          title: clampUtf8('$server.$tool', 4096),
          status: status,
          toolKind: 'mcpToolCall',
          content: text.isEmpty
              ? null
              : [
                  {
                    'type': 'content',
                    'content': {'type': 'text', 'text': bounded},
                  },
                ],
        ),
        truncated: bounded != text,
      ),
    );
  }

  AgentEvent _toolWithLoss(
    AgentEvent event, {
    bool truncated = false,
    int omitted = 0,
  }) => AgentEvent.fromJson({
    ...event.toJson(),
    if (truncated) 'truncated': true,
    if (truncated) 'contentTruncated': true,
    if (omitted > 0) 'omittedItems': omitted,
  });

  @override
  Future<void> cancel(String id) {
    if (activeNativeTurns.isEmpty) return Future.value();
    try {
      return cancelWithPermissions(id, const []);
    } on Object catch (error, stack) {
      return Future.error(error, stack);
    }
  }

  @override
  Future<void> cancelWithPermissions(String id, Iterable<Object> requests) {
    final turns = activeNativeTurns;
    final ended = _bufferedEnd;
    if (ended != null && ended.$1 == _turnId && root != null) {
      // The root turn already ended; only its transcript delivery is pending.
      // It is not interrupted natively, and Stop learns its end now.
      final thread = root!;
      turns.remove(thread);
      scheduleMicrotask(() {
        if (identical(_bufferedEnd, ended)) {
          onNativeTurnEnded?.call(thread, ended.$1, ended.$2);
        }
      });
    }
    // A root turn still awaiting its identity cannot be addressed; Stop must
    // not interrupt only the known child turns and report the root stopped.
    if (_turn != null && _turnId == null) {
      throw RpcException(
        ErrorCode.busy,
        'native turn identity is not yet available',
      );
    }
    _interruptionReason = null;
    return client
        .interruptBatch(
          turns,
          [
            for (final r in requests)
              if (r is RuntimeReply) {'id': r.id, 'result': r.result},
          ],
          (thread, error) {
            _interruptionReason =
                'Child/thread $thread interruption unavailable: $error';
          },
        )
        .then((_) {
          if (_interruptionReason != null) {
            throw CodexOptionalUnsupported(
              'Interruption',
              _interruptionReason!,
            );
          }
        });
  }

  @override
  Future<void> reply(Object id, Json result) =>
      client.replyAdmitted(id, result).timeout(const Duration(seconds: 10));
  @override
  void checkCanSteer(String expectedTurn) {
    if (_steeringUnavailable) {
      throw RpcException(
        ErrorCode.methodNotAvailable,
        'native steering unavailable',
      );
    }
    if (expectedTurn != _turnId || _turn == null) {
      throw RpcException(
        ErrorCode.turnRunning,
        'native turn is no longer current',
      );
    }
  }

  @override
  Future<void> steer(String thread, String expectedTurn, String text) {
    if (thread == root) {
      checkCanSteer(expectedTurn);
    } else if (_steeringUnavailable ||
        _children[thread]?.turn != expectedTurn) {
      throw RpcException(
        ErrorCode.turnRunning,
        'child question turn is no longer current',
      );
    }
    return client
        .request<void>(
          'turn/steer',
          {
            'threadId': thread,
            'expectedTurnId': expectedTurn,
            'input': [
              {'type': 'text', 'text': text},
            ],
          },
          requireAdmission: true,
          pauseForOutput: false,
          timeout: const Duration(seconds: 10),
          decodeResult: (result) {
            if (result is! Json || result['turnId'] != expectedTurn) {
              _steeringUnavailable = true;
              throw CodexOptionalUnsupported(
                'steering',
                'native steer identity mismatch',
              );
            }
          },
        )
        .catchError((Object error) {
          if (error is CodexRemoteException && error.code == -32601) {
            _steeringUnavailable = true;
            throw CodexOptionalUnsupported('steering', error.message);
          }
          throw error;
        });
  }

  Object? _deliverInteraction(Object interaction, String turn, Json raw) {
    final child = _children[raw['threadId']];
    if (child != null) {
      if (interaction is RuntimePermission) {
        interaction = RuntimePermission(
          interaction.id,
          interaction.turnId,
          interaction.title,
          interaction.preview,
          interaction.choices,
          interaction.cancellation,
          threadId: child.id,
          parentThreadId: child.parent,
        );
      } else if (interaction is RuntimeQuestion) {
        interaction = RuntimeQuestion(
          interaction.id,
          interaction.turnId,
          interaction.questions,
          asyncItem: interaction.asyncItem,
          threadId: child.id,
          parentThreadId: child.parent,
        );
      }
      return interaction is RuntimePermission
          ? onPermission?.call(interaction)
          : onQuestion?.call(interaction as RuntimeQuestion);
    }
    if (_turnId == null) {
      var charge = _boundedJsonBytes(raw, 64 * 1024) + 1024;
      if (interaction is RuntimePermission) {
        if (interaction.preview != null) {
          charge += _boundedJsonBytes(interaction.preview, 256 * 1024);
        }
        for (final choice in interaction.choices) {
          charge += _boundedJsonBytes(choice.label, 256 * 1024);
        }
      }
      _stage(turn, interaction: interaction, charge: charge);
      return null;
    }
    return interaction is RuntimePermission
        ? onPermission?.call(interaction)
        : onQuestion?.call(interaction as RuntimeQuestion);
  }

  /// The `turn-http-401` shape: `codexErrorInfo` holds exactly one known
  /// HTTP failure key whose value carries `httpStatusCode` exactly 401.
  static bool _isHttp401(Object? error) {
    if (error is! Json) return false;
    final info = error['codexErrorInfo'];
    if (info is! Json || info.length != 1) return false;
    final MapEntry(:key, :value) = info.entries.single;
    return const [
          'httpConnectionFailed',
          'responseStreamConnectionFailed',
          'responseStreamDisconnected',
          'responseTooManyFailedAttempts',
        ].contains(key) &&
        value is Json &&
        value['httpStatusCode'] is int &&
        value['httpStatusCode'] == 401;
  }

  String _identity(Json data, String key) {
    final value = data[key];
    if (value is! String ||
        value.isEmpty ||
        clampJsonString(value, 4096) != value) {
      throw CodexProtocolException('invalid $key');
    }
    return value;
  }

  String? _approvalPreview(
    Json raw,
    Map<String, String> fields, {
    Json? permissions,
  }) {
    final lines = <String>[];
    for (final field in fields.entries) {
      final value = raw[field.key];
      if (value == null) continue;
      if (value is! String) {
        throw CodexProtocolException('invalid approval ${field.key}');
      }
      lines.add('${field.value}: $value');
    }
    if (permissions != null) {
      lines.add('Requested permissions: ${jsonEncode(permissions)}');
    }
    return lines.isEmpty ? null : lines.join('\n');
  }

  Object? _request(Object id, String method, Object? raw) {
    // The leader is gone while accepted stdout may still be draining.
    // Never write cancellation/denial into its closed native stdin.
    if (_nativeExited) return null;
    Object? notice(String text) =>
        normalizeUpdate?.call(RuntimeUpdate(AgentEventKind.notice, text));
    final coreApproval =
        method == 'item/commandExecution/requestApproval' ||
        method == 'item/fileChange/requestApproval' ||
        method == 'item/permissions/requestApproval';
    if (!coreApproval &&
        method != 'item/tool/requestUserInput' &&
        method != 'mcpServer/elicitation/request') {
      client.deny(id, -32601, 'unsupported native request');
      return notice('Codex unsupported native request refused.');
    }
    if (raw is! Json) {
      if (coreApproval) {
        throw CodexProtocolException('invalid native approval');
      }
      throw CodexOptionalUnsupported('questions', 'invalid native request');
    }
    if (_boundedJsonBytes(raw, 64 * 1024) > 64 * 1024) {
      client.deny(id, -32602, 'interaction exceeds control capacity');
      return notice('Native interaction refused: control capacity exceeded.');
    }
    if (raw['threadId'] != root && !_children.containsKey(raw['threadId'])) {
      _childrenIncomplete = true;
      onDelegatedChanged?.call();
      client.deny(id, -32601, 'untracked child interaction');
      return notice(
        'Codex unknown child ${clampJsonString(raw['threadId'].toString(), 4096)} request refused; relationship unavailable.',
      );
    }
    if (method == 'mcpServer/elicitation/request') {
      // Its turnId is optional natively, and every elicitation is cancelled,
      // so no turn identity is required to answer it.
      client.replyAdmitted(id, {'action': 'cancel'}).ignore();
      return notice(
        'MCP elicitation unavailable: unsupported form or URL request.',
      );
    }
    final child = _children[raw['threadId']];
    if (child != null && child.turn == null) {
      client.deny(id, -32602, 'retired child turn');
      return notice(
        'Child ${child.id} request refused; native turn identity unavailable or retired.',
      );
    }
    final active = child == null ? _turnId ?? _earlyId : child.turn;
    final turn = raw['turnId'];
    if ((child == null && _turn == null) ||
        (active != null && turn != active)) {
      client.deny(id, -32602, 'retired native turn');
      return null;
    }
    if (turn is! String || turn.isEmpty) {
      if (coreApproval) {
        throw CodexProtocolException('missing approval turn');
      }
      throw CodexOptionalUnsupported('questions', 'missing question turn');
    }
    // Before acceptance, interactions are staged with their originating turn.
    // A response for another turn cannot surface or approve them.
    if (method == 'item/commandExecution/requestApproval' ||
        method == 'item/fileChange/requestApproval') {
      _identity(raw, 'itemId');
      if (raw['startedAtMs'] is! int) {
        throw CodexProtocolException('invalid approval timestamp');
      }
      final command = method == 'item/commandExecution/requestApproval';
      var decisions = command
          ? raw['availableDecisions']
          : const ['accept', 'acceptForSession', 'decline', 'cancel'];
      if (command &&
          decisions == null &&
          (!raw.containsKey('kind') || raw['kind'] == 'command') &&
          raw['networkApprovalContext'] == null &&
          raw['additionalPermissions'] == null) {
        decisions = const ['accept', 'cancel'];
      }
      if (decisions is! List ||
          decisions.isEmpty ||
          decisions.length > maxPermissionOptions ||
          decisions.any(
            (decision) => decision is! String && decision is! Json,
          )) {
        client.replyAdmitted(id, {'decision': 'decline'}).ignore();
        return notice(
          'Native approval unavailable: offered decisions missing or unsupported.',
        );
      }
      final choices = <RuntimeChoice>[];
      for (var i = 0; i < decisions.length; i++) {
        final decision = decisions[i];
        // A native object is data, never a label: it is shown by position and
        // its complete value is previewed. Objects are conservatively
        // classified as persistent scope; the response value is unchanged.
        final kind = decision is! String
            ? 'allow_always'
            : decision == 'acceptForSession'
            ? 'allow_always'
            : decision == 'decline' || decision == 'cancel'
            ? 'reject_once'
            : 'allow_once';
        choices.add(
          RuntimeChoice(
            decision is String ? decision : 'Native option ${i + 1}',
            {'decision': decision},
            kind,
            generated: decision is! String,
          ),
        );
      }
      var preview = _approvalPreview(raw, {
        if (command) 'command': 'Command',
        if (command) 'cwd': 'Working directory',
        if (!command) 'grantRoot': 'Grant root',
        'reason': 'Reason',
      });
      // A network or additional-permission approval grants different access
      // per request: show the complete context so two cards never look alike
      // while authorizing different grants. The shared display bound cancels
      // the request when the full context does not fit.
      for (final (key, label) in const [
        ('networkApprovalContext', 'Network approval context'),
        ('additionalPermissions', 'Additional permissions'),
      ]) {
        final context = raw[key];
        if (!command || context == null) continue;
        final line = '$label: ${jsonEncode(context)}';
        preview = preview == null ? line : '$preview\n$line';
      }
      if (decisions.any((decision) => decision is! String)) {
        final line = 'Native decisions: ${jsonEncode(decisions)}';
        preview = preview == null ? line : '$preview\n$line';
      }
      return _deliverInteraction(
        RuntimePermission(
          id,
          turn,
          command ? 'Command approval' : 'File change approval',
          preview,
          choices,
          {'decision': 'cancel'},
        ),
        turn,
        raw,
      );
    }
    if (method == 'item/permissions/requestApproval') {
      _identity(raw, 'itemId');
      _identity(raw, 'cwd');
      if (raw['permissions'] is! Json || raw['startedAtMs'] is! int) {
        throw CodexProtocolException('invalid additional permissions');
      }
      final requested = raw['permissions']! as Json;
      if (requested.keys.any(
        (key) => key != 'network' && key != 'fileSystem',
      )) {
        throw CodexProtocolException('unknown additional permission grant');
      }
      return _deliverInteraction(
        RuntimePermission(
          id,
          turn,
          'Additional permissions',
          _approvalPreview(raw, const {
            'cwd': 'Working directory',
            'reason': 'Reason',
          }, permissions: requested),
          [
            RuntimeChoice('Allow requested permissions for this turn', {
              'permissions': requested,
              'scope': 'turn',
            }, 'allow_once'),
            RuntimeChoice('Decline', {
              'permissions': {},
              'scope': 'turn',
            }, 'reject_once'),
          ],
          {'permissions': {}, 'scope': 'turn'},
        ),
        turn,
        raw,
      );
    }
    if (method == 'item/tool/requestUserInput') {
      try {
        _identity(raw, 'itemId');
        if (raw['isBlocking'] is! bool || raw['questions'] is! List) {
          throw const FormatException('invalid question shape');
        }
        final questions = <AgentQuestion>[];
        for (final q in raw['questions'] as List) {
          if (q is! Json) throw const FormatException('invalid question');
          final options = q['options'];
          if (options != null &&
              (options is! List ||
                  options.any(
                    (o) =>
                        o is! Json ||
                        o['label'] is! String ||
                        (o['description'] != null &&
                            o['description'] is! String),
                  ))) {
            throw const FormatException('invalid options');
          }
          questions.add(
            AgentQuestion.fromJson({
              'id': q['id'],
              'header': q['header'],
              'text': q['question'],
              'allowOther': q['isOther'] ?? false,
              'secret': q['isSecret'] ?? false,
              'options': [
                if (options is List)
                  for (final o in options)
                    if (o is Json)
                      {
                        'id': o['label'],
                        'label': o['label'],
                        'description': o['description'],
                      },
              ],
            }),
          );
        }
        if (questions.isEmpty) throw const FormatException('empty questions');
        return _deliverInteraction(
          RuntimeQuestion(id, turn, questions),
          turn,
          raw,
        );
      } on Object catch (e) {
        throw CodexOptionalUnsupported(
          'questions',
          'unsupported optional shape: $e',
        );
      }
    }
    client.deny(id, -32601, 'unsupported native request');
    return notice('Codex unsupported native request refused.');
  }
}

// Exact up to the existing control/early limit, without an escaping-expanded
// serialization buffer. Deep optional payloads are refused within that budget.
int _boundedJsonBytes(Object? value, int limit, [int depth = 0]) {
  if (limit < 0) return 1;
  if (depth > 64) return limit + 1;
  if (value is String) return jsonStringContentBytes(value) + 2;
  if (value is List<Object?>) {
    var n = 2;
    var first = true;
    for (final item in value) {
      if (!first) n++;
      first = false;
      n += _boundedJsonBytes(item, limit - n, depth + 1);
      if (n > limit) return n;
    }
    return n;
  }
  if (value is Json) {
    var n = 2;
    var first = true;
    for (final entry in value.entries) {
      if (!first) n++;
      first = false;
      n += jsonStringContentBytes(entry.key) + 3;
      if (n > limit) return n;
      n += _boundedJsonBytes(entry.value, limit - n, depth + 1);
      if (n > limit) return n;
    }
    return n;
  }
  return value == null ? 4 : value.toString().length;
}

// Native identifiers are opaque; length prefixes avoid separator collisions.
String _nativeKey(List<String?> values) =>
    values.map((v) => '${v?.length ?? 0}:${v ?? ''}').join();
