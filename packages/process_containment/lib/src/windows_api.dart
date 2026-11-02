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

/// The first use of this binding looks the symbol up, which can overwrite the
/// thread's last error: call it once before the call whose error is wanted
/// (`spawnWindowsUnit` does). A leaf call, so the transition back into the VM
/// does not touch the error either.
final int Function() getLastError = _kernel32
    .lookupFunction<Uint32 Function(), int Function()>(
      'GetLastError',
      isLeaf: true,
    );

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

/// `SetConsoleCtrlHandler`; with a null handler it sets (`1`) or clears
/// (`0`) whether this process, and the processes it creates, ignore Ctrl+C.
final int Function(Pointer<Void>, int) setConsoleCtrlHandler = _kernel32
    .lookupFunction<
      Int32 Function(Pointer<Void>, Int32),
      int Function(Pointer<Void>, int)
    >('SetConsoleCtrlHandler');

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

final int Function(Pointer<IntPtr>, Pointer<IntPtr>, Pointer<Void>, int)
createPipeNative = _kernel32
    .lookupFunction<
      Int32 Function(Pointer<IntPtr>, Pointer<IntPtr>, Pointer<Void>, Uint32),
      int Function(Pointer<IntPtr>, Pointer<IntPtr>, Pointer<Void>, int)
    >('CreatePipe');

/// Clears inheritance on parent pipe ends before any child is created.
final int Function(int, int, int) setHandleInformation = _kernel32
    .lookupFunction<
      Int32 Function(IntPtr, Uint32, Uint32),
      int Function(int, int, int)
    >('SetHandleInformation');

final int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)
readFileNative = _kernel32
    .lookupFunction<
      Int32 Function(
        IntPtr,
        Pointer<Uint8>,
        Uint32,
        Pointer<Uint32>,
        Pointer<Void>,
      ),
      int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)
    >('ReadFile');

final int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)
writeFileNative = _kernel32
    .lookupFunction<
      Int32 Function(
        IntPtr,
        Pointer<Uint8>,
        Uint32,
        Pointer<Uint32>,
        Pointer<Void>,
      ),
      int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)
    >('WriteFile');

/// Named pipe server and overlapped I/O entry points (design D2 of
/// `kumiko-tool-delivery`).
final int Function(Pointer<Utf16>, int, int, int, int, int, int, Pointer<Void>)
createNamedPipeW = _kernel32
    .lookupFunction<
      IntPtr Function(
        Pointer<Utf16>,
        Uint32,
        Uint32,
        Uint32,
        Uint32,
        Uint32,
        Uint32,
        Pointer<Void>,
      ),
      int Function(Pointer<Utf16>, int, int, int, int, int, int, Pointer<Void>)
    >('CreateNamedPipeW', isLeaf: true);

final int Function(int) disconnectNamedPipe = _kernel32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'DisconnectNamedPipe',
    );

final int Function(Pointer<Utf16>, int) waitNamedPipeW = _kernel32
    .lookupFunction<
      Int32 Function(Pointer<Utf16>, Uint32),
      int Function(Pointer<Utf16>, int)
    >('WaitNamedPipeW');

final int Function(Pointer<Void>, int, int, Pointer<Utf16>) createEventW =
    _kernel32.lookupFunction<
      IntPtr Function(Pointer<Void>, Int32, Int32, Pointer<Utf16>),
      int Function(Pointer<Void>, int, int, Pointer<Utf16>)
    >('CreateEventW');

final int Function(int) setEvent = _kernel32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('SetEvent');

final int Function(int) resetEvent = _kernel32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('ResetEvent');

final int Function(int, Pointer<IntPtr>, int, int) waitForMultipleObjects =
    _kernel32.lookupFunction<
      Uint32 Function(Uint32, Pointer<IntPtr>, Int32, Uint32),
      int Function(int, Pointer<IntPtr>, int, int)
    >('WaitForMultipleObjects');

final int Function(int, Pointer<Void>) cancelIoEx = _kernel32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Void>),
      int Function(int, Pointer<Void>)
    >('CancelIoEx');

