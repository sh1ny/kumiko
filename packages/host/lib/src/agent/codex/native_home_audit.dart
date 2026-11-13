import 'dart:io';

import 'package:path/path.dart' as p;

import '../tool_file_audit.dart'
    show AuditIoErrorCounts, AuditMetadata, FileAuditIo;
import 'windows_find_data.dart';

/// Content-selection modes for the native-home audit (design D5).
enum NativeSelection {
  legacy('legacy'),
  changedArtifactsV1('changed-artifacts-v1'),
  changedArtifactsV2('changed-artifacts-v2'),
  changedArtifactsV3('changed-artifacts-v3'),
  changedArtifactsV4('changed-artifacts-v4');

  const NativeSelection(this.wire);
  final String wire;
  static NativeSelection named(String name) => switch (name) {
    'legacy' => legacy,
    'changed-artifacts-v1' => changedArtifactsV1,
    'changed-artifacts-v2' => changedArtifactsV2,
    'changed-artifacts-v3' => changedArtifactsV3,
    'changed-artifacts-v4' => changedArtifactsV4,
    _ => throw const FormatException('unknown native selection'),
  };
}

/// The closed set of credential/configuration leaf names that changed-
/// artifacts-v1 never reads (0.166.0 research record). No request or CLI
/// argument can add a name.
const protectedNativeBasenames = [
  'auth.json',
  'config.toml',
  '.credentials.json',
  'managed_config.toml',
  'requirements.toml',
  'environments.toml',
  '.env',
];

/// Windows compares names case-insensitively; elsewhere they are exact.
bool isProtectedNativeLeaf(String basename, {bool? windows}) {
  final insensitive = windows ?? Platform.isWindows;
  final name = insensitive ? basename.toLowerCase() : basename;
  return protectedNativeBasenames.contains(name);
}

const nativeDetectorLimits = <String>[
  'metadata-equality: unchanged ordinary files outside the always-scan set are not read',
  'ASCII/UTF-8: only the ASCII canary encoded as UTF-8 bytes is matched',
];

/// The canonical wider-read disclosure. Preparation prints it beside the
/// selection, limits and hash, and the manifest carries it as scan.nativeScope.
final String changedArtifactsDisclosure =
    'changed-artifacts-v1 disclosure: all native-home entry metadata is '
    'inventoried before and after the run; only leaves named '
    '${protectedNativeBasenames.join(', ')} (case-insensitive on Windows, '
    'exact elsewhere, at every depth) are metadata-only, and a new, changed '
    'or removed one makes the audit incomplete; every other new or changed '
    'regular file, including caches and any other credential-bearing store, '
    'plus the always-scan session/log/state files and SQLite/WAL/SHM files at '
    'every depth, is read in chunks into host memory and never printed; other '
    'credential-bearing stores may be read; unchanged ordinary files outside '
    'the always-scan set are not read (metadata-equality limit) and only the '
    'ASCII canary as UTF-8 bytes is matched (ASCII/UTF-8 limit).';

/// changed-artifacts-v2 adds the link and concurrent-writer limits.
const nativeDetectorLimitsV2 = <String>[
  ...nativeDetectorLimits,
  'unchanged-link: traversal through an unchanged link is excluded, so its target gets no coverage merely because the link is present; link equality is established at the two observation times only',
  'concurrent-writers: other processes that write the native home during the walk, such as other Codex sessions, are not distinguishable from the walked run',
];

/// The canonical v2 wider-read disclosure (owner-approved amendment
/// 2026-11-12). It differs from [changedArtifactsDisclosure] and is accepted
/// for no other selection.
final String changedArtifactsV2Disclosure =
    'changed-artifacts-v2 disclosure: all native-home entry metadata, up to '
    '65,536 entries per inventory within a 16 MiB retained-string budget '
    '(32 MiB for both inventories), is inventoried before and after the run; '
    'only leaves named ${protectedNativeBasenames.join(', ')} '
    '(case-insensitive on Windows, exact elsewhere, at every depth) are '
    'metadata-only, and a new, changed or removed one makes the audit '
    'incomplete; every other new or changed regular file, including caches and '
    'any other credential-bearing store, plus the always-scan session/log/state '
    'files and SQLite/WAL/SHM files at every depth, is read in chunks into host '
    'memory and never printed; other credential-bearing stores may be read; '
    'unchanged ordinary files outside the always-scan set are not read '
    '(metadata-equality limit) and only the ASCII canary as UTF-8 bytes is '
    'matched (ASCII/UTF-8 limit); a symlink or junction in the native home is '
    'recorded without being followed or read, and one whose kind, own metadata '
    'and target text (never printed) are identical in both inventories is '
    'accounted for, while an added, removed or changed link makes the audit '
    'incomplete; traversal through an unchanged link is excluded, so its '
    'target gets no coverage merely because the link is present (a target also '
    'reachable through an ordinary path inside the native home is still '
    'inventoried there); link equality is established at the two observation '
    'times only, so a retarget restored between them is not detected; other '
    'processes that write the native home during the walk, such as other Codex '
    'sessions, are not distinguishable from the walked run, their changed files '
    'are read under the same rules and their churn can make the audit '
    'incomplete; the owner pauses other Codex sessions for the walk; a canary '
    'match is a failure wherever it came from.';

