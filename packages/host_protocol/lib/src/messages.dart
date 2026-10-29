import 'dart:convert';

/// Every wire message of the protocol, hand-written, used by both sides
/// (design D5, D8, D10). Parsing failures throw [RpcException] with
/// [ErrorCode.invalidParams].
typedef Json = Map<String, Object?>;

abstract final class Method {
  static const String hello = 'hello';
  static const String channelClose = 'channel/close';
  static const String cleanupState = 'cleanup/state';
  static const String cleanupList = 'cleanup/list';
  static const String cleanupUnits = 'cleanup/units';
  static const String cleanupRetry = 'cleanup/retry';
  static const String cleanupConfirm = 'cleanup/confirm';
  static const String workspaceChanged = 'workspace/changed';
  static const String workbenchLoad = 'workbench/load';
  static const String workbenchSave = 'workbench/save';
  static const String workspaceOpen = 'workspace/open';
  static const String workspaceCheck = 'workspace/check';
  static const String workspaceList = 'workspace/list';
  static const String workspaceRemove = 'workspace/remove';
  static const String testUnitLaunch = 'test/unit.launch';
  static const String testUnitEnd = 'test/unit.end';
  static const String testChannelOpen = 'test/channel.open';
  static const String testChannelStats = 'test/channel.stats';
  static const String testFaultSet = 'test/fault.set';
  static const String testResolveFault = 'test/resolve.fault';
  static const String testResolveRelease = 'test/resolve.release';
  static const String profileList = 'profile/list';
  static const String profileSave = 'profile/save';
  static const String profileRemove = 'profile/remove';
  static const String profileSetDefault = 'profile/setDefault';
  static const String terminalOpen = 'terminal/open';
  static const String terminalAttach = 'terminal/attach';
  static const String terminalResize = 'terminal/resize';
  static const String terminalClose = 'terminal/close';
  static const String terminalRelease = 'terminal/release';
  static const String terminalExited = 'terminal/exited';
  static const String terminalCloseFailed = 'terminal/closeFailed';
}

abstract final class Capability {
  static const String workbench = 'workbench';
  static const String testUnits = 'test.units';
  static const String testChannels = 'test.channels';
  static const String testFaults = 'test.faults';
  static const String terminal = 'terminal';
}

/// The capability a method needs; methods not listed need none.
const Map<String, String> methodCapability = {
  Method.workbenchLoad: Capability.workbench,
  Method.workbenchSave: Capability.workbench,
  Method.workspaceOpen: Capability.workbench,
  Method.workspaceCheck: Capability.workbench,
  Method.workspaceList: Capability.workbench,
  Method.workspaceRemove: Capability.workbench,
  Method.testUnitLaunch: Capability.testUnits,
  Method.testUnitEnd: Capability.testUnits,
  Method.testChannelOpen: Capability.testChannels,
  Method.testChannelStats: Capability.testChannels,
  Method.testFaultSet: Capability.testFaults,
  Method.testResolveFault: Capability.testFaults,
  Method.testResolveRelease: Capability.testFaults,
  Method.profileList: Capability.terminal,
  Method.profileSave: Capability.terminal,
  Method.profileRemove: Capability.terminal,
  Method.profileSetDefault: Capability.terminal,
  Method.terminalOpen: Capability.terminal,
  Method.terminalAttach: Capability.terminal,
  Method.terminalResize: Capability.terminal,
  Method.terminalClose: Capability.terminal,
  Method.terminalRelease: Capability.terminal,
};

/// Error reasons, carried as `error.data.reason`.
abstract final class ErrorCode {
  static const String methodNotAvailable = 'method-not-available';
  static const String protocolError = 'protocol-error';
  static const String invalidParams = 'invalid-params';
  static const String internalError = 'internal-error';
  static const String incompatibleVersion = 'incompatible-version';
  static const String busy = 'busy';
  static const String channelCap = 'channel-cap';
  static const String reconciling = 'reconciling';
  static const String unitCap = 'unit-cap';
  static const String cleanupUnresolved = 'cleanup-unresolved';
  static const String targetUnavailable = 'target-unavailable';
  static const String storeError = 'store-error';
  static const String retryInProgress = 'retry-in-progress';
  static const String outerJobMissing = 'outer-job-missing';
  static const String shuttingDown = 'shutting-down';
  static const String profileLocked = 'profile-locked';
  static const String profileUnavailable = 'profile-unavailable';
  static const String storeMigrationFailed = 'store-migration-failed';
  static const String storeNewer = 'store-newer';
  static const String storeUnreadable = 'store-unreadable';
  static const String layoutInvalid = 'layout-invalid';
  static const String staleRevision = 'stale-revision';
  static const String resolveTimeout = 'resolve-timeout';
  static const String workspaceCap = 'workspace-cap';
  static const String workspaceInUse = 'workspace-in-use';
  static const String unknownWorkspace = 'unknown-workspace';
  static const String channelLimit = 'channel-limit';
  static const String unknownTerminal = 'unknown-terminal';
  static const String invalidSize = 'invalid-size';
  static const String executableNotFound = 'executable-not-found';
  static const String spawnFailed = 'spawn-failed';
  static const String notAttached = 'not-attached';
  static const String consoleCleanupPending = 'console-cleanup-pending';

  /// The JSON-RPC numeric code for [reason].
  static int numeric(String reason) => switch (reason) {
    protocolError => -32600,
    methodNotAvailable => -32601,
    invalidParams => -32602,
    internalError => -32603,
    _ => -32000,
  };
}

/// A JSON-RPC error with a protocol reason and optional structured data (for
/// example the paths of an unreadable store).
class RpcException implements Exception {
  RpcException(this.reason, [this.message = '', this.data = const {}]);

