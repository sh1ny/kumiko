@TestOn('linux || mac-os')
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/compile_exe.dart';

/// Runs the shim on a real OS: the pid must survive `execve`, the session id
/// must equal the pid, and the exit code must reach `Process.exitCode`
/// (task 5.1, design D2 and Risks).
void main() {
  late Directory tmp;
  late String exe;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('pc_unit_exec_');
    exe = await compileExe('test/fixtures/unit_exec_main.dart', tmp);
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<(int, String, String)> runShim(List<String> target) async {
    final proc = await Process.start(exe, [
      '--unit-exec',
      'unit-test-1',
      '--',
      ...target,
    ]);
    final out = proc.stdout.transform(utf8.decoder).join();
    final err = proc.stderr.transform(utf8.decoder).join();
    final code = await proc.exitCode;
    return (code, await out, await err);
  }

  test('pid survives, session id equals pid, exit code propagates', () async {
    final proc = await Process.start(exe, [
      '--unit-exec',
      'unit-test-1',
      '--',
      exe,
      '--report',
      '7',
    ]);
    final out = await proc.stdout.transform(utf8.decoder).join();
    final code = await proc.exitCode;
    final fields = Map.fromEntries(
      out.trim().split(' ').map((kv) {
        final i = kv.indexOf('=');
        return MapEntry(kv.substring(0, i), kv.substring(i + 1));
      }),
    );
    expect(int.parse(fields['pid']!), proc.pid, reason: 'pid survives execve');
    expect(int.parse(fields['sid']!), proc.pid, reason: 'session leader');
    expect(fields['unit'], 'unit-test-1');
    expect(code, 7);
  });

  test('exec of a missing program exits 127', () async {
    final (code, _, err) = await runShim([p.join(tmp.path, 'does-not-exist')]);
    expect(code, 127);
    expect(err, contains('unit-exec'));
  });

  test('no inherited file descriptor above 2 reaches the target', () async {
    // The shell probes each descriptor by duplicating it in a subshell, so
    // the target opens nothing itself (`ls /dev/fd` opens extra handles on
    // macOS). The same probe run straight from Process.run is the baseline:
    // a shell may hold a descriptor of its own, and the shim must add
    // nothing on top of that.
    const probe = [
      '/bin/sh',
      '-c',
      r'exec 2>/dev/null; fd=0; while [ $fd -lt 256 ]; do '
          r'(exec <&$fd) && echo $fd; fd=$((fd + 1)); done',
    ];
    List<int> parse(String out) => out
        .split('\n')
        .map((l) => int.tryParse(l.trim()))
        .whereType<int>()
        .toList();

    final direct = await Process.run(probe.first, probe.sublist(1));
    expect(direct.exitCode, 0);
    final baseline = parse(direct.stdout as String);

    final (code, out, _) = await runShim(probe);
    expect(code, 0);
    final fds = parse(out);
    expect(fds, containsAll([0, 1, 2]));
    expect(
      fds.where((fd) => fd > 2 && !baseline.contains(fd)),
      isEmpty,
      reason: 'shim: $fds, direct: $baseline',
    );
  });

  test('signal mask and ignored signals are reset', () async {
    final (code, out, _) = await runShim([
      '/bin/sh',
      '-c',
      r'grep -E "^Sig(Blk|Ign)" /proc/self/status',
    ]);
    expect(code, 0);
    final masks = {
      for (final line in out.trim().split('\n'))
        line.split(':').first: int.parse(
          line.split(':').last.trim(),
          radix: 16,
        ),
    };
    expect(masks['SigBlk'], 0);
    expect(masks['SigIgn'], 0);
  }, skip: Platform.isLinux ? false : '/proc/self/status is Linux only');
}
