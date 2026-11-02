import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'unit_pipes.dart' show unitPipeChunkSize;
import 'windows_api.dart' as w;

/// Owner-only, cancellable Windows named pipe endpoint (design D2 of
/// `kumiko-tool-delivery`).
///
/// This deliberately does not reuse `WindowsPipeReader`/`WindowsPipeWriter`:
/// their blocking `ReadFile`/`WriteFile` only return when the peer acts, and
/// here the peer is a process the host does not control. Every operation on
/// an endpoint handle is overlapped and waits on its I/O event together with
/// a stop event, so the host can always cancel it.

/// A failed pipe operation with its Win32 error [code].
class WindowsPipeException implements Exception {
  const WindowsPipeException(this.message, this.code);
  final String message;
  final int code;

  @override
  String toString() => 'WindowsPipeException: $message (Win32 error $code)';
}

const int _pipeAccessDuplex = 0x00000003;
const int _fileFlagFirstPipeInstance = 0x00080000;
const int _fileFlagOverlapped = 0x40000000;
const int _pipeTypeByte = 0x00000000;
const int _pipeRejectRemoteClients = 0x00000008;
const int _genericReadWrite = 0xC0000000;
const int _openExisting = 3;
const int _invalidHandle = -1;
const int _overlappedSize = 32;
const int _overlappedEventOffset = 24;
const int _acceptPollMs = 50;
// Overlapped I/O goes through the Nt* calls (see windows_api.dart), which
// return the NTSTATUS directly: STATUS_PENDING means "wait for the event",
// anything else is the outcome already. After the event fires the outcome is
// in the IO_STATUS_BLOCK (the OVERLAPPED's first 16 bytes): status in the low
// 32 bits of Internal, byte count in InternalHigh.
const int _statusPending = 0x103;
const int _statusPipeConnected = 0xC00000B2;
const int _fsctlPipeListen = 0x110008;
const _eofStatuses = {
  0xC000014B, // STATUS_PIPE_BROKEN
  0xC00000B0, // STATUS_PIPE_DISCONNECTED
  0xC00000B1, // STATUS_PIPE_CLOSING
  0xC0000011, // STATUS_END_OF_FILE
};

int _ntStatus(int returned) => returned & 0xFFFFFFFF;

void _clear(Pointer<Uint8> overlapped) {
  overlapped
      .asTypedList(_overlappedEventOffset)
      .fillRange(0, _overlappedEventOffset, 0);
}

int _status(Pointer<Uint8> overlapped) =>
    overlapped.cast<Uint64>().value & 0xFFFFFFFF;

int _transferred(Pointer<Uint8> overlapped) =>
    (overlapped + 8).cast<Uint64>().value;

String _hex(int status) => '0x${status.toRadixString(16)}';

const Duration _busyTimeout = Duration(seconds: 2);

/// The pipe mode every instance is created with.
const int _serverPipeMode = _pipeTypeByte | _pipeRejectRemoteClients;

// Worker protocol (worker to host).
const _ready = 1;
const _chunk = 2;
const _written = 3;
const _error = 4;
const _eof = 5;
const _accepted = 6;
const _writeError = 7;
// Host to connection worker.
const _next = 1;

