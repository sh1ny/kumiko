import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';
import 'package:sqlite3/sqlite3.dart';

import '../host_options.dart';
import '../settler.dart';
import '../store/store.dart';
import '../unit_manager.dart';
import '../workspace_service.dart';
import 'acp/acp_client.dart';
import 'agent_session.dart';
import 'executable_resolver.dart';
import 'qualification.dart';
import 'runtime_profile_service.dart';

/// The captured execution target is never derived again from desktop focus or
/// a mutable workspace row. Continue will compare this durable identity.
class AgentTarget {
  const AgentTarget({required this.workspaceId, required this.path, required this.identity, this.host = 'local'});
  final String? workspaceId;
  final String path;
  final String identity;
  final String host;
}

/// One native reference only; conversation data never crosses the Store seam.
class AgentSessionRecord {
  const AgentSessionRecord({required this.id, required this.runtimeKind, required this.runtimeProfileId,
    required this.adapter, required this.nativeSessionId, required this.target,
    required this.createdAt, required this.updatedAt});
  final String id;
  final String runtimeKind;
  final String? runtimeProfileId;
  final AgentAdapter adapter;
  final String nativeSessionId;
  final AgentTarget target;
  final String createdAt;
  final String updatedAt;
}

class _StderrRing {
  final _bytes = Uint8List(64 * 1024);
  int _next = 0;
  int _length = 0;
  void add(List<int> bytes) {
    var from = bytes.length > _bytes.length ? bytes.length - _bytes.length : 0;
    while (from < bytes.length) {
      final n = min(bytes.length - from, _bytes.length - _next);
      _bytes.setRange(_next, _next + n, bytes, from);
      _next = (_next + n) % _bytes.length;
      _length = min(_length + n, _bytes.length);
      from += n;
    }
  }
  String tail() {
    final count = min(_length, 4096);
    final bytes = Uint8List(count);
    final start = (_next - count + _bytes.length) % _bytes.length;
    final first = min(count, _bytes.length - start);
    bytes.setRange(0, first, _bytes, start);
    if (first < count) {
      bytes.setRange(first, count, _bytes);
    }
    var boundary = 0;
    while (boundary < count && (bytes[boundary] & 0xc0) == 0x80) {
      boundary++;
    }
    return clampUtf8(utf8.decode(Uint8List.sublistView(bytes, boundary), allowMalformed: true), 4096);
  }
}

/// The client and stderr subscription own the caller-owned pipes even after
/// UnitManager removes its live handle. Failed cleanup retains this owner until
/// the leader really exits (for example after the existing cleanup retry).
class _AgentIO {
  _AgentIO(this.launch) : client = AcpClient.pipes(launch.pipes!) {
    errors = launch.pipes!.stderr.listen(stderr.add, onDone: () {
      if (!errorsDone.isCompleted) errorsDone.complete();
    }, onError: (Object _) {
      if (!errorsDone.isCompleted) errorsDone.complete();
    });
    launch.unit.exitCode.then((value) => status = value).ignore();
  }
  final UnitLaunch launch;
  final AcpClient client;
  final stderr = _StderrRing();
  final errorsDone = Completer<void>();
  late final StreamSubscription<Uint8List> errors;
  int? status;
  Future<UnitOutcome>? ending;
  Future<void>? disposal;
}

/// Only this queue sits between ACP normalization and ChannelWriter. Per-event
/// admission bounds escaping expansion without materializing the whole line.
/// It gates the next ACP line at 1 MiB; overshoot is at most one bounded event.
/// ACP has released its large-line permit before this consumer can pause.
class AgentEventRelay {
  AgentEventRelay({this.onPauseChanged});
  final void Function(bool paused)? onPauseChanged;
  final Queue<Uint8List> _queue = Queue();
  int _bytes = 0;
  int _offset = 0;
  ChannelWriter? _writer;
  Completer<void>? _space;
  bool _pumping = false;
  bool _closed = false;
  void Function(Object)? onFailure;
  bool _paused = false;
  bool get isPaused => _paused;
  int get queuedBytes => _bytes;

