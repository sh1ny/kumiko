/// Offline audit of exact-version adapter claims (ADR 0012).
///
/// Usage from the repository root:
/// `dart run tool/check_qualification.dart [resultsPath [sourcePath]]`.
/// See docs/qualification/claude-agent-acp.md for the literal source and
/// Markdown evidence formats. This tool never launches an adapter.
library;

import 'dart:io';

const defaultQualificationResultsPath =
    'docs/qualification/claude-agent-acp.md';
const defaultQualifiedAdaptersPath =
    'packages/host/lib/src/agent/qualified_adapters.dart';

const _oses = ['windows', 'linux', 'macos'];

/// Tool delivery item (ADR 0013 D8): a `fail` is accepted only with its
/// observed text in Notes and a matching `toolDeliveryFailures` entry.
const toolCallItem = 'kumiko tool call';
const _baselineItems = [
  'launch',
  'streaming',
  'tool activity',
  'permission request',
  'Stop',
  'close with confirmation',
  'auth-required observed',
  toolCallItem,
];
const _finderItem = 'launch from Finder or the Dock';
const _knownItems = {..._baselineItems, 'load', 'resume', _finderItem};

typedef _Adapter = (String, String);

/// Parsed source literals: qualified claims and tool delivery failures.
typedef _Source = (
  Map<_Adapter, List<String>>,
  Map<_Adapter, String>,
);

/// A pure audit result. Failures suppress the success verdict.
class QualificationReport {
  QualificationReport({
    required this.failures,
    required this.unproven,
    required this.verdict,
    this.toolDeliveryFailures = const [],
  });

  /// Pair/OS/item diagnostics, or source/results diagnostics for document errors.
  final List<String> failures;

  /// `adapterName version: os: item` for each checked unproven observation.
  final List<String> unproven;

  /// NO CLAIMS (no adapter qualified), ACCEPTED, QUALIFIED, or null on failure.
  final String? verdict;

  /// `<adapter> <version> <os>: <text>` for each accepted tool delivery failure.
  final List<String> toolDeliveryFailures;

  int get exitCode => failures.isEmpty ? 0 : 1;
}

class _Observation {
  _Observation(this.kind, this.result, this.code, this.message, this.notes);

  final String kind;
  final String result;
  final String code;
  final String message;
  final String notes;
}

/// Deliberately small literal grammar, not a Dart evaluator. Unknown syntax must
/// fail instead of silently turning claims into an empty list.
class _QualifiedSourceParser {
  _QualifiedSourceParser(this.source);

  final String source;
  int _position = 0;

  static final _trivia = RegExp(r'\s+|//[^\r\n]*|/\*[\s\S]*?\*/');
  static final _string = RegExp(r"'([^'\\\$\s]+)'");
  static final _failureText = RegExp(r"'([^'\\\$\r\n]+)'");

  void _skipTrivia() {
    while (true) {
      final match = _trivia.matchAsPrefix(source, _position);
      if (match == null) return;
      _position = match.end;
    }
  }

  static bool _identifierPart(int code) =>
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      (code >= 48 && code <= 57) ||
      code == 95 ||
      code == 36;

  bool _consume(String token) {
    _skipTrivia();
    if (!source.startsWith(token, _position)) return false;
    final end = _position + token.length;
    if (_identifierPart(token.codeUnitAt(token.length - 1)) &&
        end < source.length &&
        _identifierPart(source.codeUnitAt(end))) {
      return false;
    }
    _position = end;
    return true;
  }

  void _expect(String token) {
    if (!_consume(token)) {
      throw FormatException('expected $token', source, _position);
    }
  }

  String _readString() {
    _skipTrivia();
    final match = _string.matchAsPrefix(source, _position);
    if (match == null) {
      throw FormatException(
        'expected a single-quoted identity or capability',
        source,
        _position,
      );
    }
    _position = match.end;
    return match.group(1)!;
  }

