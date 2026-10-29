import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:process_containment/process_containment.dart';

import 'close_reason.dart';
import 'connection.dart';
import 'messages.dart';
import 'stderr_ring.dart';

/// `hello` must be answered within this (design D6).
const Duration defaultHelloTimeout = Duration(seconds: 30);

/// A lost host must be visible within this (design D6).
const Duration hostLossBound = Duration(seconds: 2);

/// The host's shutdown deadline (30 s) plus 5 s (resource-bounds table).
const Duration defaultQuitTimeout = Duration(seconds: 35);

/// How long to wait for the outer job to hold no process after terminating it
/// (design D8).
const Duration defaultJobDrainTimeout = Duration(seconds: 5);

enum HostStartFailure {
  /// The executable could not be started, or the outer job could not be
  /// created or assigned.
  spawnFailed,

  /// `hello` was not answered in time; the host was killed.
  helloTimeout,

  /// The host answered `hello` with an error (`profile-locked`,
  /// `incompatible-version`, ...); see [HostStartException.reason].
  helloRejected,

  /// The host ended or broke the protocol before `hello` was answered.
  hostLost,
}

/// The host did not reach a usable connection. The desktop shows a start
/// error; Restart host calls [HostLauncher.start] again.
class HostStartException implements Exception {
  HostStartException(
    this.kind,
    this.message, {
    this.reason,
    this.data = const {},
    this.hostExitCode,
    this.stderr = '',
  });

  final HostStartFailure kind;
  final String message;

  /// The `error.data.reason` of a rejected `hello`.
  final String? reason;

  /// The structured `error.data` of a rejected `hello` (without `reason`):
  /// store paths and versions, both version ranges, and so on.
  final Json data;

  /// Exit code of the host when it had ended (or was killed) by the time this
  /// was thrown.
  final int? hostExitCode;

  /// The tail of the host's stderr, up to 64 KiB.
  final String stderr;

  @override
  String toString() => 'HostStartException(${kind.name}): $message';
}

enum HostLossKind {
  /// The host process ended.
  exited,

  /// The connection ended or broke the protocol while the process ran; the
  /// host was killed.
  connectionClosed,
}

class HostLoss {
  const HostLoss(this.kind, this.exitCode, this.closeReason, this.stderr);

  final HostLossKind kind;
  final int? exitCode;
  final CloseReason? closeReason;

  /// The tail of the host's stderr at the time of loss.
  final String stderr;

  @override
  String toString() => 'HostLoss(${kind.name}, exit $exitCode)';
}

/// A notification from the host.
class HostNotification {
  const HostNotification(this.method, this.params);
  final String method;
  final Json params;
}

class QuitResult {
  const QuitResult({required this.exitCode, required this.timedOut});

  /// Null when the host could not be reaped even after it was killed.
  final int? exitCode;

  /// The host did not exit within the quit deadline and was killed.
  final bool timedOut;
}

/// Starts the host and keeps what the desktop needs to survive losing it: the
/// Windows outer job and the attestation for the next host (design D3, D8).
/// Pure Dart: tests and the desktop share it.
class HostLauncher {
  HostLauncher({
    required this.executable,
    required this.profileDir,
    this.executableArguments = const [],
    this.environment,
    this.versions = const VersionRange(1, 1),
    this.capabilities = const {},
    this.helloTimeout = defaultHelloTimeout,
    this.quitTimeout = defaultQuitTimeout,
    this.jobDrainTimeout = defaultJobDrainTimeout,
  });

  final String executable;

  /// Arguments before `--profile <dir>`, for example a script path when
  /// [executable] is the Dart VM.
  final List<String> executableArguments;
  final String profileDir;

  /// Extra environment for the host process, on top of the desktop's own.
  final Map<String, String>? environment;
  final VersionRange versions;
  final Set<String> capabilities;
  final Duration helloTimeout;
  final Duration quitTimeout;
  final Duration jobDrainTimeout;

  /// Held from a host loss until the next successful `hello` carries it.
  PriorHost? _prior;

  /// The previous session's loss handling, which produces [_prior].
  Future<void> _settling = Future.value();

