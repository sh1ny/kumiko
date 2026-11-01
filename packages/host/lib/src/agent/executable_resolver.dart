import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';

import '../host_faults.dart';
import '../host_options.dart';
import '../profiles/shell_detector.dart' show splitSearchPath;

/// Runtime PATH entries, excluding empty entries (never search a checkout).
List<String> runtimePathDirectories(String os, Map<String, String> env) =>
    splitSearchPath(
      env['PATH'] ?? env['Path'] ?? '',
      os == 'windows' ? ';' : ':',
    );

/// D11 install locations in precedence order. NVM versions compare numeric
/// components, not lexical order (v22.10 must precede v22.9).
/// Detection calls this only in its worker isolate because listing can block.
List<String> wellKnownRuntimeDirs(String os, Map<String, String> env) {
  String? value(String key) {
    final v = env[key];
    return v == null || v.isEmpty ? null : v;
  }

  if (os == 'windows') {
    final appData = value('APPDATA');
    final programFiles = value('ProgramFiles');
    return [
      if (appData != null) '$appData/npm',
      if (programFiles != null) '$programFiles/nodejs',
    ];
  }
  final home = value('HOME');
  String? newest;
  List<int>? newestVersion;
  if (home != null) {
    try {
      for (final entry in Directory('$home/.nvm/versions/node').listSync()) {
        if (entry is! Directory) continue;
        final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
        final match = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)$').firstMatch(name);
        if (match == null || !Directory('${entry.path}/bin').existsSync()) {
          continue;
        }
        final version = [
          for (var i = 1; i <= 3; i++) int.parse(match.group(i)!),
        ];
        var newer = newestVersion == null;
        if (newestVersion != null) {
          for (var i = 0; i < 3; i++) {
            if (version[i] == newestVersion[i]) continue;
            newer = version[i] > newestVersion[i];
            break;
          }
        }
        if (newer) {
          newest = '$home/.nvm/versions/node/$name/bin';
          newestVersion = version;
        }
      }
    } on FileSystemException {
      // No readable NVM installation; the other locations are still searched.
    }
  }
  return [
    if (os == 'macos') '/opt/homebrew/bin',
    '/usr/local/bin',
    if (home != null) ...[
      if (os != 'macos') '$home/.local/bin',
      '$home/.npm-global/bin',
      '$home/.volta/bin',
    ],
    ?newest,
  ];
}

/// Resolves and prechecks an argv executable without shell lookup, command
/// parsing, substitution or installation. First matching file wins, including
/// a refused batch file; never skip it to start another runtime.
class ExecutableResolver {
  ExecutableResolver({
    String? os,
    this._pathDirs,
    this._wellKnownDirs,
    this._pathExt,
    Map<String, String>? environment,
  }) : os = os ?? Platform.operatingSystem,
       environment = environment ?? Platform.environment;

  final String os;
  final Map<String, String> environment;
  final List<String>? _pathDirs;
  final List<String>? _wellKnownDirs;
  final String? _pathExt;

  /// Returns an absolute path, or throws [RpcException] with
  /// executable-not-found / not-executable and `data.executable` naming the
  /// requested or first matching path. Engine exits are not precheck errors.
  String resolve(String executable) {
    if (File(executable).isAbsolute) return _check(executable);
    // Relative paths are not bare names and must not resolve against a target
    // checkout (nor be interpreted as command text).
    if (executable.isEmpty ||
        executable.contains('/') ||
        executable.contains('\\')) {
      throw _missing(executable);
    }
    final paths = _pathDirs ?? runtimePathDirectories(os, environment);
    final known = _wellKnownDirs ?? wellKnownRuntimeDirs(os, environment);
    final windows = os == 'windows';
    final extensions = windows && !executable.contains('.')
        ? (_pathExt ?? environment['PATHEXT'] ?? '.COM;.EXE;.BAT;.CMD')
              .split(';')
              .where((s) => s.isNotEmpty)
              .map((s) => s.toLowerCase())
              .toList()
        : const [''];
    for (final dirs in [paths, known]) {
      for (final dir in dirs) {
        if (!File(dir).isAbsolute) continue;
        for (final ext in extensions) {
          final candidate = '$dir/$executable$ext';
          if (FileSystemEntity.typeSync(candidate) ==
              FileSystemEntityType.file) {
            return _check(File(candidate).absolute.path);
          }
        }
      }
    }
    throw _missing(executable);
  }

  String _check(String path) {
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file) {
      throw _missing(path);
    }
    if (os == 'windows') {
      if (!path.toLowerCase().endsWith('.exe')) {
        throw RpcException(
          ErrorCode.notExecutable,
          'Cannot launch "$path" directly: Windows requires a native .exe, not a batch file or command shim. '
          'Use node.exe with the script path (for npx: node.exe .../npm/bin/npx-cli.js).',
          {'executable': path},
        );
      }
    } else if (!canExecutePath(path)) {
      throw RpcException(
        ErrorCode.notExecutable,
        'Executable "$path" is not executable by the current user.',
        {'executable': path},
      );
    }
    return path;
  }

  RpcException _missing(String path) => RpcException(
    ErrorCode.executableNotFound,
    'Executable not found: "$path".',
    {'executable': path},
  );
}

/// Launch-time filesystem checks share a bounded off-isolate budget. A timeout
/// abandons the result but retains its slot until the native probe returns.
/// Unlike detection, interactive launches never queue behind stalled probes.
class LaunchExecutableResolver {
  LaunchExecutableResolver({
    required this.faults,
    ExecutableResolver? resolver,
    this.slots = HostOptions.resolveSlots,
    this.timeout = HostOptions.defaultResolveTimeout,
  }) : _resolver = resolver ?? ExecutableResolver();

  final HostFaults faults;
  final ExecutableResolver _resolver;
  final int slots;
  final Duration timeout;
  int _held = 0;

  Future<String> resolve(String executable) {
    if (_held >= slots) {
      return Future.error(RpcException(
        ErrorCode.busy,
        'Executable resolution is busy.',
        {'executable': executable},
      ));
    }
    _held++;
    final fault = faults.takeResolveFault(executable);
    ReceivePort? hangPort;
    if (fault != null && fault.hang) {
      hangPort = ReceivePort()
        ..listen((Object? message) {
          if (message is SendPort) faults.registerHung(executable, message);
        });
    }
    final result = Completer<String>();
    final timer = Timer(timeout, () {
      result.completeError(RpcException(
        ErrorCode.busy,
        'Executable resolution did not answer within ${timeout.inMilliseconds} ms.',
        {'executable': executable},
      ));
    });
    void finished() {
      timer.cancel();
      hangPort?.close();
      _held--;
    }

    _spawn(_resolver, executable, fault?.delay.inMilliseconds ?? 0, hangPort?.sendPort).then<void>(
      (path) {
        finished();
        if (!result.isCompleted) result.complete(path);
      },
      onError: (Object error, StackTrace stack) {
        finished();
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    return result.future;
  }

  // Capture plain resolver configuration only, never the service or its ports.
  static Future<String> _spawn(
    ExecutableResolver resolver,
    String executable,
    int delayMs,
    SendPort? hang,
  ) => Isolate.run(() async {
    try {
      return resolver.resolve(executable);
    } finally {
      // Test-only faults run in the same isolate as the filesystem probe.
      if (delayMs > 0) sleep(Duration(milliseconds: delayMs));
      if (hang != null) {
        final release = ReceivePort();
        hang.send(release.sendPort);
        await release.first;
        release.close();
      }
    }
  });
}