  _Source parse() {
    for (final token in [
      'const',
      'qualifiedAdapters',
      '=',
      '<',
      '(',
      'String',
      ',',
      'String',
      ',',
      'List',
      '<',
      'String',
      '>',
      ')',
      '>',
      '[',
    ]) {
      _expect(token);
    }
    final entries = <_Adapter, List<String>>{};
    if (!_consume(']')) {
      while (true) {
        _expect('(');
        final name = _readString();
        _expect(',');
        final version = _readString();
        _expect(',');
        for (final token in ['<', 'String', '>', '[']) {
          _expect(token);
        }
        final capabilities = <String>[];
        if (!_consume(']')) {
          while (true) {
            final capability = _readString();
            if (!const ['load', 'resume'].contains(capability) ||
                capabilities.contains(capability)) {
              throw FormatException(
                'unknown or duplicate capability $capability',
              );
            }
            capabilities.add(capability);
            if (_consume(']')) break;
            _expect(',');
            if (_consume(']')) break;
          }
        }
        // Dart permits a trailing comma inside a record literal too.
        _consume(',');
        _expect(')');
        final pair = (name, version);
        if (entries.containsKey(pair)) {
          throw FormatException('duplicate adapter $name $version');
        }
        entries[pair] = capabilities;
        if (_consume(']')) break;
        _expect(',');
        if (_consume(']')) break;
      }
    }
    _expect(';');
    return (entries, _parseToolDeliveryFailures());
  }

  /// `toolDeliveryFailures` follows `qualifiedAdapters`; absence is an error.
  Map<_Adapter, String> _parseToolDeliveryFailures() {
    _skipTrivia();
    if (_position >= source.length) {
      throw const _ToolFailuresFormatException(
        'the literal is missing after qualifiedAdapters',
      );
    }
    try {
      for (final token in [
        'const',
        'toolDeliveryFailures',
        '=',
        '<',
        '(',
        'String',
        ',',
        'String',
        ',',
        'String',
        ')',
        '>',
        '[',
      ]) {
        _expect(token);
      }
      final failures = <_Adapter, String>{};
      if (!_consume(']')) {
        while (true) {
          _expect('(');
          final name = _readString();
          _expect(',');
          final version = _readString();
          _expect(',');
          final text = _readFailureText();
          _consume(',');
          _expect(')');
          final pair = (name, version);
          if (failures.containsKey(pair)) {
            throw FormatException('duplicate failure for $name $version');
          }
          failures[pair] = text;
          if (_consume(']')) break;
          _expect(',');
          if (_consume(']')) break;
        }
      }
      _expect(';');
      _skipTrivia();
      if (_position != source.length) {
        throw FormatException(
          'unexpected source after toolDeliveryFailures',
          source,
          _position,
        );
      }
      return failures;
    } on FormatException catch (error) {
      throw _ToolFailuresFormatException(error.message);
    }
  }

  /// Spaces are allowed; a quote, backslash, `$` (interpolation) or line break
  /// is not, so the decoded text is exactly the source text.
  String _readFailureText() {
    _skipTrivia();
    final match = _failureText.matchAsPrefix(source, _position);
    if (match == null) {
      throw FormatException(
        'expected a nonempty single-line single-quoted failure text',
        source,
        _position,
      );
    }
    _position = match.end;
    return match.group(1)!;
  }
}

/// A `toolDeliveryFailures` diagnostic rather than a `qualifiedAdapters` one.
class _ToolFailuresFormatException extends FormatException {
  const _ToolFailuresFormatException(super.message);
}

/// The text of `observed: "<text>"` in a Notes cell, or null when absent/empty.
String? _observedText(String notes) {
  final match = RegExp(r'observed: "([^"]+)"').firstMatch(notes);
  return match?.group(1);
}

List<String> _cells(String line) {
  var text = line.trim();
  if (text.startsWith('|')) text = text.substring(1);
  if (text.endsWith('|')) text = text.substring(0, text.length - 1);
  return text.split('|').map((cell) => cell.trim()).toList();
}

String _where(_Adapter pair, String os, String item) =>
    '${pair.$1} ${pair.$2}: $os: $item';

