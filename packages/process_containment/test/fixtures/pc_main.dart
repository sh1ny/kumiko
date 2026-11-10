// Test executable that stands in for the host binary: it has the
// `--unit-exec` mode and the fixture programs units run (design D2, D10).
// Compiled by the tests with `dart compile exe`.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:process_containment/process_containment.dart';

/// Fixtures report to this file, one `role pid marker sid` line each.
const outVariable = 'PC_FIXTURE_OUT';

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == '--unit-exec') {
    runUnitExec(args.sublist(1));
  }
  if (args.length >= 2 && args.first == '--fixture') {
    switch (args[1]) {
      case 'tree':
        await _tree();
      case 'tree-child':
        await _treeChild();
      case 'sleeper':
        _report('sleeper');
        _stayAlive();
      case 'stubborn':
        ProcessSignal.sigterm.watch().listen((_) {});
        _report('stubborn');
        _stayAlive();
      case 'exit':
        exit(int.parse(args[2]));
      case 'nul-stdio':
        _nulStdio();
      case 'breakaway':
        _breakaway();
      case 'host-sim':
        await _hostSim();
      case 'tty':
        await _tty(args.sublist(2));
      case 'flood':
        await _flood();
      case 'pipes-echo':
        stderr.writeln('separate stderr');
        await stderr.flush();
        await stdout.addStream(stdin);
        await stdout.flush();
      case 'pipes-argv':
        stdout.write(jsonEncode(args.sublist(2)));
        await stdout.flush();
      case 'pipes-env-parent':
        final inherit = args[2] == 'true';
        final childArgs = ['--fixture', 'pipes-env-child'];
        final child = Platform.isWindows
            ? spawnWindowsUnit(
                executable: _self,
                args: childArgs,
                containmentId: 'env-child',
                environment: {'PC_RESOLUTION': 'explicit'},
                inheritParentEnvironment: inherit,
                pipes: true,
              )
            : await spawnPosixUnit(
                shimExecutable: _self,
                argv: [_self, ...childArgs],
                containmentId: 'env-child',
                environment: {'PC_RESOLUTION': 'explicit'},
                inheritParentEnvironment: inherit,
                pipes: true,
              );
        final errors = child.pipes!.stderr.drain<void>();
        await stdout.addStream(child.pipes!.stdout);
        await child.exitCode;
        await errors;
        await child.terminate();
        await child.pipes!.close();
        if (child is WindowsUnit) child.close();
      case 'pipes-env-child':
        stdout.write(
          jsonEncode({
            'parentMarker':
                Platform.environment['PC_PARENT_CANARY'] == 'controlled',
            'explicit': Platform.environment['PC_RESOLUTION'] == 'explicit',
            'unitMarker':
                Platform.environment[unitMarkerVariable] == 'env-child',
          }),
        );
        await stdout.flush();
      case 'pipes-options':
        stdout.write(
          jsonEncode({
            'cwd': Directory.current.path,
            'out': Platform.environment[outVariable],
          }),
        );
        await stdout.flush();
      case 'pipes-output':
        stderr.writeln('output-started');
        await stderr.flush();
        final chunk = List<int>.filled(64 * 1024, 120);
        for (var i = 0; i < 64; i++) {
          stdout.add(chunk);
          await stdout.flush();
        }
        _report('output-finished');
        stderr.writeln('output-finished');
        await stderr.flush();
      case 'pipes-no-read':
        stdout.writeln('ready');
        await stdout.flush();
        stdout.writeln('responsive');
        await stdout.flush();
        _stayAlive();
      case 'pipes-tree':
        _report('tree');
        await Process.start(_self, ['--fixture', 'pipes-tree-child']);
        _stayAlive();
      case 'pipes-tree-child':
        _report('child');
        await Process.start(_self, ['--fixture', 'sleeper']);
        _stayAlive();
      case 'pipes-inherited-stdin':
        await Process.start(_self, [
          '--fixture',
          'pipes-inherited-stdin-child',
        ], mode: ProcessStartMode.inheritStdio);
        _report('leader');
        _stayAlive();
      case 'pipes-inherited-stdin-child':
        _windowsHandles();
        stdout.writeln();
        await stdout.flush();
        _report('inherited-stdin');
        _stayAlive();
      case 'pipes-windows-handles':
        _windowsHandles();
        await stdout.flush();
      default:
        stderr.writeln('unknown fixture ${args[1]}');
        exit(64);
    }
    return;
  }
  stderr.writeln('usage: --unit-exec ... | --fixture <name>');
  exit(64);
}

String get _self => Platform.resolvedExecutable;

void _report(String role) {
  final marker = Platform.environment[unitMarkerVariable] ?? '-';
  final sid = Platform.isWindows ? '-' : '${sessionIdOf(pid)}';
  File(Platform.environment[outVariable]!).writeAsStringSync(
    '$role $pid $marker $sid\n',
    mode: FileMode.append,
    flush: true,
  );
}

void _stayAlive() {
  ReceivePort(); // keeps the isolate, and so the process, alive
}

Future<void> _tree() async {
  _report('tree');
  await Process.start(_self, ['--fixture', 'tree-child']);
  _stayAlive();
}

/// Starts a grandchild in its own POSIX session; on Windows a plain child.
Future<void> _treeChild() async {
  _report('child');
  if (Platform.isWindows) {
    await Process.start(_self, ['--fixture', 'sleeper']);
  } else {
    final id = Platform.environment[unitMarkerVariable]!;
    await Process.start(_self, [
      '--unit-exec',
      id,
      '--',
      _self,
      '--fixture',
      'sleeper',
    ]);
  }
  _stayAlive();
}

