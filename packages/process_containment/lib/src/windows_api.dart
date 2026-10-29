import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Raw `kernel32` entry points, x64 Windows only. Handles are `IntPtr`s so
/// they travel as plain integers (also between isolates: handles are
/// process-wide). Looked up lazily; importing this on POSIX loads nothing.
final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

/// A failed Win32 call with its `GetLastError` code.
class WindowsApiException implements Exception {
  const WindowsApiException(this.call, this.code);
  final String call;
  final int code;

  @override
  String toString() => '$call failed with Win32 error $code';
}

final int Function() getLastError = _kernel32
    .lookupFunction<Uint32 Function(), int Function()>('GetLastError');

final int Function(Pointer<Void>, Pointer<Utf16>) createJobObject = _kernel32
    .lookupFunction<
      IntPtr Function(Pointer<Void>, Pointer<Utf16>),
      int Function(Pointer<Void>, Pointer<Utf16>)
    >('CreateJobObjectW');

final int Function(int, int, Pointer<Void>, int) setInformationJobObject =
    _kernel32.lookupFunction<
      Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32),
      int Function(int, int, Pointer<Void>, int)
    >('SetInformationJobObject');

final int Function(int, int, Pointer<Void>, int, Pointer<Uint32>)
queryInformationJobObject = _kernel32
    .lookupFunction<
      Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32, Pointer<Uint32>),
      int Function(int, int, Pointer<Void>, int, Pointer<Uint32>)
    >('QueryInformationJobObject');

final int Function(int, int) assignProcessToJobObject = _kernel32
    .lookupFunction<Int32 Function(IntPtr, IntPtr), int Function(int, int)>(
      'AssignProcessToJobObject',
    );

final int Function(int, int) terminateJobObject = _kernel32
    .lookupFunction<Int32 Function(IntPtr, Uint32), int Function(int, int)>(
      'TerminateJobObject',
    );

final int Function(int, int, Pointer<Int32>) isProcessInJobNative = _kernel32
    .lookupFunction<
      Int32 Function(IntPtr, IntPtr, Pointer<Int32>),
      int Function(int, int, Pointer<Int32>)
    >('IsProcessInJob');

final int Function(int, int, int) openProcessNative = _kernel32
    .lookupFunction<
      IntPtr Function(Uint32, Int32, Uint32),
      int Function(int, int, int)
    >('OpenProcess');

final int Function(int) closeHandleNative = _kernel32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');

final int Function(int, int) terminateProcessNative = _kernel32
    .lookupFunction<Int32 Function(IntPtr, Uint32), int Function(int, int)>(
      'TerminateProcess',
    );

final int Function(
  int,
  Pointer<Uint64>,
  Pointer<Uint64>,
  Pointer<Uint64>,
  Pointer<Uint64>,
)
getProcessTimes = _kernel32
    .lookupFunction<
      Int32 Function(
        IntPtr,
        Pointer<Uint64>,
        Pointer<Uint64>,
        Pointer<Uint64>,
        Pointer<Uint64>,
      ),
      int Function(
        int,
        Pointer<Uint64>,
        Pointer<Uint64>,
        Pointer<Uint64>,
        Pointer<Uint64>,
      )
    >('GetProcessTimes');

final int Function(int, Pointer<Uint32>) getExitCodeProcess = _kernel32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint32>),
      int Function(int, Pointer<Uint32>)
    >('GetExitCodeProcess');

final int Function(int, int) waitForSingleObject = _kernel32
    .lookupFunction<Uint32 Function(IntPtr, Uint32), int Function(int, int)>(
      'WaitForSingleObject',
    );

final int Function(int) resumeThread = _kernel32
    .lookupFunction<Uint32 Function(IntPtr), int Function(int)>('ResumeThread');

final int Function(
  Pointer<Utf16>,
  Pointer<Utf16>,
  Pointer<Void>,
  Pointer<Void>,
  int,
  int,
  Pointer<Void>,
  Pointer<Utf16>,
  Pointer<Void>,
  Pointer<Void>,
)
createProcessW = _kernel32
    .lookupFunction<
      Int32 Function(
        Pointer<Utf16>,
        Pointer<Utf16>,
        Pointer<Void>,
        Pointer<Void>,
        Int32,
        Uint32,
        Pointer<Void>,
        Pointer<Utf16>,
        Pointer<Void>,
        Pointer<Void>,
      ),
      int Function(
        Pointer<Utf16>,
        Pointer<Utf16>,
        Pointer<Void>,
        Pointer<Void>,
        int,
        int,
        Pointer<Void>,
        Pointer<Utf16>,
        Pointer<Void>,
        Pointer<Void>,
      )
    >('CreateProcessW');

final int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)
createFileW = _kernel32
    .lookupFunction<
      IntPtr Function(
        Pointer<Utf16>,
        Uint32,
        Uint32,
        Pointer<Void>,
        Uint32,
        Uint32,
        IntPtr,
      ),
      int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)
    >('CreateFileW');

final int Function(Pointer<Void>, int, int, Pointer<Size>)
initializeProcThreadAttributeList = _kernel32
    .lookupFunction<
      Int32 Function(Pointer<Void>, Uint32, Uint32, Pointer<Size>),
      int Function(Pointer<Void>, int, int, Pointer<Size>)
    >('InitializeProcThreadAttributeList');

final int Function(
  Pointer<Void>,
  int,
  int,
  Pointer<Void>,
  int,
  Pointer<Void>,
  Pointer<Size>,
)
updateProcThreadAttribute = _kernel32
    .lookupFunction<
      Int32 Function(
        Pointer<Void>,
        Uint32,
        IntPtr,
        Pointer<Void>,
        Size,
        Pointer<Void>,
        Pointer<Size>,
      ),
      int Function(
        Pointer<Void>,
        int,
        int,
        Pointer<Void>,
        int,
        Pointer<Void>,
        Pointer<Size>,
      )
    >('UpdateProcThreadAttribute');

final void Function(Pointer<Void>) deleteProcThreadAttributeList = _kernel32
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
      'DeleteProcThreadAttributeList',
    );

const int processTerminate = 0x0001;
const int processSetQuota = 0x0100;
const int processQueryLimitedInformation = 0x1000;
const int stillActive = 259;
const int infinite = 0xFFFFFFFF;
