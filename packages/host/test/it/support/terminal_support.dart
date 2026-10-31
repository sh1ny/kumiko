import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'harness.dart';

/// Terminal notifications of one host session, in arrival order.
class TerminalEvents {
  final List<TerminalExited> exits = [];
  final List<TerminalCloseFailed> closeFailures = [];

  /// Output bytes the terminal's consumer had received when its `exited`
  /// arrived (the pipe is ordered, so everything sent before it is in).
  final Map<String, int> outputAtExit = {};
  final Map<String, OpenTerminal> terminals = {};
  StreamSubscription<HostNotification>? _subscription;

  void _listen(HostSession session) {
    _subscription = session.notifications.listen((n) {
      switch (n.method) {
        case Method.terminalExited:
          final exited = TerminalExited.fromJson(n.params);
          exits.add(exited);
          outputAtExit[exited.terminalId] =
              terminals[exited.terminalId]?.receivedBytes ?? 0;
        case Method.terminalCloseFailed:
          closeFailures.add(TerminalCloseFailed.fromJson(n.params));
      }
    });
  }

  Future<void> cancel() async => _subscription?.cancel();
}

final Expando<TerminalEvents> _events = Expando('terminal events');

final RegExp _escapes = RegExp(
  r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)|\x1B\[[0-?]*[ -/]*[@-~]|'
  r'\x1B[()][A-Za-z0-9]|\x1B[=>78MNOPXZc]',
);

/// Decodes terminal output for assertions: escape sequences removed.
String plainText(List<int> bytes) =>
    utf8.decode(bytes, allowMalformed: true).replaceAll(_escapes, '');

/// A terminal the stand-in desktop opened and attached: its two channels, the
/// bytes received so far and the means to send input.
class OpenTerminal {
  OpenTerminal._(this.desktop, this.result, this.output, this.input);

  final Desktop desktop;
  final TerminalOpenResult result;
  final ChannelWriter input;
  final BytesBuilder output;
  late StreamSubscription<Uint8List> subscription;
  int receivedBytes = 0;

  String get id => result.terminalId;
  int get outputChannel => result.outputChannel;
  int get inputChannel => result.inputChannel;

  Uint8List get bytes => output.toBytes();
  String get text => plainText(output.toBytes());

  void pause() => subscription.pause();
  void resume() => subscription.resume();

  /// Sends [text] as input (UTF-8), then a carriage return when [enter].
  Future<void> send(String text, {bool enter = true}) =>
      input.write(utf8.encode('$text${enter ? '\r' : ''}'));

  /// Waits until the plain text contains [needle].
  Future<String> waitForText(
    String needle, {
    Duration within = const Duration(seconds: 30),
  }) async {
    await eventually(
      () => text.contains(needle),
      within: within,
      reason: 'output never contained "$needle"; got ${_tail(text)}',
    );
    return text;
  }

  static String _tail(String s) =>
      jsonEncode(s.length > 600 ? s.substring(s.length - 600) : s);

  TerminalEvents get events => _events[desktop.session]!;

  TerminalExited? get exited {
    for (final e in events.exits) {
      if (e.terminalId == id) return e;
    }
    return null;
  }

  Future<TerminalExited> waitExited({
    Duration within = const Duration(seconds: 40),
  }) async {
    await eventually(
      () => exited != null,
      within: within,
      reason: 'no terminal/exited for $id; output ${_tail(text)}',
    );
    return exited!;
  }

  TerminalCloseFailed? get closeFailed {
    for (final e in events.closeFailures) {
      if (e.terminalId == id) return e;
    }
    return null;
  }

  Future<void> release() => desktop.releaseTerminal(id);
  Future<void> close() => desktop.closeTerminal(id);
}

/// Terminal calls of the stand-in desktop.
extension TerminalDesktop on Desktop {
  TerminalEvents get terminalEvents {
    return _events[session] ??= TerminalEvents().._listen(session);
  }

  Future<TerminalOpenResult> openTerminalRaw(
    String profileId, {
    String? workspaceId,
    int cols = 80,
    int rows = 24,
  }) async {
    terminalEvents; // listen before anything can arrive
    final result = await connection.request(
      Method.terminalOpen,
      TerminalOpenParams(
        profileId: profileId,
        workspaceId: workspaceId,
        cols: cols,
        rows: rows,
      ).toJson(),
    );
    return TerminalOpenResult.fromJson(result! as Json);
  }