  factory RpcException.fromJson(Json json) {
    final data = json['data'];
    final extra = data is Map<String, Object?>
        ? data
        : const <String, Object?>{};
    return RpcException(
      extra['reason'] is String
          ? extra['reason']! as String
          : ErrorCode.internalError,
      json['message'] is String ? json['message']! as String : '',
      {...extra}..remove('reason'),
    );
  }

  final String reason;
  final String message;
  final Json data;

  Json toJson() => {
    'code': ErrorCode.numeric(reason),
    'message': message,
    'data': {...data, 'reason': reason},
  };

  @override
  String toString() => 'RpcException($reason): $message';
}

T _req<T>(Json json, String key) {
  final value = json[key];
  if (value is T) return value;
  throw RpcException(ErrorCode.invalidParams, 'missing or invalid "$key"');
}

T? _opt<T>(Json json, String key) {
  final Object? value = json[key];
  if (value == null) return null;
  if (value is T) return value as T;
  throw RpcException(ErrorCode.invalidParams, 'invalid "$key"');
}

List<T> _list<T>(Json json, String key) => [
  for (final e in _req<List<Object?>>(json, key))
    if (e is T)
      e
    else
      throw RpcException(ErrorCode.invalidParams, 'invalid "$key" element'),
];

int _limit(Json json, int max) {
  final limit = _opt<int>(json, 'limit') ?? max;
  if (limit < 1 || limit > max) {
    throw RpcException(ErrorCode.invalidParams, 'limit must be 1..$max');
  }
  return limit;
}

T _enum<T extends Enum>(List<T> values, Json json, String key) {
  final name = _req<String>(json, key);
  for (final v in values) {
    if (v.name == name) return v;
  }
  throw RpcException(ErrorCode.invalidParams, 'unknown $key "$name"');
}

// --- hello ---------------------------------------------------------------

class VersionRange {
  const VersionRange(this.min, this.max);

  factory VersionRange.fromJson(Json json) {
    final range = VersionRange(_req<int>(json, 'min'), _req<int>(json, 'max'));
    if (range.min > range.max) {
      throw RpcException(ErrorCode.invalidParams, 'empty version range');
    }
    return range;
  }

  final int min;
  final int max;

  bool contains(int version) => version >= min && version <= max;

  /// The highest version in both ranges, or null when they do not overlap.
  int? highestCommon(VersionRange other) {
    final high = max < other.max ? max : other.max;
    final low = min > other.min ? min : other.min;
    return high >= low ? high : null;
  }

  Json toJson() => {'min': min, 'max': max};

  @override
  String toString() => '$min..$max';
}

class PriorHost {
  const PriorHost(this.instanceId, {required this.jobTerminated});

  factory PriorHost.fromJson(Json json) => PriorHost(
    _req<String>(json, 'instanceId'),
    jobTerminated: _req<bool>(json, 'jobTerminated'),
  );

  final String instanceId;
  final bool jobTerminated;

  Json toJson() => {'instanceId': instanceId, 'jobTerminated': jobTerminated};
}

class HelloParams {
  HelloParams({
    required this.versions,
    required this.capabilities,
    this.priorHost,
    this.desktopPid,
    this.desktopStartTime,
    this.outerJobHeld,
  });

  factory HelloParams.fromJson(Json json) {
    final prior = _opt<Json>(json, 'priorHost');
    return HelloParams(
      versions: VersionRange.fromJson(_req<Json>(json, 'versions')),
      capabilities: _list<String>(json, 'capabilities').toSet(),
      priorHost: prior == null ? null : PriorHost.fromJson(prior),
      desktopPid: _opt<int>(json, 'desktopPid'),
      desktopStartTime: _opt<int>(json, 'desktopStartTime'),
      outerJobHeld: _opt<bool>(json, 'outerJobHeld'),
    );
  }

  final VersionRange versions;
  final Set<String> capabilities;
  final PriorHost? priorHost;

  /// The desktop's pid and OS start time (`processStartTime`), recorded with
  /// every ledger entry so a later host can tell whether the desktop that
  /// held the Windows job still runs (design D8 b). Optional on the wire.
  final int? desktopPid;
  final int? desktopStartTime;

  /// Windows: the desktop attests it holds the host in its kill-on-close
  /// outer job. Absent or false makes the host refuse launches.
  final bool? outerJobHeld;

  Json toJson() => {
    'versions': versions.toJson(),
    'capabilities': capabilities.toList()..sort(),
    if (priorHost != null) 'priorHost': priorHost!.toJson(),
    if (desktopPid != null) 'desktopPid': desktopPid,
    if (desktopStartTime != null) 'desktopStartTime': desktopStartTime,
    if (outerJobHeld != null) 'outerJobHeld': outerJobHeld,
  };
}

enum HostState {
  reconciling,
  ready;

  static HostState fromJson(Json json, String key) => _enum(values, json, key);
}

/// What the host adds to a hello answer beyond the negotiation.
class HelloInfo {
  const HelloInfo({
    required this.instanceId,
    this.hostVersion = '',
    this.state = HostState.ready,
  });

  const HelloInfo.ready(String instanceId)
    : this(instanceId: instanceId, state: HostState.ready);

  final String instanceId;
  final String hostVersion;
  final HostState state;
}

class Negotiated {
  const Negotiated(this.version, this.capabilities);
  final int version;
  final Set<String> capabilities;
}

/// The session parameters, or null when the ranges do not overlap.
Negotiated? negotiate(
  VersionRange localVersions,
  Set<String> localCapabilities,
  HelloParams remote,
) {
  final version = localVersions.highestCommon(remote.versions);
  if (version == null) return null;
  return Negotiated(
    version,
    localCapabilities.intersection(remote.capabilities),
  );
}

class HelloResult {
  const HelloResult({
    required this.version,
    required this.capabilities,
    required this.instanceId,
    required this.hostVersion,
    required this.state,
  });

