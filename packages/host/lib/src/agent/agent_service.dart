import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
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
import '../workspace_resolver.dart';
import 'acp/acp_client.dart';
import 'codex/codex_client.dart';
import 'codex/version_probe.dart';
import 'runtime_driver.dart';
import 'agent_session.dart';
import 'adapter_detector.dart';
import 'draft_store.dart';
import 'executable_resolver.dart';
import 'qualification.dart';
import 'qualified_adapters.dart';
import 'runtime_profile_service.dart';
import 'tools/tool_service.dart';

/// The captured execution target is never derived again from desktop focus or
/// a mutable workspace row. Continue will compare this durable identity.
class AgentTarget {
  const AgentTarget({
    required this.workspaceId,
    required this.path,
    required this.identity,
    this.host = 'local',
  });
  final String? workspaceId;
  final String path;
  final String identity;
  final String host;
}

/// One native reference only; conversation data never crosses the Store seam.
class AgentSessionRecord {
  const AgentSessionRecord({
    required this.id,
    required this.runtimeKind,
    required this.runtimeProfileId,
    required this.adapter,
    required this.nativeSessionId,
    required this.target,
    required this.createdAt,
    required this.updatedAt,
  });
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
    return clampUtf8(
      utf8.decode(Uint8List.sublistView(bytes, boundary), allowMalformed: true),
      4096,
    );
  }
}

/// The client and stderr subscription own the caller-owned pipes even after
/// UnitManager removes its live handle. Failed cleanup retains this owner until
/// containment is confirmed settled, not merely until its leader exits.
class _AgentIO {
  _AgentIO(
    this.launch, {
    String? codexVersion,
    List<(String, String, List<String>)> qualified = qualifiedAdapters,
    List<(int, String)> authSignatures = const [],
  }) : client = codexVersion == null
           ? AcpRuntimeDriver(
               AcpClient.pipes(launch.pipes!),
               qualified: qualified,
             )
           : CodexRuntimeDriver(
               CodexClient.pipes(launch.pipes!, authSignatures: authSignatures),
               codexVersion,
             ) {
    errors = launch.pipes!.stderr.listen(
      stderr.add,
      onDone: () {
        if (!errorsDone.isCompleted) errorsDone.complete();
      },
      onError: (Object _) {
        if (!errorsDone.isCompleted) errorsDone.complete();
      },
    );
    launch.unit.exitCode.then((value) => status = value).ignore();
  }
  final UnitLaunch launch;
  final RuntimeDriver client;
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
  int _reserved = 0;
  int get reservedBytes => _reserved;
  bool reserveEarly(int bytes) {
    if (bytes < 0 || _bytes + _reserved + bytes > 1024 * 1024) return false;
    _reserved += bytes;
    return true;
  }

  void releaseEarly(int bytes) {
    _reserved = max(0, _reserved - bytes);
    if (_bytes + _reserved < 1024 * 1024) _wake();
  }

  Future<void> enqueueReserved(RuntimeDelivery delivery) async {
    if (_closed || _sealed) {
      delivery.release();
      return;
    }
    delivery.release();
    for (final line in delivery.lines) {
      _queue.add(line);
      _bytes += line.length;
      _eventCount++;
    }
    _pump();
    await _admit();
  }

  int _offset = 0;
  ChannelWriter? _writer;
  Completer<void>? _space;
  bool _pumping = false;
  bool _closed = false;
  bool _sealed = false;
  int _eventCount = 0;
  int get eventCount => _eventCount;
  void Function(Object)? onFailure;
  bool _paused = false;
  bool get isPaused => _paused;
  int get queuedBytes => _bytes;
  int get channelQueuedBytes => _writer?.queuedBytes ?? 0;
  int get channelSentBytes => _writer?.sentBytes ?? 0;

  void _pause(bool value) {
    if (_paused == value) return;
    _paused = value;
    onPauseChanged?.call(value);
  }

  Future<void> _admit() async {
    while (!_closed && !_sealed && _bytes + _reserved >= 1024 * 1024) {
      _pause(true);
      await (_space ??= Completer<void>()).future;
    }
    _pause(false);
  }

  Future<void> enqueue(Iterable<Uint8List> lines) async {
    if (_closed || _sealed) return;
    for (final line in lines) {
      await _admit();
      if (_closed || _sealed) return;
      _queue.add(line);
      _eventCount++;
      _bytes += line.length;
      _pump();
    }
    // A completed enqueue permits ACP to read its next line. Do not complete
    // while this queue is full, even if the current line had just one event.
    await _admit();
  }

  void attach(ChannelWriter writer) {
    _writer = writer;
    _pump();
  }

  void _wake() {
    final space = _space;
    _space = null;
    space?.complete();
  }

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
        writer
            .write(Uint8List.sublistView(line, _offset, _offset + count))
            .then<void>(
              (_) {},
              onError: (Object error, StackTrace stack) {
                if (!_closed) onFailure?.call(error);
              },
            );
        _offset += count;
        _bytes -= count;
        if (_offset == line.length) {
          _queue.removeFirst();
          _offset = 0;
        }
        if (_bytes < 1024 * 1024) _wake();
      }
    } on Object catch (error) {
      if (!_closed) onFailure?.call(error);
    } finally {
      _pumping = false;
    }
  }

  /// Freeze the final accepted-record count without discarding queued output.
  /// A failed producer may have an admission waiting for room; it owns no
  /// accepted record until insertion into the queue above.
  void seal() {
    _sealed = true;
    _pause(false);
    _wake();
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
  _Agent({
    required this.record,
    required this.io,
    required this.reservation,
    required this.runId,
    this.mode,
    this.grant,
    this.mcpServers = const [],
  }) : restoring = mode != null;
  final AgentSessionRecord record;
  final _AgentIO io;
  final ChannelReservation reservation;
  final String runId;
  final AgentContinueMode? mode;

  /// This run's tool grant, revoked when the run ends; null without an endpoint.
  final ToolGrant? grant;

  /// The `mcpServers` list every session request of this run carries.
  final List<Json> mcpServers;
  bool restoring;
  final relay = AgentEventRelay();
  late final AgentSession session;
  Timer? attachTimer;
  bool attached = false;
  bool ending = false;
  bool closeRequested = false;

  /// A prompt is committing its draft removal; no second prompt starts.
  bool sending = false;
  bool exited = false;
  bool closeFailed = false;
  bool consumerClosed = false;
  bool callbacks = true;
  AgentExitedParams? exitNotification;
  int get channel => reservation.ids.single;
}

