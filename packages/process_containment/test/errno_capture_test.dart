@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:process_containment/src/libc.dart';
import 'package:process_containment/src/posix_process_table.dart';
import 'package:test/test.dart';

/// The signal wrappers report the errno of their own call (design D4): a
/// signal to a pid no process can hold answers `ESRCH`. This checks the
/// capture on this run; the leaf bindings are what keep a VM transition from
/// overwriting it.
void main() {
  // Above every system's pid limit (Linux at most 2^22, macOS 99999).
  const noSuchPid = 0x7fffffff;

  test('kill reports ESRCH for a pid no process can hold', () {
    expect(posixKill(noSuchPid, 0), esrch);
  }, skip: Platform.isWindows ? 'POSIX signals' : false);

  test('killpg reports ESRCH for a group no process can lead', () {
    expect(posixKillpg(noSuchPid, 0), esrch);
  }, skip: Platform.isWindows ? 'POSIX signals' : false);
}