  factory HelloResult.fromJson(Json json) => HelloResult(
    version: _req<int>(json, 'version'),
    capabilities: _list<String>(json, 'capabilities').toSet(),
    instanceId: _req<String>(json, 'instanceId'),
    hostVersion: _req<String>(json, 'hostVersion'),
    state: HostState.fromJson(json, 'state'),
  );

  final int version;
  final Set<String> capabilities;
  final String instanceId;
  final String hostVersion;
  final HostState state;

  Json toJson() => {
    'version': version,
    'capabilities': capabilities.toList()..sort(),
    'instanceId': instanceId,
    'hostVersion': hostVersion,
    'state': state.name,
  };
}

RpcException incompatibleVersions(
  VersionRange requester,
  VersionRange responder,
) => RpcException(
  ErrorCode.incompatibleVersion,
  'incompatible protocol versions: desktop $requester, host $responder',
  {'requester': requester.toJson(), 'responder': responder.toJson()},
);

// --- channel/close -------------------------------------------------------

class ChannelCloseParams {
  const ChannelCloseParams(this.channel);
  factory ChannelCloseParams.fromJson(Json json) =>
      ChannelCloseParams(_req<int>(json, 'channel'));
  final int channel;
  Json toJson() => {'channel': channel};
}

// --- cleanup/* -----------------------------------------------------------

const int maxListWorkspaces = 25;
const int maxUnitsPerWorkspaceInList = 10;
const int maxUnitsPage = 100;
const int maxReasonBytes = 256;
const int maxPathBytes = 4096;

/// [value] cut to at most [maxBytes] of UTF-8, on a character boundary.
String clampUtf8(String value, int maxBytes) {
  final bytes = utf8.encode(value);
  if (bytes.length <= maxBytes) return value;
  var end = maxBytes;
  while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
    end--;
  }
  return utf8.decode(bytes.sublist(0, end));
}

/// Position in a cleanup listing, keyed by `(target_identity, containment_id)`.
class CleanupCursor {
  const CleanupCursor(this.targetIdentity, this.containmentId);

  factory CleanupCursor.decode(String encoded) {
    try {
      final parts = jsonDecode(utf8.decode(base64Url.decode(encoded)));
      if (parts is List<Object?> &&
          parts.length == 2 &&
          parts[0] is String &&
          parts[1] is String) {
        return CleanupCursor(parts[0]! as String, parts[1]! as String);
      }
    } on FormatException {
      // fall through
    }
    throw RpcException(ErrorCode.invalidParams, 'invalid cursor');
  }

  final String targetIdentity;
  final String containmentId;

  String encode() => base64Url.encode(
    utf8.encode(jsonEncode([targetIdentity, containmentId])),
  );
}

class CleanupState {
  const CleanupState({
    required this.reconciling,
    required this.revision,
    required this.unresolvedWorkspaces,
    required this.unresolvedUnits,
  });

  factory CleanupState.fromJson(Json json) => CleanupState(
    reconciling: _req<bool>(json, 'reconciling'),
    revision: _req<int>(json, 'revision'),
    unresolvedWorkspaces: _req<int>(json, 'unresolvedWorkspaces'),
    unresolvedUnits: _req<int>(json, 'unresolvedUnits'),
  );

  final bool reconciling;
  final int revision;
  final int unresolvedWorkspaces;
  final int unresolvedUnits;

  Json toJson() => {
    'reconciling': reconciling,
    'revision': revision,
    'unresolvedWorkspaces': unresolvedWorkspaces,
    'unresolvedUnits': unresolvedUnits,
  };
}

class CleanupUnit {
  const CleanupUnit({
    required this.containmentId,
    required this.kind,
    this.reason,
    this.pid,
  });

  factory CleanupUnit.fromJson(Json json) => CleanupUnit(
    containmentId: _req<String>(json, 'containmentId'),
    kind: _req<String>(json, 'kind'),
    reason: _opt<String>(json, 'reason'),
    pid: _opt<int>(json, 'pid'),
  );

  final String containmentId;
  final String kind;
  final String? reason;
  final int? pid;

  Json toJson() => {
    'containmentId': containmentId,
    'kind': kind,
    if (reason != null) 'reason': clampUtf8(reason!, maxReasonBytes),
    if (pid != null) 'pid': pid,
  };
}

class CleanupWorkspace {
  CleanupWorkspace({
    required this.targetIdentity,
    required this.targetPath,
    required this.unitCount,
    required this.units,
  }) : assert(units.length <= maxUnitsPerWorkspaceInList);

  factory CleanupWorkspace.fromJson(Json json) => CleanupWorkspace(
    targetIdentity: _req<String>(json, 'targetIdentity'),
    targetPath: _req<String>(json, 'targetPath'),
    unitCount: _req<int>(json, 'unitCount'),
    units: [
      for (final u in _list<Json>(json, 'units')) CleanupUnit.fromJson(u),
    ],
  );

  final String targetIdentity;
  final String targetPath;
  final int unitCount;
  final List<CleanupUnit> units;

  Json toJson() => {
    'targetIdentity': targetIdentity,
    'targetPath': clampUtf8(targetPath, maxPathBytes),
    'unitCount': unitCount,
    'units': [for (final u in units) u.toJson()],
  };
}

class CleanupListParams {
  const CleanupListParams({
    this.cursor,
    this.limit = maxListWorkspaces,
    this.revision,
    this.workspace,
  });

  factory CleanupListParams.fromJson(Json json) => CleanupListParams(
    cursor: _opt<String>(json, 'cursor'),
    limit: _limit(json, maxListWorkspaces),
    revision: _opt<int>(json, 'revision'),
    workspace: _opt<String>(json, 'workspace'),
  );

  final String? cursor;
  final int limit;

  /// The revision the caller last saw; a different current one marks the page
  /// stale.
  final int? revision;

