/// Offline audit of exact-version adapter claims (ADR 0012).
///
/// Usage from the repository root:
/// `dart run tool/check_qualification.dart [resultsPath [sourcePath]]`.
/// See docs/qualification/claude-agent-acp.md for the literal source and
/// Markdown evidence formats. This tool never launches an adapter.
library;

import 'dart:convert';
import 'dart:io';

const defaultQualificationResultsPath =
    'docs/qualification/claude-agent-acp.md';
const defaultQualifiedAdaptersPath =
    'packages/host/lib/src/agent/qualified_adapters.dart';
const defaultCodexResultsPath = 'docs/qualification/codex-app-server.md';
const defaultCodexAuthSourcePath =
    'packages/host/lib/src/agent/codex/codex_auth_signatures.dart';

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
typedef _Source = (Map<_Adapter, List<String>>, Map<_Adapter, String>);

/// A pure audit result. Failures suppress the success verdict.
class QualificationReport {
  QualificationReport({
    required this.failures,
    required this.unproven,
    required this.verdict,
    this.toolDeliveryFailures = const [],
    this.codexObservations = const [],
  });

  /// Pair/OS/item diagnostics, or source/results diagnostics for document errors.
  final List<String> failures;

  /// `adapterName version: os: item` for each checked unproven observation.
  final List<String> unproven;

  /// NO CLAIMS (no adapter qualified), ACCEPTED, QUALIFIED, or null on failure.
  final String? verdict;

  /// `<adapter> <version> <os>: <text>` for each accepted tool delivery failure.
  final List<String> toolDeliveryFailures;

  /// Exact native observation statuses; these make no runtime admission claim.
  final List<String> codexObservations;

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
          final text = name == 'codex-app-server'
              ? _readNativeString()
              : _readFailureText();
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

