import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:path/path.dart' as p;

import 'dart:isolate';

import 'package:host_protocol/host_protocol.dart';

import 'executable_resolver.dart';

const Duration adapterDetectionCap = Duration(seconds: 2);
const String builtinCodexRuntimeId = 'builtin:codex';
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
    Map<String, String>? environment,
  }) : os = os ?? Platform.operatingSystem,
       environment = environment ?? Platform.environment;

  final String os;
  final List<String>? pathDirs;
  final List<String>? wellKnownDirs;
  final Map<String, String> environment;
}

class AdapterDetectionResult {
  const AdapterDetectionResult({this.profile, this.reason, this.codex});
  final RuntimeProfile? codex;
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
  final claude = input.$3(input.$2);
  input.$1.send(
    AdapterDetectionResult(
      profile: claude.profile,
      reason: claude.reason,
      codex: detectCodex(input.$2),
    ),
  );
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
    return AdapterDetectionResult(
      profile: RuntimeProfile(
        id: builtinClaudeRuntimeId,
        name: 'Claude Code',
        runtimeKind: 'claude-code',
        executable: node,
        args: [File(script).absolute.path],
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

/// File-only native lookup. Overrides replace all automatic roots, including npm.
RuntimeProfile? detectCodex(AdapterDetectionConfig config) {
  final windows = config.os == 'windows';
  final paths =
      config.pathDirs ?? runtimePathDirectories(config.os, config.environment);
  final known =
      config.wellKnownDirs ??
      wellKnownRuntimeDirs(config.os, config.environment);
  final resolver = ExecutableResolver(
    os: config.os,
    pathDirs: paths,
    wellKnownDirs: known,
    environment: config.environment,
  );
  RuntimeProfile? profile(String file, {Map<String, String> env = const {}}) {
    try {
      return RuntimeProfile(
        id: builtinCodexRuntimeId,
        name: 'Codex',
        runtimeKind: 'codex',
        executable: resolver.resolve(file),
        args: const ['app-server'],
        env: env,
      );
    } on RpcException {
      return null;
    }
  }

  for (final dir in [...paths, ...known]) {
    if (!p.isAbsolute(dir)) continue;
    final direct = profile(p.join(dir, windows ? 'codex.exe' : 'codex'));
    if (direct != null) return direct;
  }
  // Resolve only package roots adjacent to known global npm shim/bin roots.
  for (final dir in [...paths, ...known]) {
    if (!p.isAbsolute(dir)) continue;
    for (final root in [
      p.join(dir, 'node_modules'),
      if (!windows) p.normalize(p.join(dir, '..', 'lib', 'node_modules')),
    ]) {
      final package = p.join(root, '@openai', 'codex');
      try {
        final meta = jsonDecode(
          File(p.join(package, 'package.json')).readAsStringSync(),
        );
        if (meta is! Map || meta['name'] != '@openai/codex') continue;
        final deps = meta['optionalDependencies'];
        if (deps is! Map) continue;
        final os = windows
            ? 'win32'
            : config.os == 'macos'
            ? 'darwin'
            : 'linux';
        // Only current installed platform packages named by package metadata.
        for (final key in deps.keys.whereType<String>()) {
          final dependency = File(p.join(root, key, 'package.json'));
          if (!key.startsWith('@openai/codex-') || !dependency.existsSync()) {
            continue;
          }
          final declaration = deps[key];
          if (declaration is! String) continue;
          var expectedName = key;
          String? expectedPackageVersion;
          if (declaration.startsWith('npm:')) {
            final separator = declaration.lastIndexOf('@');
            if (separator <= 4) continue;
            expectedName = declaration.substring(4, separator);
            expectedPackageVersion = declaration.substring(separator + 1);
            // npm installs the alias under `key`, while package metadata keeps
            // the declared underlying package identity. Packaging versions are
            // provenance only; --version still supplies native runtime identity.
            if (expectedName != '@openai/codex' ||
                expectedPackageVersion.isEmpty) {
              continue;
            }
          }
          final platform = jsonDecode(dependency.readAsStringSync());
          if (platform is! Map ||
              platform['name'] != expectedName ||
              (expectedPackageVersion != null &&
                  platform['version'] != expectedPackageVersion) ||
              platform['os'] is! List ||
              !(platform['os'] as List).contains(os)) {
            continue;
          }
          final cpu = platform['cpu'];
          final arch = Platform.version.contains('arm64') ? 'arm64' : 'x64';
          if (cpu is! List || !cpu.contains(arch)) continue;
          final target = windows
              ? (arch == 'arm64'
                    ? 'aarch64-pc-windows-msvc'
                    : 'x86_64-pc-windows-msvc')
              : config.os == 'macos'
              ? (arch == 'arm64'
                    ? 'aarch64-apple-darwin'
                    : 'x86_64-apple-darwin')
              : (arch == 'arm64'
                    ? 'aarch64-unknown-linux-musl'
                    : 'x86_64-unknown-linux-musl');
          final found = profile(
            p.join(
              root,
              key,
              'vendor',
              target,
              'codex',
              windows ? 'codex.exe' : 'codex',
            ),
            env: {
              'CODEX_MANAGED_PACKAGE_ROOT': Directory(package)
                  .resolveSymbolicLinksSync(),
              'CODEX_MANAGED_BY_NPM': '1',
              'CODEX_MANAGED_BY_BUN': '',
              'CODEX_MANAGED_BY_PNPM': '',
              'CODEX_MANAGED_BY_VITE_PLUS': '',
            },
          );
          if (found != null) return found;
        }
      } on FileSystemException {
        continue;
      } on FormatException {
        continue;
      }
    }
  }
  return null;
}

/// Host-private launch environment; detected profiles retain only compact
/// validated provenance, never the inherited PATH in stored/profile DTOs.
Map<String, String> nativeCodexLaunchEnvironment(
  RuntimeProfile profile,
  String executable, {
  Map<String, String>? inherited,
}) {
  final env = {...(inherited ?? Platform.environment), ...profile.env};
  if (profile.env['CODEX_MANAGED_PACKAGE_ROOT'] != null &&
      profile.env['CODEX_MANAGED_BY_NPM'] == '1') {
    for (final key in [
      'CODEX_MANAGED_BY_BUN',
      'CODEX_MANAGED_BY_PNPM',
      'CODEX_MANAGED_BY_VITE_PLUS',
    ]) {
      env.remove(key);
    }
    final resources = p.join(p.dirname(p.dirname(executable)), 'path');
    final explicitPath = profile.env.keys.any(
      (key) => Platform.isWindows ? key.toUpperCase() == 'PATH' : key == 'PATH',
    );
    if (!explicitPath && Directory(resources).existsSync()) {
      final previous = env['PATH'] ?? env['Path'] ?? '';
      env.remove('Path');
      env['PATH'] = '$resources${Platform.isWindows ? ';' : ':'}$previous';
    }
  }
  return env;
}