/// Contained execution and transport owner; AgentSession remains the sole
/// turn/permission/Stop state writer. Cleanup and launch gating remain wholly
/// in the existing UnitManager/Settler/ledger, shared with terminals.
class AgentService {
  AgentService({
    required this.connection,
    required this.profileDirectory,
    required this.units,
    required this.workspaces,
    required this.profiles,
    required this.store,
    required this.options,
    required this.tools,
    required this.drafts,
    this.qualifiedAdaptersOverride,
    this.toolDeliveryFailuresOverride,
  }) {
    drafts.onAvailable = _draftStoreReady;
  }
  final Connection connection;
  final Directory profileDirectory;
  final UnitManager units;
  final WorkspaceService workspaces;
  final RuntimeProfileService profiles;
  final Store store;
  final HostOptions options;
  final List<(String, String, List<String>)>? qualifiedAdaptersOverride;
  final ToolService tools;

  /// Unsent composer drafts; the worker behind it never blocks this isolate.
  final DraftStore drafts;
  final List<(String, String, String)>? toolDeliveryFailuresOverride;
  late final _executables = LaunchExecutableResolver(
    faults: workspaces.resolver.faults,
    timeout: options.resolveTimeout,
  );
  final _continuing = <String>{};
  final _agents = <String, _Agent>{};
  final _io = <_AgentIO>{};
  final _random = Random.secure();
  bool _disposed = false;

  /// Live grants, and the secrets of the most recently revoked ones: every
  /// one is redacted from adapter stderr before it leaves the host.
  final _grants = <ToolGrant>{};
  final _revokedSecrets = Queue<String>();

  void _revoke(ToolGrant? grant) {
    if (grant == null || !_grants.remove(grant)) return;
    _revokedSecrets.add(grant.secret);
    while (_revokedSecrets.length > options.revokedSecretsKept) {
      _revokedSecrets.removeFirst();
    }
    grant.revoke();
  }

  /// Redacts every live and recently revoked secret, and always [own]: the
  /// run's own grant is revoked before its diagnostics are built, and other
  /// revocations may meanwhile have evicted it from the recent ones.
  String _redact(String text, [ToolGrant? own]) {
    var out = text;
    for (final secret in _secretsFor(own)) {
      out = out.replaceAll(secret, '<redacted>');
    }
    return out;
  }

  /// Every secret [_redact] removes: the run's own, live and kept revoked.
  List<String> _secretsFor(ToolGrant? own) => [
    ?own?.secret,
    for (final g in _grants) g.secret,
    ..._revokedSecrets,
  ];

  /// Read only on demand by the test extension; no transcript or new counters.
  Json snapshot() => {
    for (final entry in _agents.entries)
      entry.key: {
        'ending': entry.value.ending,
        'hasGrant': entry.value.grant?.isLive ?? false,
        'paused': entry.value.relay.isPaused,
        'queuedBytes': entry.value.relay.queuedBytes,
        'reservedBytes': entry.value.relay.reservedBytes,
        'channelQueuedBytes': entry.value.relay.channelQueuedBytes,
        'channelSentBytes': entry.value.relay.channelSentBytes,
        'largeLineOwned': entry.value.io.client.largeLineOwned,
        'largeLineWaiting': entry.value.io.client.largeLineWaiting,
      },
  };

  String _newId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  void _available() {
    if (_disposed) {
      throw RpcException(ErrorCode.shuttingDown, 'the host is shutting down');
    }
  }

  _Agent _require(String id, {bool allowExited = false}) {
    final a = _agents[id];
    if (a == null || (!allowExited && (a.exited || a.closeFailed))) {
      throw RpcException(
        ErrorCode.unknownSession,
        'there is no live agent session $id',
        {'sessionId': id},
      );
    }
    return a;
  }

  bool _current(_Agent a) =>
      !_disposed && a.callbacks && identical(_agents[a.record.id], a);
  void _notify(_Agent a, String method, Json params) {
    if (_current(a)) connection.notify(method, params);
  }

  Future<AgentStartResult> start(AgentStartParams params) async {
    _available();
    if (params.workspaceId.isEmpty) {
      throw RpcException(
        ErrorCode.workspaceRequired,
        'an agent needs a workspace',
      );
    }
    final workspace = workspaces.row(params.workspaceId);
    if (workspace == null ||
        workspaces.record(workspace).availability == Availability.unavailable) {
      throw RpcException(
        ErrorCode.workspaceUnavailable,
        'the selected workspace is unavailable',
        {'workspaceId': params.workspaceId},
      );
    }
    final resolved = await workspaces.resolver.resolve(
      workspace.path,
      queue: false,
    );
    _available();
    if (resolved is ResolveBusy || resolved is ResolveStarved) {
      throw RpcException(ErrorCode.busy, 'workspace resolution is busy');
    }
    if (resolved is! ResolveFound) {
      throw RpcException(
        ErrorCode.workspaceUnavailable,
        'the selected workspace is unavailable',
        {'workspaceId': params.workspaceId},
      );
    }
    final target = AgentTarget(
      workspaceId: workspace.id,
      path: resolved.directory.realPath,
      identity: resolved.directory.id,
    );
    final String? profileId;
    if (params.runtimeProfileId != null) {
      profileId = params.runtimeProfileId;
    } else {
      final listed = await profiles.list();
      profileId = listed.defaultId;
    }
    final profile = profileId == null ? null : await profiles.find(profileId);
    if (profile == null) {
      throw RpcException(
        ErrorCode.noRuntimeProfile,
        'Runtime profile "${profileId ?? params.runtimeProfileId ?? 'default'}" is unavailable. Choose or add a runtime profile.',
      );
    }
    if (params.runtimeKind != null &&
        profile.runtimeKind != params.runtimeKind) {
      throw RpcException(
        ErrorCode.noRuntimeProfile,
        'Choose a compatible ${params.runtimeKind} runtime profile.',
      );
    }
    final (a, adapter, claims) = await _open(target, profile);
    return AgentStartResult(
      sessionId: a.record.id,
      eventChannel: a.channel,
      adapter: adapter,
      capabilities: claims.capabilities,
      tools: a.session.tools,
    );
  }

