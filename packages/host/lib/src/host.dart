import 'dart:async';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';

import 'cleanup_service.dart';
import 'host_extension.dart';
import 'host_faults.dart';
import 'host_log.dart';
import 'host_options.dart';
import 'ledger.dart';
import 'profiles/profile_service.dart';
import 'profile_lock.dart';
import 'settler.dart';
import 'store/store.dart';
import 'store/store_error.dart';
import 'terminal/terminal_service.dart';
import 'unit_manager.dart';
import 'workbench_service.dart';
import 'workspace_resolver.dart';
import 'workspace_service.dart';

/// The version the host reports in `hello`.
const String hostVersion = '0.1.0';

/// Exit codes of the host.
abstract final class HostExit {
  /// The connection to the desktop ended normally.
  static const int ok = 0;

  /// The profile or store could not be used; `hello` said why.
  static const int startFailed = 2;

  /// Bad command line.
  static const int usage = 64;

  /// The desktop broke the wire contract.
  static const int protocolViolation = 65;

  /// Pending control passed its bound: the desktop counts as lost.
  static const int controlOverflow = 66;

  /// Anything else that ended the connection, such as a failed write.
  static const int connectionFailed = 67;
}

/// A start that failed in a way `hello` reports.
class _StartFailure {
  _StartFailure(this.error, this.exitCode);
  final RpcException error;
  final int exitCode;
}

/// The execution host: it takes the profile lock, opens the store, answers
/// `hello`, reconciles, serves the cleanup API, and ends its units when the
/// desktop goes (design D4, D5, D10).
class Host {
  Host({required this.profile, this.extension})
    : options = extension?.options ?? const HostOptions();

  final Directory profile;
  final HostExtension? extension;
  final HostOptions options;
  final HostFaults faults = HostFaults();

  final Completer<int> _exit = Completer();
  late final Connection _connection;
  late final Future<_StartFailure?> _startup;

  ProfileLock? _lock;
  Store? _store;
  HostLog? _log;
  Ledger? _ledger;
  UnitManager? _units;
  CleanupService? _cleanup;
  WorkspaceService? _workspaces;
  WorkbenchService? _workbench;
  ProfileService? _profiles;
  TerminalService? _terminals;
  bool _stopping = false;

  /// Runs until the desktop goes away; returns the exit code.
  Future<int> run() {
    _startup = _start();
    _connection = Connection(
      input: stdin,
      // Non-blocking: a desktop that stops reading must not block the isolate
      // in a write, or the host could neither notice nor shut down.
      output: IOSinkAdapter(stdout.nonBlocking),
      capabilities: {
        Capability.workbench,
        Capability.terminal,
        ...?extension?.capabilities,
      },
      onHello: _onHello,
      onRequest: _onRequest,
    );
    unawaited(_connection.closed.then(_onClosed));
    return _exit.future;
  }

  /// The lock, then the store, in that order; nothing is written to the
  /// profile before the lock is held (design D4, D12).
  Future<_StartFailure?> _start() async {
    try {
      if (!profile.existsSync()) profile.createSync(recursive: true);
    } on FileSystemException catch (e) {
      return _unavailable(e);
    }
    // The store holds profile environments, which can carry secrets: only
    // the owner may enter the profile (the files in it then need no mode of
    // their own), so a profile that cannot be made so is not used.
    if (!Platform.isWindows) {
      final refused = _notOwnerOnly();
      if (refused != null) return _unavailable(FileSystemException(refused));
    }
    try {
      _lock = await ProfileLock.tryAcquire(profile);
    } on FileSystemException catch (e) {
      return _unavailable(e);
    }
    if (_lock == null) {
      return _StartFailure(
        RpcException(
          ErrorCode.profileLocked,
          'Kumiko is already running: the profile ${profile.path} is in use',
          {'path': profile.path},
        ),
        HostExit.ok,
      );
    }
    final log = _log = HostLog.open(profile, version: hostVersion);
    try {
      _store = Store.open(profile, _lock!);
    } on StoreError catch (e) {
      log.event('store-failed', code: e.code);
      return _StartFailure(_storeError(e), HostExit.startFailed);
    }
    log.event('host-start', ids: {'pid': pid});
    return null;
  }