  /// A workspace id (not a `target_identity`): list only that workspace's
  /// cleanup group. Absent lists every group.
  final String? workspace;

  Json toJson() => {
    if (cursor != null) 'cursor': cursor,
    'limit': limit,
    if (revision != null) 'revision': revision,
    if (workspace != null) 'workspace': workspace,
  };
}

class CleanupListResult {
  const CleanupListResult({
    required this.revision,
    required this.stale,
    required this.workspaces,
    this.nextCursor,
  });

  factory CleanupListResult.fromJson(Json json) => CleanupListResult(
    revision: _req<int>(json, 'revision'),
    stale: _req<bool>(json, 'stale'),
    workspaces: [
      for (final w in _list<Json>(json, 'workspaces'))
        CleanupWorkspace.fromJson(w),
    ],
    nextCursor: _opt<String>(json, 'nextCursor'),
  );

  final int revision;
  final bool stale;
  final List<CleanupWorkspace> workspaces;
  final String? nextCursor;

  Json toJson() => {
    'revision': revision,
    'stale': stale,
    'workspaces': [for (final w in workspaces) w.toJson()],
    if (nextCursor != null) 'nextCursor': nextCursor,
  };
}

class CleanupUnitsParams {
  const CleanupUnitsParams({
    required this.workspace,
    this.cursor,
    this.limit = maxUnitsPage,
    this.revision,
  });

  factory CleanupUnitsParams.fromJson(Json json) => CleanupUnitsParams(
    workspace: _req<String>(json, 'workspace'),
    cursor: _opt<String>(json, 'cursor'),
    limit: _limit(json, maxUnitsPage),
    revision: _opt<int>(json, 'revision'),
  );

  /// The workspace's `target_identity`.
  final String workspace;
  final String? cursor;
  final int limit;
  final int? revision;

  Json toJson() => {
    'workspace': workspace,
    if (cursor != null) 'cursor': cursor,
    'limit': limit,
    if (revision != null) 'revision': revision,
  };
}

class CleanupUnitsResult {
  const CleanupUnitsResult({
    required this.revision,
    required this.stale,
    required this.units,
    this.nextCursor,
  });

  factory CleanupUnitsResult.fromJson(Json json) => CleanupUnitsResult(
    revision: _req<int>(json, 'revision'),
    stale: _req<bool>(json, 'stale'),
    units: [
      for (final u in _list<Json>(json, 'units')) CleanupUnit.fromJson(u),
    ],
    nextCursor: _opt<String>(json, 'nextCursor'),
  );

  final int revision;
  final bool stale;
  final List<CleanupUnit> units;
  final String? nextCursor;

  Json toJson() => {
    'revision': revision,
    'stale': stale,
    'units': [for (final u in units) u.toJson()],
    if (nextCursor != null) 'nextCursor': nextCursor,
  };
}

/// Params of `cleanup/retry` and `cleanup/confirm`: they act on every unit of
/// the workspace, whatever was paged.
class CleanupActionParams {
  const CleanupActionParams(this.workspace);
  factory CleanupActionParams.fromJson(Json json) =>
      CleanupActionParams(_req<String>(json, 'workspace'));
  final String workspace;
  Json toJson() => {'workspace': workspace};
}

class CleanupActionResult {
  const CleanupActionResult({
    required this.resolvedUnits,
    required this.unresolvedUnits,
  });

  factory CleanupActionResult.fromJson(Json json) => CleanupActionResult(
    resolvedUnits: _req<int>(json, 'resolvedUnits'),
    unresolvedUnits: _req<int>(json, 'unresolvedUnits'),
  );

  final int resolvedUnits;
  final int unresolvedUnits;

  Json toJson() => {
    'resolvedUnits': resolvedUnits,
    'unresolvedUnits': unresolvedUnits,
  };
}

// --- workbench/* and workspace/* -----------------------------------------

/// A `stale-revision` error carrying the stored layout revision.
RpcException staleRevision(int storedRevision, [String message = '']) =>
    RpcException(ErrorCode.staleRevision, message, {
      'storedRevision': storedRevision,
    });

/// The `storedRevision` of a `stale-revision` error, or null when absent.
int? storedRevisionOf(RpcException e) {
  final v = e.data['storedRevision'];
  return v is int ? v : null;
}

enum Availability {
  checking,
  available,
  unavailable;

  static Availability fromJson(Json json, String key) =>
      _enum(values, json, key);
}

class WorkspaceCleanup {
  const WorkspaceCleanup({required this.groups});

  factory WorkspaceCleanup.fromJson(Json json) =>
      WorkspaceCleanup(groups: _req<int>(json, 'groups'));

  /// Unresolved cleanup groups attributed to the workspace.
  final int groups;

  Json toJson() => {'groups': groups};
}

class WorkspaceRecord {
  const WorkspaceRecord({
    required this.id,
    required this.path,
    required this.label,
    required this.identity,
    required this.availability,
    required this.seq,
    required this.cleanup,
    this.reason,
  });

  factory WorkspaceRecord.fromJson(Json json) => WorkspaceRecord(
    id: _req<String>(json, 'id'),
    path: _req<String>(json, 'path'),
    label: _req<String>(json, 'label'),
    identity: _req<String>(json, 'identity'),
    availability: Availability.fromJson(json, 'availability'),
    reason: _opt<String>(json, 'reason'),
    seq: _req<int>(json, 'seq'),
    cleanup: WorkspaceCleanup.fromJson(_req<Json>(json, 'cleanup')),
  );

  final String id;
  final String path;
  final String label;
  final String identity;
  final Availability availability;

  /// Why the workspace is unavailable (a reason code or short text).
  final String? reason;

  /// Per-workspace sequence: a later `seq` supersedes an earlier one.
  final int seq;
  final WorkspaceCleanup cleanup;

