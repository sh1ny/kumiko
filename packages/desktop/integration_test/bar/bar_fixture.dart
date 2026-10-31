// A program the engine bar test runs in a host terminal, through a profile
// whose executable is the Dart VM: `dart bar_fixture.dart <mode>`. Uses
// SDK libraries only, so it needs no package resolution.
//
// Every mode clears the screen, writes its pattern from the top-left cell,
// prints `READY` on row 10 and then waits for input until it is killed.
//
//   colour  256 indexed foreground colours (one `X` each, from row 1 column 1,
//           wrapping at 80 columns), then 16 true-colour `T`s on row 6.
//   wide    `中文😀a` on row 1.
//   paste   turns bracketed paste on, then reports the bytes of one paste on
//           row 12 as `GOT <hex>`. On Windows it first asks the console for
//           virtual-terminal input, as programs that take bracketed paste
//           there do; without it the console keeps the paste markers.
import 'dart:ffi';
import 'dart:io';

/// The true-colour samples, also used by the test.
List<(int, int, int)> trueColours() => [
  for (var i = 0; i < 16; i++) (i * 16 + 7, 255 - i * 16, (i * 37 + 11) % 256),
];

Future<void> main(List<String> args) async {
  stdout.write('\x1b[2J\x1b[H');
  switch (args.single) {
    case 'colour':
      for (var n = 0; n < 256; n++) {
        stdout.write('\x1b[38;5;${n}mX');
      }
      stdout.write('\x1b[0m\x1b[6;1H');
      for (final (r, g, b) in trueColours()) {
        stdout.write('\x1b[38;2;$r;$g;${b}mT');
      }
      stdout.write('\x1b[0m');
    case 'wide':
      stdout.write('中文😀a');
    case 'paste':
      stdin
        ..echoMode = false
        ..lineMode = false;
      if (Platform.isWindows) _virtualTerminalInput();
      stdout.write('\x1b[?2004h');
  }
  stdout.write('\x1b[10;1HREADY');
  await stdout.flush();
  final received = <int>[];
  await for (final chunk in stdin) {
    if (args.single != 'paste') continue;
    received.addAll(chunk);
    // Everything read so far, for a failure message.
    stdout.write('\x1b[13;1HRAW ${_hex(received)}');
    await stdout.flush();
    final text = String.fromCharCodes(received);
    if (text.contains('\x1b[201~')) {
      stdout.write('\x1b[12;1HGOT ${_hex(received)}');
      await stdout.flush();
      received.clear();
    }
  }
}

String _hex(List<int> bytes) =>
    [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

/// Adds ENABLE_VIRTUAL_TERMINAL_INPUT to the console input mode, so the
/// console passes escape sequences such as the paste markers through as
/// bytes.
void _virtualTerminalInput() {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final getStdHandle = kernel32
      .lookupFunction<IntPtr Function(Uint32), int Function(int)>(
        'GetStdHandle',
      );
  final getConsoleMode = kernel32
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)
      >('GetConsoleMode');
  final setConsoleMode = kernel32
      .lookupFunction<Int32 Function(IntPtr, Uint32), int Function(int, int)>(
        'SetConsoleMode',
      );
  const stdInputHandle = -10 & 0xFFFFFFFF;
  const enableVirtualTerminalInput = 0x0200;
  final input = getStdHandle(stdInputHandle);
  // dart:ffi has no allocator of its own; the 4 bytes are never freed.
  final localAlloc = kernel32
      .lookupFunction<
        Pointer<Uint32> Function(Uint32, IntPtr),
        Pointer<Uint32> Function(int, int)
      >('LocalAlloc');
  const zeroInit = 0x40;
  final mode = localAlloc(zeroInit, 4);
  if (getConsoleMode(input, mode) == 0 ||
      setConsoleMode(input, mode.value | enableVirtualTerminalInput) == 0) {
    throw StateError('could not enable virtual-terminal input');
  }
}
