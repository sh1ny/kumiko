import 'dart:io';
import 'dart:typed_data';

import 'package:host/src/agent/tool_file_audit.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

const chunk = 1024 * 1024;
const canary = 'ascii-canary-123';

class FakeFile {
  FakeFile(
    this.size, {
    this.data = const {},
    this.shortRead,
    this.throwAt,
    this.readSize,
    this.grow = false,
    this.kind = FileSystemEntityType.file,
    this.statError,
    this.enumerationError,
    this.openError,
    this.readError,
    this.closeError,
  });
  final FileSystemException? statError,
      enumerationError,
      openError,
      readError,
      closeError;
  final int size;
  final Map<int, int> data;
  final int? shortRead, throwAt, readSize;
  final bool grow;
  final FileSystemEntityType kind;
  int stats = 0, opens = 0;
}

class FakeIo implements AuditIo {
  FakeIo(this.files, {this.tree = const {}, this.maxListings});
  final Map<String, FakeFile> files;
  final Map<String, List<String>> tree;
  final int? maxListings;
  final listed = <String, int>{};
  final statPaths = <String>{};
  var yielded = 0;
  final requests = <int>[];
  int closed = 0;
  @override
  Future<AuditMetadata> stat(String path) async {
    statPaths.add(path);
    final f = files[path]!;
    if (f.statError != null) throw f.statError!;
    return (
      f.kind,
      f.size + (f.grow && f.stats++ > 0 ? 1 : 0),
      DateTime(2026),
      DateTime(2026),
    );
  }

  @override
  Stream<String> children(String path) async* {
    if (files[path]!.enumerationError != null) {
      throw files[path]!.enumerationError!;
    }
    final count = listed.update(path, (count) => count + 1, ifAbsent: () => 1);
    // The finite fault seam makes a cyclic graph terminate under legacy code.
    if (maxListings != null && count > maxListings!) return;
    for (final child in tree[path] ?? const <String>[]) {
      yielded++;
      yield child;
    }
  }

  @override
  Future<AuditReader> open(String path) async {
    files[path]!.opens++;
    if (files[path]!.openError != null) throw files[path]!.openError!;
    return FakeReader(this, files[path]!);
  }
}

class FakeReader implements AuditReader {
  FakeReader(this.io, this.file);
  final FakeIo io;
  final FakeFile file;
  int offset = 0;
  @override
  Future<Uint8List> read(int count) async {
    io.requests.add(count);
    if (file.readError != null) throw file.readError!;
    if (file.throwAt != null && offset >= file.throwAt!) {
      throw const FileSystemException('synthetic');
    }
    final n = [
      count,
      (file.readSize ?? file.size) - offset,
      if (file.shortRead != null) file.shortRead!,
    ].reduce((a, b) => a < b ? a : b);
    final bytes = Uint8List(n);
    for (final e in file.data.entries) {
      if (e.key >= offset && e.key < offset + n) {
        bytes[e.key - offset] = e.value;
      }
    }
    offset += n;
    return bytes;
  }

  @override
  Future<void> close() async {
    io.closed++;
    if (file.closeError != null) throw file.closeError!;
  }
}

Map<int, int> at(int offset, String value) => {
  for (var i = 0; i < value.length; i++) offset + i: value.codeUnitAt(i),
};
void invariant(Map<String, Object?> r, {int bound = 32 * chunk}) {
  expect(r['scannedBytes'] as int, lessThanOrEqualTo(r['readBytes'] as int));
  expect(r['readBytes'] as int, lessThanOrEqualTo(r['chargedBytes'] as int));
  expect(r['chargedBytes'] as int, lessThanOrEqualTo(bound));
}

