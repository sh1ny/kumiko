import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'contained_unit.dart';
import 'unit_exec.dart';
import 'windows_api.dart';
import 'windows_jobs.dart';

/// Quotes [args] into one command line the way `CommandLineToArgvW` and the
/// MSVC runtime read it back.
String quoteWindowsCommandLine(List<String> args) => args.map(_quote).join(' ');

String _quote(String arg) {
  final needsQuotes = arg.isEmpty || arg.contains(' ') || arg.contains('\t');
  final out = StringBuffer(needsQuotes ? '"' : '');
  var backslashes = 0;
  for (final unit in arg.codeUnits) {
    final c = String.fromCharCode(unit);
    if (c == r'\') {
      backslashes++;
    } else if (c == '"') {
      out
        ..write(r'\' * (backslashes * 2 + 1))
        ..write('"');
      backslashes = 0;
    } else {
      out
        ..write(r'\' * backslashes)
        ..write(c);
      backslashes = 0;
    }
  }
  if (needsQuotes) {
    out
      ..write(r'\' * (backslashes * 2))
      ..write('"');
  } else {
    out.write(r'\' * backslashes);
  }
  return out.toString();
}

/// A unit on Windows: a process created suspended, assigned to its own job
/// (nested in the outer job of its creator) and then resumed.
class WindowsUnit implements ContainedUnit {
  WindowsUnit._(
    this.pid,
    this.startTime,
    this.containmentId,
    this._processHandle,
    this._job,
  ) {
    exitCode = Isolate.run(() => _waitForExit(_processHandle)).whenComplete(() {
      _exited = true;
      _closeProcessIfDone();
    });
  }

  @override
  final int pid;

  @override
  final int startTime;

  @override
  final String containmentId;

  final int _processHandle;
  int _job;
  bool _jobClosed = false;
  bool _exited = false;
  bool _closeRequested = false;
  bool _processClosed = false;

  /// The unit's job handle; invalid after [closeJob].
  int get jobHandle => _job;

  @override
  late final Future<int> exitCode;

  /// `TerminateJobObject`, then a wait of up to [wait] for zero active
  /// processes (design: Resource Bounds). Idempotent.
  @override
  Future<TerminationResult> terminate({
    Duration wait = const Duration(seconds: 5),
  }) async {
    if (!_jobClosed) {
      terminateJob(_job);
    }
    final clock = Stopwatch()..start();
    while (true) {
      final gone = _jobClosed ? _exited : jobActiveProcesses(_job) == 0;
      if (gone) return const TerminationResult.terminated();
      if (clock.elapsed >= wait) {
        return const TerminationResult.failed('termination-timeout');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Closes the job handle. The job has kill-on-close, so every process still
  /// in it dies.
  void closeJob() {
    if (_jobClosed) return;
    _jobClosed = true;
    closeHandle(_job);
    _job = 0;
  }

  /// Releases the handles. The process handle stays open until the exit wait
  /// finished, because the helper isolate waits on it.
  void close() {
    closeJob();
    _closeRequested = true;
    _closeProcessIfDone();
  }

  void _closeProcessIfDone() {
    if (_closeRequested && _exited && !_processClosed) {
      _processClosed = true;
      closeHandle(_processHandle);
    }
  }
}

int _waitForExit(int processHandle) {
  waitForSingleObject(processHandle, infinite);
  final code = calloc<Uint32>();
  try {
    getExitCodeProcess(processHandle, code);
    return code.value;
  } finally {
    calloc.free(code);
  }
}

const int _createSuspended = 0x00000004;
const int _createUnicodeEnvironment = 0x00000400;
const int _extendedStartupInfoPresent = 0x00080000;
const int _createNoWindow = 0x08000000;
const int _startfUseStdHandles = 0x00000100;
const int _procThreadAttributeHandleList = 0x00020002;
const int _genericReadWrite = 0xC0000000;
const int _shareReadWrite = 0x00000003;
const int _openExisting = 3;

/// Creates a unit: a new job, then [executable] created suspended with `NUL`
/// stdio and `KUMIKO_UNIT=<containmentId>` in its environment, assigned to
/// the job before its first instruction runs, then resumed. The process is
/// born in the creator's own job (the desktop's outer job when the host is
/// the creator), so it ends up in both, and neither lets it break away.
WindowsUnit spawnWindowsUnit({
  required String executable,
  List<String> args = const [],
  required String containmentId,
  Map<String, String>? environment,
  String? workingDirectory,
}) {
  final job = createJob();
  final toFree = <Pointer<NativeType>>[];
  var nul = 0;
  var attributeList = nullptr.cast<Void>();
  var processHandle = 0;
  var threadHandle = 0;
  try {
    // SECURITY_ATTRIBUTES (24 bytes, bInheritHandle at 16) for an inheritable
    // NUL handle.
    final sa = calloc<Uint8>(24);
    toFree.add(sa);
    sa.cast<Uint32>().value = 24;
    (sa + 16).cast<Int32>().value = 1;
    final nulName = 'NUL'.toNativeUtf16();
    toFree.add(nulName);
    nul = createFileW(
      nulName,
      _genericReadWrite,
      _shareReadWrite,
      sa.cast<Void>(),
      _openExisting,
      0,
      0,
    );
    if (nul == -1) {
      throw WindowsApiException('CreateFileW(NUL)', getLastError());
    }

    // Only the NUL handle is inherited, not every inheritable handle the host
    // happens to hold.
    final listSize = calloc<Size>();
    toFree.add(listSize);
    initializeProcThreadAttributeList(nullptr, 1, 0, listSize);
    attributeList = calloc<Uint8>(listSize.value).cast<Void>();
    toFree.add(attributeList);
    if (initializeProcThreadAttributeList(attributeList, 1, 0, listSize) == 0) {
      throw WindowsApiException(
        'InitializeProcThreadAttributeList',
        getLastError(),
      );
    }
    final handles = calloc<IntPtr>(1);
    toFree.add(handles);
    handles.value = nul;
    if (updateProcThreadAttribute(
          attributeList,
          0,
          _procThreadAttributeHandleList,
          handles.cast<Void>(),
          sizeOf<IntPtr>(),
          nullptr,
          nullptr,
        ) ==
        0) {
      throw WindowsApiException('UpdateProcThreadAttribute', getLastError());
    }

    // STARTUPINFOEXW: STARTUPINFOW is 104 bytes on x64, then the list pointer.
    final startup = calloc<Uint8>(112);
    toFree.add(startup);
    startup.cast<Uint32>().value = 112;
    (startup + 60).cast<Uint32>().value = _startfUseStdHandles;
    (startup + 80).cast<IntPtr>().value = nul;
    (startup + 88).cast<IntPtr>().value = nul;
    (startup + 96).cast<IntPtr>().value = nul;
    (startup + 104).cast<Pointer<Void>>().value = attributeList;

    final info = calloc<Uint8>(24); // PROCESS_INFORMATION
    toFree.add(info);

    final commandLine = quoteWindowsCommandLine([executable, ...args])
        .toNativeUtf16();
    toFree.add(commandLine);
    final application = executable.toNativeUtf16();
    toFree.add(application);
    final env = _environmentBlock({
      ...?environment,
      unitMarkerVariable: containmentId,
    });
    toFree.add(env);
    final cwd = workingDirectory?.toNativeUtf16();
    if (cwd != null) toFree.add(cwd);

    final ok = createProcessW(
      application,
      commandLine,
      nullptr,
      nullptr,
      1,
      _createSuspended |
          _createUnicodeEnvironment |
          _extendedStartupInfoPresent |
          _createNoWindow,
      env.cast<Void>(),
      cwd ?? nullptr,
      startup.cast<Void>(),
      info.cast<Void>(),
    );
    if (ok == 0) throw WindowsApiException('CreateProcessW', getLastError());
    processHandle = info.cast<IntPtr>().value;
    threadHandle = (info + 8).cast<IntPtr>().value;
    final pid = (info + 16).cast<Uint32>().value;

    try {
      assignProcessToJob(job, processHandle);
    } on WindowsApiException {
      terminateProcessNative(processHandle, 1);
      rethrow;
    }
    final startTime = processHandleStartTime(processHandle);
    if (startTime == null) {
      terminateProcessNative(processHandle, 1);
      throw WindowsApiException('GetProcessTimes', getLastError());
    }
    if (resumeThread(threadHandle) == 0xFFFFFFFF) {
      terminateProcessNative(processHandle, 1);
      throw WindowsApiException('ResumeThread', getLastError());
    }

    final unit = WindowsUnit._(
      pid,
      startTime,
      containmentId,
      processHandle,
      job,
    );
    processHandle = 0; // now owned by the unit
    return unit;
  } catch (_) {
    closeHandleNative(job);
    if (processHandle != 0) closeHandleNative(processHandle);
    rethrow;
  } finally {
    if (threadHandle != 0) closeHandleNative(threadHandle);
    if (nul != 0 && nul != -1) closeHandleNative(nul);
    if (attributeList != nullptr) deleteProcThreadAttributeList(attributeList);
    for (final p in toFree) {
      calloc.free(p);
    }
  }
}

/// `NAME=value\0...\0\0` in UTF-16, the parent's environment overridden by
/// [overrides]. Windows names compare case-insensitively.
Pointer<Utf16> _environmentBlock(Map<String, String> overrides) {
  final merged = <String, MapEntry<String, String>>{};
  for (final e in Platform.environment.entries) {
    merged[e.key.toUpperCase()] = e;
  }
  for (final e in overrides.entries) {
    merged[e.key.toUpperCase()] = e;
  }
  final keys = merged.keys.toList()..sort();
  final text = StringBuffer();
  for (final k in keys) {
    final e = merged[k]!;
    text
      ..write(e.key)
      ..write('=')
      ..write(e.value)
      ..write('\u0000');
  }
  text.write('\u0000');
  final units = text.toString().codeUnits;
  final block = calloc<Uint16>(units.length + 1);
  block.asTypedList(units.length).setAll(0, units);
  return block.cast<Utf16>();
}
