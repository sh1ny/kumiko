import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'windows_api.dart';

const int _jobObjectBasicAccountingInformation = 1;
const int _jobObjectExtendedLimitInformation = 9;
const int _extendedLimitInformationSize = 144; // x64
const int _basicAccountingInformationSize = 48; // x64
const int _limitKillOnJobClose = 0x2000;

/// Creates a job object whose handle is returned as an integer. With
/// [killOnClose] closing the last handle kills every process in it. No
/// breakaway limit is set, so processes in the job can neither start
/// children outside it nor leave it.
int createJob({bool killOnClose = true}) {
  final job = createJobObject(nullptr, nullptr);
  if (job == 0) throw WindowsApiException('CreateJobObjectW', getLastError());
  if (killOnClose) {
    final info = calloc<Uint8>(_extendedLimitInformationSize);
    try {
      // JOBOBJECT_BASIC_LIMIT_INFORMATION.LimitFlags is at offset 16.
      (info + 16).cast<Uint32>().value = _limitKillOnJobClose;
      final ok = setInformationJobObject(
        job,
        _jobObjectExtendedLimitInformation,
        info.cast<Void>(),
        _extendedLimitInformationSize,
      );
      if (ok == 0) {
        final code = getLastError();
        closeHandleNative(job);
        throw WindowsApiException('SetInformationJobObject', code);
      }
    } finally {
      calloc.free(info);
    }
  }
  return job;
}

/// Assigns the process with [pid] to [job], for example the host to the
/// desktop's outer job.
void assignPidToJob(int job, int pid) {
  final process = openProcessNative(processSetQuota | processTerminate, 0, pid);
  if (process == 0) throw WindowsApiException('OpenProcess', getLastError());
  try {
    assignProcessToJob(job, process);
  } finally {
    closeHandleNative(process);
  }
}

/// Assigns an open process handle to [job].
void assignProcessToJob(int job, int processHandle) {
  if (assignProcessToJobObject(job, processHandle) == 0) {
    throw WindowsApiException('AssignProcessToJobObject', getLastError());
  }
}

/// `TerminateJobObject`: true when the call succeeded.
bool terminateJob(int job, {int exitCode = 1}) =>
    terminateJobObject(job, exitCode) != 0;

/// The number of processes currently running in [job], descendants of nested
/// jobs included.
int jobActiveProcesses(int job) {
  final info = calloc<Uint8>(_basicAccountingInformationSize);
  try {
    final ok = queryInformationJobObject(
      job,
      _jobObjectBasicAccountingInformation,
      info.cast<Void>(),
      _basicAccountingInformationSize,
      nullptr,
    );
    if (ok == 0) {
      throw WindowsApiException('QueryInformationJobObject', getLastError());
    }
    return (info + 40).cast<Uint32>().value; // ActiveProcesses
  } finally {
    calloc.free(info);
  }
}

/// `IsProcessInJob` for an open process handle.
bool isProcessHandleInJob(int processHandle, int job) {
  final result = calloc<Int32>();
  try {
    if (isProcessInJobNative(processHandle, job, result) == 0) {
      throw WindowsApiException('IsProcessInJob', getLastError());
    }
    return result.value != 0;
  } finally {
    calloc.free(result);
  }
}

/// `IsProcessInJob` by pid; false when the process cannot be opened.
bool isPidInJob(int pid, int job) {
  final process = openProcessNative(processQueryLimitedInformation, 0, pid);
  if (process == 0) return false;
  try {
    return isProcessHandleInJob(process, job);
  } finally {
    closeHandleNative(process);
  }
}

void closeHandle(int handle) {
  closeHandleNative(handle);
}

/// `TerminateProcess` by pid; false when it cannot be opened or ended.
bool terminatePid(int pid) {
  final process = openProcessNative(processTerminate, 0, pid);
  if (process == 0) return false;
  try {
    return terminateProcessNative(process, 1) != 0;
  } finally {
    closeHandleNative(process);
  }
}

/// The creation time of the process behind [processHandle] as a `FILETIME`
/// (100 ns ticks since 1601), or null when it cannot be read.
int? processHandleStartTime(int processHandle) {
  final times = calloc<Uint64>(4);
  try {
    final ok = getProcessTimes(
      processHandle,
      times,
      times + 1,
      times + 2,
      times + 3,
    );
    return ok == 0 ? null : times.value;
  } finally {
    calloc.free(times);
  }
}

/// Windows start time of [pid], or null when it cannot be opened (gone).
int? windowsProcessStartTime(int pid) {
  final process = openProcessNative(processQueryLimitedInformation, 0, pid);
  if (process == 0) return null;
  try {
    return processHandleStartTime(process);
  } finally {
    closeHandleNative(process);
  }
}

/// True while [pid] runs with start time [startTime]. An exited process
/// whose handle is still held elsewhere is not alive.
bool windowsIsProcessAlive(int pid, int startTime) {
  final process = openProcessNative(processQueryLimitedInformation, 0, pid);
  if (process == 0) return false;
  try {
    if (processHandleStartTime(process) != startTime) return false;
    final code = calloc<Uint32>();
    try {
      return getExitCodeProcess(process, code) != 0 &&
          code.value == stillActive;
    } finally {
      calloc.free(code);
    }
  } finally {
    closeHandleNative(process);
  }
}