void main() {
  test('Codex audit budget: each request is at most one MiB', () async {
    final io = FakeIo({'a': FakeFile(2 * chunk)});
    final r = await ToolFileAudit(io: io).scan(['a'], canary);
    expect(io.requests.every((n) => n <= chunk), true);
    expect(r['complete'], true);
    invariant(r);
  });
  test('Codex audit budget: match survives later growth', () async {
    final io = FakeIo({'a': FakeFile(40, data: at(0, canary), grow: true)});
    final r = await ToolFileAudit(io: io).scan(['a'], canary);
    expect(r['matchedFiles'], 1);
    expect(r['complete'], false);
    invariant(r);
  });
  test(
    'Codex audit budget: reservation survives throw and prior match survives',
    () async {
      final io = FakeIo({
        'a': FakeFile(2 * chunk, data: at(0, canary), throwAt: chunk),
      });
      final r = await ToolFileAudit(io: io).scan(['a'], canary);
      expect(r['matchedFiles'], 1);
      expect(r['complete'], false);
      expect(r['chargedBytes'] as int, greaterThan(r['readBytes'] as int));
      invariant(r);
    },
  );
  test(
    'Codex audit budget: links and nonregular leaves are incomplete',
    () async {
      for (final kind in [
        FileSystemEntityType.link,
        FileSystemEntityType.pipe,
        FileSystemEntityType.notFound,
      ]) {
        final io = FakeIo({'a': FakeFile(1, kind: kind)});
        final r = await ToolFileAudit(io: io).scan(['a'], canary);
        expect(r['complete'], false);
        expect(io.requests, isEmpty);
        invariant(r);
      }
    },
  );

  test('Codex audit budget: default large and unknown profile limits', () {
    expect(AuditBudget.defaults.echo, {
      'auditProfile': 'default',
      'maxFiles': 4096,
      'maxFileBytes': 16 * chunk,
      'maxTotalBytes': 32 * chunk,
    });
    expect(AuditBudget.large.echo, {
      'auditProfile': 'large-native-home',
      'maxFiles': 4096,
      'maxFileBytes': 256 * chunk,
      'maxTotalBytes': 512 * chunk,
    });
    expect(() => AuditBudget.named('other'), throwsFormatException);
  });
  test('Codex audit budget: exact 256 MiB files and aggregate complete without overprobe', () async {
    final io = FakeIo({
      'a': FakeFile(256 * chunk),
      'b': FakeFile(256 * chunk),
      'empty': FakeFile(0),
    });
    final r = await ToolFileAudit(
      io: io,
      budget: AuditBudget.large,
    ).scan(['a', 'b', 'empty'], canary);
    expect(r['complete'], true);
    expect(r['scannedFiles'], 3);
    expect(r['scannedBytes'], 512 * chunk);
    expect(io.requests, hasLength(512));
    expect(io.files['empty']!.opens, 0);
    invariant(r, bound: 512 * chunk);
  }, timeout: Timeout(Duration(minutes: 2)));
  test('Codex audit budget: per-file oversize is unread', () async {
    final io = FakeIo({'a': FakeFile(16 * chunk + 1)});
    final r = await ToolFileAudit(io: io).scan(['a'], canary);
    expect(r['complete'], false);
    expect(io.requests, isEmpty);
    expect(io.files['a']!.opens, 0);
    invariant(r);
  });
  test('Codex audit budget: aggregate partial file retains match and stable empties after exhaustion', () async {
    final io = FakeIo({
      'a': FakeFile(16 * chunk),
      'b': FakeFile(15 * chunk),
      'c': FakeFile(2 * chunk, data: at(0, canary)),
      'empty': FakeFile(0),
      'outstanding': FakeFile(1),
    });
    final r = await ToolFileAudit(io: io).scan(io.files.keys.toList(), canary);
    expect(r['complete'], false);
    expect(r['matchedFiles'], 1);
    expect((r['errorCategories'] as Map)['aggregateLimit'], 2);
    expect(r['readBytes'], 32 * chunk);
    expect(r['scannedBytes'], 31 * chunk);
    expect(r['scannedFiles'], 3);
    expect(io.files['empty']!.opens, 0);
    expect(io.files['outstanding']!.opens, 0);
    invariant(r);
  });
  test(
    'Codex audit budget: every split across chunk boundary matches',
    () async {
      for (var split = 1; split < canary.length; split++) {
        final io = FakeIo({
          'a': FakeFile(chunk + canary.length, data: at(chunk - split, canary)),
        });
        final r = await ToolFileAudit(io: io).scan(['a'], canary);
        expect(r['complete'], true);
        expect(r['matchedFiles'], 1, reason: 'split $split');
        invariant(r);
      }
    },
  );
  test(
    'Codex audit budget: every split survives one-byte short reads',
    () async {
      for (var split = 1; split < canary.length; split++) {
        final io = FakeIo({
          'a': FakeFile(
            canary.length + split,
            data: at(split, canary),
            shortRead: 1,
          ),
        });
        final r = await ToolFileAudit(io: io).scan(['a'], canary);
        expect(r['complete'], true);
        expect(r['matchedFiles'], 1);
        expect(r['chargedBytes'], canary.length + split);
        invariant(r);
      }
    },
  );
  test('Codex audit budget: carry resets between files', () async {
    final io = FakeIo({
      'a': FakeFile(5, data: at(0, canary.substring(0, 5))),
      'b': FakeFile(canary.length - 5, data: at(0, canary.substring(5))),
    });
    final r = await ToolFileAudit(io: io).scan(['a', 'b'], canary);
    expect(r['matchedFiles'], 0);
    expect(r['complete'], true);
    invariant(r);
  });
  test(
    'Codex audit budget: first read throw retains entire reservation',
    () async {
      final io = FakeIo({'a': FakeFile(5, throwAt: 0)});
      final r = await ToolFileAudit(io: io).scan(['a'], canary);
      expect(r['readBytes'], 0);
      expect(r['chargedBytes'], chunk);
      expect(r['complete'], false);
      expect(io.closed, 1);
      invariant(r);
    },
  );
  test('Codex audit budget: file allowance bounds requests independently of metadata size', () async {
    final io = FakeIo({
      'a': FakeFile(16 * chunk, data: at(0, canary), shortRead: chunk - 1),
    });
    final r = await ToolFileAudit(io: io).scan(['a'], canary);
    expect(r['complete'], true);
    expect(io.requests.last, 16);
    expect(r['matchedFiles'], 1);
    invariant(r);
  });
  test(
    'Codex audit budget: actual owned files and directory links never followed',
    () async {
      final owned = await Directory.systemTemp.createTemp('kumiko_file_audit_');
      addTearDown(() => owned.delete(recursive: true));
      final root = await Directory(p.join(owned.path, 'root')).create();
      final outside = await Directory(p.join(owned.path, 'outside')).create();
      await File(p.join(outside.path, 'must-not-read')).writeAsString(canary);
      await File(p.join(root.path, 'plain')).writeAsString('safe');
      final link = Link(p.join(root.path, 'directory-link'));
      await link.create(outside.path);
      expect(
        await FileSystemEntity.type(link.path, followLinks: false),
        FileSystemEntityType.link,
      );
      final r = await ToolFileAudit().scan([root.path], canary);
      expect(r['complete'], false);
      expect(r['matchedFiles'], 0);
      expect(r['scannedFiles'], 1);
      invariant(r);
      await link.delete();
    },
  );

  test('Codex audit budget: actual Windows junction is an error without reading its target', () async {
    if (!Platform.isWindows) return;
    final owned = await Directory.systemTemp.createTemp(
      'kumiko_junction_audit_',
    );
    addTearDown(() => owned.delete(recursive: true));
    final root = await Directory(p.join(owned.path, 'root')).create();
    final target = await Directory(p.join(owned.path, 'target')).create();
    await File(p.join(target.path, 'private')).writeAsString(canary);
    final junction = Link(p.join(root.path, 'junction'));
    String quote(String value) => "'${value.replaceAll("'", "''")}'";
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'New-Item -ItemType Junction -Path ${quote(junction.path)} '
          '-Target ${quote(target.path)} | Select-Object -ExpandProperty LinkType',
    ]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(result.stdout.toString().trim(), 'Junction');
    addTearDown(() async {
      if (await junction.exists()) await junction.delete();
    });
    expect(
      await FileSystemEntity.type(junction.path, followLinks: false),
      FileSystemEntityType.link,
    );
    final r = await ToolFileAudit().scan([root.path], canary);
    expect(r['complete'], false);
    expect(r['matchedFiles'], 0);
    expect(r['readBytes'], 0);
    invariant(r);
  });
  test('Codex audit budget: growth past initial size is charged to file allowance and retains match', () async {
    final io = FakeIo({
      'a': FakeFile(
        40,
        data: at(0, canary),
        readSize: 16 * chunk + 1,
        grow: true,
      ),
    });
    final r = await ToolFileAudit(io: io).scan(['a'], canary);
    expect(r['readBytes'], 16 * chunk);
    expect(r['chargedBytes'], 16 * chunk);
    expect(r['complete'], false);
    expect(r['matchedFiles'], 1);
    expect(io.requests.every((n) => n <= chunk), true);
    invariant(r);
  });
  test('Codex audit budget: 4096-file cap remains bounded', () async {
    final io = FakeIo({for (var i = 0; i < 4097; i++) '$i': FakeFile(0)});
    final r = await ToolFileAudit(io: io).scan(io.files.keys.toList(), canary);
    expect((r['errorCategories'] as Map)['metadataAdmission'], 1);
    expect(r['scannedFiles'], 4096);
    expect(r['complete'], false);
    expect(io.requests, isEmpty);
    invariant(r);
  });

  test(
    'Codex audit budget: metadata admission bounds directory-only forests',
    () async {
      final children = [for (var i = 0; i < 5000; i++) 'directory-$i'];
      final io = FakeIo(
        {
          'root': FakeFile(0, kind: FileSystemEntityType.directory),
          for (final child in children)
            child: FakeFile(0, kind: FileSystemEntityType.directory),
        },
        tree: {'root': children},
      );
      final result = await ToolFileAudit(io: io).scan(['root'], canary);
      expect(result['complete'], false);
      expect(io.statPaths.length, lessThanOrEqualTo(4096));
      expect(io.yielded, lessThanOrEqualTo(4096));
      expect(io.requests, isEmpty);
      invariant(result);
    },
  );
  test('Codex audit budget: metadata admission stops siblings and later roots globally', () async {
    final children = [for (var i = 0; i < 5000; i++) 'file-$i'];
    final io = FakeIo(
      {
        'root': FakeFile(0, kind: FileSystemEntityType.directory),
        'later': FakeFile(0),
        for (final child in children) child: FakeFile(0),
      },
      tree: {'root': children},
    );
    final result = await ToolFileAudit(io: io).scan(['root', 'later'], canary);
    expect(result['complete'], false);
    expect(io.statPaths.length, lessThanOrEqualTo(4096));
    expect(io.yielded, lessThanOrEqualTo(4096));
    expect(io.statPaths, isNot(contains('later')));
    expect(result['scannedFiles'] as int, lessThanOrEqualTo(4096));
    expect(io.requests, isEmpty);
    invariant(result);
  });
  test(
    'Codex audit budget: repeated directories and cycles are traversed once',
    () async {
      for (final cyclic in [false, true]) {
        final io = FakeIo(
          {
            'root': FakeFile(0, kind: FileSystemEntityType.directory),
            'dir': FakeFile(0, kind: FileSystemEntityType.directory),
            'file': FakeFile(0),
          },
          tree: cyclic
              ? {
                  'root': ['root'],
                }
              : {
                  'root': ['dir', 'dir'],
                  'dir': ['file'],
                },
          maxListings: 1,
        );
        final result = await ToolFileAudit(io: io).scan(['root'], canary);
        expect(result['complete'], true);
        expect(io.listed.values, everyElement(1));
        invariant(result);
      }
    },
  );
  test(
    'Codex audit budget: duplicate candidates cannot evade metadata admission',
    () async {
      final io = FakeIo(
        {
          'root': FakeFile(0, kind: FileSystemEntityType.directory),
          'dir': FakeFile(0, kind: FileSystemEntityType.directory),
        },
        tree: {'root': List.filled(5000, 'dir')},
      );
      final result = await ToolFileAudit(io: io).scan(['root'], canary);
      expect(result['complete'], false);
      expect(io.yielded, lessThanOrEqualTo(4096));
      expect(io.listed['dir'] ?? 0, lessThanOrEqualTo(1));
      invariant(result);
    },
  );

  test('Codex audit diagnostics: existing failures expose only fixed categories and errno buckets', () async {
    final io = FakeIo({
      'link': FakeFile(1, kind: FileSystemEntityType.link),
      'large': FakeFile(16 * chunk + 1),
      'unstable': FakeFile(2, grow: true),
      'read': FakeFile(5, throwAt: 0),
    });
    final result = await ToolFileAudit(io: io)
        .scan(io.files.keys.toList(), canary);
    expect(result['errorCategories'], isA<Map<String, int>>());
    final categories = result['errorCategories'] as Map<String, int>;
    expect(categories['nonRegular'], 1);
    expect(categories['fileLimit'], 1);
    expect(categories['unstable'], 1);
    expect(categories['readIo'], 1);
    expect(result['ioErrorCategories'], isA<Map<String, int>>());
    expect(result['errorCount'], 4);
    invariant(result);
  });

  test('Codex audit diagnostics: each IO stage preserves scalar failures and fixed errno classes', () async {
    for (final stage in [
      'statIo',
      'enumerationIo',
      'openIo',
      'readIo',
      'closeIo',
    ]) {
      for (final code in [32, 33, 5, 13, 999]) {
        final error = FileSystemException(
          'PRIVATE_EXCEPTION',
          'PRIVATE_PATH',
          OSError('PRIVATE_OS', code),
        );
        final io = FakeIo({
          'a': FakeFile(
            1,
            kind: stage == 'enumerationIo'
                ? FileSystemEntityType.directory
                : FileSystemEntityType.file,
            statError: stage == 'statIo' ? error : null,
            enumerationError: stage == 'enumerationIo' ? error : null,
            openError: stage == 'openIo' ? error : null,
            readError: stage == 'readIo' ? error : null,
            closeError: stage == 'closeIo' ? error : null,
          ),
        });
        final r = await ToolFileAudit(io: io).scan(['a'], canary);
        expect(r['errorCount'], 1);
        expect(r['complete'], false);
        expect((r['errorCategories'] as Map)[stage], 1);
        final expected = Platform.isWindows && code == 32
            ? 'sharingViolation'
            : Platform.isWindows && code == 33
            ? 'lockViolation'
            : code == 13 || Platform.isWindows && code == 5
            ? 'accessDenied'
            : 'other';
        expect((r['ioErrorCategories'] as Map)[expected], 1);
        expect(r.toString(), isNot(contains('PRIVATE_')));
        invariant(r);
      }
    }
  });
}
