import 'dart:io';

import 'package:process_containment/process_containment.dart';
import 'package:process_containment/src/libc.dart' show eacces, enoent;
import 'package:process_containment/src/posix_process_table.dart';
import 'package:test/test.dart';

/// The Linux `/proc` listing, with the listing injected: an entry that
/// vanishes while `/proc` is listed makes the listing fail, and only that
/// failure is listed again (issue #40, design D4).
void main() {
  FileSystemException failure(String path, int code) =>
      FileSystemException('Directory listing failed', path, OSError('', code));

  test('a vanished /proc entry is listed again and the listing succeeds', () {
    var attempts = 0;
    final pids = listProcPids(() {
      attempts++;
      if (attempts < 3) throw failure('/proc/4242', enoent);
      return ['/proc/1', '/proc/self', '/proc/4243', '/proc/sys'];
    });
    expect(pids, [1, 4243]);
    expect(attempts, 3);
  });

  test('a listing that succeeds at once is listed once', () {
    var attempts = 0;
    final pids = listProcPids(() {
      attempts++;
      return ['/proc/7'];
    });
    expect(pids, [7]);
    expect(attempts, 1);
  });

  test('eight vanished-entry failures or another error are unlistable', () {
    var attempts = 0;
    expect(
      () => listProcPids(() {
        attempts++;
        throw failure('/proc/${4000 + attempts}', enoent);
      }),
      throwsA(isA<ProcessTableUnlistable>()),
    );
    expect(attempts, 8);

    for (final other in [
      failure('/proc/4242', eacces),
      failure('/proc/sys', enoent),
      failure('/proc', enoent),
    ]) {
      attempts = 0;
      expect(
        () => listProcPids(() {
          attempts++;
          throw other;
        }),
        throwsA(isA<ProcessTableUnlistable>()),
        reason: '${other.path} ${other.osError}',
      );
      expect(attempts, 1, reason: '${other.path} ${other.osError}');
    }
  });
}
