// Root-only tooling intentionally consumes the workspace's public protocol API
// without adding a production dependency to the workspace root.
// ignore: depend_on_referenced_packages
import 'package:host_protocol/host_protocol.dart';

import 'check_qualification.dart';

const qualificationOses = ['windows', 'linux', 'macos'];
const _items = [
  'launch',
  'streaming',
  'tool activity',
  'permission request',
  'Stop',
  'close with confirmation',
  'load',
  'resume',
  'auth-required observed',
];
const finderQualificationItem = 'launch from Finder or the Dock';
List<String> qualificationItems(String os) {
  if (!qualificationOses.contains(os)) {
    throw FormatException('Unsupported OS: $os');
  }
  return [..._items, if (os == 'macos') finderQualificationItem];
}

class QualificationOptions {
  QualificationOptions._(
    this.dryRun,
    this.help,
    this.workspace,
    this.profileDir,
    this.profile,
    this.evidence,
  );
  final bool dryRun;
  final bool help;
  final String? workspace;
  final String? profileDir;
  final String? profile;
  final String evidence;

  factory QualificationOptions.parse(List<String> args) {
    final values = <String, String>{};
    final flags = <String>{};
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--dry-run' || arg == '--help') {
        if (!flags.add(arg)) throw FormatException('Repeated $arg');
      } else if (const [
        '--workspace',
        '--profile-dir',
        '--profile',
        '--evidence',
      ].contains(arg)) {
        if (values.containsKey(arg) ||
            i + 1 == args.length ||
            args[i + 1].startsWith('--') ||
            args[i + 1].trim().isEmpty) {
          throw FormatException('Expected one value for $arg');
        }
        values[arg] = args[++i];
      } else {
        throw FormatException('Unknown argument: $arg');
      }
    }
    final dry = flags.contains('--dry-run');
    if (dry && values.isNotEmpty) {
      throw const FormatException(
        '--dry-run owns its workspace/profile and never accepts evidence destinations',
      );
    }
    if (!dry && !flags.contains('--help') && values['--workspace'] == null) {
      throw const FormatException('Real qualification requires --workspace');
    }
    return QualificationOptions._(
      dry,
      flags.contains('--help'),
      values['--workspace'],
      values['--profile-dir'],
      values['--profile'],
      values['--evidence'] ?? defaultQualificationResultsPath,
    );
  }
}

/// Terminal presentation only. Never use the displayed text as exact evidence.
String qualificationDisplay(String value) {
  const limit = 512;
  final prefix = value.length > limit ? value.substring(0, limit) : value;
  final safe = prefix.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '?');
  return value.length > limit ? '$safe [display truncated]' : safe;
}

/// Preserve known failure fields consistently without dumping arbitrary RPC
/// data, profile environments, or transcripts. Exact auth evidence is read
/// separately from the original native fields, never this bounded display.
String qualificationRpcDiagnostic(RpcException error) {
  final fields = <String>[
    'reason=${qualificationDisplay(error.reason)}',
    for (final key in const [
      'stage',
      'status',
      'resumeReason',
      'nativeCode',
      'nativeMessageTruncated',
    ])
      if (error.data[key] case final String value)
        '$key=${qualificationDisplay(value)}'
      else if (error.data[key] is num || error.data[key] is bool)
        '$key=${error.data[key]}',
    'message=${qualificationDisplay(error.message)}',
    for (final key in const ['nativeMessage', 'detail'])
      if (error.data[key] case final String value)
        '$key=${qualificationDisplay(value)}',
  ];
  return fields.join('; ');
}

bool approvedAction({required bool interactive, required String? answer}) =>
    interactive && answer?.trim().toLowerCase() == 'yes';
bool mayWriteEvidence({
  required bool fixture,
  required bool interactive,
  required String? answer,
}) => !fixture && approvedAction(interactive: interactive, answer: answer);

RuntimeProfile selectQualificationProfile(
  RuntimeListResult list,
  String? selected,
) {
  final id = selected ?? list.defaultId;
  if (id == null || (selected == null && !list.defaultAvailable)) {
    throw StateError(
      'No available default runtime profile: ${list.defaultReason ?? 'not configured'}',
    );
  }
  for (final profile in list.profiles) {
    if (profile.id == id) return profile;
  }
  throw StateError('Runtime profile $id is missing; no fallback was selected');
}