  RpcException _resumeUnavailable(
    String reason,
    String message, {
    AgentTools? tools,
  }) => RpcException(ErrorCode.resumeUnavailable, message, {
    'resumeReason': reason,
    'tools': ?tools?.toJson(),
  });

  AgentSessionRecord? _record(String id) {
    try {
      final rows = store.select('SELECT * FROM agent_session WHERE id = ?', [
        id,
      ]);
      if (rows.isEmpty) return null;
      final r = rows.single;
      return AgentSessionRecord(
        id: r['id'] as String,
        runtimeKind: r['runtime_kind'] as String,
        runtimeProfileId: r['runtime_profile_id'] as String?,
        adapter: AgentAdapter(
          name: r['adapter_name'] as String,
          version: r['adapter_version'] as String,
        ),
        nativeSessionId: r['native_session_id'] as String,
        target: AgentTarget(
          workspaceId: r['workspace_id'] as String?,
          host: r['target_host'] as String,
          path: r['target_path'] as String,
          identity: r['target_identity'] as String,
        ),
        createdAt: r['created_at'] as String,
        updatedAt: r['updated_at'] as String,
      );
    } on SqliteException {
      throw RpcException(
        ErrorCode.storeError,
        'could not read the saved agent session reference',
      );
    }
  }

  Future<AgentRecordsResult> records(AgentRecordsParams params) async {
    _available();
    if (params.sessionIds.length > maxAgentRecordIds) {
      throw RpcException(
        ErrorCode.invalidParams,
        'at most $maxAgentRecordIds session ids',
      );
    }
    // Start each check without queueing: the shared resolver admits at most
    // four calls, including timed-out calls that still own their slots. A batch
    // cannot multiply the timeout by its number of saved panes.
    final records = await Future.wait([
      for (final id in params.sessionIds.toSet()) _inspectRecord(id),
    ]);
    return AgentRecordsResult(Map.fromEntries(records));
  }

  Future<MapEntry<String, AgentRecord>> _inspectRecord(String id) async {
    final record = _record(id);
    final result = record == null
        ? null
        : await workspaces.resolver.resolve(record.target.path, queue: false);
    return MapEntry(
      id,
      AgentRecord(
        known: record != null,
        targetPath: record?.target.path,
        adapterVersion: record?.adapter.version,
        workspaceAvailable:
            result is ResolveFound &&
            result.directory.id == record!.target.identity,
      ),
    );
  }

  Future<void> _checkContinueTarget(AgentTarget saved) async {
    final result = await workspaces.resolver.resolve(saved.path, queue: false);
    final ResolvedDirectory target;
    switch (result) {
      case ResolveFound(:final directory):
        target = directory;
      case ResolveMissing():
        throw _resumeUnavailable(
          'target-missing',
          'the saved session target is missing',
        );
      case ResolveTimedOut():
        throw _resumeUnavailable(
          'target-missing',
          'the saved session target did not answer in time',
        );
      case ResolveBusy() || ResolveStarved():
        throw RpcException(
          ErrorCode.busy,
          'the host is resolving too many folders',
        );
    }
    if (target.id != saved.identity) {
      throw _resumeUnavailable(
        'target-changed',
        'the saved session target has changed',
      );
    }
    if (units.ledger.isUnresolved(identity: saved.identity, path: saved.path)) {
      throw _resumeUnavailable(
        'cleanup-unresolved',
        'cleanup of the saved session target is unresolved',
      );
    }
  }

  Future<AgentContinueResult> continueSession(
    AgentContinueParams params,
  ) async {
    _available();
    final record = _record(params.sessionId);
    if (record == null) {
      throw _resumeUnavailable(
        'unknown-record',
        'the saved session is unknown',
      );
    }
    if (record.runtimeKind == 'codex') {
      _requireCodexPeer();
    }
    final previous = _agents[record.id];
    if (_continuing.contains(record.id) ||
        (previous != null && !previous.exited)) {
      throw RpcException(
        ErrorCode.turnRunning,
        'the saved session is already open',
        {'sessionId': record.id},
      );
    }
    // Reserve before target resolution's first await. A second request cannot
    // resolve or spawn while this record is being initialized.
    _continuing.add(record.id);
    try {
      await _checkContinueTarget(record.target);
      _available();
      if (previous != null) _forget(previous);
      final wanted = params.runtimeProfileId ?? record.runtimeProfileId;
      var profile = wanted == null ? null : await profiles.find(wanted);
      if (profile == null && params.runtimeProfileId == null) {
        final listed = await profiles.list();
        profile = listed.defaultId == null
            ? null
            : await profiles.find(listed.defaultId!);
      }
      if (profile == null) {
        throw RpcException(
          ErrorCode.noRuntimeProfile,
          'The saved session runtime profile and current default are unavailable. Choose or add a runtime profile.',
        );
      }
      if (profile.runtimeKind != record.runtimeKind) {
        throw RpcException(
          ErrorCode.noRuntimeProfile,
          'Choose a compatible ${record.runtimeKind} runtime profile.',
        );
      }
      _available();
      final (a, adapter, claims) = await _open(
        record.target,
        profile,
        saved: record,
      );
      return AgentContinueResult(
        eventChannel: a.channel,
        adapter: adapter,
        capabilities: claims.capabilities,
        mode: a.mode!,
        tools: a.session.tools,
      );
    } finally {
      _continuing.remove(record.id);
    }
  }

