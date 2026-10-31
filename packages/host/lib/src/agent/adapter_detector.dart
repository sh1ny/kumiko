import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:host_protocol/host_protocol.dart';

import 'executable_resolver.dart';

const Duration adapterDetectionCap = Duration(seconds: 2);
const String builtinClaudeRuntimeId = 'builtin:claude-code';
const String adapterInstallReason =
    'Claude Code adapter not found. Install @agentclientprotocol/claude-agent-acp with npm and Node ≥ 22, or add a runtime profile.';

/// Plain data sent to the detector isolate. Null search overrides use the
/// inherited environment; an empty list deliberately disables that search.
class AdapterDetectionConfig {
  AdapterDetectionConfig({
    String? os,
    this.pathDirs,
    this.wellKnownDirs,
    String? inheritedPath,
    Map<String, String>? environment,
  }) : os = os ?? Platform.operatingSystem,
       environment = environment ?? Platform.environment,
       inheritedPath =
           inheritedPath ??
           (environment ?? Platform.environment)['PATH'] ??
           (environment ?? Platform.environment)['Path'] ??
           '';

  final String os;
  final List<String>? pathDirs;
  final List<String>? wellKnownDirs;
  final String inheritedPath;
  final Map<String, String> environment;
}

class AdapterDetectionResult {
  const AdapterDetectionResult({this.profile, this.reason});
  final RuntimeProfile? profile;
  final String? reason;
}

/// Synchronous filesystem probe, executed only by [AdapterDetector]'s worker.
/// The probe seam allows a blocked-filesystem qualification without executing
/// an adapter (detection never launches Node or runs an install command).
typedef AdapterProbe = AdapterDetectionResult Function(AdapterDetectionConfig);

class AdapterDetector {
  const AdapterDetector(this.config, {this.probe = detectAdapter});
  final AdapterDetectionConfig config;
  final AdapterProbe probe;

  /// A true overall two-second deadline, including isolate startup and all
  /// filesystem lookups. The worker is killed on completion, error or timeout;
  /// a blocking filesystem call cannot extend the caller's deadline.
  Future<AdapterDetectionResult> detect() {
    final result = Completer<AdapterDetectionResult>();
    final port = ReceivePort();
    Isolate? worker;
    late final Timer timer;
    void finish(AdapterDetectionResult value) {
      if (result.isCompleted) return;
      timer.cancel();
      worker?.kill(priority: Isolate.immediate);
      port.close();
      result.complete(value);
    }

    timer = Timer(
      adapterDetectionCap,
      () => finish(
        const AdapterDetectionResult(
          reason:
              'Adapter detection exceeded its 2 s limit. $adapterInstallReason',
        ),
      ),
    );
    port.listen((message) {
      if (message is AdapterDetectionResult) {
        finish(message);
      } else {
        finish(
          const AdapterDetectionResult(
            reason: 'Adapter detection failed. $adapterInstallReason',
          ),
        );
      }
    });
    Isolate.spawn(
      _detectWorker,
      (port.sendPort, config, probe),
      onError: port.sendPort,
      onExit: port.sendPort,
      errorsAreFatal: true,
    ).then(
      (isolate) {
        worker = isolate;
        if (result.isCompleted) isolate.kill(priority: Isolate.immediate);
      },
      onError: (Object error, StackTrace stack) {
        finish(
          const AdapterDetectionResult(
            reason: 'Adapter detection failed. $adapterInstallReason',
          ),
        );
      },
    );
    return result.future;
  }
}

void _detectWorker((SendPort, AdapterDetectionConfig, AdapterProbe) input) {
  input.$1.send(input.$3(input.$2));
}

AdapterDetectionResult detectAdapter(AdapterDetectionConfig config) {
  final paths =
      config.pathDirs ?? runtimePathDirectories(config.os, config.environment);
  final known =
      config.wellKnownDirs ??
      wellKnownRuntimeDirs(config.os, config.environment);
  final windows = config.os == 'windows';
  final shimName = windows ? 'claude-agent-acp.cmd' : 'claude-agent-acp';
  String? shim;
  for (final dirs in [paths, known]) {
    for (final dir in dirs) {
      if (!File(dir).isAbsolute) continue;
      final candidate = '$dir/$shimName';
      if (FileSystemEntity.typeSync(candidate) == FileSystemEntityType.file) {
        shim = File(candidate).absolute.path;
        break;
      }
    }
    if (shim != null) break;
  }
  if (shim == null) {
    return const AdapterDetectionResult(reason: adapterInstallReason);
  }
  try {
    final shimDir = File(shim).parent.path;
    final String script;
    if (windows) {
      script = File(
        '$shimDir/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js',
      ).absolute.path;
    } else {
      final target = File(shim).resolveSymbolicLinksSync();
      const package = '/node_modules/@agentclientprotocol/claude-agent-acp/';
      final index = target.lastIndexOf(package);
      script = index >= 0
          ? '${target.substring(0, index + package.length)}dist/index.js'
          : File(
              '$shimDir/../lib/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js',
            ).absolute.path;
    }
    if (!File(script).existsSync()) {
      return AdapterDetectionResult(
        reason: 'Adapter script not found: "$script". $adapterInstallReason',
      );
    }
    final resolver = ExecutableResolver(
      os: config.os,
      pathDirs: [shimDir, ...paths],
      wellKnownDirs: known,
      environment: config.environment,
    );
    final node = resolver.resolve(windows ? 'node.exe' : 'node');
    final nodeDir = File(node).parent.path;
    final separator = windows ? ';' : ':';
    return AdapterDetectionResult(
      profile: RuntimeProfile(
        id: builtinClaudeRuntimeId,
        name: 'Claude Code',
        runtimeKind: 'claude-code',
        executable: node,
        args: [File(script).absolute.path],
        env: {
          'PATH':
              '$nodeDir${config.inheritedPath.isEmpty ? '' : '$separator${config.inheritedPath}'}',
        },
      ),
    );
  } on RpcException catch (error) {
    return AdapterDetectionResult(
      reason: '${error.message} $adapterInstallReason',
    );
  } on FileSystemException catch (error) {
    return AdapterDetectionResult(
      reason: 'Adapter files unavailable: ${error.path}. $adapterInstallReason',
    );
  }
}