Map<String, String> isolatedAuthEnvironment(
  Map<String, String> profile,
  Map<String, String> inherited,
  String configDir,
) => {
  ...profile,
  'CLAUDE_CONFIG_DIR': configDir,
  for (final key in const [
    'ANTHROPIC_API_KEY',
    'ANTHROPIC_AUTH_TOKEN',
    'CLAUDE_CODE_OAUTH_TOKEN',
  ])
    if (profile.containsKey(key) || inherited.containsKey(key)) key: '',
};

const qualificationAuthPrompt = 'Reply only OK; no tools or file changes.';

/// The isolated observation uses ordinary host operations supplied by the CLI.
/// Starting a session and accepting a prompt are not model/auth observations.
/// The caller bounds [waitForTurn] and owns session/host/profile cleanup.
Future<QualificationObservation?> runQualificationAuthProbe({
  required bool fixture,
  required Future<void> Function() start,
  required Future<void> Function() attach,
  required Future<bool> Function(String question) approve,
  required Future<void> Function(String text) prompt,
  required Future<AgentTurnEndedParams> Function() waitForTurn,
  required void Function(String message) report,
}) async {
  Future<QualificationObservation?> nativeError(
    String stage,
    Object? code,
    Object? message,
    bool truncated,
  ) async {
    if (code is! int || message is! String || message.isEmpty || truncated) {
      report(
        'Exact native code/message unavailable or truncated at $stage; auth cannot qualify.',
      );
      return null;
    }
    report(
      'Actual $stage native code: $code\nActual native message (exact):\n$message',
    );
    if (fixture) {
      report('FIXTURE ONLY: native error is not real qualification evidence.');
      return null;
    }
    if (!await approve(
      'Do you personally confirm this exact native error means authentication is required (not another failure)?',
    )) {
      report(
        'Authentication semantics not confirmed; auth-required remains unrecorded.',
      );
      return null;
    }
    if (!await approve(
      'Did you personally verify this exact result for auth-required observed?',
    )) {
      report('Evidence not confirmed; auth-required remains unrecorded.');
      return null;
    }
    return QualificationObservation.confirmed(
      passed: true,
      confirmed: true,
      authCode: '$code',
      authMessage: message,
    );
  }

  try {
    await start();
  } on RpcException catch (error) {
    report('Actual isolated start error: ${qualificationRpcDiagnostic(error)}');
    if (error.data['stage'] != 'session/new') {
      report(
        'Not a session/new observation; auth-required remains unrecorded.',
      );
      return null;
    }
    return nativeError(
      'session/new',
      error.data['nativeCode'],
      error.data['nativeMessage'],
      error.data['nativeMessageTruncated'] == true,
    );
  } on Object catch (error) {
    report('Isolated start failed: $error; auth-required remains unrecorded.');
    return null;
  }

  report(
    'Isolated start SUCCEEDED. This does not prove model execution or authentication.\n'
    'Other provider or OS credentials may still authenticate.',
  );
  try {
    await attach();
  } on Object catch (error) {
    report(
      'Isolated attach failed: ${error is RpcException ? qualificationRpcDiagnostic(error) : error}; '
      'auth-required remains unrecorded.',
    );
    return null;
  }
  if (!await approve(
    'Approve sending this exact minimal prompt in the isolated session '
    '(may contact a provider and spend tokens)?\n$qualificationAuthPrompt',
  )) {
    report('Isolated prompt declined; auth-required remains unrecorded.');
    return null;
  }
  try {
    await prompt(qualificationAuthPrompt);
  } on RpcException catch (error) {
    report(
      'Isolated prompt request failed: ${qualificationRpcDiagnostic(error)}',
    );
    if (error.data['stage'] != 'session/prompt') {
      report(
        'Not a session/prompt observation; auth-required remains unrecorded.',
      );
      return null;
    }
    return nativeError(
      'session/prompt',
      error.data['nativeCode'],
      error.data['nativeMessage'],
      error.data['nativeMessageTruncated'] == true,
    );
  } on Object catch (error) {
    report(
      'Isolated prompt request failed: $error; auth-required remains unrecorded.',
    );
    return null;
  }

  report('Isolated prompt accepted; waiting for its actual turn outcome.');
  final AgentTurnEndedParams turn;
  try {
    turn = await waitForTurn();
  } on Object catch (error) {
    report(
      'Isolated turn incomplete: $error; auth-required remains unrecorded.',
    );
    return null;
  }
  if (turn.error != null) {
    report(
      'Isolated session/prompt turn failed: ${qualificationDisplay(turn.error!)}; '
      '${qualificationDisplay(turn.message ?? '')}',
    );
    return nativeError(
      'session/prompt',
      turn.nativeCode,
      turn.nativeMessage,
      turn.nativeMessageTruncated,
    );
  }
  if (turn.stopReason == 'end_turn') {
    report(
      'Isolated model turn completed successfully. Authentication may still be available; '
      'success is NOT an auth-required pass.',
    );
  } else {
    report(
      'Isolated turn ended without successful model completion: '
      '${qualificationDisplay(turn.stopReason ?? 'unspecified')}; '
      'auth-required remains unrecorded.',
    );
  }
  return null;
}