  void _pause(bool value) {
    if (_paused == value) return;
    _paused = value;
    onPauseChanged?.call(value);
  }
  Future<void> _admit() async {
    while (!_closed && _bytes >= 1024 * 1024) {
      _pause(true);
      await (_space ??= Completer<void>()).future;
    }
    _pause(false);
  }
  Future<void> enqueue(Iterable<Uint8List> lines) async {
    if (_closed) return;
    for (final line in lines) {
      await _admit();
      if (_closed) return;
      _queue.add(line);
      _bytes += line.length;
      _pump();
    }
    // A completed enqueue permits ACP to read its next line. Do not complete
    // while this queue is full, even if the current line had just one event.
    await _admit();
  }
  void attach(ChannelWriter writer) { _writer = writer; _pump(); }
  void _wake() { final space = _space; _space = null; space?.complete(); }
  void _pump() {
    if (_closed || _pumping || _writer == null || _queue.isEmpty) return;
    _pumping = true;
    unawaited(_run());
  }
  Future<void> _run() async {
    final writer = _writer!;
    try {
      while (!_closed && _queue.isNotEmpty) {
        await writer.ready;
        if (_closed) return;
        final line = _queue.first;
        final count = min(writer.room, line.length - _offset);
        // This fits the writer's window now: no waiting write retains an
        // additional event buffer outside our byte accounting.
        writer.write(Uint8List.sublistView(line, _offset, _offset + count)).then<void>(
          (_) {}, onError: (Object error, StackTrace stack) { if (!_closed) onFailure?.call(error); },
        );
        _offset += count;
        _bytes -= count;
        if (_offset == line.length) { _queue.removeFirst(); _offset = 0; }
        if (_bytes < 1024 * 1024) _wake();
      }
    } on Object catch (error) {
      if (!_closed) onFailure?.call(error);
    } finally { _pumping = false; }
  }
  void close() {
    _closed = true;
    _queue.clear();
    _offset = 0;
    _bytes = 0;
    _pause(false);
    _wake();
  }
}

class _Agent {
  _Agent({required this.record, required this.io, required this.reservation});
  final AgentSessionRecord record;
  final _AgentIO io;
  final ChannelReservation reservation;
  final relay = AgentEventRelay();
  late final AgentSession session;
  Timer? attachTimer;
  bool attached = false;
  bool ending = false;
  bool exited = false;
  bool closeFailed = false;
  bool callbacks = true;
  AgentExitedParams? exitNotification;
  int get channel => reservation.ids.single;
}

/// Contained execution and transport owner; AgentSession remains the sole
/// turn/permission/Stop state writer. Cleanup and launch gating remain wholly
/// in the existing UnitManager/Settler/ledger, shared with terminals.
class AgentService {
  AgentService({required this.connection, required this.units, required this.workspaces,
    required this.profiles, required this.store, required this.options});
  final Connection connection;
  final UnitManager units;
  final WorkspaceService workspaces;
  final RuntimeProfileService profiles;
  final Store store;
  final HostOptions options;
  final _agents = <String, _Agent>{};
  final _io = <_AgentIO>{};
  final _random = Random.secure();
  bool _disposed = false;

  String _newId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
  void _available() {
    if (_disposed) throw RpcException(ErrorCode.shuttingDown, 'the host is shutting down');
  }
  _Agent _require(String id, {bool allowExited = false}) {
    final a = _agents[id];
    if (a == null || (!allowExited && (a.exited || a.closeFailed))) {
      throw RpcException(ErrorCode.unknownSession, 'there is no live agent session $id', {'sessionId': id});
    }
    return a;
  }
  bool _current(_Agent a) => !_disposed && a.callbacks && identical(_agents[a.record.id], a);
  void _notify(_Agent a, String method, Json params) {
    if (_current(a)) connection.notify(method, params);
  }