/// Checks source and recorded evidence without filesystem or process access.
/// [qualifiedSource] is null when the qualified source is missing.
QualificationReport checkQualification(
  String markdown,
  String? qualifiedSource,
) {
  final failures = <String>[];
  final unproven = <String>[];
  final recorded = <String>[];
  QualificationReport report(String? verdict) => QualificationReport(
    failures: failures,
    unproven: unproven,
    verdict: failures.isEmpty ? verdict : null,
    toolDeliveryFailures: recorded,
  );

  if (qualifiedSource == null) {
    failures.add('source: qualifiedAdapters source is missing');
    return report(null);
  }
  final Map<_Adapter, List<String>> claims;
  final Map<_Adapter, String> listedFailures;
  try {
    (claims, listedFailures) = _QualifiedSourceParser(qualifiedSource).parse();
  } on _ToolFailuresFormatException catch (error) {
    failures.add(
      'source: unrecognised toolDeliveryFailures literal: ${error.message}',
    );
    return report(null);
  } on FormatException catch (error) {
    failures.add(
      'source: unrecognised qualifiedAdapters literal: ${error.message}',
    );
    return report(null);
  }
  if (markdown.trim().isEmpty) {
    failures.add('results: document is blank');
    return report(null);
  }

  final evidence = <_Adapter, Map<String, Map<String, _Observation>>>{};
  _Adapter? pair;
  String? os;
  String? fenceCharacter;
  var fenceLength = 0;
  final fence = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$');
  final adapterHeading = RegExp(r'^## adapter (\S+) (\S+)$');
  final osHeading = RegExp(r'^###\s+(.+)$');
  final separator = RegExp(r'^:?-+:?$');
  const header = [
    'Item',
    'Kind',
    'Result',
    'Notes',
    'Auth code',
    'Auth message',
  ];

  for (final rawLine in markdown.replaceAll('\r\n', '\n').split('\n')) {
    final fenceMatch = fence.firstMatch(rawLine);
    if (fenceCharacter != null) {
      if (fenceMatch != null &&
          fenceMatch.group(1)!.startsWith(fenceCharacter) &&
          fenceMatch.group(1)!.length >= fenceLength &&
          fenceMatch.group(2)!.trim().isEmpty) {
        fenceCharacter = null;
      }
      continue;
    }
    if (fenceMatch != null) {
      fenceCharacter = fenceMatch.group(1)![0];
      fenceLength = fenceMatch.group(1)!.length;
      continue;
    }
    final line = rawLine.trim();
    final adapterMatch = adapterHeading.firstMatch(line);
    if (adapterMatch != null) {
      pair = (adapterMatch.group(1)!, adapterMatch.group(2)!);
      os = null;
      if (evidence.containsKey(pair)) {
        failures.add(
          '${_where(pair, 'all', 'section')}: duplicate adapter section',
        );
      } else {
        evidence[pair] = {};
      }
      continue;
    }
    if (line.startsWith('## ')) {
      if (line.startsWith('## adapter')) {
        failures.add('results: unrecognised adapter section "$line"');
      }
      pair = null;
      os = null;
      continue;
    }
    if (pair == null) continue;
    final osMatch = osHeading.firstMatch(line);
    if (osMatch != null) {
      os = osMatch.group(1)!;
      if (!_oses.contains(os)) {
        failures.add('${_where(pair, os, 'section')}: unknown OS');
      }
      if (evidence[pair]!.containsKey(os)) {
        failures.add('${_where(pair, os, 'section')}: duplicate OS section');
      } else {
        evidence[pair]![os] = {};
      }
      continue;
    }
    if (!line.startsWith('|')) continue;
    if (os == null) {
      failures.add(
        '${_where(pair, 'unspecified', 'section')}: table has no OS',
      );
      continue;
    }
    final cells = _cells(line);
    final where = _where(pair, os, cells.first);
    if (cells.length != header.length) {
      failures.add('$where: expected six table cells');
      continue;
    }
    if (cells.indexed.every((cell) => cell.$2 == header[cell.$1]) ||
        cells.every(separator.hasMatch)) {
      continue;
    }
    final item = cells[0];
    if (!_knownItems.contains(item) || (item == _finderItem && os != 'macos')) {
      failures.add('$where: unknown item for this OS');
      continue;
    }
    final rows = evidence[pair]![os]!;
    if (rows.containsKey(item)) {
      failures.add('$where: duplicate item row');
      continue;
    }
    rows[item] = _Observation(
      cells[1],
      cells[2],
      cells[4],
      cells[5],
      cells[3],
    );
    if (cells[1] != 'user' && cells[1] != 'agent') {
      failures.add('$where: unknown kind "${cells[1]}"');
    }
    if (cells[2].isEmpty) {
      failures.add('$where: result is blank');
    } else if (!const ['pass', 'fail', 'unproven'].contains(cells[2])) {
      failures.add('$where: unknown result "${cells[2]}"');
    }
  }
  if (fenceCharacter != null) {
    failures.add('results: unclosed code fence');
  }

  for (final entry in claims.entries) {
    for (final os in _oses) {
      for (final item in [
        ..._baselineItems,
        ...entry.value,
        if (os == 'macos') _finderItem,
      ]) {
        final where = _where(entry.key, os, item);
        final row = evidence[entry.key]?[os]?[item];
        if (row == null) {
          failures.add('$where: no observation for listed pair');
          continue;
        }
        switch (row.result) {
          case 'pass':
            if (item == 'auth-required observed' &&
                (row.code.isEmpty || row.message.isEmpty)) {
              failures.add(
                '$where: pass requires observed auth code and message',
              );
            }
          case 'fail':
            if (item == toolCallItem) {
              final observed = _observedText(row.notes);
              final listed = listedFailures[entry.key];
              if (observed == null) {
                failures.add(
                  '$where: fail needs observed: "<text>" in Notes',
                );
              } else if (listed == null) {
                failures.add(
                  '$where: fail is not listed in toolDeliveryFailures',
                );
              } else if (listed != observed) {
                failures.add(
                  '$where: observed text differs from the toolDeliveryFailures entry',
                );
              } else {
                recorded.add(
                  '${entry.key.$1} ${entry.key.$2} $os: $observed',
                );
              }
            } else {
              failures.add('$where: fail');
            }
          case 'unproven':
            if (os != 'windows' && row.kind == 'user') {
              unproven.add(where);
            } else {
              failures.add(
                '$where: unproven is allowed only for user items on linux or macos',
              );
            }
          // Blank and unknown statuses already have pair/OS/item diagnostics.
        }
      }
    }
  }
  for (final listed in listedFailures.entries) {
    final rows = {
      for (final os in _oses) os: evidence[listed.key]?[os]?[toolCallItem],
    };
    final observedFail = rows.values.any(
      (row) =>
          row != null &&
          row.result == 'fail' &&
          _observedText(row.notes) == listed.value,
    );
    for (final os in _oses) {
      final row = rows[os];
      final where = _where(listed.key, os, toolCallItem);
      if (row != null &&
          row.result == 'fail' &&
          _observedText(row.notes) != listed.value) {
        if (claims.containsKey(listed.key)) continue; // reported above
        failures.add(
          '$where: observed text differs from the toolDeliveryFailures entry',
        );
      } else if (!observedFail && (row == null || row.result != 'fail')) {
        failures.add(
          '$where: toolDeliveryFailures lists this version but the evidence is '
          '${row == null ? 'missing' : row.result.isEmpty ? 'blank' : row.result}',
        );
      }
    }
  }
  return report(
    claims.isEmpty
        ? 'NO CLAIMS (no adapter qualified)'
        : (unproven.isEmpty ? 'QUALIFIED' : 'ACCEPTED'),
  );
}