  /// Why the POSIX profile directory is not owner-only, or null when it is
  /// now: it is not a symbolic link, chmod to 0700 succeeded (only the owner
  /// or root may chmod), and its mode reads back as 0700.
  String? _notOwnerOnly() {
    if (FileSystemEntity.isLinkSync(profile.path)) {
      return 'it is a symbolic link';
    }
    if (!chmodPath(profile.path, 0x1c0)) {
      return 'it cannot be made owner-only (another account owns it?)';
    }
    if (FileStat.statSync(profile.path).mode & 0x1ff != 0x1c0) {
      return 'its mode does not stay owner-only (0700)';
    }
    return null;
  }

  _StartFailure _unavailable(FileSystemException e) => _StartFailure(
    RpcException(
      ErrorCode.profileUnavailable,
      'the profile directory ${profile.path} cannot be used: ${e.message}',
      {'path': profile.path},
    ),
    HostExit.startFailed,
  );

  RpcException _storeError(StoreError e) => switch (e) {
    StoreMigrationFailed() => RpcException(
      ErrorCode.storeMigrationFailed,
      'store migration ${e.fromVersion} -> ${e.toVersion} failed in '
      '$_storePath: ${e.cause}',
      {
        'path': _storePath,
        'fromVersion': e.fromVersion,
        'toVersion': e.toVersion,
        'cause': '${e.cause}',
      },
    ),
    StoreNewer() => RpcException(
      ErrorCode.storeNewer,
      'the store $_storePath has version ${e.storeVersion}; this Kumiko '
      'supports up to ${e.supportedVersion}',
      {
        'path': _storePath,
        'storeVersion': e.storeVersion,
        'supportedVersion': e.supportedVersion,
      },
    ),
    StoreUnreadable() => RpcException(
      ErrorCode.storeUnreadable,
      'the store $_storePath cannot be opened as a database',
      {'path': _storePath, if (e.cause != null) 'cause': '${e.cause}'},
    ),
  };

  String get _storePath => '${profile.path}${Platform.pathSeparator}kumiko.db';

  Future<HelloInfo> _onHello(HelloParams params, Negotiated negotiated) async {
    final failure = await _startup;
    if (failure != null) {
      // Send the error, then exit: nothing else is served.
      unawaited(
        Future<void>(() async {
          await _connection.drain();
          await _finish(failure.exitCode);
        }),
      );
      throw failure.error;
    }

    final store = _store!;
    final log = _log!;
    final ledger = _ledger = Ledger(store);
    final instance = ledger.openInstance(
      hostPid: pid,
      hostStartedAt: processStartTime(pid),
      desktopPid: params.desktopPid,
      desktopStartedAt: params.desktopStartTime,
      os: Platform.operatingSystem,
    );
    final settler = Settler(ledger: ledger, log: log, faults: faults);
    final units = _units =
        UnitManager(
            ledger: ledger,
            log: log,
            faults: faults,
            settler: settler,
            options: options,
          )
          ..desktop = DesktopInfo(
            pid: params.desktopPid,
            startTime: params.desktopStartTime,
            outerJobHeld: params.outerJobHeld ?? false,
          );
    final workspaces = _workspaces = WorkspaceService(
      store: store,
      ledger: ledger,
      log: log,
      options: options,
      resolver: WorkspaceResolver(
        faults: faults,
        timeout: options.resolveTimeout,
      ),
      notify: _connection.notify,
    );
    final profiles = _profiles = ProfileService(
      store: store,
      log: log,
      faults: faults,
      options: options,
    );
    _terminals = TerminalService(
      connection: _connection,
      units: units,
      profiles: profiles,
      workspaces: workspaces,
      faults: faults,
      options: options,
      log: log,
    );
    _workbench = WorkbenchService(
      store: store,
      ledger: ledger,
      workspaces: workspaces,
      faults: faults,
    );
    final cleanup = _cleanup = CleanupService(
      ledger: ledger,
      log: log,
      settler: settler,
      units: units,
      options: options,
      notify: _connection.notify,
      workspaceTarget: workspaces.cleanupTarget,
    )..startReconciliation(params.priorHost);
    units.onUnresolved = cleanup.sendState;
    log.event(
      'hello',
      ids: {'instance': instance, 'version': negotiated.version},
    );
    return HelloInfo(
      instanceId: '$instance',
      hostVersion: hostVersion,
      state: HostState.reconciling,
    );
  }

