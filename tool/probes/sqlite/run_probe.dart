// Drives the SQLite probe on the current OS (task 1.1) and prints one
// markdown table row per mode x build, followed by the bundle layouts.
//
//   dart run_probe.dart        (from tool/probes/sqlite/)
import 'dart:async';
import 'dart:convert';
import 'dart:io';

String systemHooks(String? name) => '''

hooks:
  user_defines:
    sqlite3:
      source: system
${name == null ? '' : '      name: $name\n'}''';

const testEntry = '''
import 'probe.dart' as probe;

void main(List<String> args) {
  print('test-entry');
  probe.main(args);
}
''';

final exe = Platform.isWindows ? '.exe' : '';
final os = Platform.operatingSystem;

Future<void> main() async {
  final probeDir = File(Platform.script.toFilePath()).parent;
  final root = Directory.systemTemp.createTempSync('kumiko-sqlite-probe-');
  final rows = <String>[];
  final layouts = <String>[];
  final modes = [
    'bundled',
    'system',
    if (Platform.isWindows) 'system-winsqlite3',
  ];
  for (final mode in modes) {
    final work = Directory('${root.path}/$mode')..createSync();
    var pubspec = File('${probeDir.path}/pubspec.yaml').readAsStringSync();
    if (mode == 'system') pubspec += systemHooks(null);
    if (mode == 'system-winsqlite3') pubspec += systemHooks('winsqlite3');
    File('${work.path}/pubspec.yaml').writeAsStringSync(pubspec);
    Directory('${work.path}/bin').createSync();
    File('${probeDir.path}/bin/probe.dart')
        .copySync('${work.path}/bin/probe.dart');
    Directory('${work.path}/tool').createSync();
    File('${work.path}/tool/probe_test.dart').writeAsStringSync(
      testEntry.replaceFirst('probe.dart', '../bin/probe.dart'),
    );
    final get = await run('dart', ['pub', 'get'], work);
    if (get.exitCode != 0) {
      rows.add(row(mode, 'pub get', 'no (${firstLine(get)})'));
      continue;
    }
    for (final build in ['compile-exe', 'build-cli']) {
      final outDir = '${work.path}/out-$build';
      String? binary;
      var define = 'yes';
      if (build == 'compile-exe') {
        Directory(outDir).createSync();
        final r = await run('dart', [
          'compile', 'exe', '-Dprobe.define=yes', 'bin/probe.dart', //
          '-o', '$outDir/probe$exe',
        ], work);
        if (r.exitCode == 0) binary = '$outDir/probe$exe';
        if (r.exitCode != 0) {
          rows.add(row(mode, build, 'no (${firstLine(r)})'));
          continue;
        }
      } else {
        var r = await run('dart', [
          'build',
          'cli',
          '-Dprobe.define=yes',
          '-o',
          outDir,
        ], work);
        if (r.exitCode != 0) {
          define = 'rejected by `build cli`';
          r = await run('dart', [
            '-Dprobe.define=yes',
            'build',
            'cli',
            '-o',
            outDir,
          ], work);
        }
        if (r.exitCode != 0) {
          rows.add(row(mode, build, 'no (${firstLine(r)})', define: define));
          continue;
        }
        binary = '$outDir/bundle/bin/probe$exe';
      }
      layouts.add(
        '$os / $mode / $build:\n'
        '${listing(Directory(outDir)).map((f) => '  $f').join('\n')}',
      );
      final info = await run(binary!, ['info'], work);
      final infoOut = info.stdout.toString();
      if (info.exitCode != 0) {
        rows.add(
          row(
            mode,
            build,
            'yes',
            define: define,
            layout: 'see below',
            wal: 'no (runs: ${firstLine(info)})',
          ),
        );
        continue;
      }
      if (!infoOut.contains('define=yes')) {
        define = define == 'yes'
            ? 'ignored'
            : '$define; `dart -D build cli` builds but ignores it';
      }
      if (build == 'build-cli') {
        final alt = '${work.path}/out-alt';
        final r = await run('dart', [
          'build', 'cli', '-t', 'tool/probe_test.dart', '-o', alt, //
        ], work);
        final altInfo = r.exitCode == 0
            ? await run('$alt/bundle/bin/probe_test$exe', ['info'], work)
            : r;
        final ok = altInfo.stdout.toString().contains('test-entry');
        define =
            '$define; separate test entry point (`-t`): '
            '${ok ? 'builds and runs' : 'fails (${firstLine(altInfo)})'}';
      }
      final sqliteVersion = RegExp(r'sqlite=(\S+)').firstMatch(infoOut)?[1];
      final result = await killMidWrite(binary, work);
      rows.add(
        row(
          mode,
          build,
          'yes',
          define: define,
          layout: 'see below',
          wal: result.wal,
          durable: result.durable,
          licence: licence(mode, sqliteVersion),
        ),
      );
    }
  }
  stdout
    ..writeln(
      '| OS | Mode | Build | Builds? | `-D` passes | Bundle layout '
      '| WAL + FULL ok | Row durable after kill | Licence |',
    )
    ..writeln('|---|---|---|---|---|---|---|---|---|')
    ..writeAll(rows.map((r) => '$r\n'))
    ..writeln()
    ..writeln('```')
    ..writeAll(layouts, '\n')
    ..writeln()
    ..writeln('```');
  root.deleteSync(recursive: true);
}

