import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

final _user32 = DynamicLibrary.open('user32.dll');
final _kernel32 = DynamicLibrary.open('kernel32.dll');

final _findWindowEx = _user32
    .lookupFunction<
      IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
      int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)
    >('FindWindowExW');
final _windowPid = _user32
    .lookupFunction<
      Uint32 Function(IntPtr, Pointer<Uint32>),
      int Function(int, Pointer<Uint32>)
    >('GetWindowThreadProcessId');
final _className = _user32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>, Int32),
      int Function(int, Pointer<Utf16>, int)
    >('GetClassNameW');
final _getParent = _user32
    .lookupFunction<IntPtr Function(IntPtr), int Function(int)>('GetParent');
final _activePopup = _user32
    .lookupFunction<IntPtr Function(IntPtr), int Function(int)>(
      'GetLastActivePopup',
    );
final _createWindow = _user32
    .lookupFunction<
      IntPtr Function(
        Uint32,
        Pointer<Utf16>,
        Pointer<Utf16>,
        Uint32,
        Int32,
        Int32,
        Int32,
        Int32,
        IntPtr,
        IntPtr,
        IntPtr,
        Pointer<Void>,
      ),
      int Function(
        int,
        Pointer<Utf16>,
        Pointer<Utf16>,
        int,
        int,
        int,
        int,
        int,
        int,
        int,
        int,
        Pointer<Void>,
      )
    >('CreateWindowExW');
final _isWindow = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindow');
final _postMessage = _user32
    .lookupFunction<
      Int32 Function(IntPtr, Uint32, UintPtr, IntPtr),
      int Function(int, int, int, int)
    >('PostMessageW');
final _openProcess = _kernel32
    .lookupFunction<
      IntPtr Function(Uint32, Int32, Uint32),
      int Function(int, int, int)
    >('OpenProcess');
final _wait = _kernel32
    .lookupFunction<Uint32 Function(IntPtr, Uint32), int Function(int, int)>(
      'WaitForSingleObject',
    );
final _closeHandle = _kernel32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');

const runnerWindowClass = 'FLUTTER_RUNNER_WIN32_WINDOW';

Map<int, String> ownedTopLevelWindows(int pid) => using((arena) {
  final windows = <int, String>{};
  final owner = arena<Uint32>();
  final buffer = arena<Uint16>(256).cast<Utf16>();
  var window = _findWindowEx(0, 0, nullptr, nullptr);
  while (window != 0) {
    if (_getParent(window) == 0 &&
        _windowPid(window, owner) != 0 &&
        owner.value == pid) {
      final length = _className(window, buffer, 256);
      if (length > 0) windows[window] = buffer.toDartString(length: length);
    }
    window = _findWindowEx(0, window, nullptr, nullptr);
  }
  return windows;
});

bool windowExists(int window) => _isWindow(window) != 0;

void postTitleBarClose(int window) {
  const wmSysCommand = 0x0112;
  const scClose = 0xf060;
  if (_postMessage(window, wmSysCommand, scClose, 0) == 0) {
    throw StateError('Could not post the system Close command');
  }
}

void postWindowClose(int window) {
  if (_postMessage(window, 0x0010, 0, 0) == 0) {
    throw StateError('Could not post WM_CLOSE');
  }
}

int? nativeFolderPicker(int owner) {
  final dialog = _activePopup(owner);
  if (dialog == owner || _getParent(dialog) != owner) return null;
  return using((arena) {
    final buffer = arena<Uint16>(256).cast<Utf16>();
    final length = _className(dialog, buffer, 256);
    return length > 0 && buffer.toDartString(length: length) == '#32770'
        ? dialog
        : null;
  });
}

void cancelNativeFolderPicker(int dialog) {
  const wmCommand = 0x0111;
  const idCancel = 2;
  if (_postMessage(dialog, wmCommand, idCancel, 0) == 0) {
    throw StateError('Could not cancel the test-owned folder picker');
  }
}

void createAuxiliaryWindow() => using((arena) {
  final window = _createWindow(
    0,
    'STATIC'.toNativeUtf16(allocator: arena),
    nullptr,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    nullptr,
  );
  if (window == 0) {
    throw StateError('Could not create the test auxiliary window');
  }
  // This hidden, unowned window is retained until the fixture process exits.
});

int openProcessForExit(int pid) {
  const synchronize = 0x00100000;
  final handle = _openProcess(synchronize, 0, pid);
  if (handle == 0) throw StateError('Could not retain the test host handle');
  return handle;
}

Future<void> waitForProcessExit(int handle) => Isolate.run(() {
  const infinite = 0xffffffff;
  if (_wait(handle, infinite) != 0) {
    throw StateError('Test host process wait failed');
  }
});

void closeProcessHandle(int handle) => _closeHandle(handle);
