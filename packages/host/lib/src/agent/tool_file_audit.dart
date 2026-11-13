import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// Internal filesystem seam: never accepted through a host request.
typedef AuditMetadata = (FileSystemEntityType, int, DateTime, DateTime);

abstract interface class AuditReader {
  Future<Uint8List> read(int count);
  Future<void> close();
}

abstract interface class AuditIo {
  Future<AuditMetadata> stat(String path);
  Stream<String> children(String path);
  Future<AuditReader> open(String path);
}

class FileAuditIo implements AuditIo {
  @override
  Future<AuditMetadata> stat(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.directory) {
      return (
        type,
        0,
        DateTime.fromMillisecondsSinceEpoch(0),
        DateTime.fromMillisecondsSinceEpoch(0),
      );
    }
    final s = await FileStat.stat(path);
    return (type, s.size, s.modified, s.changed);
  }

  @override
  Stream<String> children(String path) =>
      Directory(path).list(followLinks: false).map((entry) => entry.path);
  @override
  Future<AuditReader> open(String path) async =>
      _Reader(await File(path).open());
}

class _Reader implements AuditReader {
  _Reader(this.file);
  final RandomAccessFile file;
  @override
  Future<Uint8List> read(int count) => file.read(count);
  @override
  Future<void> close() => file.close();
}

class AuditBudget {
  const AuditBudget._(this.auditProfile, this.maxFileBytes, this.maxTotalBytes);
  static const defaults = AuditBudget._(
    'default',
    16 * 1024 * 1024,
    32 * 1024 * 1024,
  );
  static const large = AuditBudget._(
    'large-native-home',
    256 * 1024 * 1024,
    512 * 1024 * 1024,
  );
  final String auditProfile;
  final int maxFileBytes, maxTotalBytes;
  static AuditBudget named(String name) => switch (name) {
    'default' => defaults,
    'large-native-home' => large,
    _ => throw const FormatException('unknown audit profile'),
  };
  Map<String, Object?> get echo => {
    'auditProfile': auditProfile,
    'maxFiles': 4096,
    'maxFileBytes': maxFileBytes,
    'maxTotalBytes': maxTotalBytes,
  };
}

class AuditIoErrorCounts {
  final counts = <String, int>{
    'sharingViolation': 0,
    'lockViolation': 0,
    'accessDenied': 0,
    'other': 0,
  };
  void record(FileSystemException error) {
    final code = error.osError?.errorCode;
    final key = switch ((Platform.isWindows, code)) {
      (true, 32) => 'sharingViolation',
      (true, 33) => 'lockViolation',
      (true, 5) || (_, 13) => 'accessDenied',
      _ => 'other',
    };
    counts[key] = counts[key]! + 1;
  }
}

