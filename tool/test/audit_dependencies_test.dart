import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../audit_dependencies.dart';

String _fixture(String name) =>
    File(p.join('tool', 'test', 'fixtures', name)).readAsStringSync();

PubDepsRunner _runnerReturning(String stdout) =>
    (workingDirectory) async =>
        PubDepsOutput(exitCode: 0, stdout: stdout, stderr: '');

/// A workspace directory holding a readable lock file.
Directory _workspaceWithLock() {
  final dir = Directory.systemTemp.createTempSync('audit_ws_');
  File(p.join(dir.path, 'pubspec.lock')).writeAsStringSync('packages: {}\n');
  return dir;
}

void _write(Directory root, String relative, String content) {
  final file = File(p.join(root.path, relative));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

String _graphJson(Map<String, List<String>> members) => jsonEncode({
  'root': 'kumiko_workspace',
  'packages': [
    {'name': 'kumiko_workspace', 'kind': 'root', 'dependencies': <String>[]},
    for (final e in members.entries)
      {'name': e.key, 'kind': 'root', 'dependencies': e.value},
  ],
});

Map<String, Object?> _graph(Map<String, List<String>> members) =>
    jsonDecode(_graphJson(members)) as Map<String, Object?>;

void main() {
  late Directory ws;
  setUp(() => ws = _workspaceWithLock());
  tearDown(() => ws.deleteSync(recursive: true));

  group('dependency audit', () {
    test('clean graph passes and lists packages', () async {
      final report = await auditDependencies(
        workspaceRoot: ws.path,
        runPubDeps: _runnerReturning(_fixture('pub_deps_clean.json')),
      );
      expect(report.failures, isEmpty);
      expect(report.ok, isTrue);
      expect(
        report.checkedPackages,
        containsAll(['desktop', 'host', 'domain', 'sqlite3', 'collection']),
      );
      expect(report.checkedPackages, hasLength(9));
    });

    test('denylisted transitive package fails with path', () async {
      final report = await auditDependencies(
        workspaceRoot: ws.path,
        runPubDeps: _runnerReturning(_fixture('pub_deps_denylisted.json')),
      );
      expect(report.ok, isFalse);
      final message = report.failures.single;
      expect(message, contains('sentry'));
      expect(message, contains('host -> sqlite3 -> remote_logger -> sentry'));
    });

    test('substring pattern matches and allowlist overrides it', () async {
      final graph = _graphJson({
        'desktop': ['my_analytics_kit'],
        'my_analytics_kit': [],
      });
      final failing = await auditDependencies(
        workspaceRoot: ws.path,
        runPubDeps: _runnerReturning(graph),
      );
      expect(failing.failures.single, contains('my_analytics_kit'));
      expect(failing.failures.single, contains('analytics'));

      _write(
        ws,
        'tool/audit_allowlist.yaml',
        'my_analytics_kit: local-only metrics, reviewed 2026-10-29\n',
      );
      final allowed = await auditDependencies(
        workspaceRoot: ws.path,
        runPubDeps: _runnerReturning(graph),
      );
      expect(allowed.ok, isTrue);
      expect(allowed.allowlisted, ['my_analytics_kit']);
    });

    test('allowlist entry without a reason fails', () async {
      _write(ws, 'tool/audit_allowlist.yaml', 'my_analytics_kit: ""\n');
      final report = await auditDependencies(
        workspaceRoot: ws.path,
        runPubDeps: _runnerReturning(_fixture('pub_deps_clean.json')),
      );
      expect(report.ok, isFalse);
      expect(report.failures.single, contains('my_analytics_kit'));
      expect(report.failures.single, contains('reason'));
    });

    test('missing lock or failing pub deps fails audit', () async {
      var ran = false;
      File(p.join(ws.path, 'pubspec.lock')).deleteSync();
      final missing = await auditDependencies(
        workspaceRoot: ws.path,
        runPubDeps: (_) async {
          ran = true;
          return PubDepsOutput(exitCode: 0, stdout: '{}', stderr: '');
        },
      );
      expect(missing.ok, isFalse);
      expect(missing.failures.single, contains('pubspec.lock'));
      expect(ran, isFalse, reason: 'a missing lock must not be skipped over');

      // An unreadable lock (a directory in its place) also fails.
      Directory(p.join(ws.path, 'pubspec.lock')).createSync();
      final unreadable = await auditDependencies(
        workspaceRoot: ws.path,
        runPubDeps: _runnerReturning(_fixture('pub_deps_clean.json')),
      );
      expect(unreadable.ok, isFalse);
      expect(unreadable.failures.single, contains('pubspec.lock'));
      Directory(p.join(ws.path, 'pubspec.lock')).deleteSync();
      File(p.join(ws.path, 'pubspec.lock')).writeAsStringSync('packages: {}');

      final failing = await auditDependencies(
        workspaceRoot: ws.path,
        runPubDeps: (_) async => PubDepsOutput(
          exitCode: 65,
          stdout: '',
          stderr: 'resolution failed',
        ),
      );
      expect(failing.ok, isFalse);
      expect(failing.failures.single, contains('pub deps'));
      expect(failing.failures.single, contains('resolution failed'));

      final garbage = await auditDependencies(
        workspaceRoot: ws.path,
        runPubDeps: _runnerReturning('not json'),
      );
      expect(garbage.ok, isFalse);
    });
  });

  group('D1 package dependency rule', () {
    test('compliant graph has no violations', () {
      final graph = jsonDecode(_fixture('pub_deps_clean.json'));
      expect(checkLayerRules(graph as Map<String, Object?>), isEmpty);
    });

    test('desktop must not depend on host', () {
      final violations = checkLayerRules(
        _graph({
          'desktop': ['host', 'domain'],
          'host': ['domain'],
          'domain': [],
        }),
      );
      expect(violations.single, contains('desktop'));
      expect(violations.single, contains('host'));
    });

    test('host must not depend on desktop', () {
      final violations = checkLayerRules(
        _graph({
          'desktop': ['domain'],
          'host': ['desktop'],
          'domain': [],
        }),
      );
      expect(violations.single, contains('host'));
    });
  });

  group('D1 and D10 import rules', () {
    test('domain importing dart:io or dart:ffi is reported', () {
      _write(ws, 'packages/domain/pubspec.yaml', 'name: domain\n');
      _write(ws, 'packages/domain/lib/ok.dart', "import 'dart:async';\n");
      _write(ws, 'packages/domain/lib/src/bad_io.dart', "import 'dart:io';\n");
      _write(
        ws,
        'packages/domain/lib/src/bad_ffi.dart',
        '// header\nimport "dart:ffi" show Pointer;\n',
      );
      _write(
        ws,
        'packages/domain/lib/src/bad_cond.dart',
        "import 'stub.dart' if (dart.library.io) 'dart:io';\n",
      );
      final violations = checkImportRules(ws.path);
      expect(violations, hasLength(3));
      expect(violations.join('\n'), contains('bad_io.dart'));
      expect(violations.join('\n'), contains('bad_ffi.dart'));
      expect(violations.join('\n'), contains('bad_cond.dart'));
    });

    test('a commented-out dart:io import is not a violation', () {
      _write(ws, 'packages/domain/pubspec.yaml', 'name: domain\n');
      _write(ws, 'packages/domain/lib/a.dart', "// import 'dart:io';\n");
      expect(checkImportRules(ws.path), isEmpty);
    });

    void hostTree({required String binImport}) {
      _write(ws, 'packages/host/pubspec.yaml', 'name: host\n');
      _write(
        ws,
        'packages/host/bin/kumiko_host.dart',
        "import '$binImport';\nvoid main() {}\n",
      );
      _write(
        ws,
        'packages/host/lib/src/test_hooks/hooks.dart',
        'void register() {}\n',
      );
      _write(ws, 'packages/host/lib/host.dart', "export 'src/main.dart';\n");
      _write(ws, 'packages/host/lib/src/main.dart', 'void run() {}\n');
    }

    test('release entry point not reaching test_hooks passes', () {
      hostTree(binImport: 'package:host/host.dart');
      expect(checkImportRules(ws.path), isEmpty);
    });

    test('release entry point directly importing test_hooks fails', () {
      hostTree(binImport: '../lib/src/test_hooks/hooks.dart');
      expect(checkImportRules(ws.path).single, contains('test_hooks'));
    });

    test('transitive import of test_hooks is reported with its chain', () {
      hostTree(binImport: 'package:host/host.dart');
      _write(
        ws,
        'packages/host/lib/src/main.dart',
        "import 'test_hooks/hooks.dart';\n",
      );
      final violations = checkImportRules(ws.path);
      expect(violations.single, contains('kumiko_host.dart'));
      expect(violations.single, contains('main.dart'));
      expect(violations.single, contains('hooks.dart'));
    });

    test('test_hooks reached through another workspace package fails', () {
      hostTree(binImport: 'package:other/other.dart');
      _write(ws, 'packages/other/pubspec.yaml', 'name: other\n');
      _write(
        ws,
        'packages/other/lib/other.dart',
        "import 'package:host/src/test_hooks/hooks.dart';\n",
      );
      expect(checkImportRules(ws.path).single, contains('test_hooks'));
    });
  });
}