void _nulStdio() {
  // stdin must be at end of file; stdout must accept writes.
  final eof = stdin.readByteSync() == -1;
  stdout.writeln('x');
  _report(eof ? 'nul-stdio-eof' : 'nul-stdio-open');
}

typedef _CreateProcessNative = Int32 Function(
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
);
typedef _CreateProcessDart = int Function(
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
);

/// Asks Windows to start a child outside this process's job.
void _breakaway() {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final createProcess = kernel32
      .lookupFunction<_CreateProcessNative, _CreateProcessDart>(
        'CreateProcessW',
      );
  final getLastError = kernel32
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');
  final startup = calloc<Uint8>(104);
  startup.cast<Uint32>().value = 104;
  final info = calloc<Uint8>(24);
  final cmd = '"$_self" --fixture sleeper'.toNativeUtf16();
  const createBreakawayFromJob = 0x01000000;
  const createNoWindow = 0x08000000;
  final ok = createProcess(
    nullptr,
    cmd,
    nullptr,
    nullptr,
    0,
    createBreakawayFromJob | createNoWindow,
    nullptr,
    nullptr,
    startup.cast<Void>(),
    info.cast<Void>(),
  );
  if (ok == 0) {
    _report('breakaway-failed-${getLastError()}');
  } else {
    final childPid = (info + 16).cast<Uint32>().value;
    _report('breakaway-started-$childPid');
  }
}

/// Plays the host: waits for a line on stdin (the desktop has put it in the
/// outer job by then), starts one unit and reports its pid.
Future<void> _hostSim() async {
  stdin.readLineSync();
  final unit = spawnWindowsUnit(
    executable: _self,
    args: ['--fixture', 'sleeper'],
    containmentId: 'host-sim-unit',
    environment: {outVariable: Platform.environment[outVariable]!},
  );
  _report('host-sim-unit-${unit.pid}');
  _stayAlive();
}

/// Reports what a PTY child sees on its stdio: `TTY:<in>:<out>:<err>;` for
/// terminal-ness, `ARGS:<base64 of the JSON argument list>;`, then
/// `SIZE:<cols>x<rows>;` every 100 ms.
Future<void> _tty(List<String> rest) async {
  final flags = [stdin.hasTerminal, stdout.hasTerminal, stderr.hasTerminal];
  stdout.write('TTY:${flags.map((f) => f ? 1 : 0).join(':')};');
  stdout.write('ARGS:${base64.encode(utf8.encode(jsonEncode(rest)))};');
  await stdout.flush();
  while (true) {
    stdout.write('SIZE:${stdout.terminalColumns}x${stdout.terminalLines};');
    await stdout.flush();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// Native inventory of every inheritable handle in this process. Windows'
/// ProcessHandleInformation (51) snapshots the full handle table, including
/// handles whose numerical value is outside a guessed probing range.
void _windowsHandles() {
  final kernel = DynamicLibrary.open('kernel32.dll');
  final query = DynamicLibrary.open('ntdll.dll')
      .lookupFunction<
        Int32 Function(IntPtr, Uint32, Pointer<Void>, Uint32, Pointer<Uint32>),
        int Function(int, int, Pointer<Void>, int, Pointer<Uint32>)
      >('NtQueryInformationProcess');
  final getInfo = kernel
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)
      >('GetHandleInformation');
  final getStd = kernel
      .lookupFunction<IntPtr Function(Uint32), int Function(int)>(
        'GetStdHandle',
      );
  final getType = kernel
      .lookupFunction<Uint32 Function(IntPtr), int Function(int)>(
        'GetFileType',
      );
  final consoleWindow = kernel
      .lookupFunction<IntPtr Function(), int Function()>('GetConsoleWindow');
  final needed = calloc<Uint32>();
  final flags = calloc<Uint32>();
  Pointer<Uint8> snapshot = nullptr;
  try {
    var size = 4096;
    while (true) {
      snapshot = calloc<Uint8>(size);
      final status = query(-1, 51, snapshot.cast<Void>(), size, needed);
      if (status == 0) break;
      calloc.free(snapshot);
      snapshot = nullptr;
      if (status != -1073741820) {
        // STATUS_INFO_LENGTH_MISMATCH
        throw StateError('NtQueryInformationProcess: $status');
      }
      size = needed.value > size ? needed.value : size * 2;
    }
    final inherited = <int>[];
    final count = snapshot.cast<UintPtr>().value;
    for (var i = 0; i < count; i++) {
      // PROCESS_HANDLE_SNAPSHOT_INFORMATION starts with two ULONG_PTRs;
      // PROCESS_HANDLE_TABLE_ENTRY_INFO occupies 40 bytes on Windows x64.
      final handle = (snapshot + 16 + i * 40).cast<IntPtr>().value;
      if (getInfo(handle, flags) != 0 && (flags.value & 1) != 0) {
        inherited.add(handle);
      }
    }
    final std = [getStd(0xfffffff6), getStd(0xfffffff5), getStd(0xfffffff4)];
    stdout.write(
      jsonEncode({
        'inherited': inherited,
        'std': std,
        'stdTypes': std.map(getType).toList(),
        'stdInheritable': std
            .map((h) => getInfo(h, flags) != 0 && (flags.value & 1) != 0)
            .toList(),
        'consoleWindow': consoleWindow(),
      }),
    );
  } finally {
    if (snapshot != nullptr) calloc.free(snapshot);
    calloc.free(needed);
    calloc.free(flags);
  }
}

/// Writes output as fast as the terminal takes it, forever.
Future<void> _flood() async {
  _report('flood');
  final line = '${'x' * 100}\n';
  while (true) {
    stdout.write(line);
    await stdout.flush();
  }
}
