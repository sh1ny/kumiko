/// Mechanical check of the terminal engine spike results (host-terminals,
/// ADR 0010).
///
/// Reads `spike-results.md`: an `Adopted candidate:` line and, per OS
/// (`## windows`, `## linux`, `## macos`), a table
/// `| Item | Kind | Candidate | Result | Notes |`. Only rows whose Candidate
/// equals the adopted candidate count.
///
/// The check fails (exit 1), naming the OS and item, unless every item is
/// `pass` on every OS, or `unproven` for a user-verified item on Linux or
/// macOS. Every unproven item is printed. It prints ADOPTABLE when any item is
/// unproven and QUALIFIED when none is.
///
/// Usage, from the repository root:
/// `dart run tool/check_spike_results.dart [path]`.
library;

import 'dart:io';

/// Default location of the results file, relative to the repository root.
const defaultSpikeResultsPath =
    'openspec/changes/host-terminals/spike-results.md';

/// The OS sections, in file order.
const spikeOses = <String>['windows', 'linux', 'macos'];

/// One daily-driver bar item (roadmap M1 exit criteria).
class SpikeItem {
  const SpikeItem(this.name, this.kind);

  /// The exact text of the Item cell.
  final String name;

  /// `agent` (agent-scripted) or `user` (user-verified).
  final String kind;
}

/// Every bar item that must appear once per OS.
const spikeItems = <SpikeItem>[
  SpikeItem(
    'Fullscreen TUIs: vim, lazygit, htop or btop, tmux (keyboard with '
        'modifiers, function and navigation keys; mouse reporting)',
    'user',
  ),
  SpikeItem('Colour: 256 colours and 24-bit true colour', 'agent'),
  SpikeItem('Input: bracketed paste', 'agent'),
  SpikeItem('Input: CJK IME composition', 'user'),
  SpikeItem('Unicode: wide characters and emoji widths', 'agent'),
  SpikeItem('Throughput: 100 MB cat and Ctrl+C interrupt', 'agent'),
  // Judged on real hardware only: CI VMs render in software (user decision
  // 2026-10-30).
  SpikeItem(
    'Throughput: frames under 100 ms during the 100 MB cat, on real hardware',
    'user',
  ),
  SpikeItem('Resize: rapid resize storm', 'user'),
  SpikeItem('Conformance: vttest subset', 'agent'),
  SpikeItem('Selection, copy and scrollback search', 'user'),
];

/// Outcome of checking one results file.
class SpikeReport {
  SpikeReport({
    required this.failures,
    required this.unproven,
    required this.verdict,
  });

  /// One line per problem, each starting with the OS and item.
  final List<String> failures;

  /// `os: item` for every unproven cell, in file order.
  final List<String> unproven;

  /// `ADOPTABLE` or `QUALIFIED`; null when [failures] is not empty.
  final String? verdict;
}

class _Row {
  _Row(this.kind, this.candidate, this.result);
  final String kind;
  final String candidate;
  final String result;
}

List<String> _cells(String line) {
  var t = line.trim();
  if (t.startsWith('|')) t = t.substring(1);
  if (t.endsWith('|')) t = t.substring(0, t.length - 1);
  return t.split('|').map((c) => c.trim()).toList();
}

/// Checks the text of a results file.
SpikeReport checkSpikeResults(String markdown) {
  final failures = <String>[];
  final unproven = <String>[];

  String? adopted;
  String? os;
  // os -> item name -> rows of the adopted candidate.
  final rows = <String, Map<String, List<_Row>>>{
    for (final o in spikeOses) o: {},
  };
  final knownNames = {for (final i in spikeItems) i.name};
  final adoptedLine = RegExp(r'^\s*Adopted candidate:(.*)$');
  final heading = RegExp(r'^##\s+(\S+)\s*$');

  final parsed = <(String, String, _Row)>[];
  // A Windows checkout may carry CRLF, and `.` does not match `\r`.
  for (final line in markdown.replaceAll('\r\n', '\n').split('\n')) {
    final a = adoptedLine.firstMatch(line);
    if (a != null) {
      adopted = a.group(1)!.trim();
      continue;
    }
    final h = heading.firstMatch(line.trimRight());
    if (h != null) {
      os = h.group(1)!.toLowerCase();
      continue;
    }
    if (os == null ||
        !rows.containsKey(os) ||
        !line.trimLeft().startsWith('|')) {
      continue;
    }
    final c = _cells(line);
    if (c.length < 4 || !knownNames.contains(c[0])) continue;
    parsed.add((os, c[0], _Row(c[1], c[2], c[3])));
  }

  if (adopted == null || adopted.isEmpty) {
    failures.add('Adopted candidate is not set');
    return SpikeReport(failures: failures, unproven: unproven, verdict: null);
  }
  for (final (o, name, row) in parsed) {
    if (row.candidate == adopted) {
      rows[o]!.putIfAbsent(name, () => []).add(row);
    }
  }

  for (final o in spikeOses) {
    for (final item in spikeItems) {
      final found = rows[o]![item.name] ?? const <_Row>[];
      final where = '$o: ${item.name}';
      if (found.isEmpty) {
        failures.add('$where: no row for candidate $adopted');
        continue;
      }
      if (found.length > 1) {
        failures.add('$where: listed ${found.length} times');
        continue;
      }
      final row = found.single;
      if (row.kind != item.kind) {
        failures.add('$where: kind is "${row.kind}", expected "${item.kind}"');
        continue;
      }
      switch (row.result) {
        case 'pass':
          break;
        case 'unproven':
          if (item.kind == 'user' && o != 'windows') {
            unproven.add(where);
          } else {
            failures.add(
              '$where: unproven is allowed only for user-verified items on '
              'linux or macos',
            );
          }
        case '':
          failures.add('$where: result is blank');
        case 'fail':
          failures.add('$where: fail');
        default:
          failures.add('$where: unknown result "${row.result}"');
      }
    }
  }

  return SpikeReport(
    failures: failures,
    unproven: unproven,
    verdict: failures.isNotEmpty
        ? null
        : (unproven.isEmpty ? 'QUALIFIED' : 'ADOPTABLE'),
  );
}

/// Runs the check for [args] (an optional path) and returns the exit code.
int runSpikeCheck(List<String> args, {required StringSink out}) {
  final path = args.isEmpty ? defaultSpikeResultsPath : args.first;
  final file = File(path);
  if (!file.existsSync()) {
    out.writeln('FAILED: results file not found: $path');
    return 1;
  }
  final report = checkSpikeResults(file.readAsStringSync());
  for (final u in report.unproven) {
    out.writeln('unproven: $u');
  }
  if (report.failures.isNotEmpty) {
    for (final f in report.failures) {
      out.writeln('FAILED: $f');
    }
    return 1;
  }
  out.writeln(report.verdict);
  return 0;
}

void main(List<String> args) {
  exit(runSpikeCheck(args, out: stdout));
}