  Future<AgentStartResult> start(AgentStartParams params) async {
    _available();
    if (params.workspaceId.isEmpty) throw RpcException(ErrorCode.workspaceRequired, 'an agent needs a workspace');
    final workspace = workspaces.row(params.workspaceId);
    final resolved = workspace == null ? null : directoryIdentity(workspace.path);
    if (workspace == null || workspaces.record(workspace).availability == Availability.unavailable || resolved is! ResolvedDirectory) {
      throw RpcException(ErrorCode.workspaceUnavailable, 'the selected workspace is unavailable', {'workspaceId': params.workspaceId});
    }
    final target = AgentTarget(workspaceId: workspace.id, path: resolved.realPath, identity: resolved.id);
    final String? profileId;
    if (params.runtimeProfileId != null) {
      profileId = params.runtimeProfileId;
    } else {
      final listed = await profiles.list();
      profileId = listed.defaultId;
    }
    final profile = profileId == null ? null : await profiles.find(profileId);
    if (profile == null) throw RpcException(ErrorCode.noRuntimeProfile, 'Runtime profile "${profileId ?? params.runtimeProfileId ?? 'default'}" is unavailable. Choose or add a runtime profile.');
    final executable = ExecutableResolver().resolve(profile.executable);
    _available();
    final reservation = connection.reserveChannels(1);
    _AgentIO? io;
    var stage = 'spawn';
    try {
      final launch = await units.launch(target: target.path, kind: 'agent',
        argv: [executable, ...profile.args], workingDirectory: target.path,
        environment: profile.env, pipes: true);
      io = _AgentIO(launch);
      _io.add(io);
      _available();
      if (launch.target.id != target.identity || launch.target.realPath != target.path) {
        throw RpcException(ErrorCode.workspaceUnavailable, 'the workspace target changed while the adapter was starting');
      }
      stage = 'initialize';
      final initialization = await io.client.initialize();
      _available();
      final claims = qualifyAdapter(initialization);
      stage = 'session/new';
      final native = await io.client.newSession(target.path);
      _available();
      final now = DateTime.now().toUtc().toIso8601String();
      final record = AgentSessionRecord(id: _newId(), runtimeKind: profile.runtimeKind,
        runtimeProfileId: profile.id, adapter: AgentAdapter(name: initialization.adapterName,
          version: initialization.adapterVersion ?? ''), nativeSessionId: native,
        target: target, createdAt: now, updatedAt: now);
      stage = 'record';
      _insert(record);
      final a = _Agent(record: record, io: io, reservation: reservation);
      _agents[record.id] = a;
      a.relay.onFailure = (error) => _fail(a, error);
      a.session = AgentSession(sessionId: record.id, client: io.client, claims: claims,
        enqueueEvents: a.relay.enqueue,
        onState: (p) {
          _notify(a, Method.agentState, p.toJson());
          if (p.state == AgentState.failed) {
            // The constructor publishes starting before its assignment.
            unawaited(Future<void>(() => _fail(a, a.session.failure ?? const AcpClosedException())));
          }
        },
        onPermissionRequested: (p) => _notify(a, Method.agentPermissionRequested, p.toJson()),
        onPermissionResolved: (p) => _notify(a, Method.agentPermissionResolved, p.toJson()),
        onStopResult: (p) => _notify(a, Method.agentStopResult, p.toJson()),
        onTurnEnded: (p) => _notify(a, Method.agentTurnEnded, p.toJson()),
      );
      a.session.ready(nativeSessionId: native);
      a.attachTimer = Timer(options.attachTimeout, () {
        if (!_current(a) || a.attached) return;
        if (a.exited || a.closeFailed) {
          _forget(a);
        } else {
          _beginClose(a, attachTimeout: true);
        }
      });
      unawaited(_watchExit(a));
      return AgentStartResult(sessionId: record.id, eventChannel: a.channel,
        adapter: record.adapter, capabilities: claims.capabilities);
    } on Object catch (error) {
      if (io != null) {
        final outcome = await _end(io);
        await io.client.close();
        if (outcome.cleaned) {
          try { await _disposeIo(io); } on Object {
            // Containment is already settled. Preserve the actual start
            // failure rather than replacing it with an endpoint-close error.
          }
        } else {
          _disposeAfterExit(io);
        }
      }
      reservation.release();
      if (error is RpcException) rethrow;
      if (error is AcpProtocolException) throw RpcException(ErrorCode.adapterProtocol, error.message, {'stage': stage});
      final tail = io?.stderr.tail() ?? '';
      final status = io?.status;
      final reason = stage == 'initialize' && tail.startsWith('unit-exec:')
          ? status == 127 ? ErrorCode.executableNotFound : status == 126 ? ErrorCode.notExecutable : ErrorCode.adapterStartFailed
          : ErrorCode.adapterStartFailed;
      final message = error is AcpRemoteException ? error.message : error.toString();
      final nativeMessage = error is AcpRemoteException ? clampUtf8(error.message, 4096) : null;
      throw RpcException(reason, clampUtf8('$message${status == null ? '' : ' (exit status $status)'}${tail.isEmpty ? '' : '\n$tail'}', 4096), {
        'stage': stage, 'detail': tail.isEmpty ? clampUtf8(message, 4096) : tail,
        'status': ?status,
        if (error is AcpRemoteException) 'nativeCode': error.code,
        'nativeMessage': ?nativeMessage,
        if (error is AcpRemoteException && nativeMessage != error.message)
          'nativeMessageTruncated': true,
      });
    }
  }