  /// Opens a terminal and attaches it the way a desktop does (design D4):
  /// register both channels, send attach, then grant the output window.
  /// [consume] false leaves the output subscription paused (a stalled
  /// consumer); [grantOutput] false never grants the output window.
  /// [onData] receives the output instead of it being kept.
  Future<OpenTerminal> openTerminal(
    String profileId, {
    String? workspaceId,
    int cols = 80,
    int rows = 24,
    bool consume = true,
    bool grantOutput = true,
    void Function(Uint8List data)? onData,
  }) async {
    final result = await openTerminalRaw(
      profileId,
      workspaceId: workspaceId,
      cols: cols,
      rows: rows,
    );
    final output = BytesBuilder(copy: false);
    final stream = connection.attachInbound(
      result.outputChannel,
      grantInitial: false,
    );
    final input = connection.attachOutbound(result.inputChannel);
    final terminal = OpenTerminal._(this, result, output, input);
    terminalEvents.terminals[result.terminalId] = terminal;
    terminal.subscription = stream.listen((data) {
      terminal.receivedBytes += data.length;
      if (onData != null) {
        onData(data);
      } else {
        output.add(data);
      }
    });
    if (!consume) terminal.subscription.pause();
    await connection.request(
      Method.terminalAttach,
      TerminalAttachParams(result.terminalId).toJson(),
    );
    if (grantOutput) connection.grantInitial(result.outputChannel);
    return terminal;
  }

  Future<void> resizeTerminal(String id, int cols, int rows) async {
    await connection.request(
      Method.terminalResize,
      TerminalResizeParams(terminalId: id, cols: cols, rows: rows).toJson(),
    );
  }

  Future<void> closeTerminal(String id) async {
    await connection.request(
      Method.terminalClose,
      TerminalCloseParams(id).toJson(),
    );
  }

  Future<void> releaseTerminal(String id) async {
    await connection.request(
      Method.terminalRelease,
      TerminalReleaseParams(id).toJson(),
    );
  }

  /// A user profile that runs the compiled fixture with [fixtureArgs].
  Future<ShellProfile> saveFixtureProfile({
    String id = 'fixture',
    List<String> fixtureArgs = const ['shell'],
    String? cwd,
    Map<String, String> env = const {},
    String? executable,
  }) => saveProfile(
    ShellProfile(
      id: id,
      name: 'Fixture $id',
      executable: executable ?? terminalFixtureExecutable(),
      args: fixtureArgs,
      cwd: cwd,
      env: env,
    ),
  );
}

/// The error an expected failure threw.
Future<RpcException> rpcFailure(Future<Object?> call) async {
  try {
    await call;
  } on RpcException catch (e) {
    return e;
  }
  fail('expected an RpcException');
}

/// A token of the fixture's output, `NAME:value;`.
String? tokenOf(String text, String name) {
  final m = RegExp('$name:([^;]*);').firstMatch(text);
  return m?.group(1);
}

/// The base64 token [name] decoded.
String? decodedToken(String text, String name) {
  final value = tokenOf(text, name);
  return value == null ? null : utf8.decode(base64.decode(value));
}

/// Host resident memory in KiB, from the OS (the host is another process).
int hostRssKiB(int pid) {
  if (Platform.isWindows) {
    final r = Process.runSync('tasklist', [
      '/FI',
      'PID eq $pid',
      '/FO',
      'CSV',
      '/NH',
    ]);
    // "name","pid","session","#","12,345 K" - keep the digits of the last.
    final last = (r.stdout as String).trim().split('","').last;
    return int.parse(last.replaceAll(RegExp(r'[^0-9]'), ''));
  }
  final r = Process.runSync('ps', ['-o', 'rss=', '-p', '$pid']);
  return int.parse((r.stdout as String).trim());
}

/// The pseudo-terminals process [hostPid] holds: its console host children
/// (`conhost.exe` / `OpenConsole.exe`, Windows) or its open PTY master
/// descriptors (`/dev/ptmx`, through `/proc` on Linux and `lsof` on macOS).
Future<int> ptysHeldBy(int hostPid) async {
  if (Platform.isWindows) {
    final r = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      'Get-CimInstance Win32_Process -Filter "ParentProcessId=$hostPid" | '
          r'Where-Object { $_.Name -in "conhost.exe","OpenConsole.exe" } | '
          r'ForEach-Object { $_.ProcessId }',
    ]);
    return RegExp(r'\d+').allMatches(r.stdout as String).length;
  }
  if (Platform.isLinux) {
    var n = 0;
    for (final fd in Directory('/proc/$hostPid/fd').listSync()) {
      try {
        if (Link(fd.path).targetSync().endsWith('ptmx')) n++;
      } on FileSystemException {
        // closed while listing
      }
    }
    return n;
  }
  final r = await Process.run('lsof', ['-p', '$hostPid', '-Fn']);
  return [
    for (final l in LineSplitter.split(r.stdout as String))
      if (l.startsWith('n') && l.contains('ptmx')) l,
  ].length;
}