  /// Starts the host and completes `hello`. Throws [HostStartException];
  /// the host is not running afterwards.
  Future<HostSession> start() async {
    await _settling;
    final prior = _prior;
    _prior = null;

    int? job;
    if (Platform.isWindows) {
      try {
        job = createJob();
      } on Object catch (e) {
        _prior = prior;
        throw HostStartException(
          HostStartFailure.spawnFailed,
          'cannot create the outer job: $e',
        );
      }
    }

    final Process process;
    try {
      process = await Process.start(executable, [
        ...executableArguments,
        '--profile',
        profileDir,
      ], environment: environment);
    } on ProcessException catch (e) {
      if (job != null) closeHandle(job);
      _prior = prior;
      throw HostStartException(HostStartFailure.spawnFailed, e.toString());
    }

    final session = HostSession._(this, process, job, _Notifications());
    _settling = session._settled;
    try {
      // The host spawns nothing before hello, so assigning it now puts every
      // later descendant in the job.
      if (job != null) assignPidToJob(job, process.pid);
    } on Object catch (e) {
      await session._abandon();
      _prior = prior;
      throw HostStartException(
        HostStartFailure.spawnFailed,
        'cannot assign the host to the outer job: $e',
        hostExitCode: session._exitCode,
        stderr: session.stderrTail,
      );
    }

    try {
      session._hello = await session.connection
          .hello(
            priorHost: prior,
            desktopPid: pid,
            desktopStartTime: processStartTime(pid),
            outerJobHeld: job != null,
          )
          .timeout(helloTimeout);
    } on TimeoutException {
      await session._abandon();
      _prior = prior;
      throw HostStartException(
        HostStartFailure.helloTimeout,
        'no hello answer in ${helloTimeout.inMilliseconds} ms',
        hostExitCode: session._exitCode,
        stderr: session.stderrTail,
      );
    } on RpcException catch (e) {
      await session._abandon();
      _prior = prior;
      throw HostStartException(
        HostStartFailure.helloRejected,
        e.message,
        reason: e.reason,
        data: e.data,
        hostExitCode: session._exitCode,
        stderr: session.stderrTail,
      );
    } on ConnectionClosedException catch (e) {
      await session._abandon();
      _prior = prior;
      throw HostStartException(
        HostStartFailure.hostLost,
        'the host ended before hello: ${e.reason}',
        hostExitCode: session._exitCode,
        stderr: session.stderrTail,
      );
    }
    return session;
  }
}

/// The notifications of one session. The host may send one as soon as its
/// `hello` answer is out, before the caller can listen, so the first
/// listener also receives those that came earlier (at most [_maxEarly]).
/// Later listeners see what arrives after they listen.
class _Notifications {
  static const int _maxEarly = 64;

  final StreamController<HostNotification> _live =
      StreamController<HostNotification>.broadcast(sync: true);
  final List<HostNotification> _early = [];
  bool _listened = false;

  void add(String method, Json params) {
    final notification = HostNotification(method, params);
    if (!_listened) {
      if (_early.length < _maxEarly) _early.add(notification);
      return;
    }
    _live.add(notification);
  }

  void close() => unawaited(_live.close());

  Stream<HostNotification> get stream => Stream.multi((controller) {
    if (!_listened) {
      _listened = true;
      _early
        ..forEach(controller.addSync)
        ..clear();
    }
    final subscription = _live.stream.listen(
      controller.addSync,
      onDone: controller.closeSync,
    );
    controller.onCancel = subscription.cancel;
  }, isBroadcast: true);
}

/// A started host with a completed `hello`.
class HostSession {
  HostSession._(this._launcher, this._process, this._job, this._notifications)
    : connection = Connection(
        input: _process.stdout,
        output: IOSinkAdapter(_process.stdin),
        versions: _launcher.versions,
        capabilities: _launcher.capabilities,
        onNotification: _notifications.add,
      ) {
    // A dead host breaks the pipe; the connection reports that.
    _process.stdin.done.then<void>((_) {}, onError: (Object _) {});
    _process.stderr.listen(_ring.add, onError: (Object _) {});
    unawaited(
      _process.exitCode.then((code) {
        _exitCode = code;
        _ended(HostLossKind.exited, null);
      }),
    );
    unawaited(
      connection.closed.then((reason) {
        _notifications.close();
        _ended(HostLossKind.connectionClosed, reason);
      }),
    );
  }

  final HostLauncher _launcher;
  final Process _process;
  final StderrRing _ring = StderrRing();
  final Completer<HostLoss> _lost = Completer();
  final Completer<void> _settledDone = Completer();
  final _Notifications _notifications;

  /// The JSON-RPC connection to the host.
  final Connection connection;

  HelloResult? _hello;
  int? _job;
  int? _exitCode;

  /// A quit or an abandoned start is not a host loss.
  bool _expected = false;
  bool _isLost = false;
  Future<void>? _loss;
  Future<QuitResult>? _quit;

  Future<void> get _settled => _settledDone.future;

  /// Every notification the host sends. The host may send one as soon as its
  /// `hello` answer is out, before the caller can listen, so the first
  /// listener also receives those that came earlier (at most 64). Later
  /// listeners see what arrives after they listen.
  Stream<HostNotification> get notifications => _notifications.stream;