/// Blocking form (`bWait` TRUE) for the wait after `CancelIoEx`: not a leaf
/// call, so it never stalls the isolate group's safepoints.
final int Function(int, Pointer<Void>, Pointer<Uint32>, int)
getOverlappedResult = _kernel32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Void>, Pointer<Uint32>, Int32),
      int Function(int, Pointer<Void>, Pointer<Uint32>, int)
    >('GetOverlappedResult');

// Non-blocking and their error is read right after, so a leaf call (a
// non-leaf transition can clobber the thread's last error).

final int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)
createFileLeaf = _kernel32
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
    >('CreateFileW', isLeaf: true);

final DynamicLibrary _ntdll = DynamicLibrary.open('ntdll.dll');

/// The `Nt*` I/O calls return the `NTSTATUS` directly. Overlapped pipe I/O
/// uses them instead of `ReadFile`/`WriteFile`/`ConnectNamedPipe` because the
/// Win32 wrappers report their outcome through the thread's last error, which
/// the VM can clear between the call and `GetLastError` (a lost
/// `ERROR_PIPE_CONNECTED` would hang an accept). The `IO_STATUS_BLOCK` is the
/// first 16 bytes of the `OVERLAPPED`.
final int Function(
  int,
  int,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  int,
  Pointer<Void>,
  int,
  Pointer<Void>,
  int,
)
ntFsControlFile = _ntdll
    .lookupFunction<
      Int32 Function(
        IntPtr,
        IntPtr,
        Pointer<Void>,
        Pointer<Void>,
        Pointer<Void>,
        Uint32,
        Pointer<Void>,
        Uint32,
        Pointer<Void>,
        Uint32,
      ),
      int Function(
        int,
        int,
        Pointer<Void>,
        Pointer<Void>,
        Pointer<Void>,
        int,
        Pointer<Void>,
        int,
        Pointer<Void>,
        int,
      )
    >('NtFsControlFile');

final int Function(
  int,
  int,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Void>,
  Pointer<Void>,
)
ntReadFile = _ntdll
    .lookupFunction<
      Int32 Function(
        IntPtr,
        IntPtr,
        Pointer<Void>,
        Pointer<Void>,
        Pointer<Void>,
        Pointer<Uint8>,
        Uint32,
        Pointer<Void>,
        Pointer<Void>,
      ),
      int Function(
        int,
        int,
        Pointer<Void>,
        Pointer<Void>,
        Pointer<Void>,
        Pointer<Uint8>,
        int,
        Pointer<Void>,
        Pointer<Void>,
      )
    >('NtReadFile');

final int Function(
  int,
  int,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Void>,
  Pointer<Void>,
)
ntWriteFile = _ntdll
    .lookupFunction<
      Int32 Function(
        IntPtr,
        IntPtr,
        Pointer<Void>,
        Pointer<Void>,
        Pointer<Void>,
        Pointer<Uint8>,
        Uint32,
        Pointer<Void>,
        Pointer<Void>,
      ),
      int Function(
        int,
        int,
        Pointer<Void>,
        Pointer<Void>,
        Pointer<Void>,
        Pointer<Uint8>,
        int,
        Pointer<Void>,
        Pointer<Void>,
      )
    >('NtWriteFile');

final int Function() getCurrentProcess = _kernel32
    .lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');

final Pointer<Void> Function(Pointer<Void>) localFree = _kernel32
    .lookupFunction<
      Pointer<Void> Function(Pointer<Void>),
      Pointer<Void> Function(Pointer<Void>)
    >('LocalFree');

final DynamicLibrary _advapi32 = DynamicLibrary.open('advapi32.dll');

final int Function(int, int, Pointer<IntPtr>) openProcessToken = _advapi32
    .lookupFunction<
      Int32 Function(IntPtr, Uint32, Pointer<IntPtr>),
      int Function(int, int, Pointer<IntPtr>)
    >('OpenProcessToken');

final int Function(int, int, Pointer<Void>, int, Pointer<Uint32>)
getTokenInformation = _advapi32
    .lookupFunction<
      Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32, Pointer<Uint32>),
      int Function(int, int, Pointer<Void>, int, Pointer<Uint32>)
    >('GetTokenInformation');

final int Function(Pointer<Void>, Pointer<Pointer<Utf16>>)
convertSidToStringSidW = _advapi32
    .lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Pointer<Utf16>>),
      int Function(Pointer<Void>, Pointer<Pointer<Utf16>>)
    >('ConvertSidToStringSidW');