  /// Node-based Claude runtimes need their resolved Node directory on PATH,
  /// including editable copies of detected profiles under a minimal desktop
  /// environment. Keep inherited PATH host-private rather than serializing it
  /// into a bounded profile. Explicit overrides retain their normal authority.
  Map<String, String> _launchEnvironment(
    RuntimeProfile profile,
    String executable,
  ) {
    if (profile.runtimeKind == 'codex') {
      return nativeCodexLaunchEnvironment(profile, executable);
    }
    if (profile.runtimeKind != 'claude-code') return profile.env;
    final windows = Platform.isWindows;
    final name = executable.substring(
      max(executable.lastIndexOf('/'), executable.lastIndexOf('\\')) + 1,
    );
    if (windows ? name.toLowerCase() != 'node.exe' : name != 'node') {
      return profile.env;
    }
    for (final key in profile.env.keys) {
      if (windows ? key.toUpperCase() == 'PATH' : key == 'PATH') {
        return profile.env;
      }
    }
    final inherited =
        Platform.environment['PATH'] ?? Platform.environment['Path'] ?? '';
    final nodeDir = File(executable).parent.path;
    final separator = windows ? ';' : ':';
    return {
      'PATH': '$nodeDir${inherited.isEmpty ? '' : '$separator$inherited'}',
      ...profile.env,
    };
  }

  /// Start and Continue share exactly the contained launch, initialization,
  /// reservation, callback ownership and failed-attempt cleanup path.
  Future<(_Agent, AgentAdapter, AdapterClaims)> _open(
    AgentTarget target,
    RuntimeProfile profile, {
    AgentSessionRecord? saved,
  }) async {
    if (profile.runtimeKind == 'codex') {
      _requireCodexPeer();
    }
    if (!const ['claude-code', 'codex'].contains(profile.runtimeKind)) {
      throw RpcException(
        ErrorCode.invalidProfile,
        'Unsupported runtime kind ${profile.runtimeKind}',
      );
    }
    // Profile detection may have awaited. Continue rechecks through the bounded
    // resolver; UnitManager verifies the captured identity before spawn for both.
    if (saved != null) await _checkContinueTarget(target);
    final executable = await _executables.resolve(profile.executable);
    final executableFile = File(executable);
    final identity = await executableFile.stat();
    String? codexVersion;
    if (profile.runtimeKind == 'codex') {
      try {
        codexVersion = await probeCodexVersion(
          units,
          profileDirectory,
          executable,
          options,
          resolutionEnvironment: _launchEnvironment(profile, executable),
        );
      } on CodexProtocolException catch (e) {
        throw RpcException(ErrorCode.adapterProtocol, e.message);
      }
      final again = await executableFile.stat();
      if (again.size != identity.size ||
          again.modified != identity.modified ||
          await _executables.resolve(profile.executable) != executable) {
        throw RpcException(
          ErrorCode.adapterProtocol,
          'Codex executable changed after version probe',
        );
      }
    }
    _available();
    final reservation = connection.reserveChannels(1);
    _AgentIO? io;
    ToolGrant? grant;
    _Agent? live;
    var stage = 'spawn';
    try {
      // The grant exists before the adapter starts, so a bridge that races
      // `session/new` can authenticate and wait for the record. Without an
      // endpoint the adapter gets no `kumiko` entry at all.
      final endpoint = tools.endpoint;
      if (endpoint != null && profile.runtimeKind != 'codex') {
        grant = tools.register(
          target: target.path,
          role: ToolRole.coding,
          runtime: profile.runtimeKind,
          profile: profile.id,
          onAuthenticated: () {
            final a = live;
            if (a != null && _current(a)) a.session.toolsAuthenticated();
          },
          onCallSucceeded: () {
            final a = live;
            if (a != null && _current(a)) a.session.toolsCalled();
          },
        );
        _grants.add(grant);
      }
      final launch = await units.launch(
        target: target.path,
        expectedIdentity: target.identity,
        kind: 'agent',
        argv: [executable, ...profile.args],
        workingDirectory: target.path,
        environment: _launchEnvironment(profile, executable),
        inheritParentEnvironment: profile.runtimeKind != 'codex',
        pipes: true,
      );
      io = _AgentIO(
        launch,
        codexVersion: codexVersion,
        qualified: qualifiedAdaptersOverride ?? qualifiedAdapters,
        authSignatures: options.codexAuthSignatures,
      );
      _io.add(io);
      final mcpServers = <Json>[
        if (grant != null)
          {
            'name': 'kumiko',
            'command': Platform.resolvedExecutable,
            'args': ['--mcp-bridge'],
            'env': [
              {'name': 'KUMIKO_TOOL_ENDPOINT', 'value': endpoint!},
              {'name': 'KUMIKO_TOOL_SECRET', 'value': grant.secret},
              {'name': unitMarkerVariable, 'value': launch.id},
            ],
          },
      ];
      _available();
      stage = 'initialize';
      final initialization = await io.client.initialize();
      _available();
      final claims = initialization.claims;
      final adapter = AgentAdapter(
        name: initialization.name,
        version: initialization.version,
      );
      grant?.setAdapter(adapter.name, adapter.version);
      late final _Agent a;
      if (saved == null) {
        final startingIo = io;
        stage = 'session/new';
        await io.client.newSession(
          target.path,
          mcpServers: mcpServers,
          onCreated: (native) {
            _available();
            final now = DateTime.now().toUtc().toIso8601String();
            final record = AgentSessionRecord(
              id: _newId(),
              runtimeKind: profile.runtimeKind,
              runtimeProfileId: profile.id,
              adapter: adapter,
              nativeSessionId: native,
              target: target,
              createdAt: now,
              updatedAt: now,
            );
            stage = 'record';
            _insert(record);
            a = _registerNativeSession(
              record: record,
              io: startingIo,
              reservation: reservation,
              claims: claims,
              grant: grant,
              mcpServers: mcpServers,
            );
            live = a;
          },
        );
      } else {
        if (!claims.canLoad && !claims.canResume) {
          throw _resumeUnavailable(
            claims.unavailableReason!,
            'Adapter ${adapter.name} version ${adapter.version} cannot continue this session: ${claims.unavailableReason}.',
            tools: profile.runtimeKind == 'codex'
                ? const AgentTools(
                    AgentToolsStatus.unavailable,
                    reason: 'Codex safe private tool delivery is unavailable',
                  )
                : null,
          );
        }
        a = _registerNativeSession(
          record: saved,
          io: io,
          reservation: reservation,
          claims: claims,
          mode: claims.canLoad
              ? AgentContinueMode.load
              : AgentContinueMode.resume,
          grant: grant,
          mcpServers: mcpServers,
        );
        live = a;
      }
      return (a, adapter, claims);
    } on Object catch (error) {
      // An attempt that never produced a session releases its secret; calls
      // still waiting for the record answer session unavailable.
      if (live == null) _revoke(grant);
      if (io != null) {
        final outcome = await _end(io);
        await io.client.close();
        if (outcome.cleaned) {
          try {
            await _disposeIo(io);
          } on Object {
            // Containment is already settled. Preserve the actual start
            // failure rather than replacing it with an endpoint-close error.
          }
        }
      }
      reservation.release();
      if (error is UnitTargetChanged) {
        if (saved != null) {
          throw _resumeUnavailable(
            'target-changed',
            'the saved session target changed while the adapter was starting',
          );
        }
        throw RpcException(
          ErrorCode.workspaceUnavailable,
          'the workspace target changed while the adapter was starting',
        );
      }
      if (error is RpcException) {
        if (error.reason == ErrorCode.targetUnavailable) {
          if (saved != null) {
            throw _resumeUnavailable('target-missing', error.message);
          }
          throw RpcException(
            ErrorCode.workspaceUnavailable,
            error.message,
            error.data,
          );
        }
        if (saved != null && error.reason == ErrorCode.cleanupUnresolved) {
          throw _resumeUnavailable('cleanup-unresolved', error.message);
        }
        rethrow;
      }
      if (error is CodexProtocolException) {
        throw RpcException(ErrorCode.adapterProtocol, error.message, {
          'stage': stage,
        });
      }
      if (error is AcpProtocolException) {
        throw RpcException(
          ErrorCode.adapterProtocol,
          _redact(error.message, grant),
          {'stage': stage},
        );
      }
      final tail = _redact(io?.stderr.tail() ?? '', grant);
      final status = io?.status;
      final reason =
          error is CodexRemoteException && error.isAuthenticationRequired
          ? ErrorCode.authRequired
          : stage == 'session/new' &&
                error is AcpRemoteException &&
                error.isAuthenticationRequired
          ? ErrorCode.authRequired
          : stage == 'initialize' && tail.startsWith('unit-exec:')
          ? status == 127
                ? ErrorCode.executableNotFound
                : status == 126
                ? ErrorCode.notExecutable
                : ErrorCode.adapterStartFailed
          : ErrorCode.adapterStartFailed;
      final message = _redact(
        error is AcpRemoteException
            ? error.message
            : error is CodexRemoteException
            ? error.message
            : error.toString(),
        grant,
      );
      final nativeMessage = error is AcpRemoteException
          ? clampUtf8(_redact(error.message, grant), 4096)
          : error is CodexRemoteException
          ? clampUtf8(_redact(error.message, grant), 4096)
          : null;
      throw RpcException(
        reason,
        clampUtf8(
          '$message${status == null ? '' : ' (exit status $status)'}${tail.isEmpty ? '' : '\n$tail'}',
          4096,
        ),
        {
          'stage': stage,
          'detail': tail.isEmpty ? clampUtf8(message, 4096) : tail,
          'status': ?status,
          if (error is AcpRemoteException) 'nativeCode': error.code,
          if (error is CodexRemoteException) 'nativeCode': error.code,
          'nativeMessage': ?nativeMessage,
          if (error is AcpRemoteException &&
              (error.messageTruncated ||
                  nativeMessage != _redact(error.message, grant)))
            'nativeMessageTruncated': true,
          if (error is CodexRemoteException && error.messageTruncated)
            'nativeMessageTruncated': true,
        },
      );
    }
  }

