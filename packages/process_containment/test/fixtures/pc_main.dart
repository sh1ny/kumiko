// Test executable that stands in for the host binary: it has the
// `--unit-exec` mode and the fixture programs units run (design D2, D10).
// Compiled by the tests with `dart compile exe`.
import 'dart:async';
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