final int Function(Pointer<Utf16>, int, Pointer<Pointer<Void>>, Pointer<Uint32>)
convertStringSecurityDescriptorToSecurityDescriptorW = _advapi32
    .lookupFunction<
      Int32 Function(
        Pointer<Utf16>,
        Uint32,
        Pointer<Pointer<Void>>,
        Pointer<Uint32>,
      ),
      int Function(Pointer<Utf16>, int, Pointer<Pointer<Void>>, Pointer<Uint32>)
    >('ConvertStringSecurityDescriptorToSecurityDescriptorW');

/// The bundled open-source ConPTY (design D2; `hook/build.dart`).
const String _conptyAsset = 'package:process_containment/conpty';

@Native<Int32 Function(Int32, IntPtr, IntPtr, Uint32, Pointer<IntPtr>)>(
  assetId: _conptyAsset,
  symbol: 'ConptyCreatePseudoConsole',
)
external int _conptyCreate(
  int coord,
  int input,
  int output,
  int flags,
  Pointer<IntPtr> console,
);

@Native<Int32 Function(IntPtr, Int32)>(
  assetId: _conptyAsset,
  symbol: 'ConptyResizePseudoConsole',
)
external int _conptyResize(int console, int coord);

@Native<Void Function(IntPtr)>(
  assetId: _conptyAsset,
  symbol: 'ConptyClosePseudoConsole',
)
external void _conptyClose(int console);

/// Whether the bundled ConPTY loads. Otherwise the inbox one in `kernel32`
/// serves, so a damaged install still opens terminals. Decided the same way
/// on every isolate (closers run on their own), so a console is always
/// resized and closed by the library that created it. The probe passes no
/// result pointer, which ConPTY rejects with `E_INVALIDARG` before doing
/// anything; a missing library throws instead.
final bool bundledConpty = () {
  try {
    _conptyCreate(0, -1, -1, 0, nullptr);
    return true;
  } on ArgumentError {
    return false;
  }
}();

/// `CreatePseudoConsole(COORD size, input, output, flags, &HPCON)`; returns an
/// `HRESULT` (0 is success). `COORD` is two 16-bit values passed by value in
/// one 32-bit register: [coord] is `cols | rows << 16`.
final int Function(int, int, int, int, Pointer<IntPtr>) createPseudoConsole =
    bundledConpty
    ? _conptyCreate
    : _kernel32.lookupFunction<
        Int32 Function(Int32, IntPtr, IntPtr, Uint32, Pointer<IntPtr>),
        int Function(int, int, int, int, Pointer<IntPtr>)
      >('CreatePseudoConsole');

/// `ResizePseudoConsole(HPCON, COORD)`; returns an `HRESULT`.
final int Function(int, int) resizePseudoConsole = bundledConpty
    ? _conptyResize
    : _kernel32.lookupFunction<
        Int32 Function(IntPtr, Int32),
        int Function(int, int)
      >('ResizePseudoConsole');

/// `ClosePseudoConsole(HPCON)`. Can block while the console's output is not
/// read (design D3): call it only from a closer isolate.
final void Function(int) closePseudoConsole = bundledConpty
    ? _conptyClose
    : _kernel32.lookupFunction<Void Function(IntPtr), void Function(int)>(
        'ClosePseudoConsole',
      );

/// `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`.
const int procThreadAttributePseudoconsole = 0x00020016;
const int errorBrokenPipe = 109;
const int errorHandleEof = 38;
const int errorNoData = 232;

const int processTerminate = 0x0001;
const int processSetQuota = 0x0100;
const int processQueryLimitedInformation = 0x1000;
const int stillActive = 259;
const int infinite = 0xFFFFFFFF;

const int errorFileNotFound = 2;
const int errorAccessDenied = 5;
const int errorPipeBusy = 231;
const int errorPipeNotConnected = 233;
const int errorPipeConnected = 535;
const int errorOperationAborted = 995;
const int errorIoPending = 997;
const int waitObject0 = 0;
const int waitTimeout = 258;
const int waitFailed = 0xFFFFFFFF;