String _randomHex() {
  final random = Random.secure();
  final out = StringBuffer();
  for (var i = 0; i < 16; i++) {
    out.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

/// The string SID of the process token's user.
String _currentUserSid() {
  final token = calloc<IntPtr>();
  final needed = calloc<Uint32>();
  final text = calloc<Pointer<Utf16>>();
  Pointer<Uint8>? info;
  try {
    // TOKEN_QUERY.
    if (w.openProcessToken(w.getCurrentProcess(), 0x0008, token) == 0) {
      throw WindowsPipeException('OpenProcessToken failed', w.getLastError());
    }
    // TokenUser (1): the first call only reports the size.
    w.getTokenInformation(token.value, 1, nullptr, 0, needed);
    info = calloc<Uint8>(needed.value);
    if (w.getTokenInformation(
          token.value,
          1,
          info.cast(),
          needed.value,
          needed,
        ) ==
        0) {
      throw WindowsPipeException(
        'GetTokenInformation failed',
        w.getLastError(),
      );
    }
    // TOKEN_USER starts with the SID pointer.
    final sid = info.cast<Pointer<Void>>().value;
    if (w.convertSidToStringSidW(sid, text) == 0) {
      throw WindowsPipeException(
        'ConvertSidToStringSidW failed',
        w.getLastError(),
      );
    }
    return text.value.toDartString();
  } finally {
    if (text.value != nullptr) w.localFree(text.value.cast());
    if (token.value != 0) w.closeHandleNative(token.value);
    if (info != null) calloc.free(info);
    calloc.free(token);
    calloc.free(needed);
    calloc.free(text);
  }
}

/// SECURITY_ATTRIBUTES built from an SDDL string. Not inheritable.
class _Security {
  _Security(String sddl) {
    final text = sddl.toNativeUtf16();
    final out = calloc<Pointer<Void>>();
    try {
      // SDDL_REVISION_1.
      if (w.convertStringSecurityDescriptorToSecurityDescriptorW(
            text,
            1,
            out,
            nullptr,
          ) ==
          0) {
        throw WindowsPipeException(
          'ConvertStringSecurityDescriptorToSecurityDescriptorW failed',
          w.getLastError(),
        );
      }
      _descriptor = out.value;
    } finally {
      calloc.free(text);
      calloc.free(out);
    }
    attributes = calloc<Uint8>(24);
    attributes.cast<Uint32>().value = 24; // nLength
    (attributes + 8).cast<Pointer<Void>>().value = _descriptor;
    // bInheritHandle at +16 stays 0.
  }

  late final Pointer<Void> _descriptor;
  late final Pointer<Uint8> attributes;

  void free() {
    calloc.free(attributes);
    w.localFree(_descriptor);
  }
}

String _ownerOnlySddl() => 'D:P(A;;GA;;;${_currentUserSid()})(A;;GA;;;SY)';

/// Creates one instance. Returns the handle, or `-1` with the error left to
/// [w.getLastError] (call it before anything else).
int _createInstance(
  Pointer<Utf16> name,
  Pointer<Uint8> attributes,
  int maxInstances, {
  required bool first,
}) {
  return w.createNamedPipeW(
    name,
    _pipeAccessDuplex |
        _fileFlagOverlapped |
        (first ? _fileFlagFirstPipeInstance : 0),
    _serverPipeMode,
    maxInstances,
    unitPipeChunkSize,
    unitPipeChunkSize,
    0,
    attributes.cast(),
  );
}

int _createEvent() {
  final event = w.createEventW(nullptr, 1, 0, nullptr);
  if (event == 0) {
    throw WindowsPipeException('CreateEventW failed', w.getLastError());
  }
  return event;
}

/// A per-user named pipe server.
///
/// Instances are created with the current user and SYSTEM as the only
/// trustees, `PIPE_REJECT_REMOTE_CLIENTS`, and (for the first instance)
/// `FILE_FLAG_FIRST_PIPE_INSTANCE`, so a pre-existing pipe of that name makes
/// [start] fail instead of being adopted. One accept worker isolate keeps one
/// pending instance and creates the next after each connect; each connection
/// has its own worker (see [WindowsPipeConnection]).
class WindowsPipeServer {
  WindowsPipeServer._(this.name, this._stopEvent) {
    _port.listen(_message);
  }

  /// The full pipe name, `\\.\pipe\kumiko-tools-<128-bit random hex>` unless
  /// the caller supplied one.
  final String name;
  final int _stopEvent;
  final ReceivePort _port = ReceivePort();
  final StreamController<WindowsPipeConnection> _connections =
      StreamController<WindowsPipeConnection>();
  final Set<WindowsPipeConnection> _live = {};
  final Completer<void> _acceptExited = Completer<void>();
  Future<void>? _closing;

  /// Starts serving [name] (a random per-user name when omitted).
  ///
  /// Throws [WindowsPipeException] when the pipe cannot be created, notably
  /// with `ERROR_ACCESS_DENIED` (5) when another pipe already uses the name.
  /// [maxInstances] is `nMaxInstances` (1 to 255; 255 is
  /// `PIPE_UNLIMITED_INSTANCES`, the default and the largest the API accepts -
  /// design D2's 256 is not a valid value). The host bounds connections
  /// itself.
  static Future<WindowsPipeServer> start({
    String? name,
    int maxInstances = 255,
  }) async {
    final pipeName = name ?? '\\\\.\\pipe\\kumiko-tools-${_randomHex()}';
    if (!pipeName.startsWith('\\\\.\\pipe\\') || pipeName.length < 10) {
      throw ArgumentError.value(pipeName, 'name', r'must be \\.\pipe\<name>');
    }
    if (maxInstances < 1 || maxInstances > 255) {
      throw RangeError.range(maxInstances, 1, 255, 'maxInstances');
    }
    w.getLastError(); // bind before a failing call, as elsewhere
    final sddl = _ownerOnlySddl();
    final security = _Security(sddl);
    final native = pipeName.toNativeUtf16();
    var first = _invalidHandle;
    var firstError = 0;
    try {
      // A last error of 0 after a failure is a clobbered one (see
      // windows_api.dart): the same failure repeats with its real code.
      for (var attempt = 0; attempt < 3; attempt++) {
        first = _createInstance(
          native,
          security.attributes,
          maxInstances,
          first: true,
        );
        if (first != _invalidHandle) break;
        firstError = w.getLastError();
        if (firstError != 0) break;
      }
    } finally {
      calloc.free(native);
      security.free();
    }
    if (first == _invalidHandle) {
      throw WindowsPipeException(
        'cannot create pipe $pipeName'
        '${firstError == w.errorAccessDenied ? ' (name already in use)' : ''}',
        firstError,
      );
    }
    final int stopEvent;
    try {
      stopEvent = _createEvent();
    } on Object {
      w.closeHandleNative(first);
      rethrow;
    }
    final server = WindowsPipeServer._(pipeName, stopEvent);
    try {
      await Isolate.spawn(
        _acceptMain,
        (server._port.sendPort, pipeName, sddl, first, stopEvent, maxInstances),
        onExit: server._port.sendPort,
        onError: server._port.sendPort,
      );
    } on Object {
      w.closeHandleNative(first);
      w.closeHandleNative(stopEvent);
      server._port.close();
      rethrow;
    }
    return server;
  }

  /// Pipe mode flags every instance is created with
  /// (`PIPE_TYPE_BYTE | PIPE_REJECT_REMOTE_CLIENTS`). The kernel does not
  /// expose the reject flag for read-back.
  int get pipeMode => _serverPipeMode;

  /// Accepted connections, in order. Listen right after [start]; a connection
  /// nobody wants must be `close()`d. Errors here mean the accept worker
  /// failed and no further connections will arrive.
  Stream<WindowsPipeConnection> get connections => _connections.stream;

  /// Connections whose worker has not been joined yet (the host's slot count).
  int get activeConnections => _live.length;

  void _message(dynamic message) {
    if (message == null) {
      if (!_acceptExited.isCompleted) _acceptExited.complete();
      _port.close();
      return;
    }
    if (message is List && message.length == 2 && message[0] is int) {
      final tag = message[0] as int;
      if (tag == _accepted) {
        final connection = WindowsPipeConnection._(
          message[1] as int,
          server: true,
        );
        _live.add(connection);
        unawaited(connection.done.then((_) => _live.remove(connection)));
        if (_connections.isClosed) {
          unawaited(connection.close());
        } else {
          _connections.add(connection);
        }
      } else if (tag == _error && !_connections.isClosed) {
        _connections.addError(WindowsPipeException('${message[1]}', 0));
      }
    } else if (message is List && !_connections.isClosed) {
      _connections.addError(StateError('pipe accept worker failed: $message'));
    }
  }

  /// Stops accepting, closes every live connection and joins all workers.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    w.setEvent(_stopEvent);
    await _acceptExited.future;
    await Future.wait([for (final c in _live.toList()) c.close()]);
    w.closeHandleNative(_stopEvent);
    unawaited(_connections.close());
  }
}

/// Accept worker: owns the pending instance. Waits for `ConnectNamedPipe`
/// (overlapped) and the stop event together, hands each connected handle to
/// the host and creates the next instance.
Future<void> _acceptMain((SendPort, String, String, int, int, int) init) async {
  final (out, name, sddl, firstHandle, stopEvent, maxInstances) = init;
  w.getLastError();
  final native = name.toNativeUtf16();
  final connectEvent = w.createEventW(nullptr, 1, 0, nullptr);
  final overlapped = calloc<Uint8>(_overlappedSize);
  final events = calloc<IntPtr>(2);
  _Security? security;
  var pending = firstHandle;
  try {
    security = _Security(sddl);
    (overlapped + _overlappedEventOffset).cast<IntPtr>().value = connectEvent;
    events[0] = stopEvent;
    events[1] = connectEvent;
    while (true) {
      w.resetEvent(connectEvent);
      _clear(overlapped);
      var status = _ntStatus(
        w.ntFsControlFile(
          pending,
          connectEvent,
          nullptr,
          nullptr,
          overlapped.cast(),
          _fsctlPipeListen,
          nullptr,
          0,
          nullptr,
          0,
        ),
      );
      if (status == _statusPending) {
        final r = w.waitForMultipleObjects(2, events, 0, w.infinite);
        if (r != w.waitObject0 + 1) {
          if (r != w.waitObject0) {
            out.send([_error, 'WaitForMultipleObjects: ${w.getLastError()}']);
          }
          // Stop: cancel, then wait for the cancelled listen to complete.
          w.cancelIoEx(pending, overlapped.cast());
          w.waitForSingleObject(connectEvent, w.infinite);
          return;
        }
        status = _status(overlapped);
      }
      if (_eofStatuses.contains(status)) {
        // The client came and went before it was accepted: reuse the
        // instance for the next one.
        w.disconnectNamedPipe(pending);
        continue;
      }
      if (status != 0 && status != _statusPipeConnected) {
        out.send([_error, 'ConnectNamedPipe: status ${_hex(status)}']);
        return;
      }
      out.send([_accepted, pending]); // ownership moves to the host
      pending = _invalidHandle;
      // Create the next pending instance; the instance cap may delay this.
      while (pending == _invalidHandle) {
        pending = _createInstance(
          native,
          security.attributes,
          maxInstances,
          first: false,
        );
        if (pending != _invalidHandle) break;
        final error = w.getLastError();
        // 0 is a clobbered error: retry like busy; a real failure repeats.
        if (error != w.errorPipeBusy && error != 0) {
          out.send([_error, 'CreateNamedPipeW: $error']);
          return;
        }
        if (w.waitForMultipleObjects(1, events, 0, _acceptPollMs) !=
            w.waitTimeout) {
          return; // stop requested
        }
      }
    }
  } on Object catch (error) {
    out.send([_error, '$error']);
  } finally {
    if (pending != _invalidHandle) w.closeHandleNative(pending);
    security?.free();
    w.closeHandleNative(connectEvent);
    calloc.free(native);
    calloc.free(overlapped);
    calloc.free(events);
  }
}

/// One pipe connection, server side (from [WindowsPipeServer.connections]) or
/// client side (from [openWindowsPipe]).
///
/// One worker isolate owns the handle and runs overlapped reads and writes
/// concurrently. [close] is host-initiated and needs no peer cooperation: it
/// signals the stop event, the worker cancels outstanding I/O with `CancelIoEx`,
/// waits for it with `GetOverlappedResult(bWait: TRUE)`, disconnects (server
/// side) and closes the handle, and [close] completes only after the worker
/// has exited.
class WindowsPipeConnection {
  WindowsPipeConnection._(int handle, {required bool server}) {
    _stopEvent = _createEvent();
    _wakeEvent = _createEvent();
    _incoming = StreamController<Uint8List>(
      onListen: () {
        _listening = true;
        _nextChunk();
      },
      onPause: () => _paused = true,
      onResume: () {
        _paused = false;
        _nextChunk();
      },
      onCancel: () {
        _listening = false;
      },
    );
    _port.listen(_message);
    unawaited(_start(handle, server));
  }

  late final int _stopEvent;
  late final int _wakeEvent;
  late final StreamController<Uint8List> _incoming;
  final ReceivePort _port = ReceivePort();
  final Completer<void> _done = Completer<void>();
  final Queue<(Uint8List, Completer<void>)> _writes = Queue();
  SendPort? _commands;
  bool _eventsClosed = false;
  bool _listening = false;
  bool _paused = false;
  bool _readRequested = false;
  bool _writing = false;
  bool _incomingClosed = false;
  Future<void>? _closing;

  /// Bytes from the peer. Single subscription; pausing stops further reads.
  /// Ends when the peer closes or this connection is closed.
  Stream<Uint8List> get incoming => _incoming.stream;

  /// Whether the worker has exited and the handle is released.
  bool get isJoined => _done.isCompleted;

  /// Completes once the worker has exited and the handle is released.
  Future<void> get done => _done.future;

  Future<void> _start(int handle, bool server) async {
    try {
      await Isolate.spawn(
        _connectionMain,
        (_port.sendPort, handle, _stopEvent, _wakeEvent, server),
        onExit: _port.sendPort,
        onError: _port.sendPort,
      );
    } on Object catch (error, stack) {
      w.closeHandleNative(handle);
      if (!_incomingClosed) _incoming.addError(error, stack);
      _finish();
    }
  }

  void _send(Object message) {
    _commands!.send(message);
    if (!_eventsClosed) w.setEvent(_wakeEvent);
  }

  void _nextChunk() {
    if (_commands != null &&
        _listening &&
        !_paused &&
        !_readRequested &&
        !_incomingClosed &&
        !_finished) {
      _readRequested = true;
      _send(_next);
    }
  }

  void _pump() {
    if (_commands == null || _writing || _writes.isEmpty || _finished) return;
    _writing = true;
    _send(TransferableTypedData.fromList([_writes.first.$1]));
  }

  void _message(dynamic message) {
    if (message == null) {
      _finish();
      return;
    }
    if (message is List && message.length == 2 && message[0] is int) {
      final tag = message[0] as int;
      final value = message[1];
      if (tag == _ready) {
        _commands = value as SendPort;
        _pump();
        _nextChunk();
      } else if (tag == _chunk) {
        _readRequested = false;
        if (!_incomingClosed) {
          _incoming.add(
            (value as TransferableTypedData).materialize().asUint8List(),
          );
        }
        _nextChunk();
      } else if (tag == _written) {
        _writing = false;
        if (_writes.isNotEmpty) _writes.removeFirst().$2.complete();
        _pump();
      } else if (tag == _writeError) {
        _writing = false;
        if (_writes.isNotEmpty) {
          _writes.removeFirst().$2.completeError(
            StateError('pipe write failed: $value'),
          );
        }
      } else if (tag == _error) {
        if (!_incomingClosed) {
          _incoming.addError(StateError('pipe read failed: $value'));
        }
      } else if (tag == _eof) {
        _closeIncoming();
      }
    } else if (message is List) {
      if (!_incomingClosed) {
        _incoming.addError(StateError('pipe worker failed: $message'));
      }
    }
  }

  void _closeIncoming() {
    if (_incomingClosed) return;
    _incomingClosed = true;
    unawaited(_incoming.close());
  }

  bool get _finished => _done.isCompleted;

  void _finish() {
    if (_done.isCompleted) return;
    _closeIncoming();
    for (final (_, completer) in _writes) {
      completer.completeError(StateError('pipe connection closed'));
    }
    _writes.clear();
    _eventsClosed = true;
    w.closeHandleNative(_stopEvent);
    w.closeHandleNative(_wakeEvent);
    _port.close();
    _done.complete();
  }

  /// Queues [bytes] for writing; completes when the whole chunk has been
  /// accepted by the pipe. Writes are sent in order, one at a time. Fails
  /// when the connection is closed or the peer is gone.
  Future<void> add(List<int> bytes) {
    if (_closing != null || _finished) {
      return Future.error(StateError('pipe connection is closed'));
    }
    final completer = Completer<void>();
    _writes.add((Uint8List.fromList(bytes), completer));
    _pump();
    return completer.future;
  }

  /// Host-initiated close. Cancels outstanding I/O without the peer's
  /// cooperation and completes after the worker is joined. Idempotent.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() {
    _closeIncoming();
    if (!_finished) w.setEvent(_stopEvent);
    return _done.future;
  }
}