  Json toJson() => {
    'id': id,
    'path': clampUtf8(path, maxPathBytes),
    'label': label,
    'identity': identity,
    'availability': availability.name,
    if (reason != null) 'reason': clampUtf8(reason!, maxReasonBytes),
    'seq': seq,
    'cleanup': cleanup.toJson(),
  };
}

class WorkbenchLoadResult {
  WorkbenchLoadResult({
    required this.revision,
    required this.workspaces,
    required this.cleanupRevision,
    this.layout,
    this.restoreError,
  }) : assert(layout == null || restoreError == null);

  factory WorkbenchLoadResult.fromJson(Json json) {
    final layout = _opt<Json>(json, 'layout');
    final restoreError = _opt<String>(json, 'restoreError');
    if (layout != null && restoreError != null) {
      throw RpcException(
        ErrorCode.invalidParams,
        'layout and restoreError are exclusive',
      );
    }
    return WorkbenchLoadResult(
      layout: layout,
      restoreError: restoreError,
      revision: _req<int>(json, 'revision'),
      workspaces: [
        for (final w in _list<Json>(json, 'workspaces'))
          WorkspaceRecord.fromJson(w),
      ],
      cleanupRevision: _req<int>(json, 'cleanupRevision'),
    );
  }

  /// The stored layout document, opaque to the protocol; null when none is
  /// stored or it could not be restored.
  final Json? layout;
  final String? restoreError;
  final int revision;
  final List<WorkspaceRecord> workspaces;
  final int cleanupRevision;

  Json toJson() => {
    if (layout != null) 'layout': layout,
    if (restoreError != null)
      'restoreError': clampUtf8(restoreError!, maxReasonBytes),
    'revision': revision,
    'workspaces': [for (final w in workspaces) w.toJson()],
    'cleanupRevision': cleanupRevision,
  };
}

class WorkbenchSaveParams {
  const WorkbenchSaveParams({required this.layout, required this.revision});

  factory WorkbenchSaveParams.fromJson(Json json) => WorkbenchSaveParams(
    layout: _req<Json>(json, 'layout'),
    revision: _req<int>(json, 'revision'),
  );

  final Json layout;

  /// The revision the caller last saw; a different stored one is rejected as
  /// `stale-revision`.
  final int revision;

  Json toJson() => {'layout': layout, 'revision': revision};
}

class WorkbenchSaveResult {
  const WorkbenchSaveResult(this.revision);
  factory WorkbenchSaveResult.fromJson(Json json) =>
      WorkbenchSaveResult(_req<int>(json, 'revision'));
  final int revision;
  Json toJson() => {'revision': revision};
}

class WorkspaceOpenParams {
  const WorkspaceOpenParams(this.path);

  factory WorkspaceOpenParams.fromJson(Json json) {
    final path = _req<String>(json, 'path');
    if (utf8.encode(path).length > maxPathBytes) {
      throw RpcException(
        ErrorCode.invalidParams,
        'path exceeds $maxPathBytes bytes',
      );
    }
    return WorkspaceOpenParams(path);
  }

  final String path;
  Json toJson() => {'path': path};
}

class WorkspaceOpenResult {
  const WorkspaceOpenResult({
    required this.workspace,
    required this.existing,
    required this.cleanupRevision,
  });

  factory WorkspaceOpenResult.fromJson(Json json) => WorkspaceOpenResult(
    workspace: WorkspaceRecord.fromJson(_req<Json>(json, 'workspace')),
    existing: _req<bool>(json, 'existing'),
    cleanupRevision: _req<int>(json, 'cleanupRevision'),
  );

  final WorkspaceRecord workspace;

  /// True when the path was already a known workspace.
  final bool existing;
  final int cleanupRevision;

  Json toJson() => {
    'workspace': workspace.toJson(),
    'existing': existing,
    'cleanupRevision': cleanupRevision,
  };
}

class WorkspaceCheckParams {
  const WorkspaceCheckParams(this.id);
  factory WorkspaceCheckParams.fromJson(Json json) =>
      WorkspaceCheckParams(_req<String>(json, 'id'));
  final String id;
  Json toJson() => {'id': id};
}

class WorkspaceCheckResult {
  const WorkspaceCheckResult({
    required this.workspace,
    required this.cleanupRevision,
  });

  factory WorkspaceCheckResult.fromJson(Json json) => WorkspaceCheckResult(
    workspace: WorkspaceRecord.fromJson(_req<Json>(json, 'workspace')),
    cleanupRevision: _req<int>(json, 'cleanupRevision'),
  );

  final WorkspaceRecord workspace;
  final int cleanupRevision;

  Json toJson() => {
    'workspace': workspace.toJson(),
    'cleanupRevision': cleanupRevision,
  };
}

class WorkspaceListResult {
  const WorkspaceListResult({
    required this.workspaces,
    required this.cleanupRevision,
  });

  factory WorkspaceListResult.fromJson(Json json) => WorkspaceListResult(
    workspaces: [
      for (final w in _list<Json>(json, 'workspaces'))
        WorkspaceRecord.fromJson(w),
    ],
    cleanupRevision: _req<int>(json, 'cleanupRevision'),
  );

  final List<WorkspaceRecord> workspaces;
  final int cleanupRevision;

  Json toJson() => {
    'workspaces': [for (final w in workspaces) w.toJson()],
    'cleanupRevision': cleanupRevision,
  };
}

class WorkspaceRemoveParams {
  const WorkspaceRemoveParams(this.id);
  factory WorkspaceRemoveParams.fromJson(Json json) =>
      WorkspaceRemoveParams(_req<String>(json, 'id'));
  final String id;
  Json toJson() => {'id': id};
}

class WorkspaceRemoveResult {
  const WorkspaceRemoveResult(this.revision);
  factory WorkspaceRemoveResult.fromJson(Json json) =>
      WorkspaceRemoveResult(_req<int>(json, 'revision'));

