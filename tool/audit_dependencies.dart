/// Dependency audit (design D13).
///
/// Fails when the resolved dependency graph (dev dependencies included)
/// contains a product-telemetry, crash-report or remote-logging package, and
/// checks the D1 dependency rule and the D10 import rule.
///
/// Usage, from the repository root: `dart run tool/audit_dependencies.dart`.
/// `dart pub deps` needs `FLUTTER_ROOT` because the workspace has a Flutter
/// package. The tool derives it from `flutter` on `PATH` when it is unset.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Exact package names that must never resolve.
const denylist = <String>{
  'firebase_analytics',
  'firebase_crashlytics',
  'firebase_performance',
  'sentry',
  'sentry_flutter',
  'datadog_flutter_plugin',
  'bugsnag_flutter',
  'amplitude_flutter',
  'mixpanel_flutter',
  'posthog_flutter',
  'segment_analytics',
  'newrelic_mobile',
  'instabug_flutter',
  'appcenter',
  'aptabase_flutter',
  'countly_flutter',
  'rollbar_flutter',
  'embrace',
};

/// Substrings that mark a package as telemetry or reporting.
const denyPatterns = <String>[
  'analytics',
  'crashlytics',
  'telemetry',
  'crash_report',
  'sentry',
  'bugsnag',
  'datadog',
];

