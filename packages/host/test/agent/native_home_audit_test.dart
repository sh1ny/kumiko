import 'dart:io';

import 'package:host/src/agent/codex/native_home_audit.dart';
import 'package:host/src/agent/tool_file_audit.dart';
import 'package:host/src/agent/codex/windows_find_data.dart'
    show WindowsFindRecord;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const dirType = FileSystemEntityType.directory;
const fileType = FileSystemEntityType.file;

/// Deterministic in-memory native home behind the injected inventory seam. It
/// also observes the traversal's pending list and upstream consumption.
class VirtualHome extends NativeInventoryIo {
  VirtualHome()
    : root = p.join(Directory.systemTemp.path, 'kumiko_virtual_native_home') {
    entries[root] = (dirType, 0, _time(), _time());
  }
  final String root;
  final entries = <String, AuditMetadata>{};
  final _children = <String, List<String>>{};
  final statFaults = <String>{};
  final listed = <String>[];
  int _clock = 1, maxPending = 0, maxDepth = 0, pulled = 0;
  void Function(String directory)? afterFirstChild;
  Stream<String> Function(String directory)? lister;
  final linkObservations = <String, NativeLinkObservation>{};
  final observed = <String>[];
  final linkFaults = <String>{};
  bool linksSupported = true;
  Future<NativeLinkObservation> Function(String path)? linkOverride;
  final socketObservations = <String, NativeLinkObservation>{};
  final socketsObserved = <String>[];
  final socketFaults = <String>{};
  Future<NativeLinkObservation> Function(String path)? socketOverride;
  DateTime _time() => DateTime.fromMillisecondsSinceEpoch(_clock++ * 1000);
  String path(String relative) =>
      p.normalize(p.joinAll([root, ...p.split(relative)]));
  void _touch(String directory) {
    final m = entries[directory];
    if (m != null) entries[directory] = (m.$1, m.$2, _time(), m.$4);
  }

  void _put(String key, FileSystemEntityType type, int size) {
    final parent = p.dirname(key);
    if (!entries.containsKey(key)) {
      (_children[parent] ??= []).add(key);
      _touch(parent);
    }
    entries[key] = (type, size, _time(), _time());
  }

  void file(String relative, {int size = 1}) {
    dir(p.dirname(relative) == '.' ? '' : p.dirname(relative));
    _put(path(relative), fileType, size);
  }

  void dir(String relative) {
    if (relative.isEmpty) return;
    var current = root;
    for (final part in p.split(relative)) {
      current = p.join(current, part);
      if (!entries.containsKey(current)) _put(current, dirType, 0);
    }
  }

  void entry(String relative, FileSystemEntityType type) {
    dir(p.dirname(relative) == '.' ? '' : p.dirname(relative));
    _put(path(relative), type, 0);
  }

  void resize(String relative, int size) {
    final key = path(relative);
    final m = entries[key]!;
    entries[key] = (m.$1, size, _time(), m.$4);
  }

  /// A symlink or junction leaf as the no-follow observation reports it.
  void link(
    String relative, {
    String target = 'synthetic-target',
    NativeLinkKind kind = NativeLinkKind.symlink,
    int attributes = 0x400,
    int modifiedMs = 6000,
  }) {
    dir(p.dirname(relative) == '.' ? '' : p.dirname(relative));
    final key = path(relative);
    _put(key, FileSystemEntityType.link, 0);
    linkObservations[key] = NativeLinkObservation(
      kind: kind,
      attributes: attributes,
      created: DateTime.fromMillisecondsSinceEpoch(5000),
      modified: DateTime.fromMillisecondsSinceEpoch(modifiedMs),
      target: target,
    );
  }

  /// A Unix-domain socket leaf as the no-follow observation reports it.
  void socket(
    String relative, {
    NativeLinkKind kind = NativeLinkKind.socket,
    int attributes = 0x400,
    int modifiedMs = 7000,
  }) {
    dir(p.dirname(relative) == '.' ? '' : p.dirname(relative));
    final key = path(relative);
    _put(key, FileSystemEntityType.unixDomainSock, 0);
    socketObservations[key] = NativeLinkObservation(
      kind: kind,
      attributes: attributes,
      created: DateTime.fromMillisecondsSinceEpoch(5000),
      modified: DateTime.fromMillisecondsSinceEpoch(modifiedMs),
      target: '',
    );
  }

  void touchDirectory(String relative) => _touch(path(relative));
  void remove(String relative) {
    final key = path(relative);
    entries.remove(key);
    _children[p.dirname(key)]?.remove(key);
    _touch(p.dirname(key));
  }

  @override
  Future<AuditMetadata> stat(String path) async {
    if (statFaults.contains(path)) {
      throw const FileSystemException('synthetic stat fault');
    }
    return entries[path] ??
        (
          FileSystemEntityType.notFound,
          0,
          DateTime.fromMillisecondsSinceEpoch(0),
          DateTime.fromMillisecondsSinceEpoch(0),
        );
  }

  @override
  Stream<String> children(String directory) async* {
    listed.add(directory);
    if (lister != null) {
      await for (final child in lister!(directory)) {
        pulled++;
        yield child;
      }
      return;
    }
    var first = true;
    for (final child in List<String>.of(_children[directory] ?? const [])) {
      yield child;
      if (first) afterFirstChild?.call(directory);
      first = false;
    }
  }

  @override
  bool get supportsLinks => linksSupported;
  @override
  Future<NativeLinkObservation> observeLink(String path) async {
    observed.add(path);
    if (linkFaults.contains(path)) {
      throw FileSystemException('PRIVATE synthetic link fault', path);
    }
    if (linkOverride != null) return linkOverride!(path);
    return linkObservations[path] ??
        (throw const FileSystemException('no such link'));
  }

  @override
  Future<NativeLinkObservation> observeSocket(String path) async {
    socketsObserved.add(path);
    if (socketFaults.contains(path)) {
      throw FileSystemException('PRIVATE synthetic socket fault', path);
    }
    if (socketOverride != null) return socketOverride!(path);
    return socketObservations[path] ??
        (throw const FileSystemException('no such socket'));
  }

  @override
  void observe({required int pending, required int depth}) {
    if (pending > maxPending) maxPending = pending;
    if (depth > maxDepth) maxDepth = depth;
  }
}

Future<NativeHomeAudit> prepareV1(VirtualHome home, {bool? caseInsensitive}) =>
    NativeHomeAudit.prepare(
      home.root,
      selection: NativeSelection.changedArtifactsV1,
      io: home,
      caseInsensitiveNames: caseInsensitive,
    );

Future<NativeHomeAudit> prepareV2(
  VirtualHome home, {
  bool? caseInsensitive,
  NativeStorageBudget budget = const NativeStorageBudget(),
}) => NativeHomeAudit.prepare(
  home.root,
  selection: NativeSelection.changedArtifactsV2,
  io: home,
  caseInsensitiveNames: caseInsensitive,
  budget: budget,
);

Future<NativeHomeAudit> prepareV3(
  VirtualHome home, {
  bool? caseInsensitive,
  NativeStorageBudget budget = const NativeStorageBudget(),
}) => NativeHomeAudit.prepare(
  home.root,
  selection: NativeSelection.changedArtifactsV3,
  io: home,
  caseInsensitiveNames: caseInsensitive,
  budget: budget,
);

Set<String> relativeSet(VirtualHome home, List<File> files) => {
  for (final f in files) p.relative(f.path, from: home.root),
};

class OversizeIo implements AuditIo {
  @override
  Future<AuditMetadata> stat(String path) async => (
    FileSystemEntityType.file,
    AuditBudget.defaults.maxFileBytes + 1,
    DateTime(2026),
    DateTime(2026),
  );
  @override
  Stream<String> children(String path) => const Stream.empty();
  @override
  Future<AuditReader> open(String path) => throw StateError('must not open');
}