  void _insert(AgentSessionRecord r) {
    try {
      store.execute('BEGIN IMMEDIATE');
      try {
        store.execute('INSERT INTO agent_session(id, runtime_kind, runtime_profile_id, adapter_name, adapter_version, native_session_id, role, target_host, target_path, target_identity, workspace_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [r.id, r.runtimeKind, r.runtimeProfileId, r.adapter.name, r.adapter.version, r.nativeSessionId, 'coding', r.target.host, r.target.path, r.target.identity, r.target.workspaceId, r.createdAt, r.updatedAt]);
        store.execute('COMMIT');
      } on Object {
        store.execute('ROLLBACK');
        rethrow;
      }
    } on SqliteException {
      throw RpcException(ErrorCode.storeError, 'could not save the native agent session reference');
    }
  }

  void attach(AgentSessionParams params) {
    final a = _require(params.sessionId, allowExited: true);
    final earlyExit = !a.attached && a.exitNotification?.reason == AgentExitReason.failed;
    if (a.ending && !earlyExit) throw RpcException(ErrorCode.unknownSession, 'session is closing');
    if (a.attached) throw RpcException(ErrorCode.invalidParams, 'session already attached');
    a.attached = true;
    a.attachTimer?.cancel();
    a.relay.attach(connection.attachOutbound(a.channel));
    unawaited(Future<void>(() {
      if (!_current(a)) return;
      a.session.publishState();
      final exit = a.exitNotification;
      if (earlyExit && exit != null) {
        _notify(a, Method.agentExited, exit.toJson());
        a.callbacks = false;
        a.session.dispose();
      }
    }));
  }
  void prompt(AgentPromptParams params) {
    final a = _require(params.sessionId);
    a.session.acceptPrompt(params.text);
  }
  void stop(AgentSessionParams params) {
    final a = _require(params.sessionId);
    if (a.ending) throw RpcException(ErrorCode.unknownSession, 'session is closing');
    a.session.stop();
  }
  void permissionReply(AgentPermissionReplyParams params) {
    final a = _require(params.sessionId);
    a.session.permissionReply(params.requestId, params.optionId);
  }
  void close(AgentSessionParams params) {
    final a = _require(params.sessionId);
    if (!a.ending) _beginClose(a);
  }
  void release(AgentSessionParams params) {
    final a = _require(params.sessionId, allowExited: true);
    if (!a.exited) throw RpcException(ErrorCode.invalidParams, 'session has not exited');
    _forget(a);
  }

  void _beginClose(_Agent a, {bool attachTimeout = false}) {
    if (!_current(a) || a.ending || a.exited) return;
    final running = switch (a.session.state) {
      AgentState.running || AgentState.waitingApproval || AgentState.stopping => true,
      _ => false,
    };
    a.ending = true;
    a.attachTimer?.cancel();
    a.session.beginClosing();
    a.relay.close();
    // Schedule on the event queue, not a microtask: the close result is
    // written before an idle unit can settle and publish its exit.
    unawaited(Future<void>(() async {
      if (!_current(a)) return;
      if (running && !attachTimeout) await Future<void>.delayed(const Duration(seconds: 2));
      if (!_current(a)) return;
      final outcome = await _end(a.io);
      await a.io.client.close();
      if (outcome.cleaned) {
        await _disposeIo(a.io);
      } else {
        _disposeAfterExit(a.io);
      }
      if (!_current(a)) return;
      if (outcome.cleaned) {
        a.exited = true;
        a.session.ended();
        _notify(a, Method.agentExited, AgentExitedParams(sessionId: a.record.id,
          reason: AgentExitReason.closed, status: a.io.status).toJson());
        if (attachTimeout) _forget(a);
      } else {
        a.closeFailed = true;
        _notify(a, Method.agentCloseFailed, AgentCloseFailedParams(sessionId: a.record.id,
          reason: outcome.reason ?? 'cleanup-unresolved').toJson());
        _forget(a);
      }
    }).catchError((Object error) {
      if (_current(a)) {
        a.closeFailed = true;
        _notify(a, Method.agentCloseFailed, AgentCloseFailedParams(
          sessionId: a.record.id, reason: 'agent-io-close-failed',
        ).toJson());
        _forget(a);
      }
    }));
  }

  Future<UnitOutcome> _end(_AgentIO io) => io.ending ??= () async {
    final id = io.launch.id;
    if (!units.live.containsKey(id)) {
      final row = units.ledger.unit(id);
      return row == null ? const UnitOutcome.cleaned() : UnitOutcome.unresolved(row.reason ?? 'cleanup-unresolved');
    }
    try {
      return await units.end(id).timeout(options.settleDeadline);
    } on TimeoutException {
      if (units.ledger.unit(id) != null) {
        units.ledger.markUnresolved(id, 'settlement-deadline');
        units.onUnresolved();
      }
      return const UnitOutcome.unresolved('settlement-deadline');
    } on Object {
      if (units.ledger.unit(id) != null) {
        units.ledger.markUnresolved(id, 'end-failed');
        units.onUnresolved();
      }
      return const UnitOutcome.unresolved('end-failed');
    }
  }();

  Future<void> _watchExit(_Agent a) async {
    final status = await a.io.launch.unit.exitCode;
    a.io.status = status;
    if (!_current(a) || a.ending) return;
    // EOF is owned by ACP: let final buffered updates normalize and enqueue
    // before failing the turn or disposing caller-owned pipes.
    await a.io.client.done;
    if (!_current(a) || a.ending) return;
    await _finishFailure(a, a.io.client.failure ?? const AcpClosedException());
  }
  void _fail(_Agent a, Object error) {
    if (!_current(a) || a.ending || a.exited || a.closeFailed) return;
    // EOF can precede process.exitCode by a scheduler turn. Its watcher owns
    // the status-bearing exit; parse/write failures require active termination.
    if (error is AcpClosedException) return;
    unawaited(_finishFailure(a, error));
  }
  Future<void> _finishFailure(_Agent a, Object error) async {
    if (!_current(a) || a.ending) return;
    a.ending = true;
    if (a.attached) a.attachTimer?.cancel();
    a.session.fail(error);
    var outcome = await _end(a.io);
    await a.io.client.close();
    if (outcome.cleaned) {
      try {
        await _disposeIo(a.io);
      } on Object {
        outcome = const UnitOutcome.unresolved('agent-io-close-failed');
      }
    } else {
      _disposeAfterExit(a.io);
    }
    if (!_current(a)) return;
    if (!outcome.cleaned) {
      a.closeFailed = true;
      _notify(a, Method.agentCloseFailed, AgentCloseFailedParams(sessionId: a.record.id,
        reason: outcome.reason ?? 'cleanup-unresolved').toJson());
      _forget(a);
    } else {
      a.exited = true;
      final exited = a.exitNotification = AgentExitedParams(sessionId: a.record.id,
        reason: AgentExitReason.failed, status: a.io.status,
        error: error is AcpProtocolException ? ErrorCode.adapterProtocol : 'adapter-exited',
        message: error is AcpProtocolException ? error.message : null);
      _notify(a, Method.agentExited, exited.toJson());
    }
    if (a.attached) {
      a.callbacks = false;
      a.session.dispose();
    }
  }
  Future<void> _disposeIo(_AgentIO io) => io.disposal ??= () async {
    await io.client.close();
    // Settlement precedes this operation. Drain stderr through EOF before
    // capturing a start-error tail; close() also unblocks paused stdout.
    await io.errorsDone.future.timeout(options.postExitReadDeadline, onTimeout: () {});
    await io.launch.pipes!.close();
    await io.errors.cancel();
    _io.remove(io);
  }();
  void _disposeAfterExit(_AgentIO io) {
    io.launch.unit.exitCode.then<void>((_) async {
      await _disposeIo(io);
    }).ignore();
  }
  void _forget(_Agent a) {
    a.callbacks = false;
    a.attachTimer?.cancel();
    a.session.dispose();
    a.relay.close();
    _agents.remove(a.record.id);
    a.reservation.release();
    if (a.attached) connection.closeChannel(a.channel).ignore();
  }

  /// Host calls this before the *shared* units.shutdown. Closing ACP cancels
  /// pending initialize/new/prompt work without disposing blocked native I/O.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final a in _agents.values) {
      a.callbacks = false;
      a.attachTimer?.cancel();
      a.session.dispose();
      a.relay.close();
      a.reservation.release();
    }
    for (final io in _io) { io.client.close().ignore(); }
  }
  /// After shared shutdown, join only I/O whose containment actually ended.
  /// An unresolved live unit keeps its ledger and native ownership until the
  /// host exits; never hang shutdown joining its still-blocked native read.
  Future<void> finishShutdown() async {
    await Future.wait([for (final io in _io.toList())
      if (io.status != null || !units.live.containsKey(io.launch.id)) _disposeIo(io),
    ]);
  }
}