  _Agent _registerNativeSession({
    required AgentSessionRecord record,
    required _AgentIO io,
    required ChannelReservation reservation,
    required AdapterClaims claims,
    AgentContinueMode? mode,
    ToolGrant? grant,
    List<Json> mcpServers = const [],
  }) {
    final a = _Agent(
      record: record,
      io: io,
      reservation: reservation,
      runId: _newId(),
      mode: mode,
      grant: grant,
      mcpServers: mcpServers,
    );
    _agents[record.id] = a;
    grant?.bind(record.id);
    a.relay.onFailure = (error) => _fail(a, error);
    a.session = AgentSession(
      sessionId: record.id,
      driver: io.client,
      runId: record.runtimeKind == 'codex' ? a.runId : null,
      claims: claims,
      nativeSessionId: record.nativeSessionId,
      tools: record.runtimeKind == 'codex'
          ? const AgentTools(
              AgentToolsStatus.unavailable,
              reason: 'Codex safe private tool delivery is unavailable',
            )
          : _startTools(grant, record.adapter),
      toolsAuthenticated: grant?.everAuthenticated ?? false,
      redact: (text) => _redact(text, grant),
      secrets: () => _secretsFor(grant),
      enqueueEvents: a.relay.enqueue,
      reserveEarly: a.relay.reserveEarly,
      releaseEarly: a.relay.releaseEarly,
      enqueueReserved: a.relay.enqueueReserved,
      onState: (p) {
        _notify(a, Method.agentState, p.toJson());
        if (p.state == AgentState.failed) {
          // The constructor publishes starting before its assignment.
          unawaited(
            Future<void>(
              () => _fail(a, a.session.failure ?? const AcpClosedException()),
            ),
          );
        }
      },
      onQuestionRequested: (p) =>
          _notify(a, Method.agentQuestionRequested, p.toJson()),
      onQuestionResolved: (p) =>
          _notify(a, Method.agentQuestionResolved, p.toJson()),
      onPermissionRequested: (p) =>
          _notify(a, Method.agentPermissionRequested, p.toJson()),
      onPermissionResolved: (p) =>
          _notify(a, Method.agentPermissionResolved, p.toJson()),
      onStopResult: (p) => _notify(a, Method.agentStopResult, p.toJson()),
      onTurnEnded: (p) => _notify(a, Method.agentTurnEnded, p.toJson()),
    );
    if (mode == null) {
      a.session.ready(nativeSessionId: record.nativeSessionId);
    }
    a.attachTimer = Timer(options.attachTimeout, () {
      if (!_current(a) || a.attached) return;
      // Expiry owns abandonment even if failure settlement already owns
      // teardown. Its completion must still relinquish this reservation.
      a.consumerClosed = true;
      a.relay.close();
      if (a.exited || a.closeFailed) {
        _forget(a);
      } else {
        _beginClose(a, attachTimeout: true);
      }
    });
    unawaited(_watchExit(a));
    return a;
  }

