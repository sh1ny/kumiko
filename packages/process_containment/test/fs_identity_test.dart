import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

ResolvedDirectory _resolve(String path) {
  final id = directoryIdentity(path);
  expect(id, isA<ResolvedDirectory>(), reason: '$path -> $id');
  return id as ResolvedDirectory;
}

void main() {
  late Directory tmp;
  late String dir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('pc_fs_identity_');
    dir = Directory(p.join(tmp.path, 'workdir')).absolute.path;
    Directory(dir).createSync();
  });

  tearDown(() {
    if (Platform.isWindows) {
      // Remove junctions and links without following them into the target.
      for (final e in tmp.listSync(followLinks: false)) {
        if (e is Link) e.deleteSync();
      }
      final junction = Directory(p.join(tmp.path, 'junction'));
      if (junction.existsSync()) {
        Process.runSync('cmd', ['/c', 'rmdir', junction.path]);
      }
    }
    tmp.deleteSync(recursive: true);
  });

  bool caseInsensitive() => Directory(p.join(tmp.path, 'WORKDIR')).existsSync();

  test('alias paths share identity', () {
    final base = _resolve(dir);
    var aliases = 0;

    try {
      final link = p.join(tmp.path, 'sym');
      Link(link).createSync(dir);
      expect(_resolve(link).id, base.id, reason: 'symbolic link');
      expect(_resolve(link).realPath, base.realPath);
      aliases++;
    } on FileSystemException catch (e) {
      // Windows needs Developer Mode or elevation for symbolic links.
      printOnFailure('symbolic link unavailable: $e');
    }

    if (Platform.isWindows) {
      final junction = p.join(tmp.path, 'junction');
      final r = Process.runSync('cmd', ['/c', 'mklink', '/J', junction, dir]);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect(_resolve(junction).id, base.id, reason: 'junction');
      aliases++;
    }

    if (caseInsensitive()) {
      expect(
        _resolve(p.join(tmp.path, 'WORKDIR')).id,
        base.id,
        reason: 'letter case',
      );
      aliases++;
    }

    expect(aliases, greaterThan(0), reason: 'no alias kind was available');
  });

  test('alias through a relative path with dots shares identity', () {
    final dotted = p.join(dir, '..', 'workdir', '.');
    expect(_resolve(dotted).id, _resolve(dir).id);
  });

  test(
    'distinct directories differing only in case stay distinct',
    () {
      if (caseInsensitive()) {
        markTestSkipped('volume is case-insensitive');
        return;
      }
      final upper = p.join(tmp.path, 'WORKDIR');
      Directory(upper).createSync();
      expect(_resolve(upper).id, isNot(_resolve(dir).id));
    },
    skip: Platform.isWindows
        ? 'the Windows test volume is case-insensitive'
        : false,
  );

  test('different directories have different identities', () {
    final other = Directory(p.join(tmp.path, 'other'))..createSync();
    expect(_resolve(other.path).id, isNot(_resolve(dir).id));
  });

  test('missing directory is target-unavailable', () {
    final id = directoryIdentity(p.join(tmp.path, 'missing'));
    expect(id, isA<TargetUnavailable>());
    expect((id as TargetUnavailable).reason, 'target-unavailable');
  });

  test('a file is target-unavailable', () {
    final file = File(p.join(tmp.path, 'file.txt'))..writeAsStringSync('x');
    expect(directoryIdentity(file.path), isA<TargetUnavailable>());
  });

  test('a dangling link is target-unavailable', () {
    final link = p.join(tmp.path, 'dangling');
    try {
      Link(link).createSync(p.join(tmp.path, 'nowhere'));
    } on FileSystemException {
      markTestSkipped('symbolic links unavailable');
      return;
    }
    expect(directoryIdentity(link), isA<TargetUnavailable>());
  });
}