  Future<Object?> _onRequest(String method, Json params) async {
    final cleanup = _cleanup!;
    switch (method) {
      case Method.cleanupList:
        return cleanup.list(CleanupListParams.fromJson(params)).toJson();
      case Method.cleanupUnits:
        return cleanup.unitsOf(CleanupUnitsParams.fromJson(params)).toJson();
      case Method.cleanupRetry:
        final p = CleanupActionParams.fromJson(params);
        return (await cleanup.retry(p.workspace)).toJson();
      case Method.cleanupConfirm:
        final p = CleanupActionParams.fromJson(params);
        return cleanup.confirm(p.workspace).toJson();
    }
    switch (method) {
      case Method.workbenchSave:
        final p = WorkbenchSaveParams.fromJson(params);
        return (await _workbench!.save(p)).toJson();
      case Method.workbenchLoad:
        return _workbench!.load().toJson();
      case Method.workspaceList:
        return _workspaces!.list().toJson();
      case Method.workspaceOpen:
        final p = WorkspaceOpenParams.fromJson(params);
        return (await _workspaces!.open(p.path)).toJson();
      case Method.workspaceCheck:
        final p = WorkspaceCheckParams.fromJson(params);
        return (await _workspaces!.check(p.id)).toJson();
      case Method.workspaceRemove:
        final p = WorkspaceRemoveParams.fromJson(params);
        return _workbench!.removeWorkspace(p.id).toJson();
    }
    switch (method) {
      case Method.profileList:
        return (await _profiles!.list()).toJson();
      case Method.profileSave:
        final p = ProfileSaveParams.fromJson(params);
        return (await _profiles!.save(p)).toJson();
      case Method.profileRemove:
        await _profiles!.remove(ProfileRemoveParams.fromJson(params));
        return <String, Object?>{};
      case Method.profileSetDefault:
        await _profiles!.setDefault(ProfileSetDefaultParams.fromJson(params));
        return <String, Object?>{};
    }
    switch (method) {
      case Method.terminalOpen:
        final p = TerminalOpenParams.fromJson(params);
        return (await _terminals!.open(p)).toJson();
      case Method.terminalAttach:
        await _terminals!.attach(TerminalAttachParams.fromJson(params));
        return <String, Object?>{};
      case Method.terminalResize:
        _terminals!.resize(TerminalResizeParams.fromJson(params));
        return <String, Object?>{};
      case Method.terminalClose:
        _terminals!.close(TerminalCloseParams.fromJson(params));
        return <String, Object?>{};
      case Method.terminalRelease:
        _terminals!.release(TerminalReleaseParams.fromJson(params));
        return <String, Object?>{};
    }
    if (method.startsWith('test/') && extension != null) {
      return extension!.handle(
        HostServices(units: _units!, faults: faults, connection: _connection),
        method,
        params,
      );
    }
    throw RpcException(ErrorCode.methodNotAvailable, method);
  }

  /// The connection ended: the desktop quit, died, broke the contract, or
  /// stopped reading. End every unit within the deadline and exit.
  Future<void> _onClosed(CloseReason reason) async {
    final code = switch (reason.kind) {
      CloseReason.protocolViolation => HostExit.protocolViolation,
      CloseReason.controlOverflow => HostExit.controlOverflow,
      CloseReason.inputClosed => HostExit.ok,
      _ => HostExit.connectionFailed,
    };
    if (code != HostExit.ok) {
      stderr.writeln('kumiko_host: connection closed: $reason');
    }
    await _startup;
    if (_stopping) return;
    final units = _units;
    _terminals?.dispose();
    if (units != null) {
      _log?.event('shutdown', code: reason.kind);
      await _cleanup?.reconciliation?.timeout(
        options.shutdownDeadline,
        onTimeout: () {},
      );
      await units.shutdown(options.shutdownDeadline);
    }
    await _finish(code);
  }

  Future<void> _finish(int code) async {
    if (_stopping) return;
    _stopping = true;
    final units = _units;
    try {
      _ledger?.closeInstance(cleanly: units != null && units.live.isEmpty);
    } on Object {
      // The row stays as it is; the next host reconciles.
    }
    _log?.event('host-exit', code: '$code');
    try {
      _store?.close();
      await _lock?.release();
    } on Object {
      // The OS releases the lock when the process ends.
    }
    if (!_exit.isCompleted) _exit.complete(code);
  }
}