  /// The `cleanup/state` notifications, parsed. The host sends one when
  /// reconciliation ends and after every retry or confirm.
  Stream<CleanupState> get cleanupStates => notifications
      .where((n) => n.method == Method.cleanupState)
      .map((n) => CleanupState.fromJson(n.params));

  /// The host's answer to `hello`.
  HelloResult get hello => _hello!;

  int get pid => _process.pid;

  /// The Windows outer job handle while the host is held in it; null on
  /// POSIX and once the job is closed.
  int? get outerJob => _job;

  bool get isLost => _isLost;

  /// Completes, within [hostLossBound] of it happening, when the host exits,
  /// the connection ends, or the host breaks the protocol. Never completes
  /// after a requested [quit].
  Future<HostLoss> get lost => _lost.future;

  /// The last 64 KiB of the host's stderr.
  Uint8List get stderrBytes => _ring.bytes;
  String get stderrTail => _ring.text;

  void _ended(HostLossKind kind, CloseReason? reason) {
    if (_expected || _loss != null) return;
    _loss = _handleLoss(kind, reason);
  }

  Future<void> _handleLoss(HostLossKind kind, CloseReason? reason) async {
    _isLost = true;
    unawaited(connection.close());
    // Whatever ended, a host that still runs is unusable.
    _process.kill();
    final code = await _reap(hostLossBound ~/ 2);
    _lost.complete(HostLoss(kind, code, reason, stderrTail));
    // D8 (Windows): terminate the outer job and attest the result for the
    // next hello. POSIX has no job, so there is nothing to attest.
    final hadJob = _job != null;
    final jobTerminated = await _terminateJob();
    final id = _hello?.instanceId;
    if (hadJob && id != null) {
      _launcher._prior = PriorHost(id, jobTerminated: jobTerminated);
    }
    _settledDone.complete();
  }

  Future<int?> _reap(Duration within) => _process.exitCode
      .then<int?>((c) => c)
      .timeout(within, onTimeout: () => null);

  /// Terminates the outer job and waits for it to hold no process; true when
  /// it did. Closes the handle either way.
  Future<bool> _terminateJob() async {
    final job = _job;
    if (job == null) return false;
    _job = null;
    try {
      final terminated = terminateJob(job);
      final deadline = DateTime.now().add(_launcher.jobDrainTimeout);
      while (true) {
        if (jobActiveProcesses(job) == 0) return terminated;
        if (DateTime.now().isAfter(deadline)) return false;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    } on Object {
      // The job cannot be queried: treat it as not confirmed empty.
      return false;
    } finally {
      closeHandle(job);
    }
  }

  /// A start that failed after the process began: kill it and close
  /// everything, without reporting a loss.
  Future<void> _abandon() async {
    final loss = _loss;
    if (loss != null) return loss;
    _expected = true;
    await connection.close();
    _process.kill();
    await _reap(const Duration(seconds: 5));
    await _terminateJob();
    _settledDone.complete();
  }

  /// Closes the host's stdin. A flush still in flight makes `close` throw, so
  /// it is retried until that flush is over.
  Future<void> _closeStdin() async {
    for (var attempt = 0; attempt < 100; attempt++) {
      try {
        await _process.stdin.close();
        return;
      } on StateError {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      } on Object {
        return; // the pipe is already broken
      }
    }
  }

  /// Ends the host as the desktop quits: closes stdin, which the host reads
  /// as the desktop going away, and waits up to the quit deadline for it to
  /// exit. A host that does not is killed. On Windows closing the outer job
  /// then kills anything that remains. Safe to call more than once.
  Future<QuitResult> quit() => _quit ??= _quitNow();

  Future<QuitResult> _quitNow() async {
    final loss = _loss;
    if (loss != null) {
      await loss;
      return QuitResult(exitCode: _exitCode, timedOut: false);
    }
    _expected = true;
    await connection.close();
    unawaited(_closeStdin());

    var timedOut = false;
    int? code;
    try {
      code = await _process.exitCode.timeout(_launcher.quitTimeout);
    } on TimeoutException {
      timedOut = true;
      _process.kill();
      code = await _reap(const Duration(seconds: 5));
    }
    if (_job != null) {
      // Whether the host finished in time or not, the units it left in the
      // ledger are covered by the outer job: terminate it and attest the
      // result, the same as for a loss (design D8).
      final jobTerminated = await _terminateJob();
      _launcher._prior = PriorHost(
        hello.instanceId,
        jobTerminated: jobTerminated,
      );
    }
    _settledDone.complete();
    return QuitResult(exitCode: code, timedOut: timedOut);
  }
}
