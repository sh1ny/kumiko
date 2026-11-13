import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:host_protocol/host_protocol.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

import '../host_faults.dart';

/// Where the draft store is in its life (app-exit-and-reopen design D4).
enum DraftPhase {
  /// The worker is being started or is opening its file.
  starting,

  /// The file is open and operations are accepted.
  available,

  /// The file could not be opened or is newer than this host: every
  /// operation fails until `agent/draftReset` replaces the file.
  disabled,

  /// A reset holds its reservation; operations fail meanwhile.
  resetting,
}

/// The stored draft of one session.
class DraftLoad {
  const DraftLoad({required this.revision, this.text});
  final int revision;
  final String? text;
}

/// Unsent composer drafts, kept in `drafts.sqlite` beside the main store.
///
/// The file belongs to one worker isolate with its own SQLite connection, so
/// a slow disk, a lock or an antivirus scan stalls that isolate and nothing
/// else. The host side admits at most [maxPending] operations, gives each a
/// [deadline], and never queues behind a stuck worker: after a missed
/// deadline every operation fails at once until the stuck one returns.
/// Nothing here awaits the worker on the control isolate's path except the
/// operation the caller asked for, and that call is bounded by the deadline.
class DraftStore {
  DraftStore({
    required this.file,
    required this.faults,
    this.deadline = const Duration(seconds: 5),
    this.openHold = Duration.zero,
    this.onAvailable,
    this.log,
  });

  /// Operations that may be pending at once; the next one fails at once.
  static const int maxPending = 16;

  final File file;
  final HostFaults faults;
  final Duration deadline;

  /// Extra wait before the worker opens the file (tests only).
  final Duration openHold;

  /// Called when the store (re)opens or answers again after a stall.
  void Function()? onAvailable;

  /// Operational log; never given draft text.
  final void Function(String op, {String? code})? log;

  DraftPhase _phase = DraftPhase.starting;
  String? _disabledReason;
  Map<String, Object?> _pragmas = const {};
  int _workersSpawned = 0;
  int _releases = 0;
  int _nextOp = 0;
  int _timedOut = 0;
  bool _disposed = false;
  bool _started = false;

  _Worker? _worker;
  final _pending = <int, _Op>{};

  DraftPhase get phase => _phase;
  bool get notResponding => _timedOut > 0;
  int get pending => _pending.length;
  int get workersSpawned => _workersSpawned;
  String? get disabledReason => _disabledReason;
  Map<String, Object?> get pragmas => _pragmas;

  /// Starts the worker. The host calls this after reconciliation has started,
  /// so the open never delays it.
  void start() {
    if (_started || _disposed) return;
    _started = true;
    unawaited(_spawn());
  }

  Future<int> save(String sessionId, String text, int revision) async =>
      await _run('save', {
        'id': sessionId,
        'text': text,
        'revision': revision,
      }, commits: true) as int;

  Future<DraftLoad> load(String sessionId) async {
    final r =
        await _run('load', {'id': sessionId}, commits: false) as List<Object?>;
    return DraftLoad(revision: r[0]! as int, text: r[1] as String?);
  }

  /// Removes the draft of [sessionId] ahead of a prompt: the text is gone
  /// unless a [synced] link holds newer text than [revision]. Returns the
  /// stored revision after the change.
  Future<int> commitSend(
    String sessionId,
    int revision, {
    required bool synced,
  }) async => await _run('send', {
    'id': sessionId,
    'revision': revision,
    'synced': synced,
  }, commits: true) as int;

  /// Puts [text] back after a send that removed it at [revision] (the
  /// revision [commitSend] returned) was then refused. Only an emptied draft
  /// still at that revision is restored, so a newer save always wins.
  /// Returns whether the text was restored.
  Future<bool> restoreSend(String sessionId, String text, int revision) async =>
      await _run('restore', {
        'id': sessionId,
        'text': text,
        'revision': revision,
      }, commits: true) as bool;

