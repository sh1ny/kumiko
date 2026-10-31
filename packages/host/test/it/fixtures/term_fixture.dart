// A fixture shell and programs for the terminal tests, compiled once with
// `dart compile exe` (a Dart program, so it runs the same on every OS and
// needs no exec bit from git).
//
//   term_fixture shell [args...]   a tiny interactive shell: prints a report
//                                  of what it sees, then reads commands
//   term_fixture exit N            exits N at once
//   term_fixture bytes             prints a binary blob and exits
//   term_fixture sleeper           idles (a child of the shell)
//   term_fixture stubborn-child    idles and ignores SIGTERM
//   term_fixture flooder N         writes N bytes of `flood` lines to the
//                                  terminal it inherited
//
// Output is made of tokens ending in `;` with no line feeds, so the line
// discipline of a POSIX terminal leaves it alone and a test can look for a
// token whatever escape sequences ConPTY adds around it. Commands are read in
// raw mode and end with CR or LF.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:process_containment/process_containment.dart';

/// The blob printed by `bytes`: every byte value, in an order the test
/// reproduces, wrapped in `BEGIN;` and `END;`.
Uint8List blob() =>
    Uint8List.fromList([for (var i = 0; i < 256; i++) (i * 7 + 3) % 256]);

Future<void> main(List<String> args) async {
  final mode = args.isEmpty ? 'shell' : args.first;
  switch (mode) {
    case 'shell':
      await _shell(args.skip(1).toList());
    case 'exit':
      exit(int.parse(args[1]));
    case 'bytes':
      _bytes();
      exit(0);
    case 'sleeper':
      _report('sleeper');
      await _idle();
    case 'stubborn-child':
      if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen((_) {});
      _report('stubborn-child');
      await _idle();
    case 'escapee':
      _report('escapee');
      await _idle();
    case 'flooder':
      _report('flooder');
      await _flood(int.parse(args[1]));
      await stdout.flush();
      exit(0);
    case 'deaf':
      await _deaf();
    default:
      stderr.writeln('term_fixture: unknown mode $mode');
      exit(64);
  }
}

Future<void> _idle() async {
  ReceivePort(); // keeps the isolate, and so the process, alive
  await Completer<void>().future;
}

String _b64(String s) => base64.encode(utf8.encode(s));

void _out(String token) => stdout.write(token);

void _bytes() {
  stdout.write('BEGIN;');
  stdout.add(blob());
  stdout.write('END;');
}

/// Writes `role pid startTime marker sid` to `kumiko-fixture-<pid>.out` in
/// the working directory, the way the host's own fixtures do, so a test can
/// find every process of a terminal and ask whether it still runs.
void _report(String role) {
  final marker = Platform.environment[unitMarkerVariable] ?? '-';
  final sid = Platform.isWindows ? '-' : '${sessionIdOf(pid)}';
  final name = 'kumiko-fixture-$pid';
  File('$name.tmp')
    ..writeAsStringSync(
      '$role $pid ${processStartTime(pid)} $marker $sid\n',
      flush: true,
    )
    ..renameSync('$name.out');
}

