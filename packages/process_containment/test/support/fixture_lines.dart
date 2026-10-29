import 'dart:io';

/// One line a fixture wrote: `role pid marker sid`.
class FixtureLine {
  FixtureLine(this.role, this.pid, this.marker, this.sid);

  factory FixtureLine.parse(String line) {
    final f = line.split(' ');
    return FixtureLine(f[0], int.parse(f[1]), f[2], int.tryParse(f[3]));
  }

  final String role;
  final int pid;
  final String marker;
  final int? sid;
}

/// Polls [file] until it holds [count] complete lines; fixtures have no other
/// channel on Windows, where unit stdio is NUL.
Future<List<FixtureLine>> waitForLines(
  File file,
  int count, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final lines = file.existsSync()
        ? file
              .readAsLinesSync()
              .where((l) => l.isNotEmpty)
              .map(FixtureLine.parse)
              .toList()
        : <FixtureLine>[];
    if (lines.length >= count) return lines;
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('timed out waiting for $count fixture lines: $lines');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}