  /// The new stored layout revision.
  final int revision;
  Json toJson() => {'revision': revision};
}

/// Params of the `workspace/changed` notification.
class WorkspaceChanged {
  const WorkspaceChanged({
    required this.workspace,
    required this.cleanupRevision,
  });

  factory WorkspaceChanged.fromJson(Json json) => WorkspaceChanged(
    workspace: WorkspaceRecord.fromJson(_req<Json>(json, 'workspace')),
    cleanupRevision: _req<int>(json, 'cleanupRevision'),
  );

  final WorkspaceRecord workspace;
  final int cleanupRevision;

  Json toJson() => {
    'workspace': workspace.toJson(),
    'cleanupRevision': cleanupRevision,
  };
}

// --- profile/* and terminal/* --------------------------------------------

const int maxTerminalCols = 1000;
const int maxTerminalRows = 500;

/// Bounds of one profile (design Resource Bounds).
const int maxProfileArgs = 256;
const int maxProfileArgBytes = 4096;
const int maxProfileEnv = 128;
const int maxProfileBytes = 64 * 1024;

/// `spawn-failed`: the PTY setup or exec failed at [stage] with the operating
/// system error [osError].
RpcException spawnFailed(String stage, int osError, [String message = '']) =>
    RpcException(ErrorCode.spawnFailed, message, {
      'stage': stage,
      'osError': osError,
    });

/// `executable-not-found`: [executable] does not exist ([osError] is the OS
/// code when known).
RpcException executableNotFound(
  String executable, {
  int? osError,
  String message = '',
}) => RpcException(ErrorCode.executableNotFound, message, {
  'executable': executable,
  'osError': ?osError,
});

/// A launch description: separate arguments, never a command string. Built-in
/// profiles have an id starting `builtin:` (design D6).
class ShellProfile {
  const ShellProfile({
    required this.id,
    required this.name,
    required this.executable,
    this.args = const [],
    this.cwd,
    this.env = const {},
  });

  factory ShellProfile.fromJson(Json json) {
    final args = _opt<List<Object?>>(json, 'args') == null
        ? const <String>[]
        : _list<String>(json, 'args');
    if (args.length > maxProfileArgs) {
      throw RpcException(
        ErrorCode.invalidParams,
        'at most $maxProfileArgs arguments',
      );
    }
    for (final a in args) {
      if (utf8.encode(a).length > maxProfileArgBytes) {
        throw RpcException(
          ErrorCode.invalidParams,
          'an argument exceeds $maxProfileArgBytes bytes',
        );
      }
    }
    final rawEnv = _opt<Json>(json, 'env') ?? const <String, Object?>{};
    if (rawEnv.length > maxProfileEnv) {
      throw RpcException(
        ErrorCode.invalidParams,
        'at most $maxProfileEnv environment entries',
      );
    }
    final env = <String, String>{
      for (final e in rawEnv.entries)
        e.key: e.value is String
            ? e.value! as String
            : throw RpcException(
                ErrorCode.invalidParams,
                'environment value of "${e.key}" is not a string',
              ),
    };
    final profile = ShellProfile(
      id: _req<String>(json, 'id'),
      name: _req<String>(json, 'name'),
      executable: _req<String>(json, 'executable'),
      args: args,
      cwd: _opt<String>(json, 'cwd'),
      env: env,
    );
    if (utf8.encode(jsonEncode(profile.toJson())).length > maxProfileBytes) {
      throw RpcException(
        ErrorCode.invalidParams,
        'profile exceeds $maxProfileBytes bytes',
      );
    }
    return profile;
  }

  final String id;
  final String name;
  final String executable;
  final List<String> args;
  final String? cwd;
  final Map<String, String> env;

  bool get isBuiltin => id.startsWith('builtin:');

  Json toJson() => {
    'id': id,
    'name': name,
    'executable': executable,
    'args': args,
    if (cwd != null) 'cwd': cwd,
    'env': env,
  };
}

/// `profile/list` result: every available profile, the default's id, and
/// whether that default is available. A default naming a missing profile is
/// reported with [defaultAvailable] false, never replaced.
class ProfileListResult {
  const ProfileListResult({
    required this.profiles,
    required this.defaultAvailable,
    this.defaultId,
  });

  factory ProfileListResult.fromJson(Json json) => ProfileListResult(
    profiles: [
      for (final p in _list<Json>(json, 'profiles')) ShellProfile.fromJson(p),
    ],
    defaultId: _opt<String>(json, 'defaultId'),
    defaultAvailable: _req<bool>(json, 'defaultAvailable'),
  );

  final List<ShellProfile> profiles;
  final String? defaultId;
  final bool defaultAvailable;

  Json toJson() => {
    'profiles': [for (final p in profiles) p.toJson()],
    if (defaultId != null) 'defaultId': defaultId,
    'defaultAvailable': defaultAvailable,
  };
}

class ProfileSaveParams {
  const ProfileSaveParams(this.profile);
  factory ProfileSaveParams.fromJson(Json json) =>
      ProfileSaveParams(ShellProfile.fromJson(_req<Json>(json, 'profile')));
  final ShellProfile profile;
  Json toJson() => {'profile': profile.toJson()};
}

class ProfileSaveResult {
  const ProfileSaveResult(this.profile);
  factory ProfileSaveResult.fromJson(Json json) =>
      ProfileSaveResult(ShellProfile.fromJson(_req<Json>(json, 'profile')));
  final ShellProfile profile;
  Json toJson() => {'profile': profile.toJson()};
}

class ProfileRemoveParams {
  const ProfileRemoveParams(this.id);
  factory ProfileRemoveParams.fromJson(Json json) =>
      ProfileRemoveParams(_req<String>(json, 'id'));
  final String id;
  Json toJson() => {'id': id};
}