/// Reads the two offline inputs, prints the report and returns its exit code.
int runQualificationCheck(List<String> args, {required StringSink out}) {
  if (args.length > 2) {
    out.writeln(
      'FAILED: usage: check_qualification.dart [resultsPath [sourcePath]]',
    );
    return 1;
  }
  final resultsPath = args.isEmpty ? defaultQualificationResultsPath : args[0];
  final sourcePath = args.length < 2 ? defaultQualifiedAdaptersPath : args[1];
  final String markdown;
  final String source;
  try {
    markdown = File(resultsPath).readAsStringSync();
  } on FileSystemException catch (error) {
    out.writeln(
      'FAILED: results: could not read $resultsPath: ${error.message}',
    );
    return 1;
  }
  try {
    source = File(sourcePath).readAsStringSync();
  } on FileSystemException catch (error) {
    out.writeln('FAILED: source: could not read $sourcePath: ${error.message}');
    return 1;
  }
  final report = checkQualification(markdown, source);
  for (final item in report.unproven) {
    out.writeln('unproven: $item');
  }
  for (final failure in report.failures) {
    out.writeln('FAILED: $failure');
  }
  for (final recorded in report.toolDeliveryFailures) {
    out.writeln('TOOL DELIVERY FAILURE RECORDED: $recorded');
  }
  if (report.verdict != null) out.writeln(report.verdict);
  return report.exitCode;
}

void main(List<String> args) {
  exit(runQualificationCheck(args, out: stdout));
}