String row(
  String mode,
  String build,
  String builds, {
  String define = '-',
  String layout = '-',
  String wal = '-',
  String durable = '-',
  String licence = '-',
}) =>
    '| $os | $mode | $build | $builds | $define | $layout | $wal '
    '| $durable | $licence |';

String licence(String mode, String? version) => mode == 'bundled'
    ? 'SQLite $version public domain, prebuilt by the hook; package:sqlite3 MIT'
    : 'OS SQLite $version (public domain); package:sqlite3 MIT';

/// Starts `write`, kills the process once ten batches are committed, and
/// checks that every commit it reported is still in the database.
Future<({String wal, String durable})> killMidWrite(
  String binary,
  Directory work,
) async {
  final db = '${work.path}/kill-${DateTime.now().microsecondsSinceEpoch}.db';
  final p = await Process.start(binary, ['write', db]);
  final err = StringBuffer();
  p.stderr.transform(utf8.decoder).listen(err.write);
  var header = '';
  var lastCommitted = 0;
  final done = Completer<void>();
  p.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (line) {
          if (line.startsWith('journal=')) header = line;
          final m = RegExp(r'^committed (\d+)$').firstMatch(line);
          if (m != null) {
            lastCommitted = int.parse(m[1]!);
            if (lastCommitted >= 500 && !done.isCompleted) {
              p.kill(ProcessSignal.sigkill);
              done.complete();
            }
          }
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );
  await done.future.timeout(
    const Duration(seconds: 60),
    onTimeout: () {
      p.kill(ProcessSignal.sigkill);
    },
  );
  await p.exitCode;
  if (lastCommitted == 0) {
    return (
      wal: 'no (${header.isEmpty ? err.toString().trim() : header})',
      durable: '-',
    );
  }
  final check = await run(binary, ['check', db], work);
  final out = check.stdout.toString().trim();
  final max = int.tryParse(RegExp(r'max=(\d+)').firstMatch(out)?[1] ?? '');
  final walOk =
      header == 'journal=wal synchronous=2' &&
      out.contains('journal=wal') &&
      out.contains('integrity=ok');
  return (
    wal: walOk ? 'yes ($header)' : 'no ($header; $out)',
    durable: max != null && max >= lastCommitted
        ? 'yes (reported $lastCommitted, found $max)'
        : 'no (reported $lastCommitted; $out)',
  );
}

Future<ProcessResult> run(String cmd, List<String> args, Directory dir) =>
    Process.run(
      cmd,
      args,
      workingDirectory: dir.path,
      runInShell: Platform.isWindows && cmd == 'dart',
    );

String firstLine(ProcessResult r) {
  final text = '${r.stderr}\n${r.stdout}'.trim();
  final line = text
      .split('\n')
      .firstWhere(
        (l) => l.toLowerCase().contains('error'),
        orElse: () => text.split('\n').first,
      );
  return line.trim().replaceAll('|', '/');
}

List<String> listing(Directory dir) =>
    dir
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.path.substring(dir.path.length + 1).replaceAll(r'\', '/'))
        .toList()
      ..sort();