class ProfileSetDefaultParams {
  const ProfileSetDefaultParams(this.id);
  factory ProfileSetDefaultParams.fromJson(Json json) =>
      ProfileSetDefaultParams(_req<String>(json, 'id'));
  final String id;
  Json toJson() => {'id': id};
}

/// Reads `cols` and `rows`: a missing or non-integer value is `invalid-params`,
/// a value outside 1..[maxTerminalCols] x 1..[maxTerminalRows] `invalid-size`.
(int, int) _size(Json json) {
  final cols = _req<int>(json, 'cols');
  final rows = _req<int>(json, 'rows');
  if (cols < 1 ||
      cols > maxTerminalCols ||
      rows < 1 ||
      rows > maxTerminalRows) {
    throw RpcException(
      ErrorCode.invalidSize,
      'size must be 1..$maxTerminalCols columns by 1..$maxTerminalRows rows',
    );
  }
  return (cols, rows);
}

class TerminalOpenParams {
  const TerminalOpenParams({
    required this.profileId,
    required this.cols,
    required this.rows,
    this.workspaceId,
  });

  factory TerminalOpenParams.fromJson(Json json) {
    final (cols, rows) = _size(json);
    return TerminalOpenParams(
      profileId: _req<String>(json, 'profileId'),
      workspaceId: _opt<String>(json, 'workspaceId'),
      cols: cols,
      rows: rows,
    );
  }

  final String profileId;
  final String? workspaceId;
  final int cols;
  final int rows;

  Json toJson() => {
    'profileId': profileId,
    if (workspaceId != null) 'workspaceId': workspaceId,
    'cols': cols,
    'rows': rows,
  };
}

/// The host-allocated ids of a new terminal (design D4). No frame has been
/// sent on either channel yet.
class TerminalOpenResult {
  const TerminalOpenResult({
    required this.terminalId,
    required this.outputChannel,
    required this.inputChannel,
  });

  factory TerminalOpenResult.fromJson(Json json) => TerminalOpenResult(
    terminalId: _req<String>(json, 'terminalId'),
    outputChannel: _req<int>(json, 'outputChannel'),
    inputChannel: _req<int>(json, 'inputChannel'),
  );

  final String terminalId;

  /// Host to desktop.
  final int outputChannel;

  /// Desktop to host.
  final int inputChannel;

  Json toJson() => {
    'terminalId': terminalId,
    'outputChannel': outputChannel,
    'inputChannel': inputChannel,
  };
}

class TerminalAttachParams {
  const TerminalAttachParams(this.terminalId);
  factory TerminalAttachParams.fromJson(Json json) =>
      TerminalAttachParams(_req<String>(json, 'terminalId'));
  final String terminalId;
  Json toJson() => {'terminalId': terminalId};
}

class TerminalResizeParams {
  const TerminalResizeParams({
    required this.terminalId,
    required this.cols,
    required this.rows,
  });

  factory TerminalResizeParams.fromJson(Json json) {
    final (cols, rows) = _size(json);
    return TerminalResizeParams(
      terminalId: _req<String>(json, 'terminalId'),
      cols: cols,
      rows: rows,
    );
  }

  final String terminalId;
  final int cols;
  final int rows;

  Json toJson() => {'terminalId': terminalId, 'cols': cols, 'rows': rows};
}

class TerminalCloseParams {
  const TerminalCloseParams(this.terminalId);
  factory TerminalCloseParams.fromJson(Json json) =>
      TerminalCloseParams(_req<String>(json, 'terminalId'));
  final String terminalId;
  Json toJson() => {'terminalId': terminalId};
}

class TerminalReleaseParams {
  const TerminalReleaseParams(this.terminalId);
  factory TerminalReleaseParams.fromJson(Json json) =>
      TerminalReleaseParams(_req<String>(json, 'terminalId'));
  final String terminalId;
  Json toJson() => {'terminalId': terminalId};
}

enum TerminalExitReason {
  exited('exited'),
  closed('closed'),
  ioError('io-error');

  const TerminalExitReason(this.wire);
  final String wire;
}

/// `terminal/exited`: sent after the last output byte and after cleanup is
/// confirmed. [status] is the exit status when the shell reported one.
class TerminalExited {
  const TerminalExited({
    required this.terminalId,
    required this.reason,
    required this.outputComplete,
    this.status,
  });

  factory TerminalExited.fromJson(Json json) {
    final wire = _req<String>(json, 'reason');
    return TerminalExited(
      terminalId: _req<String>(json, 'terminalId'),
      status: _opt<int>(json, 'status'),
      reason: TerminalExitReason.values.firstWhere(
        (r) => r.wire == wire,
        orElse: () => throw RpcException(
          ErrorCode.invalidParams,
          'unknown reason "$wire"',
        ),
      ),
      outputComplete: _req<bool>(json, 'outputComplete'),
    );
  }

  final String terminalId;
  final int? status;
  final TerminalExitReason reason;
  final bool outputComplete;

  Json toJson() => {
    'terminalId': terminalId,
    'status': ?status,
    'reason': reason.wire,
    'outputComplete': outputComplete,
  };
}

/// `terminal/closeFailed`: cleanup could not be confirmed in time.
class TerminalCloseFailed {
  const TerminalCloseFailed({required this.terminalId, required this.reason});

  factory TerminalCloseFailed.fromJson(Json json) => TerminalCloseFailed(
    terminalId: _req<String>(json, 'terminalId'),
    reason: _req<String>(json, 'reason'),
  );

  final String terminalId;
  final String reason;

  Json toJson() => {
    'terminalId': terminalId,
    'reason': clampUtf8(reason, maxReasonBytes),
  };
}

// --- test/* (test builds only) -------------------------------------------

enum TestFixture { tree, escaper, sleeper, stubborn }