/// changed-artifacts-v3 adds the socket limit to the v2 limits.
const nativeDetectorLimitsV3 = <String>[
  ...nativeDetectorLimitsV2,
  'sockets: Unix-domain sockets have no contents; they are recorded without being opened and an added, removed or changed socket is counted but not scanned',
];

/// The canonical v3 wider-read disclosure (owner-approved socket amendment
/// 2026-11-12): the v2 text under its own selection name plus the socket
/// clause. It is accepted for no other selection.
final String changedArtifactsV3Disclosure = changedArtifactsV2Disclosure
    .replaceFirst(
      'changed-artifacts-v2 disclosure:',
      'changed-artifacts-v3 disclosure:',
    )
    .replaceFirst(
      'other processes that write the native home',
      'Unix-domain sockets in the native home are recorded without being '
          'opened, and an added, removed or changed socket is counted but not '
          'scanned, because it has no contents, while pipes, devices and '
          'unknown types stay incomplete; other processes that write the '
          'native home',
    );

/// changed-artifacts-v4 adds the removal limit to the v3 limits.
const nativeDetectorLimitsV4 = <String>[
  ...nativeDetectorLimitsV3,
  'removals: a removed non-protected entry is counted but not scanned because no content remains; a removed protected entry still makes the audit incomplete',
];

/// The canonical v4 wider-read disclosure (owner-approved removed-entry
/// amendment 2026-11-12): the v3 text under its own selection name plus the
/// removal clause. It is accepted for no other selection.
final String changedArtifactsV4Disclosure = changedArtifactsV3Disclosure
    .replaceFirst(
      'changed-artifacts-v3 disclosure:',
      'changed-artifacts-v4 disclosure:',
    )
    .replaceFirst(
      'other processes that write the native home',
      'a removed non-protected entry is counted but not scanned, because no '
          'content remains, and does not make the audit incomplete, whether it '
          'was a file, directory, link or socket, which replaces the removed-link '
          'rule above, while a removed protected entry still makes the audit '
          'incomplete; other processes that write the native home',
    );

enum NativeLinkKind { symlink, junction, unsupported, socket }

/// A link observed without following it. Target text stays in host memory: it
/// is compared and never printed, persisted or hashed into output.
class NativeLinkObservation {
  const NativeLinkObservation({
    required this.kind,
    required this.attributes,
    required this.created,
    required this.modified,
    required this.target,
  });
  final NativeLinkKind kind;
  final int attributes;
  final DateTime created, modified;
  final String target;
}

/// A link's own find-data: kind, attributes, creation and last-write time.
typedef NativeLinkFind = (NativeLinkKind, int, DateTime, DateTime);

/// Counted UTF-8 retained-string budget of one v2 inventory (design D5). The
/// combined cap covers the live baseline plus the after-run inventory. Test
/// code may lower it through preparation; no host request can.
class NativeStorageBudget {
  const NativeStorageBudget({
    this.perInventory = 16 * 1024 * 1024,
    this.combined = 32 * 1024 * 1024,
  });
  final int perInventory, combined;
}

/// A failed link observation. Fixed text: no path, target or OS message.
class NativeLinkObservationException implements Exception {
  const NativeLinkObservationException();
  @override
  String toString() => 'link observation failed';
}

const _maxNativePathBytes = 4096;
const _nativeAdmissionV1 = 4096, _nativeAdmissionV2 = 65536;
const _reparseSymlink = 0xA000000C, _reparseMountPoint = 0xA0000003;
const _reparseAfUnix = 0x80000023; // IO_REPARSE_TAG_AF_UNIX
const _attributeReparsePoint = 0x400;