  /// Replaces a disabled store's files with a new one. The reservation is
  /// taken before the first await; a second reset, or a reset of a working
  /// store, is refused.
  Future<void> reset() async {
    if (_phase != DraftPhase.disabled) {
      throw RpcException(
        ErrorCode.draftStoreInUse,
        _phase == DraftPhase.resetting
            ? 'a reset is already running'
            : 'the draft store is working; a reset would discard its drafts',
      );
    }
    _phase = DraftPhase.resetting;
    try {
      await faults.waitForDraftResetRelease();
      await _stopWorker();
      await _deleteFiles();
      if (_disposed) throw _unavailable('the host is shutting down');
      await _spawn();
    } on Object catch (error) {
      if (_phase == DraftPhase.resetting) {
        _phase = DraftPhase.disabled;
        _disabledReason ??= 'reset failed';
      }
      if (error is RpcException) rethrow;
      throw _unavailable('the draft store could not be reset');
    }
    if (_phase != DraftPhase.available) {
      throw _unavailable('the new draft store did not open');
    }
  }

  /// Lets commits held by the draft-commit fault go (tests only).
  void releaseHeld() {
    _releases++;
    _worker?.post({'release': true});
  }

  /// Ends the worker without waiting for it.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _failAll(_unavailable('the host is shutting down'));
    _worker?.kill();
    _worker = null;
  }

  // --- operations -------------------------------------------------------

  RpcException _unavailable(String why) =>
      RpcException(ErrorCode.draftUnavailable, why);

  Future<Object?> _run(
    String kind,
    Map<String, Object?> args, {
    required bool commits,
  }) {
    if (_disposed) {
      return Future.error(_unavailable('the host is shutting down'));
    }
    switch (_phase) {
      case DraftPhase.disabled:
        return Future.error(
          _unavailable('drafts are disabled: ${_disabledReason ?? 'unusable'}'),
        );
      case DraftPhase.resetting:
        return Future.error(_unavailable('the draft store is being reset'));
      case DraftPhase.starting:
      case DraftPhase.available:
        break;
    }
    final worker = _worker;
    if (worker == null) {
      return Future.error(_unavailable('the draft store has not started'));
    }
    if (notResponding) {
      return Future.error(_unavailable('the draft store is not responding'));
    }
    if (_pending.length >= maxPending) {
      return Future.error(_unavailable('too many draft operations pending'));
    }
    final id = _nextOp++;
    final op = _Op(worker.generation);
    _pending[id] = op;
    op.timer = Timer(deadline, () {
      if (op.completer.isCompleted) return;
      op.timedOut = true;
      _timedOut++;
      log?.call('draft-deadline', code: kind);
      op.completer.completeError(
        _unavailable('the draft store did not answer in time'),
      );
    });
    worker.post({
      'op': id,
      'kind': kind,
      ...args,
      'fail': commits && faults.draftCommitFails,
      'hold': commits && faults.draftCommitHangs ? _releases : -1,
    });
    return op.completer.future;
  }

  void _failAll(RpcException error) {
    final ops = _pending.values.toList();
    _pending.clear();
    _timedOut = 0;
    for (final op in ops) {
      op.timer?.cancel();
      if (!op.completer.isCompleted) op.completer.completeError(error);
    }
  }

  void _onReply(_Worker worker, List<Object?> message) {
    if (worker.generation != _worker?.generation) return;
    final id = message[1]! as int;
    final op = _pending.remove(id);
    if (op == null) return;
    op.timer?.cancel();
    if (op.timedOut) {
      _timedOut--;
      if (_timedOut == 0 && _phase == DraftPhase.available) {
        onAvailable?.call();
      }
      return;
    }
    if (message[0] == 'ok') {
      op.completer.complete(message[2]);
      return;
    }
    final reason = message[2]! as String;
    final text = message[3]! as String;
    final stored = message[4];
    op.completer.completeError(
      stored is int ? staleRevision(stored, text) : RpcException(reason, text),
    );
  }

  // --- worker lifecycle -------------------------------------------------

  Future<void> _spawn() async {
    final generation = (_worker?.generation ?? 0) + 1;
    _phase = _phase == DraftPhase.resetting
        ? DraftPhase.resetting
        : DraftPhase.starting;
    final opened = Completer<void>();
    final worker = _Worker(generation, opened);
    _worker = worker;
    _workersSpawned++;
    try {
      await worker.spawn(
        _Init(file.path, openHold),
        onMessage: (message) => _onWorkerMessage(worker, message),
        onGone: () => _onWorkerGone(worker),
      );
    } on Object catch (error) {
      _setDisabled(worker, 'the draft worker did not start: $error');
      return;
    }
    await opened.future;
  }

  void _onWorkerMessage(_Worker worker, Object? message) {
    if (worker.generation != _worker?.generation || message is! List) return;
    switch (message[0]) {
      case 'opened':
        _pragmas = Map<String, Object?>.from(message[1]! as Map);
        _disabledReason = null;
        _phase = DraftPhase.available;
        if (!worker.opened.isCompleted) worker.opened.complete();
        // A stalled operation is still pending: the announcement waits for
        // it, so the desktop is told once, when the store answers.
        if (!notResponding) onAvailable?.call();
      case 'disabled':
        _setDisabled(worker, message[1]! as String);
      case 'ok' || 'err':
        _onReply(worker, message);
    }
  }

  void _setDisabled(_Worker worker, String reason) {
    if (worker.generation != _worker?.generation) return;
    _phase = DraftPhase.disabled;
    _disabledReason = reason;
    log?.call('draft-disabled');
    _failAll(_unavailable('drafts are disabled: $reason'));
    if (!worker.opened.isCompleted) worker.opened.complete();
  }

  void _onWorkerGone(_Worker worker) {
    if (worker.intentional || worker.generation != _worker?.generation) return;
    if (_disposed) return;
    _setDisabled(worker, 'the draft worker ended unexpectedly');
  }

  Future<void> _stopWorker() async {
    final worker = _worker;
    if (worker == null) return;
    worker.intentional = true;
    worker.post({'exit': true});
    var exited = await worker.exited.future.timeout(
      deadline,
      onTimeout: () => false,
    );
    if (!exited) {
      worker.kill();
      exited = await worker.exited.future.timeout(
        deadline,
        onTimeout: () => false,
      );
    }
    if (!exited) {
      throw _unavailable('the old draft worker did not exit');
    }
  }

  Future<void> _deleteFiles() async {
    for (final suffix in const ['', '-journal', '-wal', '-shm']) {
      final f = File('${file.path}$suffix');
      // Windows may keep a just-closed file locked for a moment.
      for (var attempt = 0; ; attempt++) {
        try {
          if (f.existsSync()) f.deleteSync();
          break;
        } on FileSystemException {
          if (attempt >= 40) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    }
  }
}

class _Op {
  _Op(this.generation);
  final int generation;
  final completer = Completer<Object?>();
  Timer? timer;
  bool timedOut = false;
}

class _Init {
  const _Init(this.path, this.openHold);
  final String path;
  final Duration openHold;
}

/// The host's handle on one worker isolate.
class _Worker {
  _Worker(this.generation, this.opened);
  final int generation;
  final Completer<void> opened;
  final exited = Completer<bool>();
  bool intentional = false;

  Isolate? _isolate;
  SendPort? _commands;
  final _early = Queue<Object?>();
  final _from = ReceivePort();
  final _exit = ReceivePort();
  final _errors = ReceivePort();

  Future<void> spawn(
    _Init init, {
    required void Function(Object? message) onMessage,
    required void Function() onGone,
  }) async {
    _from.listen((message) {
      if (message is SendPort) {
        _commands = message;
        while (_early.isNotEmpty) {
          message.send(_early.removeFirst());
        }
        return;
      }
      onMessage(message);
    });
    _exit.listen((_) {
      if (!exited.isCompleted) exited.complete(true);
      _close();
      onGone();
    });
    _errors.listen((_) {});
    _isolate = await Isolate.spawn<List<Object?>>(
      _workerMain,
      [_from.sendPort, init.path, init.openHold.inMilliseconds],
      onExit: _exit.sendPort,
      onError: _errors.sendPort,
      errorsAreFatal: true,
      debugName: 'kumiko-drafts',
    );
  }

  void post(Object? message) {
    final port = _commands;
    if (port == null) {
      _early.add(message);
    } else {
      port.send(message);
    }
  }

  void kill() {
    _isolate?.kill(priority: Isolate.immediate);
  }

  void _close() {
    _from.close();
    _exit.close();
    _errors.close();
  }
}

// --- the worker isolate -----------------------------------------------------

const _schema =
    'CREATE TABLE IF NOT EXISTS draft('
    'session_id TEXT PRIMARY KEY, '
    'text TEXT NULL, '
    'bytes INTEGER NOT NULL, '
    'revision INTEGER NOT NULL, '
    'updated_at TEXT NOT NULL)';

const _schemaVersion = 1;

void _workerMain(List<Object?> init) {
  final host = init[0]! as SendPort;
  final path = init[1]! as String;
  final hold = Duration(milliseconds: init[2]! as int);
  final commands = ReceivePort();
  host.send(commands.sendPort);
  final worker = _DraftWorker(host, path, hold);
  commands.listen(worker.onMessage);
  unawaited(worker.run());
}

class _DraftWorker {
  _DraftWorker(this.host, this.path, this.hold);
  final SendPort host;
  final String path;
  final Duration hold;

  sql.Database? _db;
  final _queue = Queue<Map<Object?, Object?>>();
  final _open = Completer<bool>();
  bool _draining = false;
  bool _exitRequested = false;
  int _released = 0;
  Completer<void> _releaseSignal = Completer<void>();

  void onMessage(Object? message) {
    if (message is! Map) return;
    if (message['release'] == true) {
      _released++;
      final signal = _releaseSignal;
      _releaseSignal = Completer<void>();
      signal.complete();
      return;
    }
    if (message['exit'] == true) {
      _exitRequested = true;
      _open.future.then<void>((_) => _exit());
      return;
    }
    _queue.add(message);
    unawaited(_drain());
  }

  void _exit() {
    try {
      _db?.close();
    } on Object {
      // The process ends the handle anyway.
    }
    _db = null;
    Isolate.exit();
  }

  Future<void> run() async {
    try {
      if (hold > Duration.zero) await Future<void>.delayed(hold);
      final pragmas = _openFile();
      if (pragmas == null) {
        _open.complete(false);
        return;
      }
      host.send(['opened', pragmas]);
      _open.complete(true);
    } on Object catch (error) {
      try {
        _db?.close();
      } on Object {
        // Nothing to release.
      }
      _db = null;
      host.send(['disabled', _describe(error)]);
      _open.complete(false);
    }
    if (!await _open.future) return;
    unawaited(_drain());
  }

  String _describe(Object error) => error is sql.SqliteException
      ? 'sqlite: ${error.message}'
      : error.runtimeType.toString();

  /// Opens and checks the file; the pragmas read back, or null after a
  /// `disabled` message was sent.
  Map<String, Object?>? _openFile() {
    final db = _db = sql.sqlite3.open(path);
    // Reading the version first rolls back a hot journal and detects a file
    // that is not a database before anything is changed.
    final version =
        db.select('PRAGMA user_version').single.values.single as int;
    if (version > _schemaVersion) {
      db.close();
      _db = null;
      host.send(['disabled', 'the draft store is newer than this host']);
      return null;
    }
    db.execute('PRAGMA journal_mode = DELETE');
    db.execute('PRAGMA synchronous = EXTRA');
    db.execute('PRAGMA secure_delete = ON');
    if (version < _schemaVersion) {
      db.execute('BEGIN IMMEDIATE');
      try {
        db.execute(_schema);
        db.execute('PRAGMA user_version = $_schemaVersion');
        db.execute('COMMIT');
      } on Object {
        db.execute('ROLLBACK');
        rethrow;
      }
    }
    final read = <String, Object?>{
      'journal_mode': db
          .select('PRAGMA journal_mode')
          .single
          .values
          .single
          .toString()
          .toLowerCase(),
      'synchronous': db.select('PRAGMA synchronous').single.values.single,
      'secure_delete': db.select('PRAGMA secure_delete').single.values.single,
      'user_version': db.select('PRAGMA user_version').single.values.single,
    };
    if (read['journal_mode'] != 'delete' ||
        read['synchronous'] != 3 ||
        read['secure_delete'] != 1) {
      db.close();
      _db = null;
      host.send(['disabled', 'the draft store settings were not applied']);
      return null;
    }
    return read;
  }

  Future<void> _drain() async {
    if (_draining || !_open.isCompleted || _db == null) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty && !_exitRequested) {
        final message = _queue.removeFirst();
        final id = message['op']! as int;
        try {
          final result = await _handle(message);
          host.send(['ok', id, result]);
        } on _Stale catch (e) {
          host.send([
            'err',
            id,
            ErrorCode.staleRevision,
            'stale draft',
            e.stored,
          ]);
        } on _Cap {
          host.send(['err', id, ErrorCode.draftCap, 'drafts are full', null]);
        } on Object catch (error) {
          host.send(['err', id, ErrorCode.storeError, _describe(error), null]);
        }
      }
    } finally {
      _draining = false;
    }
  }

  Future<Object?> _handle(Map<Object?, Object?> m) async {
    final db = _db!;
    final id = m['id']! as String;
    switch (m['kind']) {
      case 'load':
        final rows = db.select(
          'SELECT revision, text FROM draft WHERE session_id = ?',
          [id],
        );
        if (rows.isEmpty) return [0, null];
        return [rows.single['revision'], rows.single['text']];
      case 'save':
        return _commit(db, m, () => _save(db, id, m));
      case 'send':
        return _commit(db, m, () => _send(db, id, m));
      case 'restore':
        return _commit(db, m, () => _restore(db, id, m));
    }
    throw StateError('unknown draft operation ${m['kind']}');
  }

  Future<T> _commit<T>(
    sql.Database db,
    Map<Object?, Object?> m,
    T Function() change,
  ) async {
    db.execute('BEGIN IMMEDIATE');
    try {
      final result = change();
      final hold = m['hold']! as int;
      while (hold >= 0 && _released <= hold) {
        await _releaseSignal.future;
      }
      if (m['fail'] == true) throw StateError('injected draft commit failure');
      db.execute('COMMIT');
      return result;
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  int _save(sql.Database db, String id, Map<Object?, Object?> m) {
    final text = m['text']! as String;
    final revision = m['revision']! as int;
    final row = _row(db, id);
    if (row != null && revision <= row.revision) throw _Stale(row.revision);
    final bytes = utf8.encode(text).length;
    final old = row?.bytes ?? 0;
    if (bytes > old) {
      final total =
          db
                  .select('SELECT COALESCE(SUM(bytes), 0) AS n FROM draft')
                  .single['n']
              as int;
      if (total - old + bytes > maxStoredDraftBytes) throw _Cap();
    }
    _write(db, id, text.isEmpty ? null : text, bytes, revision);
    return revision;
  }

  int _send(sql.Database db, String id, Map<Object?, Object?> m) {
    final revision = m['revision']! as int;
    final synced = m['synced']! as bool;
    final row = _row(db, id);
    final stored = row?.revision ?? 0;
    if (row != null && row.bytes > 0 && synced && stored > revision) {
      // The link holds newer text than the one being sent: it stays.
      return stored;
    }
    final floor = stored > revision ? stored : revision;
    _write(db, id, null, 0, floor);
    return floor;
  }

  bool _restore(sql.Database db, String id, Map<Object?, Object?> m) {
    final text = m['text']! as String;
    final revision = m['revision']! as int;
    final row = _row(db, id);
    if (row == null || row.revision != revision || row.bytes != 0) {
      return false;
    }
    final bytes = utf8.encode(text).length;
    final total =
        db.select('SELECT COALESCE(SUM(bytes), 0) AS n FROM draft').single['n']
            as int;
    if (total + bytes > maxStoredDraftBytes) return false;
    _write(db, id, text.isEmpty ? null : text, bytes, revision);
    return true;
  }

  ({int revision, int bytes})? _row(sql.Database db, String id) {
    final rows = db.select(
      'SELECT revision, bytes FROM draft WHERE session_id = ?',
      [id],
    );
    if (rows.isEmpty) return null;
    return (
      revision: rows.single['revision'] as int,
      bytes: rows.single['bytes'] as int,
    );
  }

  void _write(
    sql.Database db,
    String id,
    String? text,
    int bytes,
    int revision,
  ) {
    db.execute(
      'INSERT INTO draft(session_id, text, bytes, revision, updated_at) '
      'VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(session_id) DO UPDATE SET text = excluded.text, '
      'bytes = excluded.bytes, revision = excluded.revision, '
      'updated_at = excluded.updated_at',
      [id, text, bytes, revision, DateTime.now().toUtc().toIso8601String()],
    );
  }
}

class _Stale implements Exception {
  _Stale(this.stored);
  final int stored;
}

class _Cap implements Exception {}