class ToolFileAudit {
  ToolFileAudit({AuditIo? io, this.budget = AuditBudget.defaults})
    : io = io ?? FileAuditIo();
  final AuditIo io;
  final AuditBudget budget;
  static const chunkBytes = 1024 * 1024;
  Future<Map<String, Object?>> scan(List<String> paths, String secret) async {
    var errors = 0, files = 0, matched = 0, scanned = 0, read = 0, charged = 0;
    var leaves = 0;
    final categories = <String, int>{
      for (final key in [
        'metadataAdmission',
        'nonRegular',
        'fileLimit',
        'aggregateLimit',
        'unstable',
        'statIo',
        'enumerationIo',
        'openIo',
        'readIo',
        'closeIo',
      ])
        key: 0,
    };
    final ioErrors = AuditIoErrorCounts();
    void fail(String category, [FileSystemException? error]) {
      errors++;
      categories[category] = categories[category]! + 1;
      if (error != null) ioErrors.record(error);
    }

    final seen = <String>{};
    final pending = <String>[];
    var admitted = 0;
    var enumerationStopped = false;
    bool admit(String path) {
      // Count every candidate, including duplicates, before retaining it.
      // Otherwise repeated directory entries could evade the traversal bound.
      if (admitted == 4096) {
        if (!enumerationStopped) fail('metadataAdmission');
        enumerationStopped = true;
        return false;
      }
      admitted++;
      pending.add(path);
      return true;
    }

    final pattern = utf8.encode(secret);
    if (pattern.isEmpty || pattern.any((byte) => byte > 127)) {
      throw ArgumentError('ASCII canary required');
    }
    // KMP retains only the matched prefix length between chunks. It is
    // equivalent to a length-minus-one carry without copying the read buffer.
    final prefix = List<int>.filled(pattern.length, 0);
    for (var i = 1, j = 0; i < pattern.length; i++) {
      while (j > 0 && pattern[i] != pattern[j]) {
        j = prefix[j - 1];
      }
      if (pattern[i] == pattern[j]) j++;
      prefix[i] = j;
    }
    Future<void> visit(String path) async {
      if (!seen.add(path)) return;
      var stage = 'statIo';
      try {
        final before = await io.stat(path);
        if (before.$1 == FileSystemEntityType.directory) {
          if (enumerationStopped) return;
          stage = 'enumerationIo';
          await for (final child in io.children(path)) {
            if (!admit(child)) break;
          }
          return;
        }
        if (++leaves > 4096) {
          fail('metadataAdmission');
          return;
        }
        if (before.$1 != FileSystemEntityType.file || before.$2 < 0) {
          fail('nonRegular');
          return;
        }
        if (before.$2 > budget.maxFileBytes) {
          fail('fileLimit');
          return;
        }
        if (before.$2 == 0) {
          if (await io.stat(path) == before) {
            files++;
          } else {
            fail('unstable');
          }
          return;
        }
        if (charged == budget.maxTotalBytes) {
          fail('aggregateLimit');
          return;
        }
        var fileCharged = 0, returned = 0, state = 0;
        var found = false, eof = false;
        stage = 'openIo';
        final reader = await io.open(path);
        try {
          while (true) {
            final allowance = [
              chunkBytes,
              budget.maxFileBytes - fileCharged,
              budget.maxTotalBytes - charged,
            ].reduce((a, b) => a < b ? a : b);
            if (allowance == 0) break;
            // The unknown count of a throwing read consumes its reservation.
            charged += allowance;
            fileCharged += allowance;
            stage = 'readIo';
            final content = await reader.read(allowance);
            if (content.length > allowance) {
              throw const FileSystemException('invalid audit read count');
            }
            charged -= allowance - content.length;
            fileCharged -= allowance - content.length;
            read += content.length;
            returned += content.length;
            for (final byte in content) {
              while (state > 0 && byte != pattern[state]) {
                state = prefix[state - 1];
              }
              if (byte == pattern[state]) state++;
              if (state == pattern.length) {
                found = true;
                state = prefix[state - 1];
              }
            }
            if (content.isEmpty) {
              eof = true;
              break;
            }
          }
          stage = 'statIo';
          final after = await io.stat(path);
          final boundary =
              fileCharged == budget.maxFileBytes ||
              charged == budget.maxTotalBytes;
          if (before == after && returned == before.$2 && (eof || boundary)) {
            files++;
            scanned += returned;
          } else {
            fail(
              charged == budget.maxTotalBytes && returned < before.$2
                  ? 'aggregateLimit'
                  : 'unstable',
            );
          }
        } finally {
          if (found) matched++;
          final previousStage = stage;
          stage = 'closeIo';
          await reader.close();
          stage = previousStage;
        }
      } on FileSystemException catch (error) {
        fail(stage, error);
      }
    }

    for (final path in paths) {
      if (enumerationStopped || !admit(path)) break;
      // Iteration keeps deep directory trees from retaining nested listings.
      // Once enumeration stops, settle only the already admitted candidates.
      while (pending.isNotEmpty) {
        await visit(pending.removeLast());
      }
    }
    return {
      ...budget.echo,
      'complete': errors == 0,
      'errorCount': errors,
      'errorCategories': categories,
      'ioErrorCategories': Map<String, int>.of(ioErrors.counts),
      'scannedFiles': files,
      'matchedFiles': matched,
      'scannedBytes': scanned,
      'readBytes': read,
      'chargedBytes': charged,
    };
  }
}