int _utf8Length(String value) {
  var bytes = 0;
  for (final rune in value.runes) {
    bytes += rune < 0x80
        ? 1
        : rune < 0x800
        ? 2
        : rune < 0x10000
        ? 3
        : 4;
  }
  return bytes;
}

/// Maps one find-data record to the link kind it describes. A record without
/// the reparse-point attribute is not a link or socket and maps to null, and
/// the reparse tag alone is never trusted without the attribute.
NativeLinkFind? nativeLinkFindFromRecord(WindowsFindRecord? record) {
  if (record == null || record.attributes & _attributeReparsePoint == 0) {
    return null;
  }
  return (
    switch (record.reparseTag) {
      _reparseSymlink => NativeLinkKind.symlink,
      _reparseMountPoint => NativeLinkKind.junction,
      _reparseAfUnix => NativeLinkKind.socket,
      _ => NativeLinkKind.unsupported,
    },
    record.attributes,
    record.created,
    record.modified,
  );
}

Future<NativeLinkFind?> _realFindData(String path) async =>
    nativeLinkFindFromRecord(windowsFindData(path));

Future<String> _realReadTarget(String path) => Link(path).target();

/// Injectable inventory I/O. Tests use it to observe traversal state; it is
/// never reachable through a host request.
abstract class NativeInventoryIo {
  Future<AuditMetadata> stat(String path);
  Stream<String> children(String path);
  void observe({required int pending, required int depth}) {}
  bool get supportsLinks => false;
  Future<NativeLinkObservation> observeLink(String path) =>
      throw UnsupportedError('no link observation');

  /// A Unix-domain socket observed from its own record only (v3). Never
  /// opens, connects to, follows or reads it.
  Future<NativeLinkObservation> observeSocket(String path) =>
      throw UnsupportedError('no socket observation');
}

class FsNativeInventoryIo extends NativeInventoryIo {
  /// Windows link observation is the entry's own find-data (FindFirstFileW),
  /// then the no-follow stored target, then the find-data again: a differing
  /// second record is an unstable observation. Elsewhere it is not
  /// implemented. [findData] and [readTarget] are test injection points.
  FsNativeInventoryIo({
    bool? windows,
    Future<NativeLinkFind?> Function(String path)? findData,
    Future<String> Function(String path)? readTarget,
  }) : _windows = windows ?? Platform.isWindows,
       _find = findData ?? _realFindData,
       _target = readTarget ?? _realReadTarget;
  final bool _windows;
  final Future<NativeLinkFind?> Function(String path) _find;
  final Future<String> Function(String path) _target;
  final _io = FileAuditIo();
  @override
  Future<AuditMetadata> stat(String path) => _io.stat(path);
  @override
  Stream<String> children(String path) => _io.children(path);
  @override
  bool get supportsLinks => _windows;
  @override
  Future<NativeLinkObservation> observeLink(String path) async {
    if (!_windows) throw UnsupportedError('no link observation');
    try {
      final first = await _find(path);
      if (first == null || first.$1 == NativeLinkKind.socket) {
        // A link observation never accepts a socket record.
        throw const NativeLinkObservationException();
      }
      if (first.$1 == NativeLinkKind.unsupported) {
        return NativeLinkObservation(
          kind: first.$1,
          attributes: first.$2,
          created: first.$3,
          modified: first.$4,
          target: '',
        );
      }
      final target = await _target(path);
      if (first != await _find(path)) {
        throw const NativeLinkObservationException();
      }
      return NativeLinkObservation(
        kind: first.$1,
        attributes: first.$2,
        created: first.$3,
        modified: first.$4,
        target: target,
      );
    } on NativeLinkObservationException {
      rethrow;
    } on Object {
      throw const NativeLinkObservationException();
    }
  }

  /// A socket is observed from its own find-data record only: the record, then
  /// the record again. It is never opened, connected to, followed or read, and
  /// no target is read. Only the AF_UNIX reparse tag is accepted, and a
  /// missing, other-tag or differing second record is an observation failure.
  @override
  Future<NativeLinkObservation> observeSocket(String path) async {
    if (!_windows) throw UnsupportedError('no socket observation');
    try {
      final first = await _find(path);
      if (first == null || first.$1 != NativeLinkKind.socket) {
        throw const NativeLinkObservationException();
      }
      if (first != await _find(path)) {
        throw const NativeLinkObservationException();
      }
      return NativeLinkObservation(
        kind: NativeLinkKind.socket,
        attributes: first.$2,
        created: first.$3,
        modified: first.$4,
        target: '',
      );
    } on NativeLinkObservationException {
      rethrow;
    } on Object {
      throw const NativeLinkObservationException();
    }
  }
}