enum TestFault {
  crashAfterPendingWrite,
  crashAfterSpawnBeforePid,
  identityReadFails,
  killFails,
  layoutSaveFails,
  layoutSaveHangs,
  pendingWriteFails,
  runningWriteFails,
  terminateHangs,
}

class TestUnitLaunchParams {
  const TestUnitLaunchParams({required this.target, required this.fixture});

  factory TestUnitLaunchParams.fromJson(Json json) => TestUnitLaunchParams(
    target: _req<String>(json, 'target'),
    fixture: _enum(TestFixture.values, json, 'fixture'),
  );

  final String target;
  final TestFixture fixture;

  Json toJson() => {'target': target, 'fixture': fixture.name};
}

class TestUnitLaunchResult {
  const TestUnitLaunchResult(this.containmentId);
  factory TestUnitLaunchResult.fromJson(Json json) =>
      TestUnitLaunchResult(_req<String>(json, 'containmentId'));
  final String containmentId;
  Json toJson() => {'containmentId': containmentId};
}

class TestUnitEndParams {
  const TestUnitEndParams(this.containmentId);
  factory TestUnitEndParams.fromJson(Json json) =>
      TestUnitEndParams(_req<String>(json, 'containmentId'));
  final String containmentId;
  Json toJson() => {'containmentId': containmentId};
}

/// The outcome of ending a test unit: cleaned (its row is gone), or
/// unresolved with [reason].
class TestUnitEndResult {
  const TestUnitEndResult({required this.cleaned, this.reason});

  factory TestUnitEndResult.fromJson(Json json) => TestUnitEndResult(
    cleaned: _req<bool>(json, 'cleaned'),
    reason: _opt<String>(json, 'reason'),
  );

  final bool cleaned;
  final String? reason;

  Json toJson() => {
    'cleaned': cleaned,
    if (reason != null) 'reason': clampUtf8(reason!, maxReasonBytes),
  };
}

class TestChannelOpenParams {
  const TestChannelOpenParams(
    this.rateBytesPerSec, {
    this.writeBytes = defaultWriteBytes,
  });

  factory TestChannelOpenParams.fromJson(Json json) {
    final write = _opt<int>(json, 'writeBytes') ?? defaultWriteBytes;
    if (write < 1 || write > maxWriteBytes) {
      throw RpcException(
        ErrorCode.invalidParams,
        'writeBytes must be 1..$maxWriteBytes',
      );
    }
    return TestChannelOpenParams(
      _req<int>(json, 'rateBytesPerSec'),
      writeBytes: write,
    );
  }

  static const int defaultWriteBytes = 16 * 1024;
  static const int maxWriteBytes = 4 * 1024 * 1024;

  final int rateBytesPerSec;

  /// The size of each of the producer's writes.
  final int writeBytes;

  Json toJson() => {
    'rateBytesPerSec': rateBytesPerSec,
    'writeBytes': writeBytes,
  };
}

class TestChannelStatsParams {
  const TestChannelStatsParams(this.channel);
  factory TestChannelStatsParams.fromJson(Json json) =>
      TestChannelStatsParams(_req<int>(json, 'channel'));
  final int channel;
  Json toJson() => {'channel': channel};
}

/// What a test channel's producer has read from its source, what of it is on
/// the wire, and what the host's writer holds unsent for it.
class TestChannelStatsResult {
  const TestChannelStatsResult({
    required this.producedBytes,
    required this.sentBytes,
    required this.queuedBytes,
  });

  factory TestChannelStatsResult.fromJson(Json json) => TestChannelStatsResult(
    producedBytes: _req<int>(json, 'producedBytes'),
    sentBytes: _req<int>(json, 'sentBytes'),
    queuedBytes: _req<int>(json, 'queuedBytes'),
  );

  final int producedBytes;

  /// Bytes of the channel on the wire.
  final int sentBytes;
  final int queuedBytes;

  Json toJson() => {
    'producedBytes': producedBytes,
    'sentBytes': sentBytes,
    'queuedBytes': queuedBytes,
  };
}

class TestChannelOpenResult {
  const TestChannelOpenResult(this.channel);
  factory TestChannelOpenResult.fromJson(Json json) =>
      TestChannelOpenResult(_req<int>(json, 'channel'));
  final int channel;
  Json toJson() => {'channel': channel};
}

class TestFaultSetParams {
  const TestFaultSetParams(this.fault, {this.enabled = true});

  factory TestFaultSetParams.fromJson(Json json) => TestFaultSetParams(
    _enum(TestFault.values, json, 'fault'),
    enabled: _opt<bool>(json, 'enabled') ?? true,
  );

  final TestFault fault;
  final bool enabled;

  Json toJson() => {'fault': fault.name, 'enabled': enabled};
}

/// `test/resolve.fault`: the next resolution of [path] is delayed by
/// [delayMs] or hangs until released. Neither set clears the fault.
class TestResolveFaultParams {
  const TestResolveFaultParams(this.path, {this.delayMs, this.hang = false});

  factory TestResolveFaultParams.fromJson(Json json) => TestResolveFaultParams(
    _req<String>(json, 'path'),
    delayMs: _opt<int>(json, 'delayMs'),
    hang: _opt<bool>(json, 'hang') ?? false,
  );

  final String path;
  final int? delayMs;
  final bool hang;

  Json toJson() => {
    'path': path,
    if (delayMs != null) 'delayMs': delayMs,
    'hang': hang,
  };
}

/// `test/resolve.release`: lets every hung resolution of [path] return.
class TestResolveReleaseParams {
  const TestResolveReleaseParams(this.path);
  factory TestResolveReleaseParams.fromJson(Json json) =>
      TestResolveReleaseParams(_req<String>(json, 'path'));
  final String path;
  Json toJson() => {'path': path};
}
