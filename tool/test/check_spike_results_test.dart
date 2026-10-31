import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../check_spike_results.dart';

const _candidate = 'flutter_alacritty';

/// Builds a results file. [result] decides each cell from (os, item).
String _results(
  String Function(String os, SpikeItem item) result, {
  String adopted = _candidate,
  String rowCandidate = _candidate,
  bool Function(String os, SpikeItem item)? omit,
}) {
  final b = StringBuffer('# Fixture\n\nAdopted candidate: $adopted\n');
  for (final os in spikeOses) {
    b.writeln('\n## $os\n');
    b.writeln('| Item | Kind | Candidate | Result | Notes |');
    b.writeln('|---|---|---|---|---|');
    for (final item in spikeItems) {
      if (omit != null && omit(os, item)) continue;
      b.writeln(
        '| ${item.name} | ${item.kind} | $rowCandidate | '
        '${result(os, item)} | n |',
      );
    }
  }
  return b.toString();
}

SpikeItem _agentItem() => spikeItems.firstWhere((i) => i.kind == 'agent');
SpikeItem _userItem() => spikeItems.firstWhere((i) => i.kind == 'user');

String _allPass(String os, SpikeItem item) => 'pass';

String _unprovenUserOnPosix(String os, SpikeItem item) =>
    item.kind == 'user' && os != 'windows' ? 'unproven' : 'pass';

/// A results file that differs from all-pass in one cell.
String _oneCell(String os, SpikeItem target, String value) =>
    _results((o, i) => o == os && i.name == target.name ? value : 'pass');

void main() {
  group('spike results check', () {
    test('every cell pass prints QUALIFIED and lists nothing unproven', () {
      final report = checkSpikeResults(_results(_allPass));
      expect(report.failures, isEmpty);
      expect(report.verdict, 'QUALIFIED');
      expect(report.unproven, isEmpty);
    });

    test('Linux and macOS user items unproven prints ADOPTABLE and lists '
        'each by OS and item', () {
      final report = checkSpikeResults(_results(_unprovenUserOnPosix));
      expect(report.failures, isEmpty);
      expect(report.verdict, 'ADOPTABLE');
      final userCount = spikeItems.where((i) => i.kind == 'user').length;
      expect(report.unproven, hasLength(userCount * 2));
      expect(report.unproven.any((u) => u.startsWith('windows: ')), isFalse);
      final item = _userItem();
      expect(report.unproven, contains('linux: ${item.name}'));
      expect(report.unproven, contains('macos: ${item.name}'));
    });

    test('a fail names the OS and item', () {
      final item = _agentItem();
      final report = checkSpikeResults(_oneCell('macos', item, 'fail'));
      expect(report.verdict, isNull);
      expect(report.failures, hasLength(1));
      expect(
        report.failures.single,
        allOf(contains('macos'), contains(item.name)),
      );
    });

    test('a fail on a user item on Linux fails too', () {
      final item = _userItem();
      final report = checkSpikeResults(_oneCell('linux', item, 'fail'));
      expect(
        report.failures.single,
        allOf(contains('linux'), contains(item.name)),
      );
    });

    test('a Windows unproven fails, naming the item', () {
      final item = _userItem();
      final report = checkSpikeResults(_oneCell('windows', item, 'unproven'));
      expect(report.verdict, isNull);
      expect(
        report.failures.single,
        allOf(contains('windows'), contains(item.name)),
      );
    });

    test('an agent-scripted unproven fails on Linux, naming the item', () {
      final item = _agentItem();
      final report = checkSpikeResults(_oneCell('linux', item, 'unproven'));
      expect(report.verdict, isNull);
      expect(
        report.failures.single,
        allOf(contains('linux'), contains(item.name)),
      );
    });

    test('a blank result fails, naming the OS and item', () {
      final item = _userItem();
      final report = checkSpikeResults(_oneCell('windows', item, ''));
      expect(report.verdict, isNull);
      expect(
        report.failures.single,
        allOf(contains('windows'), contains(item.name)),
      );
    });

    test('an unknown result value fails', () {
      final item = _agentItem();
      final report = checkSpikeResults(_oneCell('linux', item, 'ok'));
      expect(report.failures, isNotEmpty);
    });

    test('a missing item row fails, naming the OS and item', () {
      final item = _agentItem();
      final report = checkSpikeResults(
        _results(
          _allPass,
          omit: (os, i) => os == 'macos' && i.name == item.name,
        ),
      );
      expect(report.verdict, isNull);
      expect(
        report.failures.single,
        allOf(contains('macos'), contains(item.name)),
      );
    });

    test('CRLF line endings read the same as LF', () {
      final report = checkSpikeResults(
        _results(_unprovenUserOnPosix).replaceAll('\n', '\r\n'),
      );
      expect(report.failures, isEmpty);
      expect(report.verdict, 'ADOPTABLE');
    });

    test('a blank adopted candidate fails', () {
      final report = checkSpikeResults(_results(_allPass, adopted: ''));
      expect(report.verdict, isNull);
      expect(report.failures.join('\n'), contains('Adopted candidate'));
    });

    test('rows of another candidate are ignored', () {
      final report = checkSpikeResults(
        _results(_allPass, adopted: 'xterm.dart'),
      );
      expect(report.verdict, isNull);
      expect(report.failures, isNotEmpty);
    });

    test('a kind that disagrees with the item fails', () {
      final user = _userItem();
      final text = _results(_allPass)
          .replaceFirst('| ${user.name} | user |', '| ${user.name} | agent |');
      final report = checkSpikeResults(text);
      expect(report.verdict, isNull);
      expect(report.failures.join('\n'), contains(user.name));
    });
  });

  group('spike results command', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('spike_'));
    tearDown(() => dir.deleteSync(recursive: true));

    String write(String content) {
      final path = p.join(dir.path, 'spike-results.md');
      File(path).writeAsStringSync(content);
      return path;
    }

    test('exit 0 and prints ADOPTABLE with each unproven item', () {
      final out = StringBuffer();
      final code = runSpikeCheck([
        write(_results(_unprovenUserOnPosix)),
      ], out: out);
      expect(code, 0);
      expect(out.toString(), contains('ADOPTABLE'));
      expect(out.toString(), contains('unproven: linux: ${_userItem().name}'));
    });

    test('exit 0 and prints QUALIFIED', () {
      final out = StringBuffer();
      expect(runSpikeCheck([write(_results(_allPass))], out: out), 0);
      expect(out.toString(), contains('QUALIFIED'));
    });

    test('exit 1 and prints the failure naming OS and item', () {
      final item = _agentItem();
      final out = StringBuffer();
      final code = runSpikeCheck([
        write(_oneCell('windows', item, 'fail')),
      ], out: out);
      expect(code, 1);
      expect(out.toString(), contains('windows'));
      expect(out.toString(), contains(item.name));
    });

    test('exit 1 when the file is missing', () {
      final out = StringBuffer();
      expect(runSpikeCheck([p.join(dir.path, 'nope.md')], out: out), 1);
    });

    test('the recorded results file in the archived change passes', () {
      final out = StringBuffer();
      expect(
        runSpikeCheck([defaultSpikeResultsPath], out: out),
        0,
        reason: '$out',
      );
      expect(out.toString(), contains('ADOPTABLE'));
    });
  });
}