/// Passive, explicitly opted-in test diagnostic. It reads metadata first and
/// selects only changed native session/log/state bytes for the retained grant's
/// existing bounded scanner. Credentials and configuration are never read.
class NativeHomeAudit {
  NativeHomeAudit._(
    this.home,
    this.before,
    this.complete,
    this.baselineErrorCategories,
    this.baselineIoErrorCategories, {
    this.selection = NativeSelection.legacy,
    this.baselineErrorCount = 0,
    this.inventory,
    this.caseInsensitiveNames = false,
    this.links = const {},
    this.retainedBytes = 0,
    this.budget = const NativeStorageBudget(),
  });
  final NativeSelection selection;
  final Map<String, (NativeLinkKind, String)> links;
  final int retainedBytes;
  final NativeStorageBudget budget;
  bool get _v4 => selection == NativeSelection.changedArtifactsV4;
  // Socket support: v3 and later.
  bool get _v3 => selection == NativeSelection.changedArtifactsV3 || _v4;
  bool get _v2 => selection == NativeSelection.changedArtifactsV2 || _v3;
  final int baselineErrorCount;
  final NativeInventoryIo? inventory;
  final bool caseInsensitiveNames;
  final Map<String, int> baselineErrorCategories, baselineIoErrorCategories;
  Map<String, int> errorCategories = const {},
      ioErrorCategories = const {},
      unknownArtifactCategories = const {};
  static Map<String, int> _categories({bool v2 = false}) => {
    for (final key in [
      'metadataLimit',
      'nonRegular',
      'metadataIo',
      'traversalIo',
      'baselineIncomplete',
      'removedEntry',
      'changedUnknownFile',
      'changedUnknownDirectory',
      'directoryUnstable',
      'protectedEntry',
      if (v2) ...['metadataStorage', 'linkObservation'],
    ])
      key: 0,
  };
  final String home;
  final Map<String, (FileSystemEntityType, int, DateTime, DateTime)> before;
  final bool complete;
  Map<String, int> selectionCounters = const {};
  List<String> get detectorLimits => switch (selection) {
    NativeSelection.changedArtifactsV1 => nativeDetectorLimits,
    NativeSelection.changedArtifactsV2 => nativeDetectorLimitsV2,
    NativeSelection.changedArtifactsV3 => nativeDetectorLimitsV3,
    NativeSelection.changedArtifactsV4 => nativeDetectorLimitsV4,
    NativeSelection.legacy => const [],
  };
  static const _directories = {'sessions', 'log', 'logs', 'state'};

  static Future<
    (
      Map<String, (FileSystemEntityType, int, DateTime, DateTime)>,
      int,
      Map<String, int>,
      Map<String, int>,
    )
  >
  _metadata(String home) async {
    final files = <String, (FileSystemEntityType, int, DateTime, DateTime)>{};
    var errors = 0;
    var entries = 0;
    final categories = _categories();
    final ioErrors = AuditIoErrorCounts();
    void fail(String category, [FileSystemException? error]) {
      errors++;
      categories[category] = categories[category]! + 1;
      if (error != null) ioErrors.record(error);
    }

    Future<void> inspect(String path, {required bool descend}) async {
      if (++entries > 4096) {
        fail('metadataLimit');
        return;
      }
      var stage = 'metadataIo';
      try {
        final type = await FileSystemEntity.type(path, followLinks: false);
        if (type != FileSystemEntityType.file &&
            type != FileSystemEntityType.directory) {
          fail('nonRegular');
          return;
        }
        final stat = await FileStat.stat(path);
        files[p.normalize(path)] = (
          type,
          stat.size,
          stat.modified,
          stat.changed,
        );
        if (type == FileSystemEntityType.directory && descend) {
          stage = 'traversalIo';
          await for (final child in Directory(path).list(followLinks: false)) {
            if (entries >= 4096) {
              fail('metadataLimit');
              break;
            }
            await inspect(child.path, descend: true);
          }
        }
      } on FileSystemException catch (error) {
        fail(stage, error);
      }
    }

    try {
      await for (final entry in Directory(home).list(followLinks: false)) {
        if (entries >= 4096) {
          fail('metadataLimit');
          break;
        }
        await inspect(
          entry.path,
          descend: _directories.contains(p.basename(entry.path)),
        );
      }
    } on FileSystemException catch (error) {
      fail('traversalIo', error);
    }
    return (files, errors, categories, Map<String, int>.of(ioErrors.counts));
  }