class QualificationObservation {
  QualificationObservation.confirmed({
    required bool passed,
    required bool confirmed,
    this.authCode = '',
    this.authMessage = '',
    this.authTruncated = false,
  }) : result = passed ? 'pass' : 'fail' {
    if (!confirmed) {
      throw StateError('A real user observation needs explicit confirmation');
    }
  }
  const QualificationObservation.unproven()
    : result = 'unproven',
      authCode = '',
      authMessage = '',
      authTruncated = false;
  final String result;
  final String authCode;
  final String authMessage;
  final bool authTruncated;
}

void _cell(String text) {
  if (RegExp(r'[|\x00-\x1f\x7f]').hasMatch(text) || text.trim() != text) {
    throw const FormatException(
      'Evidence metadata cannot contain pipes, controls or outer whitespace',
    );
  }
}

void validateQualificationIdentity((String, String) adapter) {
  for (final value in [adapter.$1, adapter.$2]) {
    if (value.isEmpty ||
        RegExp(r'''[\s|'"$\\`\x00-\x1f\x7f]''').hasMatch(value)) {
      throw const FormatException(
        'Exact initialized identity cannot be represented safely in evidence',
      );
    }
  }
}

/// Updates just the observed OS, retaining all other recorded text verbatim.
/// A new section requires actual Windows observations; untried Windows is never
/// manufactured, even when today's real run took place on Linux or macOS.
String mergeQualificationEvidence(
  String original, {
  required (String, String) adapter,
  required String os,
  required Map<String, QualificationObservation> observations,
  required bool fixture,
  required DateTime date,
}) {
  if (fixture) throw StateError('Fixture output is not qualification evidence');
  validateQualificationIdentity(adapter);
  final items = qualificationItems(os);
  if (observations.length != items.length ||
      !items.every(observations.containsKey)) {
    throw StateError(
      'Every $os item must have a real observation before evidence is written',
    );
  }
  for (final entry in observations.entries) {
    final row = entry.value;
    if (row.result == 'unproven' && os == 'windows') {
      throw StateError('Windows observations cannot be unproven');
    }
    _cell(row.authCode);
    _cell(row.authMessage);
    if (entry.key == 'auth-required observed' &&
        (row.result == 'pass' || os == 'windows') &&
        (row.authCode.isEmpty ||
            row.authMessage.isEmpty ||
            row.authTruncated)) {
      throw StateError(
        'Authentication evidence needs the exact nontruncated native code and message',
      );
    }
  }
  final before = checkQualification(
    original,
    'const qualifiedAdapters = <(String, String, List<String>)>[];',
  );
  if (before.failures.isNotEmpty) {
    throw FormatException(before.failures.join('\n'));
  }
  final heading = '## adapter ${adapter.$1} ${adapter.$2}';
  // Only unfenced headings count. Preserve byte ranges outside this OS table.
  final headings = <(String, int)>[];
  var offset = 0;
  String? fence;
  var fenceLength = 0;
  for (final line in original.split('\n')) {
    final text = line.trim();
    final match = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$').firstMatch(line);
    if (match != null) {
      if (fence == null) {
        fence = match[1]![0];
        fenceLength = match[1]!.length;
      } else if (match[1]![0] == fence &&
          match[1]!.length >= fenceLength &&
          match[2]!.trim().isEmpty) {
        fence = null;
      }
    } else if (fence == null &&
        (text.startsWith('## ') || text.startsWith('### '))) {
      headings.add((text, offset));
    }
    offset += line.length + 1;
  }
  final start = headings.indexWhere((h) => h.$1 == heading);
  var section = '$heading\n\n';
  var sectionStart = original.length;
  var sectionEnd = original.length;
  if (start >= 0) {
    sectionStart = headings[start].$2;
    sectionEnd =
        headings
            .skip(start + 1)
            .where((h) => h.$1.startsWith('## '))
            .firstOrNull
            ?.$2 ??
        original.length;
    section = original.substring(sectionStart, sectionEnd);
  }
  // Use only unfenced headings collected above. Regexing a section again would
  // mistake examples inside fenced blocks for recorded OS tables.
  final osHeadings = start < 0
      ? <(String, int)>[]
      : [
          for (final h in headings)
            if (h.$2 > sectionStart &&
                h.$2 < sectionEnd &&
                h.$1.startsWith('### '))
              (h.$1, h.$2 - sectionStart),
        ];
  (int, int)? platformRange(String platform) {
    final index = osHeadings.indexWhere((h) => h.$1 == '### $platform');
    if (index < 0) return null;
    return (
      osHeadings[index].$2,
      index + 1 < osHeadings.length ? osHeadings[index + 1].$2 : section.length,
    );
  }

  final windows = platformRange('windows');
  if (os != 'windows') {
    if (windows == null) {
      throw StateError('Windows is unrecorded; no evidence may be written');
    }
    final rows = <String, String>{};
    for (final line in section.substring(windows.$1, windows.$2).split('\n')) {
      if (!line.trim().startsWith('|')) continue;
      final cells = line.split('|').map((s) => s.trim()).toList();
      if (cells.length == 8) rows[cells[1]] = cells[3];
    }
    if (!_items.every((item) => const ['pass', 'fail'].contains(rows[item]))) {
      throw StateError('Windows is incomplete; no evidence may be written');
    }
  }
  String table(String platform, Map<String, QualificationObservation> rows) {
    final out = StringBuffer(
      '### $platform\n\n| Item | Kind | Result | Notes | Auth code | Auth message |\n|---|---|---|---|---|---|\n',
    );
    for (final item in qualificationItems(platform)) {
      final row = rows[item]!;
      final note = row.result == 'unproven'
          ? 'Not verified by a user on this OS.'
          : 'Real local adapter through test host; OS=$platform; '
                '${date.toUtc().toIso8601String().substring(0, 10)}; user confirmed ${row.result}.';
      out.writeln(
        '| $item | user | ${row.result} | $note | ${row.authCode} | ${row.authMessage} |',
      );
    }
    return '$out\n';
  }

  // Compute every range against the unchanged section, then replace only the
  // current OS. Other OS tables, notes, fences and their line endings survive.
  final current = platformRange(os);
  if (current != null) {
    section = section.replaceRange(
      current.$1,
      current.$2,
      table(os, observations),
    );
  } else {
    section += table(os, observations);
  }
  for (final platform in qualificationOses) {
    if (platform == os || platformRange(platform) != null) continue;
    section += table(platform, {
      for (final item in qualificationItems(platform))
        item: const QualificationObservation.unproven(),
    });
  }
  final result = start < 0
      ? '$original\n$section'
      : original.replaceRange(sectionStart, sectionEnd, section);
  final checked = checkQualification(
    result,
    'const qualifiedAdapters = <(String, String, List<String>)>[];',
  );
  if (checked.failures.isNotEmpty) {
    throw FormatException(checked.failures.join('\n'));
  }
  return result;
}