void main() {
  late Directory home;
  test('native audit excludes unchanged historical session contents', () async {
    final directory = Directory(p.join(home.path, 'sessions'))..createSync();
    final history = File(p.join(directory.path, 'historical.jsonl'))
      ..writeAsStringSync('old');
    final audit = await NativeHomeAudit.prepare(home.path);
    final (files, errors) = await audit.changedFiles();
    expect(errors, 0);
    expect(files.any((file) => file.path == history.path), false);
    history.writeAsStringSync('changed historical session');
    expect(
      (await audit.changedFiles()).$1.any((file) => file.path == history.path),
      true,
    );
  });
  setUp(
    () =>
        home = Directory.systemTemp.createTempSync('kumiko_native_audit_unit_'),
  );
  tearDown(() => home.deleteSync(recursive: true));
  test('native audit missing baseline artifact stays incomplete', () async {
    final file = File(p.join(home.path, 'state.sqlite'))
      ..writeAsStringSync('before');
    final audit = await NativeHomeAudit.prepare(home.path);
    file.deleteSync();
    expect((await audit.changedFiles()).$2, greaterThan(0));
  });
  test(
    'native audit mutable artifacts scan even with unchanged metadata',
    () async {
      final file = File(p.join(home.path, 'state.sqlite'))
        ..writeAsStringSync('same');
      final audit = await NativeHomeAudit.prepare(home.path);
      final (files, errors) = await audit.changedFiles();
      expect(errors, 0);
      expect(files.map((f) => f.path), contains(file.path));
    },
  );
  test(
    'native audit new unknown directory cannot be excluded as clean',
    () async {
      final audit = await NativeHomeAudit.prepare(home.path);
      Directory(p.join(home.path, 'unknown')).createSync();
      File(p.join(home.path, 'unknown', 'data'))
          .writeAsStringSync('uninspected');
      expect((await audit.changedFiles()).$2, greaterThan(0));
    },
  );
  test(
    'native audit traversal includes empty directories in fixed entry cap',
    () async {
      final sessions = Directory(p.join(home.path, 'sessions'))..createSync();
      for (var i = 0; i < 4096; i++) {
        Directory(p.join(sessions.path, '$i')).createSync();
      }
      final audit = await NativeHomeAudit.prepare(home.path);
      expect(audit.complete, false);
      expect(audit.baselineErrorCategories['metadataLimit'], greaterThan(0));
    },
  );

  test('native audit does not descend into an owned directory link', () async {
    final outside = Directory.systemTemp.createTempSync(
      'kumiko_native_link_target_',
    );
    addTearDown(() => outside.deleteSync(recursive: true));
    File(p.join(outside.path, 'history.jsonl')).writeAsStringSync('synthetic');
    final link = Link(p.join(home.path, 'sessions'));
    await link.create(outside.path);
    addTearDown(() async {
      if (await link.exists()) await link.delete();
    });
    final audit = await NativeHomeAudit.prepare(home.path);
    expect(audit.complete, false);
    expect(audit.before, isEmpty);
    expect((await audit.changedFiles()).$2, greaterThan(0));
  });

  test('native audit diagnostics classify removed and known-literal unknown artifacts without paths', () async {
    final file = File(p.join(home.path, 'state.sqlite'))
      ..writeAsStringSync('synthetic');
    final audit = await NativeHomeAudit.prepare(home.path);
    file.deleteSync();
    for (final name in [
      'auth.json',
      'config.toml',
      'models_cache.json',
      'version.json',
      'PRIVATE_FILE',
    ]) {
      File(p.join(home.path, name)).writeAsStringSync('PRIVATE_CONTENT');
    }
    for (final name in ['tmp', 'PRIVATE_DIRECTORY']) {
      Directory(p.join(home.path, name)).createSync();
    }
    final (selected, errors) = await audit.changedFiles();
    expect(errors, 8);
    expect(selected, isEmpty);
    expect(audit.errorCategories['removedEntry'], 1);
    expect(audit.errorCategories['changedUnknownFile'], 5);
    expect(audit.errorCategories['changedUnknownDirectory'], 2);
    expect(audit.unknownArtifactCategories, {
      'credential': 1,
      'config': 1,
      'modelCache': 1,
      'versionCache': 1,
      'tempDirectory': 1,
      'otherFile': 1,
      'otherDirectory': 1,
    });
    expect(
      '${audit.errorCategories}${audit.unknownArtifactCategories}',
      isNot(contains('PRIVATE_')),
    );
  });
  test('native audit diagnostics keep incomplete baseline causes separate from current diff', () async {
    final outside = Directory.systemTemp.createTempSync(
      'kumiko_diag_link_target_',
    );
    addTearDown(() => outside.deleteSync(recursive: true));
    final link = Link(p.join(home.path, 'sessions'));
    await link.create(outside.path);
    addTearDown(() async {
      if (await link.exists()) await link.delete();
    });
    final audit = await NativeHomeAudit.prepare(home.path);
    expect(audit.baselineErrorCategories['nonRegular'], 1);
    final (_, errors) = await audit.changedFiles();
    expect(errors, 2);
    expect(audit.errorCategories['nonRegular'], 1);
    expect(audit.errorCategories['baselineIncomplete'], 1);
  });

  // ---- Codex changed artifacts: selection ----
  test('Codex changed artifacts: selection new and changed model cache and unclassified descendants join one selection', () async {
    final h = VirtualHome()
      ..file('models_cache.json')
      ..file('cache/a.bin')
      ..file('other/keep.bin');
    final audit = await prepareV1(h);
    expect(audit.complete, true);
    expect(audit.baselineErrorCount, 0);
    expect(audit.selection, NativeSelection.changedArtifactsV1);
    h
      ..resize('models_cache.json', 7)
      ..resize('cache/a.bin', 9)
      ..file('other/new.bin');
    final (files, errors) = await audit.changedFiles();
    expect(errors, 0);
    expect(relativeSet(h, files), {
      'models_cache.json',
      p.join('cache', 'a.bin'),
      p.join('other', 'new.bin'),
    });
  });
  test('Codex changed artifacts: selection changed child is selected while its parent metadata is unchanged', () async {
    final h = VirtualHome()..file('cache/deep/a.bin');
    final audit = await prepareV1(h);
    final parents = [
      h.entries[h.path('cache')],
      h.entries[h.path('cache/deep')],
    ];
    h.resize('cache/deep/a.bin', 99);
    expect([
      h.entries[h.path('cache')],
      h.entries[h.path('cache/deep')],
    ], parents);
    final (files, errors) = await audit.changedFiles();
    expect(errors, 0);
    expect(relativeSet(h, files), {p.join('cache', 'deep', 'a.bin')});
  });
  test('Codex changed artifacts: selection metadata-equal ordinary files stay unread and the detector limits are recorded', () async {
    final h = VirtualHome()
      ..file('cache/a.bin')
      ..file('plain.txt');
    final audit = await prepareV1(h);
    final (files, errors) = await audit.changedFiles();
    expect(errors, 0);
    expect(files, isEmpty);
    expect(
      audit.detectorLimits.join(' '),
      allOf(contains('metadata'), contains('ASCII'), contains('UTF-8')),
    );
    expect(audit.detectorLimits, nativeDetectorLimits);
    final legacy = await NativeHomeAudit.prepare(home.path);
    expect(legacy.detectorLimits, isEmpty);
  });
  test('Codex changed artifacts: selection legacy always-scan union is deduplicated', () async {
    final h = VirtualHome()
      ..file('sessions/old.jsonl')
      ..file('state/native.state')
      ..file('logs/native.log')
      ..file('state/db.sqlite')
      ..file('state.json')
      ..file('top.jsonl')
      ..file('x/y.sqlite-wal')
      ..file('plain.bin');
    final audit = await prepareV1(h);
    h
      ..resize('state/native.state', 5)
      ..resize('x/y.sqlite-wal', 5);
    final (files, errors) = await audit.changedFiles();
    expect(errors, 0);
    expect(files.length, files.map((f) => f.path).toSet().length);
    expect(relativeSet(h, files), {
      p.join('state', 'native.state'),
      p.join('logs', 'native.log'),
      p.join('state', 'db.sqlite'),
      'state.json',
      'top.jsonl',
      p.join('x', 'y.sqlite-wal'),
    });
  });
  test('Codex changed artifacts: selection SQLite WAL and SHM in unclassified subdirectories are scanned with unchanged metadata', () async {
    final h = VirtualHome()
      ..file('unknown/a/db.sqlite')
      ..file('unknown/a/db.sqlite-wal')
      ..file('unknown/a/db.sqlite-shm')
      ..file('unknown/a/journal-wal')
      ..file('unknown/a/region-shm')
      ..file('unknown/a/db.sqlitex')
      ..file('unknown/a/data.bin');
    final audit = await prepareV1(h);
    final (files, errors) = await audit.changedFiles();
    expect(errors, 0);
    expect(relativeSet(h, files), {
      for (final n in ['db.sqlite', 'db.sqlite-wal', 'db.sqlite-shm'])
        p.join('unknown', 'a', n),
    });
  });
  test('Codex changed artifacts: selection ordinary fully accounted directory change adds no error', () async {
    final h = VirtualHome()..file('other/f.bin');
    final audit = await prepareV1(h);
    h
      ..touchDirectory('other')
      ..dir('other/empty');
    final (files, errors) = await audit.changedFiles();
    expect(errors, 0);
    expect(files, isEmpty);
  });
  test('Codex changed artifacts: selection diagnostics hold counters only and no names or content', () async {
    final h = VirtualHome()
      ..file('PRIVATE_DIRECTORY/PRIVATE_FILE')
      ..file('PRIVATE_GONE');
    final audit = await prepareV1(h);
    h
      ..resize('PRIVATE_DIRECTORY/PRIVATE_FILE', 4)
      ..remove('PRIVATE_GONE')
      ..file('PRIVATE_DIRECTORY/auth.json');
    final (_, errors) = await audit.changedFiles();
    expect(errors, 2);
    final text =
        '${audit.errorCategories}${audit.ioErrorCategories}'
        '${audit.unknownArtifactCategories}${audit.selectionCounters}'
        '${audit.baselineErrorCategories}';
    expect(text, isNot(contains('PRIVATE')));
    expect(text, isNot(contains(h.root)));
    expect(audit.selectionCounters, isNotEmpty);
    expect(audit.selectionCounters.values.every((v) => v >= 0), true);
  });
  test('Codex changed artifacts: selection real filesystem selects a new cache and nested unclassified file', () async {
    Directory(p.join(home.path, 'cache', 'deep')).createSync(recursive: true);
    File(p.join(home.path, 'cache', 'deep', 'old.bin')).writeAsStringSync('o');
    File(p.join(home.path, 'plain.txt')).writeAsStringSync('p');
    final audit = await NativeHomeAudit.prepare(
      home.path,
      selection: NativeSelection.changedArtifactsV1,
    );
    expect(audit.complete, true);
    final cache = File(p.join(home.path, 'models_cache.json'))
      ..writeAsStringSync('cache');
    final nested = File(p.join(home.path, 'cache', 'deep', 'new.bin'))
      ..writeAsStringSync('new');
    final (files, errors) = await audit.changedFiles();
    expect(errors, 0);
    expect(files.map((f) => p.basename(f.path)).toSet(), {
      p.basename(cache.path),
      p.basename(nested.path),
    });
  });

  // ---- Codex changed artifacts: refusal ----
  test('Codex changed artifacts: refusal protected leaves at every depth are metadata-only and never selected', () async {
    expect(protectedNativeBasenames, [
      'auth.json',
      'config.toml',
      '.credentials.json',
      'managed_config.toml',
      'requirements.toml',
      'environments.toml',
      '.env',
    ]);
    for (final name in protectedNativeBasenames) {
      for (final dir in ['', 'state', 'logs/deep/er', 'unclassified/a']) {
        final h = VirtualHome()..file(p.join(dir, name));
        final audit = await prepareV1(h, caseInsensitive: false);
        final (files, errors) = await audit.changedFiles();
        expect(errors, 0, reason: '$dir/$name unchanged');
        expect(files, isEmpty, reason: '$dir/$name unchanged');
      }
    }
  });
  test('Codex changed artifacts: refusal new changed and removed protected entries stay incomplete without a read', () async {
    for (final name in protectedNativeBasenames) {
      for (final dir in ['', 'state', 'unclassified/deep']) {
        for (final mode in ['new', 'changed', 'removed']) {
          final h = VirtualHome()..dir('state');
          if (mode != 'new') h.file(p.join(dir, name));
          final audit = await prepareV1(h, caseInsensitive: false);
          switch (mode) {
            case 'new':
              h.file(p.join(dir, name));
            case 'changed':
              h.resize(p.join(dir, name), 42);
            default:
              h.remove(p.join(dir, name));
          }
          final (files, errors) = await audit.changedFiles();
          final reason = '$mode $dir/$name';
          expect(errors, greaterThan(0), reason: reason);
          expect(files.where((f) => p.basename(f.path) == name), isEmpty);
          expect(audit.errorCategories['protectedEntry'], 1, reason: reason);
          expect(audit.errorCategories.toString(), isNot(contains(name)));
        }
      }
    }
  });
  test('Codex changed artifacts: refusal protected names are case-insensitive only on Windows', () async {
    expect(isProtectedNativeLeaf('AUTH.JSON', windows: true), true);
    expect(isProtectedNativeLeaf('.Env', windows: true), true);
    expect(isProtectedNativeLeaf('AUTH.JSON', windows: false), false);
    expect(isProtectedNativeLeaf('auth.json', windows: false), true);
    for (final near in ['auth.json.bak', 'xauth.json', 'config.tom', 'env']) {
      expect(isProtectedNativeLeaf(near, windows: true), false, reason: near);
    }
    final upper = VirtualHome();
    var audit = await prepareV1(upper, caseInsensitive: true);
    upper.file('state/Config.TOML');
    var (files, errors) = await audit.changedFiles();
    expect(errors, 1);
    expect(files, isEmpty);
    final exact = VirtualHome();
    audit = await prepareV1(exact, caseInsensitive: false);
    exact.file('state/Config.TOML');
    (files, errors) = await audit.changedFiles();
    expect(errors, 0);
    expect(relativeSet(exact, files), {p.join('state', 'Config.TOML')});
  });
  test(
    'Codex changed artifacts: refusal removed ordinary entries stay incomplete',
    () async {
      final h = VirtualHome()
        ..file('cache/a.bin')
        ..file('plain.bin')
        ..dir('emptydir');
      final audit = await prepareV1(h);
      h
        ..remove('plain.bin')
        ..remove('emptydir')
        ..remove('cache/a.bin');
      final (_, errors) = await audit.changedFiles();
      expect(errors, 3);
      expect(audit.errorCategories['removedEntry'], 3);
    },
  );
  test('Codex changed artifacts: refusal missing or unstable files stay incomplete', () async {
    final h = VirtualHome()
      ..file('cache/a.bin')
      ..file('cache/b.bin');
    final audit = await prepareV1(h);
    h.entries.remove(h.path('cache/a.bin'));
    h.statFaults.add(h.path('cache/b.bin'));
    final (_, errors) = await audit.changedFiles();
    expect(errors, greaterThanOrEqualTo(2));
    expect(audit.errorCategories['metadataIo'], 1);
    expect(audit.ioErrorCategories.values.fold<int>(0, (a, b) => a + b), 1);
  });
  test('Codex changed artifacts: refusal directory membership changing mid-enumeration stays incomplete', () async {
    final h = VirtualHome()
      ..file('cache/a.bin')
      ..file('cache/b.bin');
    final audit = await prepareV1(h);
    h.afterFirstChild = (directory) {
      if (directory == h.path('cache')) h.file('cache/late.bin');
    };
    final (_, errors) = await audit.changedFiles();
    expect(errors, greaterThan(0));
    expect(audit.errorCategories['directoryUnstable'], 1);
    // The baseline inventory is checked the same way.
    final racing = VirtualHome()
      ..file('cache/a.bin')
      ..file('cache/b.bin');
    racing.afterFirstChild = (directory) {
      if (directory == racing.path('cache')) racing.file('cache/late.bin');
    };
    final baseline = await prepareV1(racing);
    expect(baseline.complete, false);
    expect(baseline.baselineErrorCategories['directoryUnstable'], 1);
  });
  test('Codex changed artifacts: refusal symlinks junctions and nonregular entries are never followed', () async {
    final h = VirtualHome()..file('ok.bin');
    h
      ..entry('link', FileSystemEntityType.link)
      ..entry('nested/pipe', FileSystemEntityType.pipe)
      ..entry('nested/socket', FileSystemEntityType.unixDomainSock);
    final audit = await prepareV1(h);
    expect(audit.complete, false);
    expect(audit.baselineErrorCategories['nonRegular'], 3);
    expect(audit.before.containsKey(h.path('link')), false);
    expect(h.listed.contains(h.path('link')), false);
    final (files, errors) = await audit.changedFiles();
    expect(errors, 4);
    expect(files, isEmpty);
    expect(audit.errorCategories['nonRegular'], 3);
    expect(audit.errorCategories['baselineIncomplete'], 1);
  });
  test('Codex changed artifacts: refusal real directory link inside an unclassified directory is never followed', () async {
    final outside = Directory.systemTemp.createTempSync(
      'kumiko_native_v1_link_target_',
    );
    addTearDown(() => outside.deleteSync(recursive: true));
    File(p.join(outside.path, 'target.bin')).writeAsStringSync('synthetic');
    Directory(p.join(home.path, 'unclassified')).createSync();
    final link = Link(p.join(home.path, 'unclassified', 'link'));
    await link.create(outside.path);
    final audit = await NativeHomeAudit.prepare(
      home.path,
      selection: NativeSelection.changedArtifactsV1,
    );
    expect(audit.complete, false);
    expect(audit.baselineErrorCategories['nonRegular'], 1);
    final (files, _) = await audit.changedFiles();
    expect(files.any((f) => p.basename(f.path) == 'target.bin'), false);
  });
  test('Codex changed artifacts: refusal metadata admission counts directories files and duplicates at exactly 4096', () async {
    final exact = VirtualHome();
    for (var i = 0; i < 2048; i++) {
      exact.dir('d$i');
    }
    for (var i = 0; i < 2048; i++) {
      exact.file('f$i');
    }
    var audit = await prepareV1(exact);
    expect(audit.complete, true);
    expect(audit.before.length, 4096);
    exact.file('one-more');
    audit = await prepareV1(exact);
    expect(audit.complete, false);
    expect(audit.baselineErrorCategories['metadataLimit'], 1);
    expect(audit.before.length, lessThanOrEqualTo(4096));

    final dirs = VirtualHome();
    for (var i = 0; i < 4096; i++) {
      dirs.dir('d$i');
    }
    expect((await prepareV1(dirs)).complete, true);
    dirs.file('x');
    expect((await prepareV1(dirs)).complete, false);

    final duplicates = VirtualHome()..file('one');
    duplicates.lister = (directory) async* {
      for (var i = 0; i < 5000; i++) {
        yield duplicates.path('one');
      }
    };
    audit = await prepareV1(duplicates);
    expect(audit.complete, false);
    expect(audit.baselineErrorCategories['metadataLimit'], 1);
    expect(audit.before.length, lessThanOrEqualTo(4096));
  });
  test('Codex changed artifacts: refusal upstream enumeration stops at the admission bound', () async {
    final h = VirtualHome();
    h.lister = (directory) async* {
      for (var i = 0; ; i++) {
        h.entries[h.path('n$i')] = (
          fileType,
          1,
          DateTime(2026),
          DateTime(2026),
        );
        yield h.path('n$i');
      }
    };
    final audit = await prepareV1(h);
    expect(audit.complete, false);
    expect(audit.baselineErrorCategories['metadataLimit'], 1);
    expect(h.pulled, lessThanOrEqualTo(4097));
  });
  test('Codex changed artifacts: refusal traversal is iterative and the pending list stays within the admission bound', () async {
    final chain = VirtualHome();
    chain.dir(List.generate(3000, (i) => 'c$i').join('/'));
    var audit = await prepareV1(chain);
    expect(audit.complete, true);
    expect(chain.maxDepth, greaterThanOrEqualTo(3000));
    expect(chain.maxPending, lessThanOrEqualTo(1));

    final wide = VirtualHome();
    for (var i = 0; i < 4000; i++) {
      wide.dir('w$i');
    }
    audit = await prepareV1(wide);
    expect(audit.complete, true);
    expect(wide.maxPending, lessThanOrEqualTo(4096));

    final overflow = VirtualHome();
    for (var i = 0; i < 4100; i++) {
      overflow.dir('w$i');
    }
    audit = await prepareV1(overflow);
    expect(audit.complete, false);
    expect(overflow.maxPending, lessThanOrEqualTo(4096));
    expect(overflow.listed.length, lessThanOrEqualTo(4097));
  });
  test('Codex changed artifacts: refusal selected files keep the unchanged byte and file rules', () async {
    final h = VirtualHome()..file('cache/a.bin');
    final audit = await prepareV1(h);
    h.resize('cache/a.bin', AuditBudget.defaults.maxFileBytes + 1);
    final (files, errors) = await audit.changedFiles();
    expect(errors, 0);
    final result = await ToolFileAudit(io: OversizeIo())
        .scan([files.single.path], 'ascii-canary-123');
    expect(result['complete'], false);
    expect((result['errorCategories'] as Map)['fileLimit'], 1);
    expect(result['scannedBytes'], 0);
    expect(result['readBytes'], 0);
  });

  // ---- Codex normal home: changed-artifacts-v2 ----
  VirtualHome wide({
    required int dirs,
    required int files,
    required int links,
  }) {
    final h = VirtualHome();
    for (var i = 0; i < dirs; i++) {
      h.dir('d$i');
    }
    for (var i = 0; i < files; i++) {
      h.file('f$i');
    }
    for (var i = 0; i < links; i++) {
      h.link('l$i', target: 't$i');
    }
    return h;
  }

  String longName(int i, int length) =>
      i.toString().padLeft(8, '0') + 'x' * (length - 8);

  Future<(NativeHomeAudit, List<File>, int)> walkV2(
    VirtualHome h,
    void Function() mutate,
  ) async {
    final audit = await prepareV2(h);
    expect(audit.complete, true, reason: '${audit.baselineErrorCategories}');
    mutate();
    final (files, errors) = await audit.changedFiles();
    return (audit, files, errors);
  }

  test('Codex normal home: admission accepts 4097 to 65,536 entries and v1 still stops at 4096', () async {
    for (final count in [4097, 13116]) {
      final h = wide(dirs: count ~/ 4, files: count ~/ 2, links: count ~/ 4);
      h.file('rest${'x' * 3}');
      final audit = await prepareV2(h);
      expect(
        audit.complete,
        true,
        reason: '$count ${audit.baselineErrorCategories}',
      );
      expect(audit.before.length, greaterThan(4096));
      final (_, errors) = await audit.changedFiles();
      expect(errors, 0, reason: '$count');
      final v1 = await prepareV1(h);
      expect(v1.complete, false, reason: '$count');
      expect(v1.baselineErrorCategories['metadataLimit'], 1);
      expect(v1.before.length, lessThanOrEqualTo(4096));
    }
  });
  test('Codex normal home: admission counts directories files links and duplicates and stops upstream at exactly 65,536', () async {
    Future<(NativeHomeAudit, VirtualHome)> run(int duplicates) async {
      final h = wide(dirs: 16384, files: 16384, links: 16384);
      final children = [
        for (final key in h.entries.keys)
          if (p.dirname(key) == h.root) key,
      ];
      h.lister = (directory) async* {
        if (directory != h.root) return;
        for (final child in children) {
          yield child;
        }
        for (var i = 0; i < duplicates; i++) {
          yield h.path('f0');
        }
      };
      return (await prepareV2(h), h);
    }

    final (exact, _) = await run(16384);
    expect(exact.complete, true, reason: '${exact.baselineErrorCategories}');
    expect(exact.before.length, 49152);
    final (over, h) = await run(16385);
    expect(over.complete, false);
    expect(over.baselineErrorCategories['metadataLimit'], 1);
    expect(over.before.length, lessThanOrEqualTo(65536));
    expect(h.pulled, lessThanOrEqualTo(65537));
    // Endless enumeration stops at the ceiling instead of growing.
    final endless = VirtualHome();
    endless.lister = (directory) async* {
      if (directory != endless.root) return;
      for (var i = 0; ; i++) {
        endless.entries[endless.path('n$i')] = (
          fileType,
          1,
          DateTime(2026),
          DateTime(2026),
        );
        yield endless.path('n$i');
      }
    };
    final audit = await prepareV2(endless);
    expect(audit.complete, false);
    expect(audit.baselineErrorCategories['metadataLimit'], 1);
    expect(endless.pulled, lessThanOrEqualTo(65537));
    expect(audit.before.length, lessThanOrEqualTo(65536));
  });

  test('Codex changed artifacts: refusal v4 keeps the 65,536 bound and protected removals incomplete', () async {
    final endless = VirtualHome();
    endless.lister = (directory) async* {
      if (directory != endless.root) return;
      for (var i = 0; ; i++) {
        endless.entries[endless.path('n$i')] = (
          fileType,
          1,
          DateTime(2026),
          DateTime(2026),
        );
        yield endless.path('n$i');
      }
    };
    final bounded = await NativeHomeAudit.prepare(
      endless.root,
      selection: NativeSelection.changedArtifactsV4,
      io: endless,
    );
    expect(bounded.complete, false);
    expect(bounded.baselineErrorCategories['metadataLimit'], 1);
    expect(endless.pulled, lessThanOrEqualTo(65537));
    expect(bounded.before.length, lessThanOrEqualTo(65536));

    final h = VirtualHome()
      ..file('auth.json')
      ..file('plain.txt');
    final audit = await NativeHomeAudit.prepare(
      h.root,
      selection: NativeSelection.changedArtifactsV4,
      io: h,
      caseInsensitiveNames: true,
    );
    expect(audit.complete, true);
    h.remove('auth.json');
    h.remove('plain.txt');
    final (files, errors) = await audit.changedFiles();
    expect(errors, 1);
    expect(audit.errorCategories['protectedEntry'], 1);
    expect(audit.selectionCounters['removedEntries'], 1);
    expect(files, isEmpty);
  });

  test('Codex normal home: an unchanged supported link is accounted for and never followed or listed', () async {
    final h = VirtualHome()
      ..file('a.bin')
      ..link('l1', target: 'PRIVATE_TARGET_ONE')
      ..link(
        'sub/l2',
        target: 'PRIVATE_TARGET_TWO',
        kind: NativeLinkKind.junction,
      );
    h.lister = (directory) {
      if (directory == h.path('l1') || directory == h.path('sub/l2')) {
        throw StateError('a link was listed');
      }
      return Stream.fromIterable([
        for (final key in h.entries.keys)
          if (p.dirname(key) == directory) key,
      ]);
    };
    final (audit, files, errors) = await walkV2(h, () {});
    expect(errors, 0);
    expect(files, isEmpty);
    expect(audit.before[h.path('l1')]!.$1, FileSystemEntityType.link);
    expect(audit.selectionCounters['linksAccounted'], 2);
    expect(h.observed.toSet(), {
      h.path('l1'),
      h.path('sub/l2'),
    }, reason: 'only link leaves are observed, nothing else is opened');
    expect(h.listed, isNot(contains(h.path('l1'))));
    expect(h.listed, isNot(contains(h.path('sub/l2'))));
  });
  test('Codex normal home: added removed and retargeted links keep the audit incomplete', () async {
    var (audit, _, errors) = await walkV2(VirtualHome(), () {});
    expect(errors, 0);
    final added = VirtualHome()..file('a.bin');
    (audit, _, errors) = await walkV2(added, () => added.link('new'));
    expect(errors, 1);
    expect(audit.errorCategories['changedUnknownFile'], 1);
    final removed = VirtualHome()..link('gone');
    (audit, _, errors) = await walkV2(removed, () => removed.remove('gone'));
    expect(errors, 1);
    expect(audit.errorCategories['removedEntry'], 1);
    final retargeted = VirtualHome()..link('l', target: 'before');
    (audit, _, errors) = await walkV2(
      retargeted,
      () => retargeted.link('l', target: 'after'),
    );
    expect(errors, 1);
    expect(audit.errorCategories['changedUnknownFile'], 1);
  });
  test('Codex normal home: link kind attributes and timestamps are compared and any change keeps the audit incomplete', () async {
    final variants = <String, void Function(VirtualHome)>{
      'kind': (h) => h.link('l', kind: NativeLinkKind.junction),
      'attributes': (h) => h.link('l', attributes: 0x410),
      'modified': (h) => h.link('l', modifiedMs: 9000),
    };
    for (final MapEntry(:key, :value) in variants.entries) {
      final h = VirtualHome()..link('l');
      final (audit, _, errors) = await walkV2(h, () => value(h));
      expect(errors, 1, reason: key);
      expect(audit.errorCategories['changedUnknownFile'], 1, reason: key);
    }
  });
  test('Codex normal home: link file and directory transitions at one path are changed entries', () async {
    final linkToFile = VirtualHome()..link('x');
    var (audit, _, errors) = await walkV2(linkToFile, () {
      linkToFile
        ..remove('x')
        ..file('x');
    });
    expect(errors, 1);
    expect(audit.errorCategories['changedUnknownFile'], 1);
    final fileToLink = VirtualHome()..file('x');
    (audit, _, errors) = await walkV2(fileToLink, () {
      fileToLink.remove('x');
      fileToLink.link('x');
    });
    expect(errors, 1);
    final dirToLink = VirtualHome()..dir('x');
    (audit, _, errors) = await walkV2(dirToLink, () {
      dirToLink.remove('x');
      dirToLink.link('x');
    });
    expect(errors, 1);
    final linkToDir = VirtualHome()..link('x');
    (audit, _, errors) = await walkV2(linkToDir, () {
      linkToDir
        ..remove('x')
        ..dir('x');
    });
    expect(errors, 1);
    expect(audit.errorCategories['changedUnknownFile'], 1);
  });
  test('Codex normal home: links named like protected leaves keep the protected rules', () async {
    for (final name in protectedNativeBasenames) {
      final unchanged = VirtualHome()..link('state/$name');
      var (audit, files, errors) = await walkV2(unchanged, () {});
      expect(errors, 0, reason: name);
      expect(files, isEmpty);
      expect(audit.selectionCounters['protectedMetadataOnly'], 1);
      final added = VirtualHome()..dir('state');
      (audit, files, errors) = await walkV2(
        added,
        () => added.link('state/$name'),
      );
      expect(errors, 1, reason: name);
      expect(audit.errorCategories['protectedEntry'], 1, reason: name);
      expect(audit.errorCategories['changedUnknownFile'], 0);
      final retargeted = VirtualHome()..link(name, target: 'a');
      (audit, files, errors) = await walkV2(
        retargeted,
        () => retargeted.link(name, target: 'b'),
      );
      expect(errors, 1);
      expect(audit.errorCategories['protectedEntry'], 1);
      final removed = VirtualHome()..link(name);
      (audit, files, errors) = await walkV2(
        removed,
        () => removed.remove(name),
      );
      expect(errors, 1);
      expect(audit.errorCategories['protectedEntry'], 1);
      expect(audit.errorCategories['removedEntry'], 0);
      final becomesFile = VirtualHome()..link(name);
      (audit, files, errors) = await walkV2(becomesFile, () {
        becomesFile
          ..remove(name)
          ..file(name);
      });
      expect(errors, 1);
      expect(audit.errorCategories['protectedEntry'], 1);
      expect(files, isEmpty, reason: 'a protected leaf is never selected');
      expect(audit.errorCategories.toString(), isNot(contains(name)));
    }
  });
  test('Codex normal home: other non-regular entries stay incomplete and nothing is observed for them', () async {
    final h = VirtualHome()
      ..file('ok.bin')
      ..entry('nested/pipe', FileSystemEntityType.pipe)
      ..entry('nested/socket', FileSystemEntityType.unixDomainSock);
    final audit = await prepareV2(h);
    expect(audit.complete, false);
    expect(audit.baselineErrorCategories['nonRegular'], 2);
    expect(h.observed, isEmpty);
  });
  test('Codex normal home: link target text and names never reach a category counter or limit', () async {
    final h = VirtualHome()
      ..file('PRIVATE_NAME.bin')
      ..link('PRIVATE_LINK', target: 'PRIVATE_TARGET_TEXT')
      ..link('PRIVATE_FAULT')
      ..link('PRIVATE_UNSUPPORTED');
    h.linkFaults.add(h.path('PRIVATE_FAULT'));
    final audit = await prepareV2(h);
    h
      ..link('PRIVATE_LINK', target: 'PRIVATE_RETARGETED')
      ..link('PRIVATE_ADDED', target: 'PRIVATE_ADDED_TARGET');
    await audit.changedFiles();
    final text =
        '${audit.errorCategories}${audit.ioErrorCategories}'
        '${audit.baselineErrorCategories}${audit.baselineIoErrorCategories}'
        '${audit.unknownArtifactCategories}${audit.selectionCounters}'
        '${audit.detectorLimits}';
    expect(text, isNot(contains('PRIVATE')));
    expect(text, isNot(contains(h.root)));
    expect(audit.baselineErrorCategories['linkObservation'], 1);
  });

  test(
    'Codex normal home: long paths and targets are bounded by 4096 UTF-8 bytes',
    () async {
      for (final (name, ok) in <(String, bool)>[
        ('a' * 4096, true),
        ('a' * 4097, false),
        ('é' * 2048, true),
        ('é' * 2049, false),
      ]) {
        final h = VirtualHome()..file(name);
        final audit = await prepareV2(h);
        expect(audit.complete, ok, reason: '${name.length}');
        if (!ok) {
          expect(audit.baselineErrorCategories['metadataStorage'], 1);
          expect(
            audit.before.length,
            0,
            reason: 'an over-long path is unadmitted',
          );
        }
      }
      // The bound applies to the relative path, not the leaf name.
      final nested = VirtualHome()..file('${'b' * 2000}/${'c' * 2200}');
      final audit = await prepareV2(nested);
      expect(audit.complete, false);
      expect(audit.baselineErrorCategories['metadataStorage'], 1);
      for (final (target, ok) in <(String, bool)>[
        ('t' * 4096, true),
        ('t' * 4097, false),
        ('é' * 2048, true),
        ('é' * 2049, false),
      ]) {
        final h = VirtualHome()..link('l', target: target);
        final linked = await prepareV2(h);
        expect(linked.complete, ok, reason: '${target.length}');
        if (!ok) {
          expect(linked.baselineErrorCategories['metadataStorage'], 1);
          expect(linked.before, isEmpty);
        }
      }
    },
  );
  test('Codex normal home: the per-inventory string budget is counted at UTF-8 length and stops enumeration upstream', () async {
    final h = VirtualHome();
    h.lister = (directory) async* {
      if (directory != h.root) return;
      for (var i = 0; ; i++) {
        final key = h.path(longName(i, 1000));
        h.entries[key] = (fileType, 1, DateTime(2026), DateTime(2026));
        yield key;
      }
    };
    final audit = await prepareV2(
      h,
      budget: const NativeStorageBudget(perInventory: 10000, combined: 100000),
    );
    expect(audit.complete, false);
    expect(audit.baselineErrorCategories['metadataStorage'], 1);
    expect(audit.baselineErrorCategories['metadataLimit'], 0);
    expect(audit.before.length, 5, reason: 'exactly the budget is admitted');
    expect(h.pulled, 6, reason: 'enumeration stops upstream at exhaustion');
    // Link target text is charged as well.
    final links = VirtualHome()
      ..link('l0', target: 't' * 1000)
      ..link('l1', target: 't' * 1000)
      ..link('l2', target: 't' * 1000);
    final linked = await prepareV2(
      links,
      budget: const NativeStorageBudget(perInventory: 3000, combined: 100000),
    );
    expect(linked.complete, false);
    expect(linked.baselineErrorCategories['metadataStorage'], 1);
    expect(linked.before.length, 2);
  });
  test('Codex normal home: the default per-inventory budget is 16 MiB and the combined budget 32 MiB', () async {
    const defaults = NativeStorageBudget();
    expect(defaults.perInventory, 16 * 1024 * 1024);
    expect(defaults.combined, 32 * 1024 * 1024);
    final h = VirtualHome();
    h.lister = (directory) async* {
      if (directory != h.root) return;
      for (var i = 0; ; i++) {
        final key = h.path(longName(i, 4000));
        h.entries[key] = (fileType, 1, DateTime(2026), DateTime(2026));
        yield key;
      }
    };
    final audit = await prepareV2(h);
    expect(audit.complete, false);
    expect(audit.baselineErrorCategories['metadataStorage'], 1);
    expect(audit.before.length, 2097);
    expect(h.pulled, 2098);
  });
  test('Codex normal home: the combined budget is exhausted while the baseline stays live', () async {
    final h = VirtualHome();
    for (var i = 0; i < 4; i++) {
      h.file(longName(i, 1000));
    }
    final audit = await prepareV2(
      h,
      budget: const NativeStorageBudget(perInventory: 10000, combined: 11999),
    );
    expect(audit.complete, true, reason: '${audit.baselineErrorCategories}');
    final (_, errors) = await audit.changedFiles();
    expect(errors, greaterThanOrEqualTo(1));
    expect(audit.errorCategories['metadataStorage'], 1);
    // The same walk fits when the baseline is not live.
    final roomy = await prepareV2(
      h,
      budget: const NativeStorageBudget(perInventory: 10000, combined: 100000),
    );
    expect((await roomy.changedFiles()).$2, 0);
  });
  test('Codex normal home: changed-artifacts-v1 has no string budget and no link support', () async {
    final h = VirtualHome();
    for (var i = 0; i < 1000; i++) {
      h.file(longName(i, 4000));
    }
    final audit = await prepareV1(h);
    expect(audit.complete, true);
    expect(audit.baselineErrorCategories.containsKey('metadataStorage'), false);
    expect(audit.baselineErrorCategories.containsKey('linkObservation'), false);
    expect(audit.detectorLimits, nativeDetectorLimits);
    final linked = VirtualHome()..link('l');
    final v1 = await prepareV1(linked);
    expect(v1.baselineErrorCategories['nonRegular'], 1);
    expect(linked.observed, isEmpty);
  });

  test('Codex normal home: failed unsupported and unavailable link observations record a content-free linkObservation error', () async {
    final h = VirtualHome()
      ..link('thrown')
      ..link('unsupported')
      ..link('fine');
    h.linkFaults.add(h.path('thrown'));
    h.linkOverride = (path) async {
      if (path == h.path('unsupported')) {
        return NativeLinkObservation(
          kind: NativeLinkKind.unsupported,
          attributes: 0x400,
          created: DateTime(2026),
          modified: DateTime(2026),
          target: 'PRIVATE_NEVER_READ',
        );
      }
      return h.linkObservations[path]!;
    };
    final audit = await prepareV2(h);
    expect(audit.complete, false);
    expect(audit.baselineErrorCategories['linkObservation'], 2);
    expect(audit.baselineErrorCategories['nonRegular'], 0);
    expect(
      audit.baselineIoErrorCategories.values.fold<int>(0, (a, b) => a + b),
      0,
    );
    expect(audit.before.containsKey(h.path('fine')), true);
    expect(audit.before.containsKey(h.path('thrown')), false);
    // An observation that fails only in the after inventory is incomplete too.
    final later = VirtualHome()..link('l');
    final base = await prepareV2(later);
    later.linkFaults.add(later.path('l'));
    final (_, errors) = await base.changedFiles();
    expect(errors, greaterThan(0));
    expect(base.errorCategories['linkObservation'], 1);
  });
  test('Codex normal home: links stay nonRegular where the observation is not implemented', () async {
    final h = VirtualHome()
      ..linksSupported = false
      ..link('l');
    final audit = await prepareV2(h);
    expect(audit.complete, false);
    expect(audit.baselineErrorCategories['nonRegular'], 1);
    expect(audit.baselineErrorCategories['linkObservation'], 0);
    expect(h.observed, isEmpty);
    expect(FsNativeInventoryIo(windows: false).supportsLinks, false);
    expect(FsNativeInventoryIo(windows: true).supportsLinks, true);
  });
  test('Codex normal home: the real seam rejects an unstable re-observation and every failure is content-free', () async {
    final first = (
      NativeLinkKind.symlink,
      0x400,
      DateTime.utc(2026, 1, 1),
      DateTime.utc(2026, 1, 2),
    );
    var reads = 0;
    final stable = FsNativeInventoryIo(
      windows: true,
      findData: (path) async => first,
      readTarget: (path) async {
        reads++;
        return 'PRIVATE_TARGET';
      },
    );
    final observed = await stable.observeLink('x');
    expect(observed.kind, NativeLinkKind.symlink);
    expect(observed.attributes, 0x400);
    expect(observed.target, 'PRIVATE_TARGET');
    expect(reads, 1);

    var n = 0;
    final unstable = FsNativeInventoryIo(
      windows: true,
      findData: (path) async => (
        NativeLinkKind.symlink,
        0x400,
        DateTime.utc(2026, 1, 1),
        DateTime.utc(2026, 1, 2 + n++),
      ),
      readTarget: (path) async => 'PRIVATE_TARGET',
    );
    final failures = <Future<NativeLinkObservation> Function()>[
      () => unstable.observeLink('PRIVATE_PATH'),
      () => FsNativeInventoryIo(
        windows: true,
        findData: (path) async => null,
        readTarget: (path) async => 'PRIVATE_TARGET',
      ).observeLink('PRIVATE_PATH'),
      () => FsNativeInventoryIo(
        windows: true,
        findData: (path) async => first,
        readTarget: (path) async =>
            throw FileSystemException('PRIVATE_TEXT', path),
      ).observeLink('PRIVATE_PATH'),
      () => FsNativeInventoryIo(
        windows: true,
        findData: (path) async =>
            throw FileSystemException('PRIVATE_TEXT', path),
        readTarget: (path) async => 'PRIVATE_TARGET',
      ).observeLink('PRIVATE_PATH'),
    ];
    for (final failure in failures) {
      Object? error;
      try {
        await failure();
      } on Object catch (e) {
        error = e;
      }
      expect(error, isNotNull);
      expect(error.toString(), isNot(contains('PRIVATE')));
    }
    // An unsupported kind is reported without reading its target.
    reads = 0;
    final alias = await FsNativeInventoryIo(
      windows: true,
      findData: (path) async => (
        NativeLinkKind.unsupported,
        0x400,
        DateTime.utc(2026),
        DateTime.utc(2026),
      ),
      readTarget: (path) async {
        reads++;
        return 'PRIVATE_TARGET';
      },
    ).observeLink('x');
    expect(alias.kind, NativeLinkKind.unsupported);
    expect(reads, 0);
    // Through the inventory: an unstable observation is a linkObservation error.
    final h = VirtualHome()..link('l');
    var m = 0;
    final seam = FsNativeInventoryIo(
      windows: true,
      findData: (path) async => (
        NativeLinkKind.junction,
        0x410,
        DateTime.utc(2026),
        DateTime.utc(2026, 1, 1, 0, 0, m++),
      ),
      readTarget: (path) async => 'PRIVATE_TARGET',
    );
    h.linkOverride = seam.observeLink;
    final audit = await prepareV2(h);
    expect(audit.complete, false);
    expect(audit.baselineErrorCategories['linkObservation'], 1);
  });

  void removeLink(String path) {
    try {
      Link(path).deleteSync();
    } on FileSystemException {
      // Already gone.
    }
  }

  void makeJunction(String link, String target) {
    final result = Process.runSync('cmd', [
      '/c',
      'mklink',
      '/J',
      link.replaceAll('/', r'\'),
      target.replaceAll('/', r'\'),
    ]);
    if (result.exitCode != 0) throw StateError('junction fixture failed');
  }

  test('Codex normal home: a real Windows junction at a path of 240 or more characters is observed', () async {
    final target = Directory.systemTemp.createTempSync('kumiko_native_v2_lt_');
    final deep = p.joinAll([
      home.path,
      for (var i = 0; i < 6; i++) 'segment_${'d' * 40}_$i',
    ]);
    // Created through the extended-length form so the depth is not refused.
    Directory('\\\\?\\$deep').createSync(recursive: true);
    final junction = p.join(deep, 'jlink');
    expect(junction.length, greaterThanOrEqualTo(240));
    addTearDown(() {
      removeLink('\\\\?\\$junction');
      target.deleteSync(recursive: true);
    });
    makeJunction('\\\\?\\$junction', target.path);
    final seen = await FsNativeInventoryIo().observeLink(junction);
    expect(seen.kind, NativeLinkKind.junction);
  }, skip: Platform.isWindows ? false : 'Windows junctions only');
  test('Codex normal home: a real Windows junction is observed without following it and is accounted for', () async {
    final target = Directory.systemTemp.createTempSync('kumiko_native_v2_jt_');
    final other = Directory.systemTemp.createTempSync('kumiko_native_v2_jo_');
    final junction = p.join(home.path, 'jlink');
    addTearDown(() {
      removeLink(junction);
      target.deleteSync(recursive: true);
      other.deleteSync(recursive: true);
    });
    File(p.join(target.path, 'sentinel.bin')).writeAsStringSync('PRIVATE');
    makeJunction(junction, target.path);
    File(p.join(home.path, 'plain.bin')).writeAsStringSync('p');
    final seen = await FsNativeInventoryIo().observeLink(junction);
    expect(seen.kind, NativeLinkKind.junction);
    expect(seen.attributes & 0x400, 0x400, reason: 'reparse point attribute');
    expect(
      p.windows.canonicalize(seen.target),
      p.windows.canonicalize(target.path),
    );
    final audit = await NativeHomeAudit.prepare(
      home.path,
      selection: NativeSelection.changedArtifactsV2,
    );
    expect(audit.complete, true, reason: '${audit.baselineErrorCategories}');
    expect(
      audit.before.keys.where((key) => key.contains('sentinel')),
      isEmpty,
      reason: 'the junction target is never traversed',
    );
    expect(audit.before[p.normalize(junction)]!.$1, FileSystemEntityType.link);
    var (files, errors) = await audit.changedFiles();
    expect(errors, 0);
    expect(files, isEmpty);
    expect(audit.selectionCounters['linksAccounted'], 1);
    // Retargeting the junction is detected.
    Directory(junction).deleteSync();
    makeJunction(junction, other.path);
    (files, errors) = await audit.changedFiles();
    expect(errors, 1);
    expect(audit.errorCategories['changedUnknownFile'], 1);
    // A dangling junction is still observed from its own record.
    Directory(junction).deleteSync();
    makeJunction(junction, target.path);
    target.deleteSync(recursive: true);
    final dangling = await NativeHomeAudit.prepare(
      home.path,
      selection: NativeSelection.changedArtifactsV2,
    );
    expect(
      dangling.complete,
      true,
      reason: '${dangling.baselineErrorCategories}',
    );
    expect(
      (await FsNativeInventoryIo().observeLink(junction)).kind,
      NativeLinkKind.junction,
    );
    target.createSync();
  }, skip: Platform.isWindows ? false : 'Windows junctions only');
  test('Codex normal home: real Windows symlinks to a directory and a file are observed without following them', () async {
    final target = Directory.systemTemp.createTempSync('kumiko_native_v2_st_');
    addTearDown(() => target.deleteSync(recursive: true));
    final file = File(p.join(target.path, 'file.bin'))..writeAsStringSync('x');
    final directoryLink = p.join(home.path, 'slink');
    final fileLink = p.join(home.path, 'flink');
    addTearDown(() {
      removeLink(directoryLink);
      removeLink(fileLink);
    });
    try {
      Link(directoryLink).createSync(target.path);
      Link(fileLink).createSync(file.path);
    } on FileSystemException catch (error) {
      markTestSkipped(
        'symlink creation refused by the OS (privilege), errno ${error.osError?.errorCode}',
      );
      return;
    }
    for (final (path, expected) in [
      (directoryLink, target.path),
      (fileLink, file.path),
    ]) {
      final seen = await FsNativeInventoryIo().observeLink(path);
      expect(seen.kind, NativeLinkKind.symlink);
      expect(
        p.windows.canonicalize(seen.target),
        p.windows.canonicalize(expected),
      );
    }
    final audit = await NativeHomeAudit.prepare(
      home.path,
      selection: NativeSelection.changedArtifactsV2,
    );
    expect(audit.complete, true, reason: '${audit.baselineErrorCategories}');
    expect(audit.before.keys.where((k) => k.contains('file.bin')), isEmpty);
    final (files, errors) = await audit.changedFiles();
    expect(errors, 0);
    expect(files, isEmpty);
    expect(audit.selectionCounters['linksAccounted'], 2);
    // Retargeting a symlink is detected.
    Link(directoryLink).updateSync(home.path);
    final (_, retargeted) = await audit.changedFiles();
    expect(retargeted, 1);
  }, skip: Platform.isWindows ? false : 'Windows symlink observation only');
  test('Codex normal home: where the OS observation is not implemented a real symlink stays nonRegular', () async {
    final target = Directory.systemTemp.createTempSync('kumiko_native_v2_nt_');
    addTearDown(() => target.deleteSync(recursive: true));
    final link = p.join(home.path, 'link');
    addTearDown(() => removeLink(link));
    try {
      Link(link).createSync(target.path);
    } on FileSystemException catch (error) {
      markTestSkipped(
        'symlink creation refused by the OS (privilege), errno ${error.osError?.errorCode}',
      );
      return;
    }
    final audit = await NativeHomeAudit.prepare(
      home.path,
      selection: NativeSelection.changedArtifactsV2,
      io: FsNativeInventoryIo(windows: false),
    );
    expect(audit.complete, false);
    expect(audit.baselineErrorCategories['nonRegular'], 1);
    expect(audit.baselineErrorCategories['linkObservation'], 0);
  });

  // ---- Codex native sockets: changed-artifacts-v3 ----
  Future<(NativeHomeAudit, List<File>, int)> walkV3(
    VirtualHome h,
    void Function() mutate,
  ) async {
    final audit = await prepareV3(h);
    expect(audit.complete, true, reason: '${audit.baselineErrorCategories}');
    mutate();
    final (files, errors) = await audit.changedFiles();
    return (audit, files, errors);
  }

  test('Codex native sockets: an unchanged socket is accounted for observed from its own record and never selected', () async {
    final h = VirtualHome()
      ..file('a.bin')
      ..socket('sock/PRIVATE.sock')
      ..link('l', target: 'PRIVATE_TARGET');
    final (audit, files, errors) = await walkV3(h, () {});
    expect(errors, 0);
    expect(files, isEmpty);
    expect(audit.selectionCounters['socketsAccounted'], 1);
    expect(audit.selectionCounters['socketsChanged'], 0);
    expect(audit.selectionCounters['linksAccounted'], 1);
    expect(audit.selectionCounters['selectedFiles'], 0);
    expect(
      audit.before[h.path('sock/PRIVATE.sock')]!.$1,
      FileSystemEntityType.unixDomainSock,
    );
    expect(audit.before[h.path('sock/PRIVATE.sock')]!.$2, 0x400);
    expect(h.socketsObserved.toSet(), {h.path('sock/PRIVATE.sock')});
    expect(h.observed.toSet(), {
      h.path('l'),
    }, reason: 'a socket never goes through the link observation');
    expect(h.listed, isNot(contains(h.path('sock/PRIVATE.sock'))));
  });
  test('Codex native sockets: added removed and metadata-changed sockets are counted without an error and never selected', () async {
    final added = VirtualHome()..file('a.bin');
    var (audit, files, errors) = await walkV3(
      added,
      () => added.socket('sock/new.sock'),
    );
    expect(errors, 0);
    expect(files, isEmpty);
    expect(audit.selectionCounters['socketsChanged'], 1);
    expect(audit.selectionCounters['socketsAccounted'], 0);
    final removed = VirtualHome()..socket('sock/old.sock');
    (audit, files, errors) = await walkV3(
      removed,
      () => removed.remove('sock/old.sock'),
    );
    expect(errors, 0);
    expect(files, isEmpty);
    expect(audit.errorCategories['removedEntry'], 0);
    expect(audit.selectionCounters['socketsChanged'], 1);
    expect(audit.selectionCounters['socketsAccounted'], 0);
    final variants = <String, void Function(VirtualHome)>{
      'attributes': (h) => h.socket('s.sock', attributes: 0x410),
      'modified': (h) => h.socket('s.sock', modifiedMs: 9000),
    };
    for (final MapEntry(:key, :value) in variants.entries) {
      final h = VirtualHome()..socket('s.sock');
      (audit, files, errors) = await walkV3(h, () => value(h));
      expect(errors, 0, reason: key);
      expect(files, isEmpty, reason: key);
      expect(audit.selectionCounters['socketsChanged'], 1, reason: key);
      expect(audit.selectionCounters['socketsAccounted'], 0, reason: key);
      expect(audit.errorCategories.values.every((v) => v == 0), true);
    }
    // Several at once are counted individually.
    final many = VirtualHome()
      ..socket('keep.sock')
      ..socket('gone.sock');
    (audit, _, errors) = await walkV3(many, () {
      many
        ..remove('gone.sock')
        ..socket('new1.sock')
        ..socket('new2.sock');
    });
    expect(errors, 0);
    expect(audit.selectionCounters['socketsAccounted'], 1);
    expect(audit.selectionCounters['socketsChanged'], 3);
  });
  test('Codex native sockets: sockets named like protected leaves follow the protected rule', () async {
    for (final name in protectedNativeBasenames) {
      final unchanged = VirtualHome()..socket('state/$name');
      var (audit, files, errors) = await walkV3(unchanged, () {});
      expect(errors, 0, reason: name);
      expect(files, isEmpty);
      expect(audit.selectionCounters['protectedMetadataOnly'], 1);
      expect(audit.selectionCounters['socketsAccounted'], 0);
      final added = VirtualHome()..dir('state');
      (audit, files, errors) = await walkV3(
        added,
        () => added.socket('state/$name'),
      );
      expect(errors, 1, reason: name);
      expect(audit.errorCategories['protectedEntry'], 1, reason: name);
      expect(audit.selectionCounters['socketsChanged'], 0);
      final changed = VirtualHome()..socket(name);
      (audit, files, errors) = await walkV3(
        changed,
        () => changed.socket(name, modifiedMs: 9999),
      );
      expect(errors, 1);
      expect(audit.errorCategories['protectedEntry'], 1);
      final removed = VirtualHome()..socket(name);
      (audit, files, errors) = await walkV3(
        removed,
        () => removed.remove(name),
      );
      expect(errors, 1);
      expect(audit.errorCategories['protectedEntry'], 1);
      expect(audit.errorCategories['removedEntry'], 0);
      expect(audit.selectionCounters['socketsChanged'], 0);
      expect(files, isEmpty);
      expect(audit.errorCategories.toString(), isNot(contains(name)));
    }
    // Case-insensitive on Windows only.
    final upper = VirtualHome()..socket('AUTH.JSON');
    final audit = await prepareV3(upper, caseInsensitive: true);
    upper.socket('AUTH.JSON', modifiedMs: 9999);
    final (_, errors) = await audit.changedFiles();
    expect(errors, 1);
    expect(audit.errorCategories['protectedEntry'], 1);
  });
  test('Codex native sockets: a transition between a socket and a file directory or link at one path is a changed entry in both directions', () async {
    final others = <String, void Function(VirtualHome, String)>{
      'file': (h, x) => h.file(x),
      'directory': (h, x) => h.dir(x),
      'link': (h, x) => h.link(x),
    };
    for (final MapEntry(:key, :value) in others.entries) {
      final toSocket = VirtualHome();
      value(toSocket, 'x');
      var (audit, files, errors) = await walkV3(toSocket, () {
        toSocket
          ..remove('x')
          ..socket('x');
      });
      expect(errors, 1, reason: '$key to socket');
      expect(audit.errorCategories['changedUnknownFile'], 1, reason: key);
      expect(audit.selectionCounters['socketsChanged'], 0, reason: key);
      expect(audit.selectionCounters['socketsAccounted'], 0, reason: key);
      expect(files, isEmpty);
      final fromSocket = VirtualHome()..socket('x');
      (audit, files, errors) = await walkV3(fromSocket, () {
        fromSocket.remove('x');
        value(fromSocket, 'x');
      });
      expect(errors, 1, reason: 'socket to $key');
      expect(audit.errorCategories['changedUnknownFile'], 1, reason: key);
      expect(audit.errorCategories['removedEntry'], 0);
      expect(audit.selectionCounters['socketsChanged'], 0, reason: key);
      expect(
        files.map((f) => p.relative(f.path, from: fromSocket.root)),
        key == 'file' ? ['x'] : isEmpty,
        reason: 'only a regular file that replaced a socket is selected',
      );
    }
  });
  test('Codex native sockets: v2 and operating systems without the observation keep every socket nonRegular', () async {
    final h = VirtualHome()
      ..file('ok.bin')
      ..socket('nested/a.sock');
    final v2 = await prepareV2(h);
    expect(v2.complete, false);
    expect(v2.baselineErrorCategories['nonRegular'], 1);
    expect(v2.baselineErrorCategories['linkObservation'], 0);
    expect(h.socketsObserved, isEmpty);
    final other = VirtualHome()
      ..linksSupported = false
      ..socket('nested/a.sock');
    final v3 = await prepareV3(other);
    expect(v3.complete, false);
    expect(v3.baselineErrorCategories['nonRegular'], 1);
    expect(v3.baselineErrorCategories['linkObservation'], 0);
    expect(other.socketsObserved, isEmpty);
    // v1 keeps its behaviour too, and a pipe stays nonRegular under v3.
    final v1 = await prepareV1(h);
    expect(v1.baselineErrorCategories['nonRegular'], 1);
    final pipe = VirtualHome()..entry('nested/pipe', FileSystemEntityType.pipe);
    final audit = await prepareV3(pipe);
    expect(audit.baselineErrorCategories['nonRegular'], 1);
    expect(pipe.socketsObserved, isEmpty);
    expect(pipe.observed, isEmpty);
    expect(FsNativeInventoryIo(windows: false).supportsLinks, false);
    await expectLater(
      FsNativeInventoryIo(windows: false).observeSocket('x'),
      throwsA(isA<Object>()),
    );
  });
  test('Codex native sockets: v3 counters and limits extend v2 and v1 v2 and legacy are unchanged', () async {
    final h = VirtualHome()..file('a.bin');
    final v3 = await prepareV3(h);
    await v3.changedFiles();
    expect(
      v3.selectionCounters.keys,
      containsAll(['linksAccounted', 'socketsAccounted', 'socketsChanged']),
    );
    expect(v3.detectorLimits.take(4), nativeDetectorLimitsV2);
    expect(v3.detectorLimits.length, 5);
    expect(v3.detectorLimits.last, contains('sockets'));
    final v2 = await prepareV2(h);
    await v2.changedFiles();
    expect(v2.selectionCounters.containsKey('socketsAccounted'), false);
    expect(v2.selectionCounters.containsKey('socketsChanged'), false);
    expect(v2.detectorLimits, nativeDetectorLimitsV2);
    expect(
      NativeSelection.named('changed-artifacts-v3'),
      NativeSelection.changedArtifactsV3,
    );
    expect(NativeSelection.changedArtifactsV3.wire, 'changed-artifacts-v3');
    for (final wire in ['changed-artifacts-v5', 'v3', '']) {
      expect(() => NativeSelection.named(wire), throwsFormatException);
    }
    final disclosure = changedArtifactsV3Disclosure;
    expect(disclosure, startsWith('changed-artifacts-v3 disclosure:'));
    expect(disclosure, isNot(changedArtifactsV2Disclosure));
    expect(disclosure, contains('Unix-domain sockets'));
    expect(disclosure, contains('without being opened'));
    expect(disclosure, contains('counted but not scanned'));
    expect(disclosure, contains('pipes, devices and unknown types'));
    expect(disclosure, contains('65,536'));
    expect(disclosure, contains('the owner pauses other Codex sessions'));
    expect(disclosure, isNot(contains('changed-artifacts-v2')));
  });
  test('Codex native sockets: a socket is charged only its relative path bytes like a file and no name reaches an output', () async {
    const name = 'sock/PRIVATE_NAME_SOCKET.sock';
    // A directory leaf costs 3x its path, a file or socket 2x its path.
    final limit = 'sock'.length * 3 + name.length * 2;
    for (final socket in [true, false]) {
      VirtualHome make() =>
          socket ? (VirtualHome()..socket(name)) : (VirtualHome()..file(name));
      final prepare = socket ? prepareV3 : prepareV2;
      final fits = await prepare(
        make(),
        budget: NativeStorageBudget(perInventory: limit, combined: limit * 2),
      );
      expect(
        fits.complete,
        true,
        reason: '$socket ${fits.baselineErrorCategories}',
      );
      final over = await prepare(
        make(),
        budget: NativeStorageBudget(
          perInventory: limit - 1,
          combined: limit * 2,
        ),
      );
      expect(over.complete, false, reason: '$socket');
      expect(over.baselineErrorCategories['metadataStorage'], 1);
    }
    // An over-long relative path is bounded like any other entry.
    final long = VirtualHome()..socket('${'a' * 4097}.sock');
    final bounded = await prepareV3(long);
    expect(bounded.complete, false);
    expect(bounded.baselineErrorCategories['metadataStorage'], 1);
    expect(long.socketsObserved, isEmpty);
    // Nothing about a socket reaches any category, counter or limit.
    final h = VirtualHome()
      ..socket('PRIVATE_DIR/PRIVATE_ONE.sock')
      ..socket('PRIVATE_FAULT.sock')
      ..socket('PRIVATE_WRONG.sock', kind: NativeLinkKind.symlink);
    h.socketFaults.add(h.path('PRIVATE_FAULT.sock'));
    final audit = await prepareV3(h);
    h
      ..socket('PRIVATE_DIR/PRIVATE_ONE.sock', modifiedMs: 9000)
      ..socket('PRIVATE_ADDED.sock');
    await audit.changedFiles();
    final text =
        '${audit.errorCategories}${audit.ioErrorCategories}'
        '${audit.baselineErrorCategories}${audit.baselineIoErrorCategories}'
        '${audit.unknownArtifactCategories}${audit.selectionCounters}'
        '${audit.detectorLimits}';
    expect(text, isNot(contains('PRIVATE')));
    expect(text, isNot(contains('.sock')));
    expect(text, isNot(contains(h.root)));
  });
  test('Codex native sockets: a failed or non-socket observation is a content-free linkObservation error in either inventory', () async {
    final h = VirtualHome()
      ..socket('thrown.sock')
      ..socket('wrongkind.sock', kind: NativeLinkKind.symlink)
      ..socket('unsupported.sock', kind: NativeLinkKind.unsupported)
      ..socket('junction.sock', kind: NativeLinkKind.junction)
      ..socket('fine.sock');
    h.socketFaults.add(h.path('thrown.sock'));
    final audit = await prepareV3(h);
    expect(audit.complete, false);
    expect(audit.baselineErrorCategories['linkObservation'], 4);
    expect(audit.baselineErrorCategories['nonRegular'], 0);
    expect(audit.before.containsKey(h.path('fine.sock')), true);
    expect(audit.before.containsKey(h.path('thrown.sock')), false);
    expect(
      audit.baselineIoErrorCategories.values.fold<int>(0, (a, b) => a + b),
      0,
    );
    // A link entry whose record says socket is refused too (kind confusion).
    final confused = VirtualHome()
      ..link('l')
      ..socket('s.sock');
    confused.linkOverride = (path) async =>
        confused.socketObservations[confused.path('s.sock')]!;
    final confusedAudit = await prepareV3(confused);
    expect(confusedAudit.baselineErrorCategories['linkObservation'], 1);
    // An observation failing only in the after inventory is incomplete too.
    final later = VirtualHome()..socket('s.sock');
    final base = await prepareV3(later);
    later.socketFaults.add(later.path('s.sock'));
    final (_, errors) = await base.changedFiles();
    expect(errors, greaterThan(0));
    expect(base.errorCategories['linkObservation'], 1);
  });
  test('Codex native sockets: the find-data mapping needs the reparse attribute and the AF_UNIX tag', () {
    DateTime t(int day) => DateTime.utc(2026, 1, day);
    WindowsFindRecord record({int attributes = 0x400, int tag = 0x80000023}) =>
        (
          attributes: attributes,
          created: t(1),
          modified: t(2),
          reparseTag: tag,
        );
    expect(nativeLinkFindFromRecord(record()), (
      NativeLinkKind.socket,
      0x400,
      t(1),
      t(2),
    ));
    expect(
      nativeLinkFindFromRecord(record(attributes: 0x410))!.$1,
      NativeLinkKind.socket,
    );
    expect(nativeLinkFindFromRecord(record(attributes: 0x20)), isNull);
    expect(nativeLinkFindFromRecord(null), isNull);
    expect(
      nativeLinkFindFromRecord(record(tag: 0xA000000C))!.$1,
      NativeLinkKind.symlink,
    );
    expect(
      nativeLinkFindFromRecord(record(tag: 0xA0000003))!.$1,
      NativeLinkKind.junction,
    );
    expect(
      nativeLinkFindFromRecord(record(tag: 0x80000024))!.$1,
      NativeLinkKind.unsupported,
    );
  });
  test('Codex native sockets: the real seam accepts only a stable AF_UNIX record and never reads a target', () async {
    final first = (
      NativeLinkKind.socket,
      0x400,
      DateTime.utc(2026, 1, 1),
      DateTime.utc(2026, 1, 2),
    );
    var reads = 0;
    Future<String> forbidden(String path) async {
      reads++;
      fail('a target was read for a socket');
    }

    var finds = 0;
    final stable = FsNativeInventoryIo(
      windows: true,
      findData: (path) async {
        finds++;
        return first;
      },
      readTarget: forbidden,
    );
    final observed = await stable.observeSocket('x');
    expect(observed.kind, NativeLinkKind.socket);
    expect(observed.attributes, 0x400);
    expect(observed.created, DateTime.utc(2026, 1, 1));
    expect(observed.modified, DateTime.utc(2026, 1, 2));
    expect(observed.target, '');
    expect(finds, 2, reason: 'the record is read, then read again');
    expect(reads, 0);

    var n = 0;
    final failures = <String, FsNativeInventoryIo>{
      'missing record': FsNativeInventoryIo(
        windows: true,
        findData: (path) async => null,
        readTarget: forbidden,
      ),
      'symlink tag': FsNativeInventoryIo(
        windows: true,
        findData: (path) async => (
          NativeLinkKind.symlink,
          0x400,
          DateTime.utc(2026),
          DateTime.utc(2026),
        ),
        readTarget: forbidden,
      ),
      'junction tag': FsNativeInventoryIo(
        windows: true,
        findData: (path) async => (
          NativeLinkKind.junction,
          0x400,
          DateTime.utc(2026),
          DateTime.utc(2026),
        ),
        readTarget: forbidden,
      ),
      'other tag': FsNativeInventoryIo(
        windows: true,
        findData: (path) async => (
          NativeLinkKind.unsupported,
          0x400,
          DateTime.utc(2026),
          DateTime.utc(2026),
        ),
        readTarget: forbidden,
      ),
      'differing re-observation': FsNativeInventoryIo(
        windows: true,
        findData: (path) async => (
          NativeLinkKind.socket,
          0x400,
          DateTime.utc(2026, 1, 1),
          DateTime.utc(2026, 1, 2 + n++),
        ),
        readTarget: forbidden,
      ),
      'tag changes on re-observation': FsNativeInventoryIo(
        windows: true,
        findData: (path) async => (
          (n++).isEven ? NativeLinkKind.socket : NativeLinkKind.symlink,
          0x400,
          DateTime.utc(2026),
          DateTime.utc(2026),
        ),
        readTarget: forbidden,
      ),
      'find fails': FsNativeInventoryIo(
        windows: true,
        findData: (path) async =>
            throw FileSystemException('PRIVATE_TEXT', path),
        readTarget: forbidden,
      ),
    };
    for (final MapEntry(:key, :value) in failures.entries) {
      Object? error;
      try {
        await value.observeSocket('PRIVATE_PATH');
      } on Object catch (e) {
        error = e;
      }
      expect(error, isA<NativeLinkObservationException>(), reason: key);
      expect(error.toString(), isNot(contains('PRIVATE')));
    }
    expect(reads, 0);
    // Through the inventory the accepted record is accounted for and each
    // failure is a linkObservation error, with no target read at all.
    final h = VirtualHome()..socket('s.sock');
    h.socketOverride = stable.observeSocket;
    final audit = await prepareV3(h);
    expect(audit.complete, true, reason: '${audit.baselineErrorCategories}');
    h.socketOverride = failures['differing re-observation']!.observeSocket;
    final broken = await prepareV3(h);
    expect(broken.complete, false);
    expect(broken.baselineErrorCategories['linkObservation'], 1);
    expect(reads, 0);
    // A link observation never accepts a socket record.
    await expectLater(
      FsNativeInventoryIo(
        windows: true,
        findData: (path) async => first,
        readTarget: forbidden,
      ).observeLink('x'),
      throwsA(isA<NativeLinkObservationException>()),
    );
    expect(reads, 0);
  });

  test(
    'Codex native sockets: a real Windows AF_UNIX socket is accounted for through the real find-data seam',
    () async {
      // The socket path must fit sockaddr_un (about 108 bytes), so the fixture
      // lives in its own short temporary folder rather than the test home.
      final root = Directory.systemTemp.createTempSync('kns');
      addTearDown(() => root.deleteSync(recursive: true));
      final nativeHome = Directory(p.join(root.path, 'h'))..createSync();
      final socketDir = Directory(p.join(nativeHome.path, 's'))..createSync();
      final socketPath = p.join(socketDir.path, 'a.sock');
      if (socketPath.length > 100) {
        markTestSkipped(
          'owned temporary folder too long for a socket path; Windows AF_UNIX acquisition stays unverified',
        );
        return;
      }
      File(p.join(nativeHome.path, 'plain.bin')).writeAsStringSync('p');
      ServerSocket server;
      try {
        server = await ServerSocket.bind(
          InternetAddress(socketPath, type: InternetAddressType.unix),
          0,
        );
      } on Object {
        markTestSkipped(
          'this machine cannot bind an AF_UNIX socket; Windows AF_UNIX acquisition stays unverified',
        );
        return;
      }
      var closed = false;
      Future<void> close() async {
        if (!closed) await server.close();
        closed = true;
      }

      addTearDown(close);
      expect(
        await FileSystemEntity.type(socketPath, followLinks: false),
        FileSystemEntityType.unixDomainSock,
      );
      final seen = await FsNativeInventoryIo().observeSocket(socketPath);
      expect(seen.kind, NativeLinkKind.socket);
      expect(seen.attributes & 0x400, 0x400, reason: 'reparse point attribute');
      expect(seen.target, '');
      final audit = await NativeHomeAudit.prepare(
        nativeHome.path,
        selection: NativeSelection.changedArtifactsV3,
      );
      expect(audit.complete, true, reason: '${audit.baselineErrorCategories}');
      expect(
        audit.before.values.where(
          (m) => m.$1 == FileSystemEntityType.unixDomainSock,
        ),
        hasLength(1),
      );
      var (files, errors) = await audit.changedFiles();
      expect(errors, 0, reason: '${audit.errorCategories}');
      expect(files, isEmpty);
      expect(audit.selectionCounters['socketsAccounted'], 1);
      expect(audit.selectionCounters['socketsChanged'], 0);
      // v2 over the same real home still refuses the socket.
      final v2 = await NativeHomeAudit.prepare(
        nativeHome.path,
        selection: NativeSelection.changedArtifactsV2,
      );
      expect(v2.complete, false);
      expect(v2.baselineErrorCategories['nonRegular'], 1);
      // A removed socket is counted, not an error.
      await close();
      // Closing the server removes the socket file; make sure it is gone.
      if (File(socketPath).existsSync()) File(socketPath).deleteSync();
      (files, errors) = await audit.changedFiles();
      expect(errors, 0, reason: '${audit.errorCategories}');
      expect(audit.selectionCounters['socketsChanged'], 1);
      expect(audit.selectionCounters['socketsAccounted'], 0);
    },
    skip: Platform.isWindows
        ? false
        : 'Windows AF_UNIX acquisition stays unverified off Windows',
  );

  // ---- Codex removed entries: changed-artifacts-v4 ----
  Future<NativeHomeAudit> prepareV4(
    VirtualHome h, {
    bool? caseInsensitive,
    NativeStorageBudget budget = const NativeStorageBudget(),
  }) => NativeHomeAudit.prepare(
    h.root,
    selection: NativeSelection.changedArtifactsV4,
    io: h,
    caseInsensitiveNames: caseInsensitive,
    budget: budget,
  );
  Future<(NativeHomeAudit, List<File>, int)> walkV4(
    VirtualHome h,
    void Function() mutate,
  ) async {
    final audit = await prepareV4(h);
    expect(audit.complete, true, reason: '${audit.baselineErrorCategories}');
    mutate();
    final (files, errors) = await audit.changedFiles();
    return (audit, files, errors);
  }

  test('Codex removed entries: a removed non-protected file directory link or socket is counted with no error and nothing selected', () async {
    final kinds = <String, void Function(VirtualHome)>{
      'file': (h) => h.file('cache/x.tmp'),
      'directory': (h) => h.dir('cache/x.tmp'),
      'link': (h) => h.link('cache/x.tmp', target: 'PRIVATE_T'),
      'socket': (h) => h.socket('cache/x.tmp'),
    };
    for (final MapEntry(:key, :value) in kinds.entries) {
      final h = VirtualHome()..file('keep.bin');
      value(h);
      final (audit, files, errors) = await walkV4(
        h,
        () => h.remove('cache/x.tmp'),
      );
      expect(errors, 0, reason: key);
      expect(files, isEmpty, reason: key);
      expect(audit.selectionCounters['removedEntries'], 1, reason: key);
      expect(audit.selectionCounters['selectedFiles'], 0, reason: key);
      expect(
        audit.errorCategories.values.every((v) => v == 0),
        true,
        reason: '$key ${audit.errorCategories}',
      );
    }
  });
  test('Codex removed entries: a removed directory with descendants counts every removed entry', () async {
    final h = VirtualHome()
      ..file('d/a.bin')
      ..file('d/sub/b.bin')
      ..link('d/l')
      ..socket('d/s.sock')
      ..file('keep.bin');
    final (audit, files, errors) = await walkV4(h, () {
      h
        ..remove('d/a.bin')
        ..remove('d/sub/b.bin')
        ..remove('d/sub')
        ..remove('d/l')
        ..remove('d/s.sock')
        ..remove('d');
    });
    expect(errors, 0, reason: '${audit.errorCategories}');
    expect(files, isEmpty);
    expect(audit.selectionCounters['removedEntries'], 6);
    expect(audit.selectionCounters['socketsChanged'], 0);
    expect(audit.errorCategories['removedEntry'], 0);
  });
  test('Codex removed entries: a removed protected file link or socket stays a protectedEntry error', () async {
    for (final name in protectedNativeBasenames) {
      final kinds = <String, void Function(VirtualHome, String)>{
        'file': (h, n) => h.file(n),
        'link': (h, n) => h.link(n),
        'socket': (h, n) => h.socket(n),
      };
      for (final MapEntry(:key, :value) in kinds.entries) {
        final h = VirtualHome();
        value(h, 'state/$name');
        final (audit, files, errors) = await walkV4(
          h,
          () => h.remove('state/$name'),
        );
        expect(errors, 1, reason: '$key $name');
        expect(audit.errorCategories['protectedEntry'], 1, reason: key);
        expect(audit.errorCategories['removedEntry'], 0, reason: key);
        expect(audit.selectionCounters['socketsChanged'], 0, reason: key);
        expect(files, isEmpty);
        expect(audit.errorCategories.toString(), isNot(contains(name)));
      }
    }
    // Case-insensitive on Windows only; a directory at such a name is not a
    // protected leaf.
    final upper = VirtualHome()..file('AUTH.JSON');
    final audit = await prepareV4(upper, caseInsensitive: true);
    upper.remove('AUTH.JSON');
    expect((await audit.changedFiles()).$2, 1);
    expect(audit.errorCategories['protectedEntry'], 1);
    final exact = VirtualHome()..file('AUTH.JSON');
    final posix = await prepareV4(exact, caseInsensitive: false);
    exact.remove('AUTH.JSON');
    expect((await posix.changedFiles()).$2, 0);
    expect(posix.selectionCounters['removedEntries'], 1);
    final directory = VirtualHome()..dir('auth.json');
    final dirAudit = await prepareV4(directory);
    directory.remove('auth.json');
    expect((await dirAudit.changedFiles()).$2, 0);
    expect(dirAudit.selectionCounters['removedEntries'], 1);
  });
  test('Codex removed entries: removal never hides an inventory error that drops entries', () async {
    // A metadata fault on one entry: it is dropped and counted as removed, and
    // the metadataIo error keeps the audit incomplete.
    var h = VirtualHome()
      ..file('cache/a.bin')
      ..file('cache/b.bin');
    var (audit, _, errors) = await walkV4(
      h,
      () => h.statFaults.add(h.path('cache/b.bin')),
    );
    expect(errors, 1);
    expect(audit.errorCategories['metadataIo'], 1);
    expect(audit.selectionCounters['removedEntries'], 1);
    // A traversal fault drops a directory's entries.
    h = VirtualHome()
      ..file('d/a.bin')
      ..file('d/b.bin');
    (audit, _, errors) = await walkV4(h, () {
      h.lister = (directory) async* {
        if (directory == h.path('d')) {
          throw const FileSystemException('synthetic list fault');
        }
        for (final key in h.entries.keys) {
          if (p.dirname(key) == directory) yield key;
        }
      };
    });
    expect(errors, 1);
    expect(audit.errorCategories['traversalIo'], 1);
    expect(audit.selectionCounters['removedEntries'], 2);
    // An after-run inventory over the admission ceiling.
    h = VirtualHome()..file('gone.bin');
    (audit, _, errors) = await walkV4(h, () {
      h.lister = (directory) async* {
        if (directory != h.root) return;
        for (var i = 0; ; i++) {
          final key = h.path('n$i');
          h.entries[key] = (fileType, 1, DateTime(2026), DateTime(2026));
          yield key;
        }
      };
    });
    expect(audit.errorCategories['metadataLimit'], 1);
    expect(errors, greaterThanOrEqualTo(1));
    expect(audit.selectionCounters['removedEntries'], 1);
    // The retained-string budget exhausted while the baseline stays live.
    h = VirtualHome();
    String name(int i) => 'n${'x' * 998}$i';
    for (var i = 0; i < 4; i++) {
      h.file(name(i));
    }
    final live = await prepareV4(
      h,
      budget: const NativeStorageBudget(perInventory: 10000, combined: 11999),
    );
    expect(live.complete, true, reason: '${live.baselineErrorCategories}');
    expect((await live.changedFiles()).$2, greaterThanOrEqualTo(1));
    expect(live.errorCategories['metadataStorage'], 1);
    expect(live.selectionCounters['removedEntries'], greaterThanOrEqualTo(1));
    // An incomplete baseline is still incomplete.
    final partial = VirtualHome()
      ..file('a.bin')
      ..entry('pipe', FileSystemEntityType.pipe);
    final baseline = await prepareV4(partial);
    expect(baseline.complete, false);
    expect((await baseline.changedFiles()).$2, greaterThanOrEqualTo(1));
    expect(baseline.errorCategories['baselineIncomplete'], 1);
  });
  test('Codex removed entries: a canary moved to a new file is selected and a move onto a protected leaf is an error', () async {
    final h = VirtualHome()
      ..file('sessions/2026/old.jsonl')
      ..file('plain.bin');
    final (audit, files, errors) = await walkV4(h, () {
      h
        ..remove('sessions/2026/old.jsonl')
        ..file('sessions/2026/new.jsonl')
        ..remove('plain.bin')
        ..file('moved.bin');
    });
    expect(errors, 0, reason: '${audit.errorCategories}');
    expect(relativeSet(h, files), {
      p.join('sessions', '2026', 'new.jsonl'),
      'moved.bin',
    });
    expect(audit.selectionCounters['removedEntries'], 2);
    final protectedMove = VirtualHome()..file('plain.bin');
    final (protectedAudit, protectedFiles, protectedErrors) = await walkV4(
      protectedMove,
      () => protectedMove
        ..remove('plain.bin')
        ..file('auth.json'),
    );
    expect(protectedErrors, 1);
    expect(protectedAudit.errorCategories['protectedEntry'], 1);
    expect(protectedFiles, isEmpty);
    expect(protectedAudit.selectionCounters['removedEntries'], 1);
  });
  test(
    'Codex removed entries: v3 v2 v1 and legacy keep their removal behaviour',
    () async {
      final v3h = VirtualHome()
        ..file('f.bin')
        ..dir('dd')
        ..link('l')
        ..socket('s.sock');
      final (v3, _, v3Errors) = await walkV3(v3h, () {
        v3h
          ..remove('f.bin')
          ..remove('dd')
          ..remove('l')
          ..remove('s.sock');
      });
      expect(v3Errors, 3);
      expect(v3.errorCategories['removedEntry'], 3);
      expect(v3.selectionCounters['socketsChanged'], 1);
      expect(v3.selectionCounters.containsKey('removedEntries'), false);
      // v2 and v1 keep removedEntry for everything they inventoried.
      for (final prepare in [prepareV2, prepareV1]) {
        final plain = VirtualHome()
          ..file('f.bin')
          ..dir('dd')
          ..link('l');
        final audit = await prepare(plain);
        plain
          ..remove('f.bin')
          ..remove('dd')
          ..remove('l');
        final (_, errors) = await audit.changedFiles();
        expect(audit.selectionCounters.containsKey('removedEntries'), false);
        expect(audit.errorCategories['removedEntry'], greaterThanOrEqualTo(2));
        expect(errors, greaterThanOrEqualTo(2));
      }
      // Legacy on a real directory.
      final real = Directory.systemTemp.createTempSync(
        'kumiko_removed_legacy_',
      );
      addTearDown(() => real.deleteSync(recursive: true));
      File(p.join(real.path, 'x.bin')).writeAsStringSync('x');
      final legacy = await NativeHomeAudit.prepare(real.path);
      File(p.join(real.path, 'x.bin')).deleteSync();
      final (_, legacyErrors) = await legacy.changedFiles();
      expect(legacyErrors, 1);
      expect(legacy.errorCategories['removedEntry'], 1);
      expect(legacy.selectionCounters.containsKey('removedEntries'), false);
    },
  );
  test(
    'Codex removed entries: v4 counters limits and disclosure extend v3',
    () async {
      final h = VirtualHome()..file('a.bin');
      final v4 = await prepareV4(h);
      await v4.changedFiles();
      expect(
        v4.selectionCounters.keys,
        containsAll([
          'linksAccounted',
          'socketsAccounted',
          'socketsChanged',
          'removedEntries',
        ]),
      );
      expect(v4.selectionCounters['removedEntries'], 0);
      expect(v4.detectorLimits.take(5), nativeDetectorLimitsV3);
      expect(v4.detectorLimits.length, 6);
      expect(v4.detectorLimits.last, contains('removed'));
      for (final other in [prepareV3, prepareV2, prepareV1]) {
        final audit = await other(h);
        await audit.changedFiles();
        expect(audit.selectionCounters.containsKey('removedEntries'), false);
      }
      expect(
        NativeSelection.named('changed-artifacts-v4'),
        NativeSelection.changedArtifactsV4,
      );
      expect(NativeSelection.changedArtifactsV4.wire, 'changed-artifacts-v4');
      for (final wire in ['changed-artifacts-v5', 'v4', '']) {
        expect(() => NativeSelection.named(wire), throwsFormatException);
      }
      final disclosure = changedArtifactsV4Disclosure;
      expect(disclosure, startsWith('changed-artifacts-v4 disclosure:'));
      expect(disclosure, isNot(changedArtifactsV3Disclosure));
      expect(disclosure, contains('Unix-domain sockets'));
      expect(disclosure, contains('65,536'));
      expect(
        disclosure,
        contains('a removed non-protected entry is counted but not scanned'),
      );
      expect(disclosure, contains('because no content remains'));
      expect(
        disclosure,
        contains('a removed protected entry still makes the audit incomplete'),
      );
      expect(disclosure, contains('the owner pauses other Codex sessions'));
      expect(disclosure, isNot(contains('changed-artifacts-v3')));
      expect(disclosure, isNot(contains('changed-artifacts-v2')));
      expect(
        changedArtifactsV3Disclosure,
        isNot(contains('removed non-protected')),
      );
    },
  );
  test(
    'Codex removed entries: no removed name or path reaches an output',
    () async {
      final h = VirtualHome()
        ..file('PRIVATE_DIR/PRIVATE_ONE.bin')
        ..link('PRIVATE_LINK', target: 'PRIVATE_TARGET')
        ..socket('PRIVATE_SOCK.sock')
        ..file('state/auth.json');
      final audit = await prepareV4(h);
      h
        ..remove('PRIVATE_DIR/PRIVATE_ONE.bin')
        ..remove('PRIVATE_DIR')
        ..remove('PRIVATE_LINK')
        ..remove('PRIVATE_SOCK.sock')
        ..remove('state/auth.json');
      await audit.changedFiles();
      final text =
          '${audit.errorCategories}${audit.ioErrorCategories}'
          '${audit.baselineErrorCategories}${audit.baselineIoErrorCategories}'
          '${audit.unknownArtifactCategories}${audit.selectionCounters}'
          '${audit.detectorLimits}';
      expect(text, isNot(contains('PRIVATE')));
      expect(text, isNot(contains('auth.json')));
      expect(text, isNot(contains(h.root)));
      expect(audit.selectionCounters['removedEntries'], 4);
      expect(audit.errorCategories['protectedEntry'], 1);
    },
  );
}