/// Opens the client end of the pipe [name] (for example the endpoint
/// `\\.\pipe\kumiko-tools-...`). A busy pipe is retried with `WaitNamedPipe`
/// for up to 2 seconds in total; a missing pipe, or any other failure, throws
/// [WindowsPipeException] right away.
Future<WindowsPipeConnection> openWindowsPipe(String name) async {
  w.getLastError(); // bind before a failing call, as elsewhere
  final native = name.toNativeUtf16();
  final clock = Stopwatch()..start();
  var sawBusy = false;
  try {
    while (true) {
      final handle = w.createFileLeaf(
        native,
        _genericReadWrite,
        0,
        nullptr,
        _openExisting,
        _fileFlagOverlapped,
        0,
      );
      if (handle != _invalidHandle) {
        return WindowsPipeConnection._(handle, server: false);
      }
      final error = w.getLastError();
      // Once busy, a missing pipe is the gap between the last instance
      // closing and the next being created: keep waiting for it.
      if (error == w.errorFileNotFound && !sawBusy) {
        throw WindowsPipeException('pipe $name does not exist', error);
      }
      if (error == 0) continue; // a clobbered error: try again
      if (error != w.errorPipeBusy && error != w.errorFileNotFound) {
        throw WindowsPipeException('cannot open pipe $name', error);
      }
      sawBusy = true;
      final remaining = _busyTimeout - clock.elapsed;
      if (remaining <= Duration.zero) {
        throw WindowsPipeException(
          'pipe $name stayed busy for ${_busyTimeout.inSeconds} s',
          w.errorPipeBusy,
        );
      }
      w.waitNamedPipeW(
        native,
        min(remaining.inMilliseconds, _acceptPollMs).clamp(1, _acceptPollMs),
      );
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  } finally {
    calloc.free(native);
  }
}

/// Connection worker. Idle or busy it sits in one `WaitForMultipleObjects`
/// over the stop event, a wake event (the host rings it after sending a
/// command, because a blocked isolate cannot see its port), and the events of
/// the reads and writes in flight.
Future<void> _connectionMain((SendPort, int, int, int, bool) init) async {
  final (out, handle, stopEvent, wakeEvent, server) = init;
  w.getLastError();
  final commands = ReceivePort();
  var tokens = 0;
  Uint8List? writeRequest;
  commands.listen((message) {
    if (message == _next) {
      tokens++;
    } else if (message is TransferableTypedData) {
      writeRequest = message.materialize().asUint8List();
    }
  });
  final readBuffer = calloc<Uint8>(unitPipeChunkSize);
  final readOverlapped = calloc<Uint8>(_overlappedSize);
  final writeOverlapped = calloc<Uint8>(_overlappedSize);
  final events = calloc<IntPtr>(4);
  final readEvent = w.createEventW(nullptr, 1, 0, nullptr);
  final writeEvent = w.createEventW(nullptr, 1, 0, nullptr);
  (readOverlapped + _overlappedEventOffset).cast<IntPtr>().value = readEvent;
  (writeOverlapped + _overlappedEventOffset).cast<IntPtr>().value = writeEvent;
  Pointer<Uint8>? writeBuffer;
  var writeLength = 0;
  var writeOffset = 0;
  var readPending = false;
  var writePending = false;

  // Completion handlers take the NTSTATUS and return false when the
  // connection is over.
  bool readDone(int status) {
    if (status != 0) {
      if (!_eofStatuses.contains(status)) {
        out.send([_error, 'ReadFile: status ${_hex(status)}']);
      }
      return false;
    }
    final bytes = _transferred(readOverlapped);
    if (bytes == 0) return false;
    out.send([
      _chunk,
      TransferableTypedData.fromList([readBuffer.asTypedList(bytes)]),
    ]);
    return true;
  }

  late final bool Function(int) writeDone;

  // Issues the rest of the current write; false if it failed at once.
  bool issueWrite() {
    w.resetEvent(writeEvent);
    _clear(writeOverlapped);
    final status = _ntStatus(
      w.ntWriteFile(
        handle,
        writeEvent,
        nullptr,
        nullptr,
        writeOverlapped.cast(),
        writeBuffer! + writeOffset,
        writeLength - writeOffset,
        nullptr,
        nullptr,
      ),
    );
    if (status == _statusPending) {
      writePending = true;
      return true;
    }
    return writeDone(status); // completed (or failed) at once
  }

  writeDone = (int status) {
    final bytes = _transferred(writeOverlapped);
    if (status != 0 || bytes == 0) {
      out.send([_writeError, 'WriteFile: status ${_hex(status)}']);
      return false;
    }
    writeOffset += bytes;
    if (writeOffset < writeLength) return issueWrite();
    calloc.free(writeBuffer!);
    writeBuffer = null;
    out.send([_written, null]);
    return true;
  };

  out.send([_ready, commands.sendPort]);
  try {
    while (true) {
      if (!readPending && tokens > 0) {
        tokens--;
        w.resetEvent(readEvent);
        _clear(readOverlapped);
        final status = _ntStatus(
          w.ntReadFile(
            handle,
            readEvent,
            nullptr,
            nullptr,
            readOverlapped.cast(),
            readBuffer,
            unitPipeChunkSize,
            nullptr,
            nullptr,
          ),
        );
        if (status == _statusPending) {
          readPending = true;
        } else if (!readDone(status)) {
          break; // completed (or failed) at once
        }
      }
      if (!writePending && writeRequest != null) {
        final bytes = writeRequest!;
        writeRequest = null;
        writeLength = bytes.length;
        writeOffset = 0;
        if (writeLength == 0) {
          out.send([_written, null]);
        } else {
          writeBuffer = calloc<Uint8>(writeLength);
          writeBuffer!.asTypedList(writeLength).setAll(0, bytes);
          if (!issueWrite()) break;
        }
      }

      var n = 0;
      events[n++] = stopEvent;
      events[n++] = wakeEvent;
      final readIndex = readPending ? n : -1;
      if (readPending) events[n++] = readEvent;
      final writeIndex = writePending ? n : -1;
      if (writePending) events[n++] = writeEvent;
      final result = w.waitForMultipleObjects(n, events, 0, w.infinite);
      if (result == w.waitFailed) {
        out.send([_error, 'WaitForMultipleObjects: ${w.getLastError()}']);
        break;
      }
      final index = result - w.waitObject0;
      if (index == 0) break; // host-initiated stop
      if (index == 1) {
        w.resetEvent(wakeEvent);
        // Let the port deliver what the host sent before it rang.
        await Future<void>.delayed(Duration.zero);
      } else if (index == readIndex) {
        readPending = false;
        if (!readDone(_status(readOverlapped))) break;
      } else if (index == writeIndex) {
        writePending = false;
        if (!writeDone(_status(writeOverlapped))) break;
      }
    }
  } on Object catch (error) {
    out.send([_error, '$error']);
  } finally {
    // Cancel what is in flight and wait for the cancellation to land before
    // the buffers and OVERLAPPEDs are freed.
    if (readPending) {
      w.cancelIoEx(handle, readOverlapped.cast());
      w.waitForSingleObject(readEvent, w.infinite);
    }
    if (writePending) {
      w.cancelIoEx(handle, writeOverlapped.cast());
      w.waitForSingleObject(writeEvent, w.infinite);
    }
    if (server) w.disconnectNamedPipe(handle);
    w.closeHandleNative(handle);
    w.closeHandleNative(readEvent);
    w.closeHandleNative(writeEvent);
    if (writeBuffer != null) calloc.free(writeBuffer!);
    calloc.free(readBuffer);
    calloc.free(readOverlapped);
    calloc.free(writeOverlapped);
    calloc.free(events);
    commands.close();
    out.send([_eof, null]);
  }
}