  /// The tools status a run starts with (design D6), seeded from what the
  /// grant already saw during `session/new`.
  AgentTools _startTools(ToolGrant? grant, AgentAdapter adapter) {
    if (grant == null) {
      return AgentTools(
        AgentToolsStatus.unavailable,
        reason: tools.unavailableReason ?? 'endpoint-unavailable: not started',
      );
    }
    if (grant.everCalled) return const AgentTools(AgentToolsStatus.connected);
    for (final (name, version, text)
        in toolDeliveryFailuresOverride ?? toolDeliveryFailures) {
      if (name == adapter.name && version == adapter.version) {
        return AgentTools(
          AgentToolsStatus.unavailable,
          reason: 'for $name $version: $text',
        );
      }
    }
    return const AgentTools(AgentToolsStatus.notYetUsed);
  }

  void _insert(AgentSessionRecord r) {
    try {
      store.execute('BEGIN IMMEDIATE');
      try {
        store.execute(
          'INSERT INTO agent_session(id, runtime_kind, runtime_profile_id, adapter_name, adapter_version, native_session_id, role, target_host, target_path, target_identity, workspace_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [
            r.id,
            r.runtimeKind,
            r.runtimeProfileId,
            r.adapter.name,
            r.adapter.version,
            r.nativeSessionId,
            'coding',
            r.target.host,
            r.target.path,
            r.target.identity,
            r.target.workspaceId,
            r.createdAt,
            r.updatedAt,
          ],
        );
        store.execute('COMMIT');
      } on Object {
        store.execute('ROLLBACK');
        rethrow;
      }
    } on SqliteException {
      throw RpcException(
        ErrorCode.storeError,
        'could not save the native agent session reference',
      );
    }
  }

  void attach(AgentSessionParams params) {
    final a = _require(params.sessionId, allowExited: true);
    // Failure settlement still owns the returned channel and its accepted
    // transcript. The first attach is valid throughout that interval, not
    // only after the final exit notification has been assembled. Explicit
    // close transitions to closing and must continue to refuse attach.
    final earlyExit = !a.attached && a.session.state == AgentState.failed;
    if (a.consumerClosed || (a.ending && !earlyExit)) {
      throw RpcException(ErrorCode.unknownSession, 'session is closing');
    }
    if (a.attached) {
      throw RpcException(ErrorCode.invalidParams, 'session already attached');
    }
    a.attached = true;
    a.attachTimer?.cancel();
    final writer = connection.attachOutbound(a.channel);
    a.relay.attach(writer);
    unawaited(
      writer.closed.then((_) {
        if (!identical(_agents[a.record.id], a) || _disposed) return;
        a.consumerClosed = true;
        a.relay.close();
        // A receiver may intentionally cancel after every byte was flushed,
        // leaving no failed write to reveal that it abandoned this channel.
        if (a.exited || a.closeFailed) {
          _forget(a);
        } else if (!a.ending) {
          _beginClose(a, attachTimeout: true);
        }
      }),
    );
    unawaited(
      Future<void>(() {
        if (!_current(a)) return;
        a.session.publishState();
        if (a.mode != null && !a.ending && !a.exited) unawaited(_restore(a));
        final exit = a.exitNotification;
        if (earlyExit && exit != null) {
          _notify(a, Method.agentExited, exit.toJson());
          a.callbacks = false;
          a.session.dispose();
        }
      }),
    );
  }

  Future<void> _restore(_Agent a) async {
    try {
      if (a.mode == AgentContinueMode.load) {
        await a.session.replayStarted();
        if (!_current(a) || a.ending) return;
        await a.io.client.loadSession(
          a.record.nativeSessionId,
          a.record.target.path,
          mcpServers: a.mcpServers,
        );
        if (!_current(a) || a.ending) return;
        await a.session.replayEnded();
      } else {
        await a.session.notice('earlier messages not shown');
        if (!_current(a) || a.ending) return;
        await a.io.client.resumeSession(
          a.record.nativeSessionId,
          a.record.target.path,
          mcpServers: a.mcpServers,
        );
      }
      if (_current(a) && !a.ending) {
        a.session.ready(nativeSessionId: a.record.nativeSessionId);
        a.restoring = false;
      }
    } on Object catch (error) {
      if (_current(a) && !a.ending) await _finishFailure(a, error);
    }
  }

  /// Validates, commits the removal of the draft the prompt carries, and only
  /// then dispatches (design D4): a failed or late commit refuses the prompt,
  /// so a sent text is never left stored. Everything before the first await
  /// runs in arrival order, so a later `agent/draftSave` queues behind the
  /// removal. A retry carries no draft fields and removes nothing.
  Future<void> prompt(AgentPromptParams params) async {
    final a = _require(params.sessionId);
    a.session.checkCanPrompt(params.text);
    final revision = params.draftRevision;
    if (revision == null) {
      a.session.acceptPrompt(params.text);
      return;
    }
    if (a.sending) {
      throw RpcException(
        ErrorCode.turnRunning,
        'a turn is already running or the session is unavailable',
      );
    }
    a.sending = true;
    try {
      await drafts.commitSend(
        params.sessionId,
        revision,
        synced: params.draftSynced ?? false,
      );
    } finally {
      a.sending = false;
    }
    _available();
    final again = _require(params.sessionId);
    again.session.acceptPrompt(params.text);
  }

  Future<AgentDraftSaveResult> draftSave(AgentDraftSaveParams params) async {
    _available();
    _requireRecord(params.sessionId);
    return AgentDraftSaveResult(
      await drafts.save(params.sessionId, params.text, params.revision),
    );
  }

  Future<AgentDraftLoadResult> draftLoad(AgentSessionParams params) async {
    _available();
    _requireRecord(params.sessionId);
    final loaded = await drafts.load(params.sessionId);
    return AgentDraftLoadResult(revision: loaded.revision, text: loaded.text);
  }

  Future<void> draftReset() async {
    _available();
    await drafts.reset();
  }

  void _requireRecord(String id) {
    if (_record(id) == null) {
      throw RpcException(
        ErrorCode.unknownSession,
        'there is no agent session $id',
        {'sessionId': id},
      );
    }
  }

  /// The store opened or answers again: tell a desktop that can use it.
  void _draftStoreReady() {
    if (_disposed) return;
    if (connection.negotiated?.capabilities.contains(Capability.agent) ??
        false) {
      connection.notify(Method.agentDraftStoreReady, <String, Object?>{});
    }
  }

  /// Read only on demand by the test extension.
  Json draftSnapshot() => {
    'phase': drafts.phase.name,
    'notResponding': drafts.notResponding,
    'pending': drafts.pending,
    'workersSpawned': drafts.workersSpawned,
    'disabledReason': drafts.disabledReason,
    'pragmas': drafts.pragmas,
  };

  void _requireCodexPeer() =>
      requireCodexCapabilities(connection.negotiated?.capabilities ?? const {});

  _Agent _extensionRun(String sessionId, String runId) {
    _requireCodexPeer();
    final a = _require(sessionId);
    if (a.ending || a.runId != runId) {
      throw RpcException(
        ErrorCode.staleRun,
        'the native run is no longer current',
      );
    }
    return a;
  }

  Future<void> steer(AgentSteerParams params) async {
    final a = _extensionRun(params.sessionId, params.runId);
    a.session.checkCanSteer(params.expectedTurnId, params.text);
    if (a.sending) {
      throw RpcException(
        ErrorCode.turnRunning,
        'another input is being admitted',
      );
    }
    final delivery = a.session.prepareSteer(params.expectedTurnId, params.text);
    try {
      if (params.draftRevision != null) {
        a.sending = true;
        try {
          await drafts.commitSend(
            params.sessionId,
            params.draftRevision!,
            synced: params.draftSynced ?? false,
          );
        } finally {
          a.sending = false;
        }
      }
      final current = _extensionRun(params.sessionId, params.runId);
      current.session.acceptSteer(params.expectedTurnId, params.text, delivery);
    } on Object {
      delivery.release();
      rethrow;
    }
  }

  void questionAnswer(AgentQuestionAnswerParams params) {
    final a = _extensionRun(params.sessionId, params.runId);
    a.session.questionAnswer(params);
  }

  void stop(AgentSessionParams params) {
    final a = _require(params.sessionId);
    if (a.ending) {
      throw RpcException(ErrorCode.unknownSession, 'session is closing');
    }
    a.session.stop();
  }

  void permissionReply(AgentPermissionReplyParams params) {
    final a = _require(params.sessionId);
    a.session.permissionReply(params.requestId, params.optionId);
  }

  void close(AgentSessionParams params) {
    final a = _require(params.sessionId);
    if (a.closeRequested) return;
    a.closeRequested = true;
    if (!a.ending) {
      _beginClose(a);
    } else {
      // Failure settlement still owns cleanup. Preserve dismissal without
      // starting another teardown, and abandon any credit-blocked transcript.
      a.attachTimer?.cancel();
      a.session.beginClosing();
      a.relay.close();
    }
  }

  void release(AgentSessionParams params) {
    final a = _require(params.sessionId, allowExited: true);
    if (!a.exited) {
      throw RpcException(ErrorCode.invalidParams, 'session has not exited');
    }
    _forget(a);
  }

  void _beginClose(_Agent a, {bool attachTimeout = false}) {
    if (!_current(a) || a.ending || a.exited) return;
    final running = switch (a.session.state) {
      AgentState.running ||
      AgentState.waitingApproval ||
      AgentState.stopping => true,
      _ => false,
    };
    a.ending = true;
    _revoke(a.grant);
    a.attachTimer?.cancel();
    a.session.beginClosing();
    a.relay.close();
    // Schedule on the event queue, not a microtask: the close result is
    // written before an idle unit can settle and publish its exit.
    unawaited(
      Future<void>(() async {
        if (!_current(a)) return;
        if (running && !attachTimeout) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        if (!_current(a)) return;
        final outcome = await _end(a.io);
        await a.io.client.close();
        if (outcome.cleaned) {
          await _disposeIo(a.io);
        }
        if (!_current(a)) return;
        if (outcome.cleaned) {
          a.exited = true;
          a.session.ended();
          _notify(
            a,
            Method.agentExited,
            AgentExitedParams(
              sessionId: a.record.id,
              reason: AgentExitReason.closed,
              eventCount: a.relay.eventCount,
              status: a.io.status,
            ).toJson(),
          );
          if (attachTimeout || a.consumerClosed) _forget(a);
        } else {
          a.closeFailed = true;
          _notify(
            a,
            Method.agentCloseFailed,
            AgentCloseFailedParams(
              sessionId: a.record.id,
              reason: outcome.reason ?? 'cleanup-unresolved',
            ).toJson(),
          );
          _forget(a);
        }
      }).catchError((Object error) {
        if (_current(a)) {
          a.closeFailed = true;
          _notify(
            a,
            Method.agentCloseFailed,
            AgentCloseFailedParams(
              sessionId: a.record.id,
              reason: 'agent-io-close-failed',
            ).toJson(),
          );
          _forget(a);
        }
      }),
    );
  }

  Future<UnitOutcome> _end(_AgentIO io) => io.ending ??= () async {
    final id = io.launch.id;
    if (!units.live.containsKey(id)) {
      final row = units.ledger.unit(id);
      return row == null
          ? const UnitOutcome.cleaned()
          : UnitOutcome.unresolved(row.reason ?? 'cleanup-unresolved');
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
    // EOF is independently terminal even if the adapter keeps running, or if
    // output closed just before AgentSession installed its failure callback.
    // Explicit close/failure settlement already owns teardown when ending.
    unawaited(
      a.io.client.done.then((_) {
        if (!_current(a) || a.ending) return;
        final error = a.io.client.failure ?? const AcpClosedException();
        a.session.fail(error);
        _fail(a, error);
      }),
    );
    final status = await a.io.launch.unit.exitCode;
    a.io.status = status;
    if (!_current(a) || a.ending) return;
    // Native exit is authoritative even when ACP is still admitting an
    // expanded final update under backpressure. Retire choices without native
    // replies: stdin has closed, but the ACP reader must drain through EOF.
    a.session.observeExit();
    // The run is over: its secret stops working now, not once the transcript
    // has drained (that can wait on desktop credit indefinitely).
    _revoke(a.grant);
    // EOF owns the separate final-count lifecycle: buffered updates must
    // finish normalization/admission before sealing or disposing their pipes.
    await a.io.client.done;
    if (!_current(a) || a.ending) return;
    await _finishFailure(a, a.io.client.failure ?? const AcpClosedException());
  }

  void _fail(_Agent a, Object error) {
    if (!_current(a) || a.ending || a.exited || a.closeFailed) return;
    // A real leader exit publishes Failed immediately, but its ACP reader may
    // still be admitting accepted final updates under credit backpressure.
    // Only that synthetic pre-EOF failure waits for lossless drain. Actual
    // EOF (including a still-live leader) always starts containment settlement.
    if (error is AcpClosedException &&
        a.io.status != null &&
        !a.io.client.isClosed) {
      return;
    }
    unawaited(_finishFailure(a, error));
  }

  Future<void> _finishFailure(_Agent a, Object error) async {
    if (!_current(a) || a.ending) return;
    final restoring = a.restoring;
    a.ending = true;
    _revoke(a.grant);
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
    }
    if (!_current(a)) return;
    if (!outcome.cleaned) {
      a.closeFailed = true;
      _notify(
        a,
        Method.agentCloseFailed,
        AgentCloseFailedParams(
          sessionId: a.record.id,
          reason: outcome.reason ?? 'cleanup-unresolved',
        ).toJson(),
      );
      _forget(a);
    } else {
      // ACP EOF joins adapter updates, but canonical user/turn/notice records
      // also use the session's FIFO. Join accepted work before sealing the
      // count, unless explicit dismissal closed the relay to abandon it.
      // Enqueue errors remain failures, not false successful exits.
      await a.session.eventsEnqueued.then<void>((_) {}, onError: (Object _) {});
      if (!_current(a)) return;
      a.exited = true;
      if (a.closeRequested) a.session.ended();
      a.session.dispose();
      a.relay.seal();
      final protocolMessage = error is AcpProtocolException
          ? error.message
          : error is CodexProtocolException
          ? error.message
          : null;
      final exited = a.exitNotification = AgentExitedParams(
        sessionId: a.record.id,
        reason: a.closeRequested
            ? AgentExitReason.closed
            : AgentExitReason.failed,
        eventCount: a.relay.eventCount,
        status: a.io.status,
        error: restoring
            ? ErrorCode.resumeUnavailable
            : protocolMessage != null
            ? ErrorCode.adapterProtocol
            : 'adapter-exited',
        resumeReason: restoring
            ? error is AcpRemoteException && error.isAuthenticationRequired
                  ? ErrorCode.authRequired
                  : 'adapter-error'
            : null,
        message: restoring
            ? error is AcpRemoteException && error.messageTruncated
                  ? '${clampUtf8(_redact(error.message, a.grant), 4096 - ' [truncated]'.length)} [truncated]'
                  : clampUtf8(
                      _redact(
                        error is AcpRemoteException
                            ? error.message
                            : error.toString(),
                        a.grant,
                      ),
                      4096,
                    )
            : protocolMessage != null
            ? _redact(protocolMessage, a.grant)
            : null,
      );
      _notify(a, Method.agentExited, exited.toJson());
      if (a.consumerClosed) _forget(a);
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
    await io.errorsDone.future.timeout(
      options.postExitReadDeadline,
      onTimeout: () {},
    );
    await io.launch.pipes!.close();
    await io.errors.cancel();
    _io.remove(io);
  }();

  void _forget(_Agent a) {
    _revoke(a.grant);
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
    drafts.dispose();
    for (final grant in _grants.toList()) {
      _revoke(grant);
    }
    for (final a in _agents.values) {
      a.callbacks = false;
      a.attachTimer?.cancel();
      a.session.dispose();
      a.relay.close();
      a.reservation.release();
    }
    for (final io in _io) {
      io.client.close().ignore();
    }
  }

  /// After shared shutdown, join only I/O whose containment actually ended.
  /// An unresolved live unit keeps its ledger and native ownership until the
  /// host exits; never hang shutdown joining its still-blocked native read.
  Future<void> finishShutdown() async {
    await Future.wait([
      for (final io in _io.toList())
        if (!units.live.containsKey(io.launch.id) &&
            units.ledger.unit(io.launch.id) == null)
          _disposeIo(io),
    ]);
  }
}