  /// Native-only Dart string subset: literal Unicode and escapes for quote,
  /// backslash, dollar, LF, CR, tab, and exactly four hexadecimal Unicode digits.
  /// There is no interpolation, raw/multiline string or expression evaluation.
  /// Claude's established failure literal grammar deliberately stays unchanged.
  String _readNativeString() {
    _skipTrivia();
    if (_position >= source.length || source[_position++] != "'") {
      throw const FormatException('expected native single-quoted string');
    }
    final decoded = StringBuffer();
    while (_position < source.length) {
      final char = source[_position++];
      if (char == "'") {
        if (decoded.isEmpty) {
          throw const FormatException('native string is empty');
        }
        return decoded.toString();
      }
      if (char == '\n' || char == '\r' || char == r'$') {
        throw const FormatException('invalid native string character');
      }
      if (char != r'\') {
        decoded.write(char);
        continue;
      }
      if (_position == source.length) break;
      final escaped = source[_position++];
      switch (escaped) {
        case "'":
        case r'\':
        case r'$':
          decoded.write(escaped);
        case 'n':
          decoded.write('\n');
        case 'r':
          decoded.write('\r');
        case 't':
          decoded.write('\t');
        case 'u':
          if (_position + 4 > source.length) {
            throw const FormatException('incomplete native Unicode escape');
          }
          final digits = source.substring(_position, _position + 4);
          if (!RegExp(r'^[0-9a-fA-F]{4}$').hasMatch(digits)) {
            throw const FormatException('invalid native Unicode escape');
          }
          decoded.writeCharCode(int.parse(digits, radix: 16));
          _position += 4;
        default:
          throw const FormatException('unknown native string escape');
      }
    }
    throw const FormatException('unclosed native string');
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

const _nativeRequired = {
  'launch',
  'streaming',
  'tool activity',
  'command approval',
  'Stop',
  'close/descendant containment',
  toolCallItem,
  'auth-required',
};
const _nativeOptional = {
  'recovery',
  'steering',
  'structured question',
  'child attribution',
};
final _nativeVersion = RegExp(
  r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
);
typedef _AuthSignature = (String, String, String);

/// The closed Codex sign-in signals, in the fixed order a record lists them.
const _codexAuthSignals = ['account-unauthenticated', 'turn-http-401'];

/// The signal names of an auth-required Code cell, or null when the cell is
/// empty, repeats or misorders a name, or names an unknown signal.
List<String>? _recordedAuthSignals(String cell) {
  if (cell.trim().isEmpty) return null;
  final names = [for (final name in cell.split(',')) name.trim()];
  var last = -1;
  for (final name in names) {
    final index = _codexAuthSignals.indexOf(name);
    if (index <= last) return null;
    last = index;
  }
  return names;
}

/// A deliberately literal registry: version and OS identify the observation,
/// while only the signal name is projected into the runtime classifier.
List<_AuthSignature> _parseCodexAuth(String source) {
  final reader = _QualifiedSourceParser(source);
  for (final token in [
    'const',
    'confirmedCodexAuthSignatures',
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
    reader._expect(token);
  }
  final entries = <_AuthSignature>[];
  if (!reader._consume(']')) {
    while (true) {
      reader._expect('(');
      final version = reader._readString();
      reader._expect(',');
      final os = reader._readString();
      reader._expect(',');
      final signal = reader._readString();
      reader._consume(',');
      reader._expect(')');
      final entry = (version, os, signal);
      if (!_nativeVersion.hasMatch(version) ||
          !_oses.contains(os) ||
          !_codexAuthSignals.contains(signal) ||
          entries.contains(entry)) {
        throw const FormatException('invalid or duplicate auth provenance');
      }
      entries.add(entry);
      if (reader._consume(']')) break;
      reader._expect(',');
      if (reader._consume(']')) break;
    }
  }
  reader._expect(';');
  reader._skipTrivia();
  if (reader._position != source.length) {
    throw const FormatException('unexpected source after auth registry');
  }
  return entries;
}

class _NativeSection {
  _NativeSection(this.version, this.os);
  final String version;
  final String os;
  final rows = <String, _Observation>{};
  bool invalid = false;
  bool malformed = false;
  String where(String item) => 'codex-app-server codex $version: $os: $item';
}

/// Native table cells use literal Unicode plus `\\|`, `\\\\`, `\\n`, `\\r`,
/// `\\t`, and `\\uXXXX` for exact boundary spaces/control characters.
/// Delimiters are recognized before decoding; unknown/dangling
/// escapes fail. Claude Markdown keeps its original cell grammar.
List<String> _nativeCells(String line) {
  final encoded = line.trim();
  final cells = <String>[];
  final value = StringBuffer();
  var position = encoded.startsWith('|') ? 1 : 0;
  var endedAtDelimiter = false;
  while (position < encoded.length) {
    final char = encoded[position++];
    endedAtDelimiter = false;
    if (char == '|') {
      cells.add(value.toString().trim());
      value.clear();
      endedAtDelimiter = true;
    } else if (char == r'\') {
      if (position == encoded.length) {
        throw const FormatException('dangling cell escape');
      }
      value.write(char);
      value.write(encoded[position++]);
    } else {
      value.write(char);
    }
  }
  if (!endedAtDelimiter) cells.add(value.toString().trim());
  return [for (final cell in cells) _decodeNativeCell(cell)];
}

String _decodeNativeCell(String encoded) {
  final value = StringBuffer();
  for (var position = 0; position < encoded.length; position++) {
    final char = encoded[position];
    if (char != r'\') {
      value.write(char);
      continue;
    }
    if (++position == encoded.length) {
      throw const FormatException('dangling cell escape');
    }
    switch (encoded[position]) {
      case '|':
        value.write('|');
      case r'\':
        value.write(r'\');
      case 'n':
        value.write('\n');
      case 'r':
        value.write('\r');
      case 't':
        value.write('\t');
      case 'u':
        if (position + 4 >= encoded.length) {
          throw const FormatException('incomplete cell Unicode escape');
        }
        final digits = encoded.substring(position + 1, position + 5);
        if (!RegExp(r'^[0-9a-fA-F]{4}$').hasMatch(digits)) {
          throw const FormatException('invalid cell Unicode escape');
        }
        value.writeCharCode(int.parse(digits, radix: 16));
        position += 4;
      default:
        throw const FormatException('unknown cell escape');
    }
  }
  return value.toString();
}

/// A native failed call's Notes cell is exactly `observed: <JSON string>`.
/// JSON quoting preserves embedded quotes/control characters without truncation.
String? _nativeObservedText(String notes) {
  if (!notes.startsWith('observed: ')) return null;
  try {
    final value = jsonDecode(notes.substring('observed: '.length));
    return value is String && value.isNotEmpty ? value : null;
  } on FormatException {
    return null;
  }
}

/// Native observations are evidence only. An absent section never becomes a
/// runtime allowlist; each recorded section nevertheless has a complete shape.
List<String> _checkCodexObservations(
  String markdown,
  String? authSource,
  Map<_Adapter, String> listedFailures,
  List<String> failures,
  List<String> unproven,
  List<String> recorded,
) {
  final signatures = <_AuthSignature>[];
  if (authSource != null) {
    try {
      signatures.addAll(_parseCodexAuth(authSource));
    } on FormatException catch (error) {
      failures.add(
        'source: unrecognised Codex auth registry: ${error.message}',
      );
    }
  }
  final sections = <(String, String), _NativeSection>{};
  final versions = <String>{};
  String? version;
  _NativeSection? section;
  String? fenceCharacter;
  var fenceLength = 0;
  final fence = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$');
  final heading = RegExp(r'^## native codex-app-server codex (\S+)$');
  const header = [
    'Item',
    'Kind',
    'Result',
    'Notes',
    'Auth code',
    'Auth message',
  ];
  final separator = RegExp(r'^:?-+:?$');
  void fail(String item, String text, {bool malformed = true}) {
    section?.invalid = true;
    if (malformed) section?.malformed = true;
    failures.add(
      '${section?.where(item) ?? 'codex-app-server codex ${version ?? 'unknown'}: unspecified: $item'}: $text',
    );
  }

  for (final raw in markdown.replaceAll('\r\n', '\n').split('\n')) {
    final marker = fence.firstMatch(raw);
    if (fenceCharacter != null) {
      if (marker != null &&
          marker.group(1)!.startsWith(fenceCharacter) &&
          marker.group(1)!.length >= fenceLength &&
          marker.group(2)!.trim().isEmpty) {
        fenceCharacter = null;
      }
      continue;
    }
    if (marker != null) {
      fenceCharacter = marker.group(1)![0];
      fenceLength = marker.group(1)!.length;
      continue;
    }
    final line = raw.trim();
    if (line.startsWith('## ')) {
      version = null;
      section = null;
      if (!line.startsWith('## native')) continue;
      final match = heading.firstMatch(line);
      if (match == null || !_nativeVersion.hasMatch(match.group(1)!)) {
        failures.add('Codex results: unrecognised native section "$line"');
      } else {
        version = match.group(1)!;
        versions.add(version);
      }
      continue;
    }
    if (version == null) continue;
    if (line.startsWith('### ')) {
      final os = line.substring(4).trim();
      final key = (version, os);
      final previous = sections[key];
      section = previous ?? _NativeSection(version, os);
      sections[key] = section;
      if (!_oses.contains(os)) fail('section', 'unknown OS');
      if (previous != null) fail('section', 'duplicate native OS section');
      continue;
    }
    if (!line.startsWith('|')) continue;
    if (section == null) {
      fail('section', 'table has no OS');
      continue;
    }
    final List<String> cells;
    try {
      cells = _nativeCells(line);
    } on FormatException catch (error) {
      fail('section', error.message);
      continue;
    }
    final item = cells.first;
    if (cells.length != header.length) {
      fail(item, 'expected six table cells');
      continue;
    }
    if (cells.indexed.every((cell) => cell.$2 == header[cell.$1]) ||
        cells.every(separator.hasMatch)) {
      continue;
    }
    if (!_nativeRequired.contains(item) && !_nativeOptional.contains(item)) {
      fail(item, 'unknown native item');
      continue;
    }
    if (section.rows.containsKey(item)) {
      fail(item, 'duplicate item row');
      continue;
    }
    section.rows[item] = _Observation(
      cells[1],
      cells[2],
      cells[4],
      cells[5],
      cells[3],
    );
    if (!const ['user', 'agent'].contains(cells[1])) fail(item, 'unknown kind');
    if (!const ['pass', 'fail', 'unverified'].contains(cells[2])) {
      fail(item, 'invalid or blank result');
    }
    if (cells[3].isEmpty) fail(item, 'result requires observation notes');
    if (item != 'auth-required' &&
        (cells[4].isNotEmpty || cells[5].isNotEmpty)) {
      fail(item, 'auth cells belong only to auth-required');
    }
  }
  if (fenceCharacter != null) {
    failures.add('Codex results: unclosed code fence');
    for (final s in sections.values) {
      s.invalid = true;
      s.malformed = true;
    }
  }
  for (final v in versions) {
    if (!sections.keys.any((key) => key.$1 == v)) {
      failures.add(
        'codex-app-server codex $v: unspecified: section: missing OS section',
      );
    }
  }
  for (final s in sections.values) {
    section = s;
    for (final item in _nativeRequired) {
      if (!s.rows.containsKey(item)) fail(item, 'missing required observation');
    }
    for (final row in s.rows.entries) {
      final item = row.key;
      final observation = row.value;
      if (observation.result == 'fail') fail(item, 'fail', malformed: false);
      if (observation.result == 'unverified') unproven.add(s.where(item));
      if (item == 'auth-required') {
        if (observation.result == 'pass') {
          final names = _recordedAuthSignals(observation.code);
          if (names == null || observation.message.isNotEmpty) {
            fail(
              item,
              'pass requires observed Codex signal names in fixed order and an empty Message',
            );
          }
        } else if (observation.code.isNotEmpty ||
            observation.message.isNotEmpty) {
          fail(item, 'unsigned auth classification requires a recorded pass');
        }
      }
      if (item == toolCallItem && observation.result == 'fail') {
        final observed = _nativeObservedText(observation.notes);
        final listed = listedFailures[('codex-app-server', s.version)];
        if (observed == null) {
          fail(item, 'fail needs exactly one observed: "<text>" in Notes');
        } else if (listed == null) {
          fail(item, 'fail is not listed in toolDeliveryFailures');
        } else if (listed != observed) {
          fail(
            item,
            'observed text differs from the toolDeliveryFailures entry',
          );
        } else {
          recorded.add('codex-app-server ${s.version} ${s.os}: $listed');
        }
      }
    }
  }
  final backedSignals = <String>{};
  for (final signature in signatures) {
    final s = sections[(signature.$1, signature.$2)];
    final row = s?.rows['auth-required'];
    if (s == null ||
        s.malformed ||
        row == null ||
        row.result != 'pass' ||
        !(_recordedAuthSignals(row.code)?.contains(signature.$3) ?? false) ||
        row.notes.isEmpty) {
      if (s != null) s.invalid = true;
      failures.add(
        'Codex auth provenance ${signature.$1} ${signature.$2} ${signature.$3}: auth registry requires a matching recorded auth-required pass',
      );
    } else {
      backedSignals.add(signature.$3);
    }
  }
  for (final s in sections.values) {
    final auth = s.rows['auth-required'];
    if (auth == null || auth.result != 'pass') continue;
    for (final name in _recordedAuthSignals(auth.code) ?? const <String>[]) {
      // Version and OS are provenance, never a gate: a later section's pass
      // is backed by the signal's valid original recorded observation.
      if (!backedSignals.contains(name)) {
        s.invalid = true;
        failures.add(
          '${s.where('auth-required')}: signal $name has no valid auth registry provenance',
        );
      }
    }
  }
  for (final listed in listedFailures.entries.where(
    (e) => e.key.$1 == 'codex-app-server',
  )) {
    final observed = sections.values
        .where((s) => s.version == listed.key.$2)
        .toList();
    if (observed.isEmpty) {
      failures.add(
        'codex-app-server ${listed.key.$2}: kumiko tool call: toolDeliveryFailures has no native observation section',
      );
    }
    for (final s in observed) {
      final row = s.rows[toolCallItem];
      if (row == null ||
          row.result != 'fail' ||
          _nativeObservedText(row.notes) != listed.value) {
        s.invalid = true;
        failures.add(
          '${s.where(toolCallItem)}: toolDeliveryFailures conflicts with recorded evidence',
        );
      }
    }
  }
  return [
    for (final s in sections.values)
      'CODEX OBSERVATIONS: ${s.version} ${s.os}: ${s.invalid
          ? 'FAIL'
          : _nativeRequired.any((item) => s.rows[item]?.result == 'unverified')
          ? 'INCOMPLETE'
          : 'PASS'}',
  ];
}

/// Checks source and recorded evidence without filesystem or process access.
/// [qualifiedSource] is null when the qualified source is missing.
QualificationReport checkQualification(
  String markdown,
  String? qualifiedSource, {
  String? codexMarkdown,
  String? codexAuthSource,
}) {
  final failures = <String>[];
  final unproven = <String>[];
  final recorded = <String>[];
  final nativeObservations = <String>[];
  QualificationReport report(String? verdict) => QualificationReport(
    failures: failures,
    unproven: unproven,
    verdict: failures.isEmpty ? verdict : null,
    toolDeliveryFailures: recorded,
    codexObservations: nativeObservations,
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
  if (claims.keys.any((pair) => pair.$1 == 'codex-app-server')) {
    failures.add(
      'source: Codex native observations cannot enter qualifiedAdapters',
    );
    return report(null);
  }
  if (markdown.trim().isEmpty) {
    failures.add('results: document is blank');
    return report(null);
  }
  if (codexMarkdown != null && codexMarkdown.trim().isEmpty) {
    failures.add('Codex results: document is blank');
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
    rows[item] = _Observation(cells[1], cells[2], cells[4], cells[5], cells[3]);
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
                failures.add('$where: fail needs observed: "<text>" in Notes');
              } else if (listed == null) {
                failures.add(
                  '$where: fail is not listed in toolDeliveryFailures',
                );
              } else if (listed != observed) {
                failures.add(
                  '$where: observed text differs from the toolDeliveryFailures entry',
                );
              } else {
                recorded.add('${entry.key.$1} ${entry.key.$2} $os: $observed');
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
    if (listed.key.$1 == 'codex-app-server') continue;
    final rows = {
      for (final os in _oses) os: evidence[listed.key]?[os]?[toolCallItem],
    };
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
      } else if (row == null || row.result != 'fail') {
        // Checked per OS: the entry reports the version unavailable on every
        // OS, so each OS needs the observed failure; pass, unproven or
        // missing evidence anywhere contradicts it.
        failures.add(
          '$where: toolDeliveryFailures lists this version but the evidence is '
          '${row == null
              ? 'missing'
              : row.result.isEmpty
              ? 'blank'
              : row.result}',
        );
      }
    }
  }
  nativeObservations.addAll(
    _checkCodexObservations(
      codexMarkdown ?? markdown,
      codexAuthSource,
      listedFailures,
      failures,
      unproven,
      recorded,
    ),
  );
  return report(
    claims.isEmpty
        ? 'NO CLAIMS (no adapter qualified)'
        : (unproven.any((item) => !item.startsWith('codex-app-server codex '))
              ? 'ACCEPTED'
              : 'QUALIFIED'),
  );
}

/// Reads the two offline inputs, prints the report and returns its exit code.
int runQualificationCheck(
  List<String> args, {
  required StringSink out,
  String? codexResultsPath,
  String? codexAuthSourcePath,
}) {
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
  String? nativeMarkdown;
  String? nativeAuth;
  final nativePath =
      codexResultsPath ?? (args.isEmpty ? defaultCodexResultsPath : null);
  if (nativePath != null) {
    try {
      final file = File(nativePath);
      // The unrecorded default is optional; an explicitly requested input is not.
      if (codexResultsPath != null || file.existsSync()) {
        nativeMarkdown = file.readAsStringSync();
      }
    } on FileSystemException catch (error) {
      out.writeln(
        'FAILED: Codex results: could not read $nativePath: ${error.message}',
      );
      return 1;
    }
  }
  // The registry's provenance lives in the Codex record, so the default
  // registry is checked only together with that record. An explicit registry
  // is always read.
  final authPath =
      codexAuthSourcePath ??
      (nativePath != null ? defaultCodexAuthSourcePath : null);
  if (authPath != null) {
    try {
      nativeAuth = File(authPath).readAsStringSync();
    } on FileSystemException catch (error) {
      out.writeln(
        'FAILED: Codex auth source: could not read $authPath: ${error.message}',
      );
      return 1;
    }
  }
  final report = checkQualification(
    markdown,
    source,
    codexMarkdown: nativeMarkdown,
    codexAuthSource: nativeAuth,
  );
  for (final item in report.unproven) {
    out.writeln('unproven: $item');
  }
  for (final failure in report.failures) {
    out.writeln('FAILED: $failure');
  }
  for (final recorded in report.toolDeliveryFailures) {
    out.writeln('TOOL DELIVERY FAILURE RECORDED: $recorded');
  }
  for (final observation in report.codexObservations) {
    out.writeln(observation);
  }
  if (report.verdict != null) out.writeln(report.verdict);
  return report.exitCode;
}

void main(List<String> args) {
  exit(runQualificationCheck(args, out: stdout));
}