  /// Iterative, bounded metadata inventory for changed-artifacts-v1 and v2.
  /// Every admitted entry (directory, file, link or duplicate) counts against
  /// one ceiling (4096 for v1, 65,536 for v2); pending work is a stack of
  /// already admitted directories, never a recursion, and upstream enumeration
  /// stops at the ceiling. A directory metadata record is revalidated after its
  /// enumeration so a concurrent membership change cannot establish
  /// completeness.
  ///
  /// v2 also charges every retained string at its UTF-8 length against a
  /// counted budget (the absolute key, home prefix included, as deduplication
  /// key, as record key and, for a directory, as pending path, plus link target
  /// text). The 4096-byte admission bound applies to the relative path. Charges are
  /// cumulative, so the count is an upper bound of what is live at once. A path
  /// or target over 4096 bytes is unadmitted; exhausting the budget stops
  /// enumeration upstream. [priorRetained] is the live baseline's retained
  /// bytes while the after-run inventory is built. Links are recorded as
  /// no-follow leaves through [NativeInventoryIo.observeLink], never listed.
  static Future<
    (
      Map<String, (FileSystemEntityType, int, DateTime, DateTime)>,
      int,
      Map<String, int>,
      Map<String, int>,
      Map<String, (NativeLinkKind, String)>,
      int,
    )
  >
  _inventory(
    String home,
    NativeInventoryIo io, {
    bool v2 = false,
    bool sockets = false,
    NativeStorageBudget budget = const NativeStorageBudget(),
    int priorRetained = 0,
  }) async {
    final files = <String, (FileSystemEntityType, int, DateTime, DateTime)>{};
    final links = <String, (NativeLinkKind, String)>{};
    var errors = 0, admitted = 0, charged = 0, retained = 0;
    var stopped = false;
    final ceiling = v2 ? _nativeAdmissionV2 : _nativeAdmissionV1;
    final storageLimit = budget.combined - priorRetained < budget.perInventory
        ? budget.combined - priorRetained
        : budget.perInventory;
    final categories = _categories(v2: v2);
    final ioErrors = AuditIoErrorCounts();
    void fail(String category, [FileSystemException? error]) {
      errors++;
      categories[category] = categories[category]! + 1;
      if (error != null) ioErrors.record(error);
    }

    bool charge(int bytes) {
      if (charged + bytes > storageLimit) return false;
      charged += bytes;
      return true;
    }

    void exhausted() {
      fail('metadataStorage');
      stopped = true;
    }

    final seen = <String>{};
    final pending = <(String, int, AuditMetadata)>[];
    try {
      final root = await io.stat(home);
      if (root.$1 != FileSystemEntityType.directory) {
        fail('nonRegular');
      } else {
        pending.add((home, 0, root));
        io.observe(pending: pending.length, depth: 0);
      }
    } on FileSystemException catch (error) {
      fail('metadataIo', error);
    }
    while (pending.isNotEmpty && !stopped) {
      final (directory, depth, recorded) = pending.removeLast();
      var stage = 'traversalIo';
      try {
        await for (final child in io.children(directory)) {
          if (admitted == ceiling) {
            fail('metadataLimit');
            stopped = true;
            break;
          }
          admitted++;
          final key = p.normalize(child);
          var pathBytes = 0;
          if (v2) {
            if (_utf8Length(p.relative(key, from: home)) >
                _maxNativePathBytes) {
              fail('metadataStorage');
              continue;
            }
            // The retained strings are absolute keys, so the home prefix is
            // charged with every entry.
            pathBytes = _utf8Length(key);
          }
          if (!seen.add(key)) continue;
          if (v2 && !charge(pathBytes)) {
            exhausted();
            break;
          }
          stage = 'metadataIo';
          final metadata = await io.stat(key);
          stage = 'traversalIo';
          if (metadata.$1 == FileSystemEntityType.directory) {
            // The record key and the pending path.
            if (v2 && !charge(pathBytes * 2)) {
              exhausted();
              break;
            }
            retained += pathBytes;
            files[key] = metadata;
            pending.add((key, depth + 1, metadata));
            io.observe(pending: pending.length, depth: depth + 1);
          } else if (metadata.$1 == FileSystemEntityType.file) {
            if (v2 && !charge(pathBytes)) {
              exhausted();
              break;
            }
            retained += pathBytes;
            files[key] = metadata;
          } else if (v2 &&
              metadata.$1 == FileSystemEntityType.link &&
              io.supportsLinks) {
            NativeLinkObservation? observation;
            try {
              observation = await io.observeLink(key);
            } on Object {
              // Content-free: no exception text, path or target is kept.
              observation = null;
            }
            if (observation == null ||
                observation.kind == NativeLinkKind.unsupported ||
                observation.kind == NativeLinkKind.socket) {
              fail('linkObservation');
              continue;
            }
            final targetBytes = _utf8Length(observation.target);
            if (targetBytes > _maxNativePathBytes) {
              fail('metadataStorage');
              continue;
            }
            if (!charge(pathBytes + targetBytes)) {
              exhausted();
              break;
            }
            retained += pathBytes + targetBytes;
            files[key] = (
              FileSystemEntityType.link,
              observation.attributes,
              observation.modified,
              observation.created,
            );
            links[key] = (observation.kind, observation.target);
          } else if (sockets &&
              metadata.$1 == FileSystemEntityType.unixDomainSock &&
              io.supportsLinks) {
            // v3: a socket is recorded from its own record and never opened.
            NativeLinkObservation? observation;
            try {
              observation = await io.observeSocket(key);
            } on Object {
              // Content-free: no exception text, path or name is kept.
              observation = null;
            }
            if (observation == null ||
                observation.kind != NativeLinkKind.socket) {
              fail('linkObservation');
              continue;
            }
            if (!charge(pathBytes)) {
              exhausted();
              break;
            }
            retained += pathBytes;
            files[key] = (
              FileSystemEntityType.unixDomainSock,
              observation.attributes,
              observation.modified,
              observation.created,
            );
          } else {
            fail('nonRegular');
          }
        }
        if (stopped) break;
        stage = 'metadataIo';
        if (await io.stat(directory) != recorded) fail('directoryUnstable');
      } on FileSystemException catch (error) {
        fail(stage, error);
      }
    }
    return (
      files,
      errors,
      categories,
      Map<String, int>.of(ioErrors.counts),
      links,
      retained,
    );
  }

