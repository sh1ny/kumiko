import 'dart:io';

import 'posix_unit.dart';
import 'windows_jobs.dart';

/// The OS start time of [pid]: `GetProcessTimes` on Windows, `/proc/<pid>/stat`
/// on Linux, `proc_pidinfo` on macOS. Null when the process is gone or cannot
/// be read. The value is opaque; compare it for equality only, together with
/// the pid, before signalling anything.
int? processStartTime(int pid) => Platform.isWindows
    ? windowsProcessStartTime(pid)
    : posixProcessStartTime(pid);

/// True while [pid] is running with start time [startTime]: a gone process, a
/// zombie and a reused pid are not.
bool isProcessAlive(int pid, int startTime) => Platform.isWindows
    ? windowsIsProcessAlive(pid, startTime)
    : posixIsProcessAlive(pid, startTime);
