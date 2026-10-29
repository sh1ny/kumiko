import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:host/src/profile_lock.dart';
import 'package:host/src/store/store.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:test/test.dart';

import 'host_build.dart';

export 'host_build.dart';

/// Fixtures report one `role pid startTime marker sid` line each, to their
/// own `kumiko-fixture-<pid>.out` in their working directory (the unit's
/// target).
const String fixtureReportPrefix = 'kumiko-fixture-';
const String fixtureReportSuffix = '.out';

const Set<String> testCapabilities = {
  Capability.workbench,
  Capability.testUnits,
  Capability.testChannels,
  Capability.testFaults,
};

String joinPath(String a, String b) => '$a${Platform.pathSeparator}$b';

Directory tempDir(String prefix) =>
    Directory.systemTemp.createTempSync('kumiko_it_$prefix');

/// Deletes [dir], retrying while Windows still holds a file of a process that
/// exited a moment ago. Gives up quietly.
Future<void> deleteTree(Directory dir) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    try {
      if (dir.existsSync()) {
        // Junctions and links are removed without following them.
        for (final e in dir.listSync(followLinks: false)) {
          if (e is Link) e.deleteSync();
        }
        dir.deleteSync(recursive: true);
      }
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

/// Waits until [check] holds, up to [within].
Future<void> eventually(
  FutureOr<bool> Function() check, {
  Duration within = const Duration(seconds: 20),
  String reason = 'condition not reached',
}) async {
  final deadline = DateTime.now().add(within);
  while (!await check()) {
    if (DateTime.now().isAfter(deadline)) fail(reason);
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

/// One process a fixture reported.
class FixtureProcess {
  FixtureProcess(this.role, this.pid, this.startTime, this.marker, this.sid);

  final String role;
  final int pid;
  final int startTime;
  final String marker;
  final String sid;

  bool get alive => isProcessAlive(pid, startTime);

  @override
  String toString() => '$role[$pid]';
}

/// The fixture reports in [target]. A fixture renames its report into place
/// once written, so one still being written (`.tmp`) is not read; only a
/// line that ended counts, as a second guard.
List<FixtureProcess> readReports(Directory target) {
  if (!target.existsSync()) return [];
  final reports = <FixtureProcess>[];
  for (final entry in target.listSync()) {
    final name = entry.uri.pathSegments.last;
    if (entry is! File ||
        !name.startsWith(fixtureReportPrefix) ||
        !name.endsWith(fixtureReportSuffix)) {
      continue;
    }
    final text = entry.readAsStringSync();
    final complete = text.substring(0, text.lastIndexOf('\n') + 1);
    for (final line in complete.split('\n')) {
      if (line.trim().isNotEmpty) {
        reports.add(_parseReport(line.trim().split(' ')));
      }
    }
  }
  return reports;
}

FixtureProcess _parseReport(List<String> f) =>
    FixtureProcess(f[0], int.parse(f[1]), int.parse(f[2]), f[3], f[4]);

/// Waits until fixtures in [target] reported [count] processes.
Future<List<FixtureProcess>> waitReports(Directory target, int count) async {
  await eventually(
    () => readReports(target).length >= count,
    reason: 'fixtures did not report $count processes in ${target.path}',
  );
  return readReports(target);
}

/// Kills every process a fixture reported, as test cleanup.
void killReported(Directory target) {
  for (final p in readReports(target)) {
    if (p.alive) Process.killPid(p.pid, ProcessSignal.sigkill);
  }
}

Future<void> expectAllGone(Iterable<FixtureProcess> processes) => eventually(
  () => processes.every((p) => !p.alive),
  reason: 'still alive: ${processes.where((p) => p.alive).toList()}',
);

/// A read-only view of `<profile>/kumiko.db`, usable while a host runs (WAL).
class LedgerView {
  LedgerView(this.profile);
  final Directory profile;

  File get file => File(joinPath(profile.path, 'kumiko.db'));

  List<Map<String, Object?>> _select(String query) {
    if (!file.existsSync()) return [];
    final db = sql.sqlite3.open(file.path, mode: sql.OpenMode.readOnly);
    try {
      return [for (final r in db.select(query)) Map.of(r)];
    } finally {
      db.close();
    }
  }

  List<Map<String, Object?>> units() =>
      _select('SELECT * FROM unit ORDER BY created_at, containment_id');

  List<Map<String, Object?>> workspaces() =>
      _select('SELECT * FROM workspace ORDER BY rowid');

  List<Map<String, Object?>> instances() =>
      _select('SELECT * FROM host_instance ORDER BY id');

  Map<String, Object?>? unit(String id) {
    for (final u in units()) {
      if (u['containment_id'] == id) return u;
    }
    return null;
  }
}

/// The host log lines of [profile] (`logs/host.log`), parsed.
List<Map<String, Object?>> readHostLog(Directory profile) {
  final file = File(joinPath(joinPath(profile.path, 'logs'), 'host.log'));
  if (!file.existsSync()) return [];
  return [
    for (final line in file.readAsLinesSync())
      if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, Object?>,
  ];
}

/// The desktop stand-in: the 4.4 launcher with test capabilities and helpers
/// for the host's test and cleanup methods.
class Desktop {
  Desktop._(this.launcher, this.session, this.profile);

  final HostLauncher launcher;
  HostSession session;
  final Directory profile;
  final List<CleanupState> states = [];
  final List<WorkspaceChanged> changes = [];
  StreamSubscription<HostNotification>? _states;

  static HostLauncher newLauncher(
    Directory profile, {
    Map<String, String>? environment,
    Set<String> capabilities = testCapabilities,
    String? executable,
  }) => HostLauncher(
    executable: executable ?? testHostExecutable(),
    profileDir: profile.path,
    capabilities: capabilities,
    environment: environment,
  );

  static Future<Desktop> start(
    Directory profile, {
    Map<String, String>? environment,
    Set<String> capabilities = testCapabilities,
  }) async {
    final launcher = newLauncher(
      profile,
      environment: environment,
      capabilities: capabilities,
    );
    final session = await launcher.start();
    return Desktop._(launcher, session, profile).._listen();
  }

  void _listen() {
    // One subscription: the first listener also gets what came before it.
    _states = session.notifications.listen((n) {
      switch (n.method) {
        case Method.cleanupState:
          states.add(CleanupState.fromJson(n.params));
        case Method.workspaceChanged:
          changes.add(WorkspaceChanged.fromJson(n.params));
      }
    });
  }

  /// Starts a new host after the previous one ended, with the same launcher
  /// (which carries the Windows attestation).
  Future<void> restart() async {
    await _states?.cancel();
    states.clear();
    changes.clear();
    session = await launcher.start();
    _listen();
  }

  Connection get connection => session.connection;

  Future<CleanupState> waitState({
    bool Function(CleanupState)? where,
    Duration within = const Duration(seconds: 30),
  }) async {
    final test = where ?? (s) => !s.reconciling;
    await eventually(
      () => states.any(test),
      within: within,
      reason:
          'no matching cleanup/state; got ${[for (final s in states) s.toJson()]}',
    );
    return states.lastWhere(test);
  }

  Future<Json> _call(String method, [Object? params]) async {
    final result = await connection.request(method, params);
    return result is Json ? result : <String, Object?>{};
  }

  // --- workspaces --------------------------------------------------------

  Future<WorkspaceOpenResult> openWorkspace(String path) async =>
      WorkspaceOpenResult.fromJson(
        await _call(Method.workspaceOpen, WorkspaceOpenParams(path).toJson()),
      );

  Future<WorkspaceCheckResult> checkWorkspace(String id) async =>
      WorkspaceCheckResult.fromJson(
        await _call(Method.workspaceCheck, WorkspaceCheckParams(id).toJson()),
      );

  Future<WorkspaceListResult> listWorkspaces() async =>
      WorkspaceListResult.fromJson(await _call(Method.workspaceList, {}));

  Future<WorkspaceRemoveResult> removeWorkspace(String id) async =>
      WorkspaceRemoveResult.fromJson(
        await _call(Method.workspaceRemove, WorkspaceRemoveParams(id).toJson()),
      );

  Future<WorkbenchLoadResult> loadWorkbench() async =>
      WorkbenchLoadResult.fromJson(await _call(Method.workbenchLoad, {}));

  Future<void> resolveFault(String path, {int? delayMs, bool hang = false}) =>
      _call(
        Method.testResolveFault,
        TestResolveFaultParams(path, delayMs: delayMs, hang: hang).toJson(),
      );

  Future<void> releaseResolve(String path) =>
      _call(Method.testResolveRelease, TestResolveReleaseParams(path).toJson());

  /// The `workspace/changed` notifications received for workspace [id].
  List<WorkspaceChanged> changesOf(String id) => [
    for (final c in changes)
      if (c.workspace.id == id) c,
  ];

  Future<WorkspaceChanged> waitChange(
    String id, {
    bool Function(WorkspaceRecord)? where,
  }) async {
    bool match(WorkspaceChanged c) =>
        c.workspace.id == id && (where?.call(c.workspace) ?? true);
    await eventually(
      () => changes.any(match),
      reason:
          'no workspace/changed for $id; got '
          '${[for (final c in changes) c.workspace.toJson()]}',
    );
    return changes.lastWhere(match);
  }

  Future<String> launch(Directory target, TestFixture fixture) async {
    final r = await _call(
      Method.testUnitLaunch,
      TestUnitLaunchParams(target: target.path, fixture: fixture).toJson(),
    );
    return TestUnitLaunchResult.fromJson(r).containmentId;
  }

  Future<TestUnitEndResult> end(String containmentId) async =>
      TestUnitEndResult.fromJson(
        await _call(
          Method.testUnitEnd,
          TestUnitEndParams(containmentId).toJson(),
        ),
      );

  Future<void> setFault(TestFault fault, {bool enabled = true}) => _call(
    Method.testFaultSet,
    TestFaultSetParams(fault, enabled: enabled).toJson(),
  );

  Future<CleanupListResult> list({
    String? cursor,
    int limit = maxListWorkspaces,
    int? revision,
    String? workspace,
  }) async => CleanupListResult.fromJson(
    await _call(
      Method.cleanupList,
      CleanupListParams(
        cursor: cursor,
        limit: limit,
        revision: revision,
        workspace: workspace,
      ).toJson(),
    ),
  );

  Future<CleanupUnitsResult> units(
    String workspace, {
    String? cursor,
    int limit = maxUnitsPage,
    int? revision,
  }) async => CleanupUnitsResult.fromJson(
    await _call(
      Method.cleanupUnits,
      CleanupUnitsParams(
        workspace: workspace,
        cursor: cursor,
        limit: limit,
        revision: revision,
      ).toJson(),
    ),
  );

  Future<CleanupActionResult> retry(String workspace) async =>
      CleanupActionResult.fromJson(
        await _call(
          Method.cleanupRetry,
          CleanupActionParams(workspace).toJson(),
        ),
      );

  Future<CleanupActionResult> confirm(String workspace) async =>
      CleanupActionResult.fromJson(
        await _call(
          Method.cleanupConfirm,
          CleanupActionParams(workspace).toJson(),
        ),
      );

  /// Every unresolved workspace, all pages.
  Future<List<CleanupWorkspace>> allWorkspaces() async {
    final all = <CleanupWorkspace>[];
    String? cursor;
    do {
      final page = await list(cursor: cursor);
      all.addAll(page.workspaces);
      cursor = page.nextCursor;
    } while (cursor != null);
    return all;
  }

  /// The launch error's reason, or null when the launch was accepted.
  Future<String?> launchRefusal(Directory target, TestFixture fixture) async {
    try {
      await launch(target, fixture);
      return null;
    } on RpcException catch (e) {
      return e.reason;
    }
  }

  /// Turns the kill fault off and quits, as test cleanup.
  Future<void> dispose() async {
    if (!session.isLost) {
      try {
        await setFault(TestFault.killFails, enabled: false);
      } on Object {
        // The host may be gone already.
      }
    }
    await _states?.cancel();
    await session.quit();
  }
}

/// Runs a call and returns the [RpcException] reason it failed with.
Future<String?> failureReason(Future<Object?> Function() call) async {
  try {
    await call();
    return null;
  } on RpcException catch (e) {
    return e.reason;
  }
}

/// The host process started directly, with a connection whose input a test can
/// stop reading (the desktop that stops reading the pipe).
class RawHost {
  RawHost._(
    this.process,
    this._reading,
    this.connection,
    this.stderrText,
    this._job,
    this._reconciled,
  );

  final Process process;
  final int? _job;
  final Completer<void> _reconciled;
  final StreamSubscription<List<int>> _reading;
  final Connection connection;
  final StringBuffer stderrText;

  static Future<RawHost> start(
    Directory profile, {
    Map<String, String>? environment,
    Set<String> capabilities = testCapabilities,
    bool holdInJob = true,
    void Function(List<int> chunk)? tap,
  }) async {
    final process = await Process.start(testHostExecutable(), [
      '--profile',
      profile.path,
    ], environment: environment);
    // On Windows a desktop holds its host in a kill-on-close job.
    int? job;
    if (Platform.isWindows && holdInJob) {
      job = createJob();
      assignPidToJob(job, process.pid);
    }
    final input = StreamController<List<int>>();
    final reading = process.stdout.listen((chunk) {
      tap?.call(chunk);
      input.add(chunk);
    }, onDone: input.close);
    final stderrText = StringBuffer();
    process.stderr.transform(utf8.decoder).listen(stderrText.write);
    process.stdin.done.then<void>((_) {}, onError: (Object _) {});
    final reconciled = Completer<void>();
    final connection = Connection(
      input: input.stream,
      output: IOSinkAdapter(process.stdin),
      capabilities: capabilities,
      onNotification: (method, params) {
        if (method == Method.cleanupState &&
            !CleanupState.fromJson(params).reconciling &&
            !reconciled.isCompleted) {
          reconciled.complete();
        }
      },
    );
    return RawHost._(process, reading, connection, stderrText, job, reconciled);
  }

  int get pid => process.pid;

  Future<HelloResult> hello() => connection.hello(
    desktopPid: pid,
    desktopStartTime: processStartTime(pid),
    outerJobHeld: _job != null,
  );

  /// Completes once the host reports that reconciliation has ended.
  Future<void> get reconciled =>
      _reconciled.future.timeout(const Duration(seconds: 30));

  /// Stops reading the host's stdout, so the pipe fills.
  void stopReading() => _reading.pause();

  /// Writes bytes to the host's stdin, outside the connection.
  void writeRaw(List<int> bytes) => process.stdin.add(bytes);

  Future<int> get exitCode => process.exitCode;

  Future<void> dispose() async {
    process.kill();
    await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () => -1,
    );
    await _reading.cancel();
    final job = _job;
    if (job != null) closeHandle(job);
  }
}

/// A frame header declaring a payload over the limit.
Uint8List oversizeHeader() {
  final bytes = ByteData(frameHeaderSize)
    ..setUint32(0, maxFramePayload + 1)
    ..setUint32(4, controlChannel)
    ..setUint8(8, FrameKind.data.wire)
    ..setUint8(9, flagEndOfMessage);
  return bytes.buffer.asUint8List();
}

/// Opens the profile's store under its lock (no host running) for [body].
Future<void> withStore(
  Directory profile,
  void Function(Store store) body,
) async {
  final lock = await ProfileLock.tryAcquire(profile);
  if (lock == null) fail('profile is locked');
  try {
    final store = Store.open(profile, lock);
    try {
      body(store);
    } finally {
      store.close();
    }
  } finally {
    await lock.release();
  }
}

/// Inserts a `host_instance` row (id [id]) left by an earlier host.
void seedInstance(
  Store store, {
  int id = 900,
  int? desktopPid = 2147483000,
  int? desktopStartedAt = 1,
}) => store.execute(
  'INSERT INTO host_instance(id, host_pid, host_started_at, desktop_pid, '
  'desktop_started_at, os, opened_at, closed_cleanly) VALUES '
  "(?, 1, '1', ?, ?, 'seed', '2020-01-01T00:00:00.000Z', 0)",
  [id, desktopPid, desktopStartedAt?.toString()],
);

/// Inserts one ledger row of instance [instance].
void seedUnit(
  Store store, {
  required String id,
  required String state,
  String path = '/seed',
  String identity = 'seed:0',
  int? pid,
  int? startedAt,
  String? reason,
  int instance = 900,
}) => store.execute(
  'INSERT INTO unit(containment_id, host_instance_id, kind, target_path, '
  'target_identity, state, pid, process_started_at, unresolved_reason, '
  "created_at, updated_at) VALUES (?, ?, 'test', ?, ?, ?, ?, ?, ?, ?, ?)",
  [
    id,
    instance,
    path,
    identity,
    state,
    pid,
    startedAt?.toString(),
    reason,
    _seededAt,
    _seededAt,
  ],
);

/// When seeded rows were "created": now, as for a unit of the host that just
/// died. The marker scan only looks at processes started since the oldest
/// row, so a date far in the past would make it read every process of the
/// machine, including ones that cannot be read.
final String _seededAt = DateTime.now().toUtc().toIso8601String();

/// A ledger of [workspaces] unresolved workspaces with [unitsEach] units
/// each, left by an earlier host instance that never recorded their pids,
/// under a desktop that still runs (this test process). Reconciliation cannot
/// confirm such a unit cleaned, so the rows stay unresolved until confirmed.
Future<void> seedUnresolved(
  Directory profile, {
  required int workspaces,
  required int unitsEach,
  int reasonBytes = 200,
  int pathBytes = 3000,
}) => withStore(profile, (store) {
  store.execute('BEGIN');
  seedInstance(store, desktopPid: pid, desktopStartedAt: processStartTime(pid));
  final reason = 'r' * reasonBytes;
  for (var w = 0; w < workspaces; w++) {
    final tag = w.toString().padLeft(4, '0');
    for (var u = 0; u < unitsEach; u++) {
      seedUnit(
        store,
        id: 'seed-$tag-${u.toString().padLeft(4, '0')}',
        state: 'unresolved',
        path: '/seed/$tag/${'p' * pathBytes}',
        identity: 'seed:$tag',
        reason: reason,
      );
    }
  }
  store.execute('COMMIT');
});