/// Result of running `dart pub deps --json`.
class PubDepsOutput {
  PubDepsOutput({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// Runs `dart pub deps --json` in [workingDirectory]. Injectable for tests.
typedef PubDepsRunner = Future<PubDepsOutput> Function(String workingDirectory);

/// Outcome of the dependency audit.
class AuditReport {
  AuditReport({
    required this.checkedPackages,
    required this.allowlisted,
    required this.failures,
  });

  /// Every resolved package the audit checked.
  final List<String> checkedPackages;

  /// Denylist matches that the allowlist waived.
  final List<String> allowlisted;
  final List<String> failures;

  bool get ok => failures.isEmpty;
}

AuditReport _failed(String message) =>
    AuditReport(checkedPackages: [], allowlisted: [], failures: [message]);

/// Audits the resolved dependencies of the workspace at [workspaceRoot].
Future<AuditReport> auditDependencies({
  required String workspaceRoot,
  required PubDepsRunner runPubDeps,
  String? allowlistPath,
}) async {
  final lockPath = p.join(workspaceRoot, 'pubspec.lock');
  try {
    loadYaml(File(lockPath).readAsStringSync());
  } on Object catch (e) {
    return _failed('cannot read lock file $lockPath: $e');
  }

  final Map<String, String> allowlist;
  try {
    allowlist = _readAllowlist(
      allowlistPath ?? p.join(workspaceRoot, 'tool', 'audit_allowlist.yaml'),
    );
  } on FormatException catch (e) {
    return _failed(e.message);
  }

  final PubDepsOutput output;
  try {
    output = await runPubDeps(workspaceRoot);
  } on Object catch (e) {
    return _failed('`pub deps` could not run: $e');
  }
  if (output.exitCode != 0) {
    return _failed(
      '`pub deps` failed with exit code ${output.exitCode}: '
      '${output.stderr.trim()}',
    );
  }

  final Map<String, Object?> graph;
  try {
    graph = _decodeGraph(output.stdout);
  } on FormatException catch (e) {
    return _failed('`pub deps --json` output unreadable: ${e.message}');
  }

  final packages = _packages(graph);
  final failures = <String>[];
  final allowlisted = <String>[];
  final parents = _shortestPathParents(graph);
  for (final name in packages.keys) {
    final matched = _denyMatch(name);
    if (matched == null) continue;
    if (allowlist.containsKey(name)) {
      allowlisted.add(name);
      continue;
    }
    failures.add(
      'denylisted package "$name" ($matched) is pulled in by shipped '
      'package "${_pathTo(name, parents).first}" via '
      '${_pathTo(name, parents).join(' -> ')}',
    );
  }
  return AuditReport(
    checkedPackages: packages.keys.toList()..sort(),
    allowlisted: allowlisted..sort(),
    failures: failures,
  );
}

String? _denyMatch(String name) {
  if (denylist.contains(name)) return 'denylist entry';
  for (final pattern in denyPatterns) {
    if (name.contains(pattern)) return 'pattern "$pattern"';
  }
  return null;
}

Map<String, String> _readAllowlist(String path) {
  final file = File(path);
  if (!file.existsSync()) return {};
  final YamlNode doc;
  try {
    doc = loadYamlNode(file.readAsStringSync());
  } on YamlException catch (e) {
    throw FormatException('cannot parse allowlist $path: ${e.message}');
  }
  if (doc is YamlScalar && doc.value == null) return {};
  if (doc is! YamlMap) {
    throw FormatException('allowlist $path must be a map of package: reason');
  }
  final result = <String, String>{};
  for (final entry in doc.entries) {
    final reason = entry.value;
    if (reason is! String || reason.trim().isEmpty) {
      throw FormatException(
        'allowlist $path: package "${entry.key}" needs a non-empty reason',
      );
    }
    result['${entry.key}'] = reason;
  }
  return result;
}

Map<String, Object?> _decodeGraph(String source) {
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException catch (e) {
    throw FormatException(e.message);
  }
  if (decoded is! Map<String, Object?> || decoded['packages'] is! List) {
    throw const FormatException('missing "packages" list');
  }
  return decoded;
}

/// Package name to its `dependencies` (dev dependencies included for
/// workspace members).
Map<String, List<String>> _packages(Map<String, Object?> graph) => {
  for (final entry in (graph['packages']! as List<Object?>))
    if (entry is Map<String, Object?>)
      entry['name']! as String: [
        for (final d in (entry['dependencies'] as List<Object?>? ?? const []))
          d as String,
      ],
};

/// Workspace members other than the workspace root: the shipped packages.
List<String> _shippedPackages(Map<String, Object?> graph) => [
  for (final entry in (graph['packages']! as List<Object?>))
    if (entry is Map<String, Object?> &&
        entry['kind'] == 'root' &&
        entry['name'] != graph['root'])
      entry['name']! as String,
];

/// Breadth-first parents from the shipped packages (then the workspace root).
Map<String, String?> _shortestPathParents(Map<String, Object?> graph) {
  final deps = _packages(graph);
  final parents = <String, String?>{};
  final queue = <String>[];
  for (final start in [..._shippedPackages(graph), graph['root'] as String?]) {
    if (start == null || parents.containsKey(start)) continue;
    parents[start] = null;
    queue.add(start);
  }
  // Seeds are processed in order, so shipped packages win over the root.
  for (var i = 0; i < queue.length; i++) {
    for (final dep in deps[queue[i]] ?? const <String>[]) {
      if (parents.containsKey(dep)) continue;
      parents[dep] = queue[i];
      queue.add(dep);
    }
  }
  return parents;
}

List<String> _pathTo(String name, Map<String, String?> parents) {
  final path = <String>[];
  for (String? n = name; n != null; n = parents[n]) {
    path.insert(0, n);
  }
  return path;
}

/// D1 dependency rule on the workspace members of [graph]: `desktop` depends
/// only on `host_protocol`, `domain` and `process_containment`; `host` does
/// not depend on `desktop`.
List<String> checkLayerRules(Map<String, Object?> graph) {
  const desktopAllowed = {'host_protocol', 'domain', 'process_containment'};
  final members = _shippedPackages(graph).toSet();
  final deps = _packages(graph);
  final violations = <String>[];
  for (final dep in deps['desktop'] ?? const <String>[]) {
    if (members.contains(dep) && !desktopAllowed.contains(dep)) {
      violations.add(
        'D1: package "desktop" must not depend on workspace package "$dep"',
      );
    }
  }
  if ((deps['host'] ?? const <String>[]).contains('desktop')) {
    violations.add('D1: package "host" must not depend on "desktop"');
  }
  return violations;
}

final _directive = RegExp(
  r'^\s*(?:import|export|part)\s[^;]*;',
  multiLine: true,
);
final _quoted = RegExp('''['"]([^'"]+)['"]''');

/// URIs named by the import, export and part directives of [source],
/// including conditional-import alternatives.
List<String> directiveUris(String source) {
  final withoutComments = source
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
      .split('\n')
      .map((l) => l.trimLeft().startsWith('//') ? '' : l)
      .join('\n');
  return [
    for (final match in _directive.allMatches(withoutComments))
      for (final uri in _quoted.allMatches(match.group(0)!)) uri.group(1)!,
  ];
}

Iterable<File> _dartFiles(String dir) {
  final d = Directory(dir);
  if (!d.existsSync()) return const [];
  return d
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'));
}

/// D1 (domain imports no `dart:io` or `dart:ffi`) and D10 (nothing reachable
/// from `packages/host/bin/kumiko_host.dart` lies under
/// `packages/host/lib/src/test_hooks/`).
List<String> checkImportRules(String workspaceRoot) {
  final violations = <String>[];
  final packagesDir = p.join(workspaceRoot, 'packages');

  // Workspace package name -> its lib directory.
  final libs = <String, String>{};
  final pubspecs = Directory(packagesDir).existsSync()
      ? Directory(packagesDir).listSync().whereType<Directory>()
      : const <Directory>[];
  for (final dir in pubspecs) {
    final pubspec = File(p.join(dir.path, 'pubspec.yaml'));
    if (!pubspec.existsSync()) continue;
    final name = (loadYaml(pubspec.readAsStringSync()) as YamlMap)['name'];
    if (name is String) libs[name] = p.join(dir.path, 'lib');
  }

  final domainDir = p.join(packagesDir, 'domain');
  for (final sub in const ['lib', 'bin']) {
    for (final file in _dartFiles(p.join(domainDir, sub))) {
      for (final uri in directiveUris(file.readAsStringSync())) {
        if (uri == 'dart:io' || uri == 'dart:ffi') {
          violations.add(
            'D1: ${p.relative(file.path, from: workspaceRoot)} imports $uri; '
            'domain must not import dart:io or dart:ffi',
          );
        }
      }
    }
  }

  final hostDir = p.join(packagesDir, 'host');
  if (File(p.join(hostDir, 'pubspec.yaml')).existsSync()) {
    final entry = p.normalize(p.join(hostDir, 'bin', 'kumiko_host.dart'));
    if (!File(entry).existsSync()) {
      violations.add('D10: release entry point $entry does not exist');
    } else {
      final hooks = p.normalize(p.join(hostDir, 'lib', 'src', 'test_hooks'));
      final parents = <String, String?>{entry: null};
      final queue = [entry];
      for (var i = 0; i < queue.length; i++) {
        final current = queue[i];
        for (final uri in directiveUris(File(current).readAsStringSync())) {
          final target = _resolve(uri, current, libs);
          if (target == null ||
              parents.containsKey(target) ||
              !File(target).existsSync()) {
            continue;
          }
          parents[target] = current;
          queue.add(target);
          if (p.isWithin(hooks, target)) {
            final chain = <String>[];
            for (String? n = target; n != null; n = parents[n]) {
              chain.insert(0, p.relative(n, from: workspaceRoot));
            }
            violations.add(
              'D10: release entry point reaches lib/src/test_hooks/: '
              '${chain.join(' -> ')}',
            );
          }
        }
      }
    }
  }
  return violations;
}

String? _resolve(String uri, String from, Map<String, String> libs) {
  if (uri.startsWith('dart:')) return null;
  if (uri.startsWith('package:')) {
    final rest = uri.substring('package:'.length);
    final slash = rest.indexOf('/');
    if (slash < 0) return null;
    final lib = libs[rest.substring(0, slash)];
    return lib == null
        ? null
        : p.normalize(p.join(lib, rest.substring(slash + 1)));
  }
  if (uri.contains(':')) return null;
  return p.normalize(p.join(p.dirname(from), uri));
}

/// Locates `flutter` on PATH and returns the Flutter SDK root, if any.
String? _flutterRootFromPath() {
  final names = Platform.isWindows
      ? ['flutter.bat', 'flutter.exe', 'flutter.cmd']
      : ['flutter'];
  final separator = Platform.isWindows ? ';' : ':';
  for (final dir in (Platform.environment['PATH'] ?? '').split(separator)) {
    if (dir.isEmpty) continue;
    for (final name in names) {
      if (File(p.join(dir, name)).existsSync()) {
        return p.dirname(
          p.dirname(File(p.join(dir, name)).resolveSymbolicLinksSync()),
        );
      }
    }
  }
  return null;
}

Future<PubDepsOutput> _runRealPubDeps(String workingDirectory) async {
  final environment = Map<String, String>.of(Platform.environment);
  if ((environment['FLUTTER_ROOT'] ?? '').isEmpty) {
    final root = _flutterRootFromPath();
    if (root != null) environment['FLUTTER_ROOT'] = root;
  }
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['pub', 'deps', '--json'],
    workingDirectory: workingDirectory,
    environment: environment,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  return PubDepsOutput(
    exitCode: result.exitCode,
    stdout: result.stdout as String,
    stderr: result.stderr as String,
  );
}

Future<void> main(List<String> args) async {
  final root = Directory.current.path;
  final report = await auditDependencies(
    workspaceRoot: root,
    runPubDeps: _runRealPubDeps,
  );
  final failures = [...report.failures];

  if (report.ok) {
    stdout.writeln('Checked ${report.checkedPackages.length} packages:');
    for (final name in report.checkedPackages) {
      stdout.writeln('  $name');
    }
    for (final name in report.allowlisted) {
      stdout.writeln('allowlisted: $name');
    }
    final graph = _decodeGraph((await _runRealPubDeps(root)).stdout);
    failures.addAll(checkLayerRules(graph));
  }
  failures.addAll(checkImportRules(root));

  if (failures.isEmpty) {
    stdout.writeln('Dependency audit passed.');
    return;
  }
  for (final failure in failures) {
    stderr.writeln('FAIL: $failure');
  }
  exitCode = 1;
}