  static Future<NativeHomeAudit> prepare(
    String home, {
    NativeSelection selection = NativeSelection.legacy,
    NativeInventoryIo? io,
    bool? caseInsensitiveNames,
    NativeStorageBudget budget = const NativeStorageBudget(),
  }) async {
    final wider = selection != NativeSelection.legacy;
    final v3 =
        selection == NativeSelection.changedArtifactsV3 ||
        selection == NativeSelection.changedArtifactsV4;
    final v2 = selection == NativeSelection.changedArtifactsV2 || v3;
    final inventoryIo = io ?? FsNativeInventoryIo();
    final String canonical;
    if (wider && io != null) {
      // Test-only injected inventory: there is no real directory to resolve.
      canonical = p.normalize(home);
    } else {
      if (await FileSystemEntity.type(home, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw const FileSystemException(
          'native audit root is not an ordinary directory',
        );
      }
      canonical = await Directory(home).resolveSymbolicLinks();
    }
    final (files, errors, categories, ioErrors, links, retained) = wider
        ? await _inventory(
            canonical,
            inventoryIo,
            v2: v2,
            sockets: v3,
            budget: budget,
          )
        : await _metadata(canonical).then(
            (m) => (
              m.$1,
              m.$2,
              m.$3,
              m.$4,
              const <String, (NativeLinkKind, String)>{},
              0,
            ),
          );
    return NativeHomeAudit._(
      canonical,
      Map.unmodifiable(files),
      errors == 0,
      Map.unmodifiable(categories),
      Map.unmodifiable(ioErrors),
      selection: selection,
      baselineErrorCount: errors,
      inventory: wider ? inventoryIo : null,
      caseInsensitiveNames: caseInsensitiveNames ?? Platform.isWindows,
      links: Map.unmodifiable(links),
      retainedBytes: retained,
      budget: budget,
    );
  }

  static final _sqliteFamily = RegExp(r'\.sqlite(?:-wal|-shm)?$');

  Future<(List<File>, int)> _changedArtifacts() async {
    final (
      after,
      initialErrors,
      categories,
      ioErrors,
      afterLinks,
      _,
    ) = await _inventory(
      home,
      inventory!,
      v2: _v2,
      sockets: _v3,
      budget: budget,
      priorRetained: retainedBytes,
    );
    var errors = initialErrors + (complete ? 0 : 1);
    categories['baselineIncomplete'] = complete ? 0 : 1;
    final selected = <File>[];
    var changedFiles = 0,
        alwaysScan = 0,
        protectedOnly = 0,
        directories = 0,
        linksAccounted = 0,
        socketsAccounted = 0,
        socketsChanged = 0,
        removedEntries = 0;
    for (final entry in before.entries) {
      if (after.containsKey(entry.key)) continue;
      final removedSocket =
          entry.value.$1 == FileSystemEntityType.unixDomainSock;
      final protected =
          (entry.value.$1 == FileSystemEntityType.file ||
              entry.value.$1 == FileSystemEntityType.link ||
              removedSocket) &&
          isProtectedNativeLeaf(
            p.basename(entry.key),
            windows: caseInsensitiveNames,
          );
      if (_v4 && !protected) {
        // v4: nothing remains on disk to hold a canary. Counted, no error. A
        // removed non-protected socket counts here and not in socketsChanged.
        removedEntries++;
        continue;
      }
      if (!_v4 && removedSocket && !protected) {
        // v3: a socket carries no bytes a canary could be in: counted, no error.
        socketsChanged++;
        continue;
      }
      errors++;
      final category = protected ? 'protectedEntry' : 'removedEntry';
      categories[category] = categories[category]! + 1;
    }
    for (final entry in after.entries) {
      final isLink = entry.value.$1 == FileSystemEntityType.link;
      final isSocket = entry.value.$1 == FileSystemEntityType.unixDomainSock;
      final wasLink = before[entry.key]?.$1 == FileSystemEntityType.link;
      final wasSocket =
          before[entry.key]?.$1 == FileSystemEntityType.unixDomainSock;
      final linkName = p.basename(entry.key);
      if (isSocket) {
        // A socket is a no-follow leaf with no contents: accounted for when its
        // own metadata equals the baseline's, counted as changed when it is
        // new or its metadata differs. Never selected.
        final protected = isProtectedNativeLeaf(
          linkName,
          windows: caseInsensitiveNames,
        );
        final existed = before.containsKey(entry.key);
        final unchanged = wasSocket && before[entry.key] == entry.value;
        if (protected) {
          if (unchanged) {
            protectedOnly++;
          } else {
            errors++;
            categories['protectedEntry'] = categories['protectedEntry']! + 1;
          }
        } else if (existed && !wasSocket) {
          // A transition from a file, directory or link is a changed entry.
          errors++;
          categories['changedUnknownFile'] =
              categories['changedUnknownFile']! + 1;
        } else if (unchanged) {
          socketsAccounted++;
        } else {
          socketsChanged++;
        }
        continue;
      }
      if (isLink) {
        // A link is a no-follow leaf: accounted for only when its kind, own
        // metadata and target text equal the baseline's. Never selected.
        final unchanged =
            wasLink &&
            before[entry.key] == entry.value &&
            links[entry.key] == afterLinks[entry.key];
        if (isProtectedNativeLeaf(linkName, windows: caseInsensitiveNames)) {
          if (unchanged) {
            protectedOnly++;
          } else {
            errors++;
            categories['protectedEntry'] = categories['protectedEntry']! + 1;
          }
        } else if (unchanged) {
          linksAccounted++;
        } else {
          errors++;
          categories['changedUnknownFile'] =
              categories['changedUnknownFile']! + 1;
        }
        continue;
      }
      if ((wasLink || wasSocket) &&
          !isProtectedNativeLeaf(linkName, windows: caseInsensitiveNames)) {
        // A link or socket replaced by a file or directory is a changed entry.
        errors++;
        categories['changedUnknownFile'] =
            categories['changedUnknownFile']! + 1;
      }
      if (entry.value.$1 == FileSystemEntityType.directory) {
        directories++;
        continue;
      }
      final parts = p.split(p.relative(entry.key, from: home));
      final name = parts.last;
      final changed = before[entry.key] != entry.value;
      if (isProtectedNativeLeaf(name, windows: caseInsensitiveNames)) {
        // Metadata-only: never selected, even under an always-scan path.
        if (changed) {
          errors++;
          categories['protectedEntry'] = categories['protectedEntry']! + 1;
        } else {
          protectedOnly++;
        }
        continue;
      }
      final family = _sqliteFamily.hasMatch(name);
      final stateFile =
          parts.length == 1 &&
          (family ||
              p.extension(name) == '.jsonl' ||
              (name.contains('state') && p.extension(name) == '.json'));
      final knownDirectory = _directories.contains(parts.first);
      final changedSession = parts.first == 'sessions' && changed;
      final mutableArtifact =
          knownDirectory && (parts.first != 'sessions' || family);
      final legacyScan =
          (parts.length > 1 && (changedSession || mutableArtifact)) ||
          stateFile;
      if (changed) changedFiles++;
      if (legacyScan || family) alwaysScan++;
      if (changed || legacyScan || family) selected.add(File(entry.key));
    }
    errorCategories = Map.unmodifiable(categories);
    ioErrorCategories = Map.unmodifiable(ioErrors);
    unknownArtifactCategories = Map.unmodifiable({
      for (final key in [
        'credential',
        'config',
        'modelCache',
        'versionCache',
        'tempDirectory',
        'otherFile',
        'otherDirectory',
      ])
        key: 0,
    });
    selectionCounters = Map.unmodifiable({
      'inventoryEntries': after.length,
      'directoriesAccounted': directories,
      'changedFiles': changedFiles,
      'alwaysScanFiles': alwaysScan,
      'protectedMetadataOnly': protectedOnly,
      'selectedFiles': selected.length,
      if (_v2) 'linksAccounted': linksAccounted,
      if (_v3) ...{
        'socketsAccounted': socketsAccounted,
        'socketsChanged': socketsChanged,
      },
      if (_v4) 'removedEntries': removedEntries,
    });
    return (selected, errors);
  }

  Future<(List<File>, int)> changedFiles() async {
    if (selection != NativeSelection.legacy) {
      return _changedArtifacts();
    }
    final (after, initialErrors, categories, ioErrors) = await _metadata(home);
    var errors = initialErrors + (complete ? 0 : 1);
    categories['baselineIncomplete'] = complete ? 0 : 1;
    final artifacts = <String, int>{
      for (final key in [
        'credential',
        'config',
        'modelCache',
        'versionCache',
        'tempDirectory',
        'otherFile',
        'otherDirectory',
      ])
        key: 0,
    };
    final selected = <File>[];
    final removed = before.keys
        .where((path) => !after.containsKey(path))
        .length;
    errors += removed;
    categories['removedEntry'] = removed;
    for (final entry in after.entries) {
      final parts = p.split(p.relative(entry.key, from: home));
      final name = parts.last;
      final stateFile =
          parts.length == 1 &&
          (RegExp(r'\.sqlite(?:-wal|-shm)?$').hasMatch(name) ||
              p.extension(name) == '.jsonl' ||
              (name.contains('state') && p.extension(name) == '.json'));
      final knownDirectory = _directories.contains(parts.first);
      final changedSession =
          parts.first == 'sessions' && before[entry.key] != entry.value;
      final mutableArtifact =
          knownDirectory &&
          (parts.first != 'sessions' ||
              RegExp(r'\.sqlite(?:-wal|-shm)?$').hasMatch(name));
      if (entry.value.$1 == FileSystemEntityType.file &&
          ((parts.length > 1 && (changedSession || mutableArtifact)) ||
              stateFile)) {
        selected.add(File(entry.key));
      } else if (before[entry.key] != entry.value && !knownDirectory) {
        // A new/changed unrecognized artifact cannot be declared clean by
        // exclusion. In particular never read auth or config as a shortcut.
        errors++;
        final directory = entry.value.$1 == FileSystemEntityType.directory;
        final category = directory
            ? 'changedUnknownDirectory'
            : 'changedUnknownFile';
        categories[category] = categories[category]! + 1;
        final artifact = parts.length == 1
            ? switch (name) {
                'auth.json' when !directory => 'credential',
                'config.toml' when !directory => 'config',
                'models_cache.json' when !directory => 'modelCache',
                'version.json' when !directory => 'versionCache',
                'tmp' when directory => 'tempDirectory',
                _ => directory ? 'otherDirectory' : 'otherFile',
              }
            : directory
            ? 'otherDirectory'
            : 'otherFile';
        artifacts[artifact] = artifacts[artifact]! + 1;
      }
    }
    errorCategories = Map.unmodifiable(categories);
    ioErrorCategories = Map.unmodifiable(ioErrors);
    unknownArtifactCategories = Map.unmodifiable(artifacts);
    return (selected, errors);
  }
}