/// A program that does not read its input until a file named `go` appears in
/// its working directory, then reads until a `!` and checks the bytes before
/// it against the pattern `a..z` repeated. Prints `GOT:<count>:<1 if right>;`.
Future<void> _deaf() async {
  _report('deaf');
  stdin.echoMode = false;
  stdin.lineMode = false;
  _out('READY;');
  await stdout.flush();
  while (!File('go').existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  var received = 0;
  var ok = true;
  var done = false;
  await for (final chunk in stdin) {
    for (final byte in chunk) {
      if (byte == 0x21) {
        done = true;
        break;
      }
      if (byte != 0x61 + received % 26) ok = false;
      received++;
    }
    if (done) break;
  }
  _out('GOT:$received:${ok ? 1 : 0};');
  await stdout.flush();
  exit(0);
}

List<String> _shellArgs = const [];

Future<void> _shell(List<String> rest) async {
  _shellArgs = rest;
  _report('shell');
  final flags = [stdin.hasTerminal, stdout.hasTerminal, stderr.hasTerminal];
  _out('TTY:${flags.map((f) => f ? 1 : 0).join(':')};');
  _out('PID:$pid;');
  _out('ARGS:${_b64(jsonEncode(rest))};');
  _out('CWD:${_b64(Directory.current.path)};');
  if (!Platform.isWindows) {
    ProcessSignal.sigwinch.watch().listen((_) => _out(_size()));
  }
  _out('READY;');
  await stdout.flush();

  stdin.echoMode = false;
  stdin.lineMode = false;
  final line = StringBuffer();
  await for (final chunk in stdin) {
    for (final byte in chunk) {
      if (byte == 0x0D || byte == 0x0A) {
        final text = line.toString();
        line.clear();
        if (text.isNotEmpty) await _command(text);
      } else {
        line.writeCharCode(byte);
      }
    }
  }
}

String _size() => 'SIZE:${stdout.terminalColumns}x${stdout.terminalLines};';

Future<void> _command(String text) async {
  final parts = text.split(' ');
  final arg = parts.length > 1 ? parts.sublist(1).join(' ') : '';
  switch (parts.first) {
    case 'exit':
      exit(int.parse(arg));
    case 'bye':
      // Print a last line, then exit at once.
      _out('LASTLINE;');
      await stdout.flush();
      exit(int.parse(arg));
    case 'echo':
      _out('ECHO:$arg;');
    case 'size':
      _out(_size());
    case 'env':
      _out('ENV:$arg=${_b64(Platform.environment[arg] ?? '-')};');
    case 'bytes':
      _bytes();
    case 'child':
      final child = await Process.start(Platform.resolvedExecutable, [
        'sleeper',
      ], mode: ProcessStartMode.detachedWithStdio);
      _out('CHILD:${child.pid};');
    case 'stubborn':
      // Ignores SIGTERM, with a child that does too: only SIGKILL ends them.
      if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen((_) {});
      final child = await Process.start(Platform.resolvedExecutable, [
        'stubborn-child',
      ], mode: ProcessStartMode.detachedWithStdio);
      _out('STUBBORN:${child.pid};');
    case 'escapee':
      // POSIX: a descendant in a session of its own that keeps the unit's
      // marker, which only the marker scan can reach. Elsewhere a plain child.
      final host = Platform.environment['TERM_FIXTURE_HOST'];
      final marker = Platform.environment[unitMarkerVariable];
      final Process child;
      if (Platform.isWindows || host == null || marker == null) {
        child = await Process.start(Platform.resolvedExecutable, [
          'escapee',
        ], mode: ProcessStartMode.detachedWithStdio);
      } else {
        child = await Process.start(host, [
          '--unit-exec',
          marker,
          '--',
          Platform.resolvedExecutable,
          'escapee',
        ], mode: ProcessStartMode.detachedWithStdio);
      }
      _out('ESCAPEE:${child.pid};');
    case 'args':
      _out('ARGV:${_b64(jsonEncode(_shellArgs))};');
    case 'floodexit':
      // `floodexit N CODE`: like `flood N`, then exits CODE at once, so the
      // shell is gone while the terminal may still hold unread output.
      final both = arg.split(' ');
      await _flood(int.parse(both[0]), done: false);
      await stdout.flush();
      exit(int.parse(both[1]));
    case 'floodchild':
      // `floodchild N`: starts a `flooder N` on this terminal and exits 1 s
      // after it has reported, by when the flooder has filled whatever the
      // terminal takes without a reader. The shell is then gone while its
      // terminal holds unread output (the host ends the flooder with the
      // shell's unit).
      final child = await Process.start(Platform.resolvedExecutable, [
        'flooder',
        arg,
      ], mode: ProcessStartMode.inheritStdio);
      final report = File('kumiko-fixture-${child.pid}.out');
      while (!report.existsSync()) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      exit(0);
    case 'flood':
      // `flood N`: N bytes of numbered lines, as fast as the terminal takes
      // them. Every line is `L<8 digits>` plus padding and CR LF, so a reader
      // can check that none is missing whatever the terminal adds around it.
      await _flood(int.parse(arg));
    default:
      _out('fixture: ${parts.first}: command not found;');
  }
  await stdout.flush();
}

Future<void> _flood(int bytes, {bool done = true}) async {
  const lineLength = 64;
  final pad = 'x' * (lineLength - 11);
  var written = 0;
  var seq = 0;
  final buffer = StringBuffer();
  while (written < bytes) {
    buffer.clear();
    for (var i = 0; i < 256 && written < bytes; i++) {
      buffer.write('L${seq.toString().padLeft(8, '0')}$pad\r\n');
      seq++;
      written += lineLength;
    }
    stdout.write(buffer.toString());
    await stdout.flush();
  }
  if (done) stdout.write('FLOODED:${min(seq, 1 << 30)};');
}
