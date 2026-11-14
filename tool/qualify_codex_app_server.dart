/// Bounded native qualification through the ordinary test-host service path.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Root tooling uses the workspace's already-resolved public protocol/crypto.
// ignore: depend_on_referenced_packages
import 'package:crypto/crypto.dart';
// ignore: depend_on_referenced_packages
import 'package:host_protocol/host_protocol.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:process_containment/process_containment.dart';

import '../packages/host/test/it/support/host_build.dart' as builder;

// ignore: depend_on_referenced_packages
import 'package:host/src/agent/codex/codex_auth_signatures.dart';
// ignore: depend_on_referenced_packages
import 'package:host/src/agent/codex/native_home_audit.dart'
    show
        NativeSelection,
        changedArtifactsDisclosure,
        changedArtifactsV2Disclosure,
        changedArtifactsV3Disclosure,
        changedArtifactsV4Disclosure;
// ignore: depend_on_referenced_packages
import 'package:host/src/agent/codex/windows_find_data.dart'
    show windowsFindData;
// ignore: depend_on_referenced_packages
import 'package:host/src/agent/tool_file_audit.dart' show AuditBudget;

const _legacyNativeScope =
    'metadata baseline; new/changed session files; always-scan mutable log/logs/state and SQLite/WAL/SHM artifacts plus root JSONL/state-JSON; missing/unknown changed artifacts make the audit incomplete; no credential/config contents';

/// The canonical scope text a manifest must carry for [selection]: the legacy
/// summary, or the selection's own disclosure.
String _nativeScopeFor(NativeSelection selection) => switch (selection) {
  NativeSelection.legacy => _legacyNativeScope,
  NativeSelection.changedArtifactsV1 => changedArtifactsDisclosure,
  NativeSelection.changedArtifactsV2 => changedArtifactsV2Disclosure,
  NativeSelection.changedArtifactsV3 => changedArtifactsV3Disclosure,
  NativeSelection.changedArtifactsV4 => changedArtifactsV4Disclosure,
};

Json makeCodexWalkPlan({
  required String workspace,
  required String profile,
  required String executable,
  required String nativeHome,
  required String version,
  required String hostExecutable,
  required String canaryCommand,
  required String stopCommand,
  String auditProfile = 'default',
  String nativeSelection = 'legacy',
}) => {
  'schema': 2,
  'workspace': workspace,
  'profile': profile,
  'nativeExecutable': executable,
  'nativeHome': nativeHome,
  'nativeVersion': version,
  'hostExecutable': hostExecutable,
  'approvalPolicy': 'native-configured; no qualification override',
  'nativeArgs': [
    'app-server',
    '-c',
    'mcp_servers.kumiko_qualification_probe.command=${jsonEncode(hostExecutable)}',
    '-c',
    'mcp_servers.kumiko_qualification_probe.args=${jsonEncode(['--test-fixture', 'qualification-mcp-env', '--report', p.join(workspace, 'qualification-env-presence.json')])}',
  ],
  'maxTurns': 3,
  'turnDeadlineSeconds': 75,
  'cost': 'Provider bills the configured model; no hard monetary cap is available. At most three root prompts/native turns, each with a 75-second observation deadline; tool loops can cause additional billable provider requests. No retries; Stop/close follows timeout.',
  'authExperiment': 'unapproved; separate scope',
  'canaryCommand': canaryCommand,
  'stopCommand': stopCommand,
  'envProbeReport': p.join(workspace, 'qualification-env-presence.json'),
  'prompts': [
    'Write three short numbered sentences about this inert qualification workspace. '
        'Then call only the Kumiko kumiko_session_info tool once and the '
        'kumiko_qualification_probe env_presence tool once. Do not read files, '
        'run commands, delegate, browse, or change files.',
    'Run exactly this inert command in the workspace and request native command '
        'approval. Do nothing else: $canaryCommand',
    'Run exactly this inert command in the workspace and request native command '
        'approval. Leave it running so the harness can exercise Stop, then close '
        'the session. Do nothing else: $stopCommand',
  ],
  'scan': {
    'roots': [workspace, profile, nativeHome],
    ...AuditBudget.named(auditProfile).echo,
    'nativeSelection': NativeSelection.named(nativeSelection).wire,
    'nativeScope': _nativeScopeFor(NativeSelection.named(nativeSelection)),
  },
};

Json validatedCodexAuditScan(Json plan) {
  final scan = plan['scan'];
  if (scan is! Json) throw const FormatException('missing audit scan');
  final name = scan.containsKey('auditProfile')
      ? scan['auditProfile']
      : 'default';
  if (name is! String) throw const FormatException('invalid audit profile');
  final budget = AuditBudget.named(name);
  // Absent means legacy for an old schema-2 manifest; it never means wider.
  final selectionName = scan.containsKey('nativeSelection')
      ? scan['nativeSelection']
      : 'legacy';
  if (selectionName is! String) {
    throw const FormatException('invalid native selection');
  }
  final selection = NativeSelection.named(selectionName);
  final scope = scan['nativeScope'];
  if (scope is! String ||
      (selection == NativeSelection.legacy
          ? scope.contains('changed-artifacts')
          : scope != _nativeScopeFor(selection))) {
    throw const FormatException('noncanonical native scope');
  }
  if (budget.echo.entries.any(
    (entry) =>
        entry.key != 'auditProfile' &&
        (scan[entry.key] is! int || scan[entry.key] != entry.value),
  )) {
    throw const FormatException('inconsistent audit limits');
  }
  final roots = scan['roots'];
  final declared = [plan['workspace'], plan['profile'], plan['nativeHome']];
  final paths =
      plan['workspace'] is String &&
          p.windows.isAbsolute(plan['workspace']! as String)
      ? p.windows
      : p.context;
  if (roots is! List ||
      roots.length != 3 ||
      declared.any((root) => root is! String || !paths.isAbsolute(root))) {
    throw const FormatException('invalid audit roots');
  }
  for (var i = 0; i < roots.length; i++) {
    if (roots[i] is! String ||
        !paths.isAbsolute(roots[i] as String) ||
        !paths.equals(
          paths.normalize(roots[i] as String),
          paths.normalize(declared[i]! as String),
        )) {
      throw const FormatException('inconsistent audit roots');
    }
  }
  return {
    ...scan,
    ...budget.echo,
    'nativeSelection': selection.wire,
    'roots': List<String>.unmodifiable(roots.cast<String>()),
  };
}

bool codexAuditEchoMatches(Json scan, Json echo) => const [
  'auditProfile',
  'maxFiles',
  'maxFileBytes',
  'maxTotalBytes',
  'nativeSelection',
].every((key) => echo[key] == scan[key]);
void requireCodexAuditPreparation(Json scan, Json echo) {
  if (!codexAuditEchoMatches(scan, echo)) {
    throw StateError('audit preparation echo differs from manifest');
  }
}

const _baselineErrorCategoryKeys = {
  'metadataLimit',
  'metadataStorage',
  'linkObservation',
  'nonRegular',
  'metadataIo',
  'traversalIo',
  'baselineIncomplete',
  'removedEntry',
  'changedUnknownFile',
  'changedUnknownDirectory',
  'directoryUnstable',
  'protectedEntry',
};
const _baselineIoErrorCategoryKeys = {
  'sharingViolation',
  'lockViolation',
  'accessDenied',
  'other',
};

/// Copies only fixed category keys with non-negative integer counts, so a
/// host reply can never put a name, path or other text into the receipt.
Map<String, int> _knownCounters(Object? value, Set<String> keys) => {
  if (value is Map)
    for (final MapEntry(:key, :value) in value.entries)
      if (keys.contains(key) && value is int && value >= 0)
        key as String: value,
};

/// Binds the audit once through the closed two-key preparation request, then
/// validates every echo before any App Server or prompt. In a changed-artifacts
/// selection (v1, v2 or v3) an incomplete or erroring baseline records a content-free
/// INCOMPLETE receipt and aborts: no provider work, no content scan, no fallback to legacy.
Future<void> prepareCodexAuditBinding({
  required Json scan,
  required Json observations,
  required Future<Json> Function(String method, Json params) call,
}) async {
  final echo = await call('test/codex.audit.prepare', {
    'auditProfile': scan['auditProfile'],
    'nativeSelection': scan['nativeSelection'],
  });
  requireCodexAuditPreparation(scan, echo);
  if (scan['nativeSelection'] == NativeSelection.legacy.wire) return;
  final complete = echo['baselineComplete'];
  final count = echo['baselineErrorCount'];
  if (complete == true && count is int && count == 0) return;
  observations['baselinePreflight'] = {
    'stage': 'baseline-preflight',
    'status': 'INCOMPLETE',
    'baselineComplete': false,
    // -1 marks a count the host did not report as a non-negative integer.
    'baselineErrorCount': count is int && count >= 0 ? count : -1,
    'baselineErrorCategories': _knownCounters(
      echo['baselineErrorCategories'],
      _baselineErrorCategoryKeys,
    ),
    'baselineIoErrorCategories': _knownCounters(
      echo['baselineIoErrorCategories'],
      _baselineIoErrorCategoryKeys,
    ),
    'providerWork': false,
    'contentScan': false,
  };
  throw StateError('native baseline incomplete; aborting before provider work');
}

/// Fixed preparation output: limits, selection and hash, plus the canonical
/// selection-specific wider-read disclosure for changed-artifacts-v1 through v4.
String codexPreparationSummary({
  required String manifest,
  required String sha256Hex,
  required AuditBudget budget,
  required String nativeSelection,
}) {
  final selection = NativeSelection.named(nativeSelection);
  return [
    'Manifest: $manifest',
    'SHA256: $sha256Hex',
    'Audit: ${jsonEncode(budget.echo)}',
    'NativeSelection: ${selection.wire}',
    if (selection != NativeSelection.legacy)
      'Disclosure: ${_nativeScopeFor(selection)}',
  ].join('\n');
}

void recordCodexCanaryAudit(Json observations, Json scan, Json result) {
  final audit = {...result};
  if (!codexAuditEchoMatches(scan, audit)) audit['complete'] = false;
  observations['canaryAudit'] = audit;
  if (audit['matchedFiles'] is int && (audit['matchedFiles']! as int) > 0) {
    observations['kumiko tool call'] = 'fail';
    observations['unsafeConfigurationPath'] =
        'REFUSE this path; do not repeat secret injection';
  } else if (observations['kumiko tool call'] != 'fail' &&
      (audit['matchedFiles'] != 0 ||
          audit['complete'] != true ||
          observations['unrelatedMcpEnvironmentIsolated'] != true ||
          observations['unrelatedCommandEnvironmentIsolated'] != true)) {
    observations['kumiko tool call'] = 'unverified';
  }
}

List<String> nativeArgsForManifest(Json plan) {
  final args = plan['nativeArgs'];
  if (plan['schema'] != 2 ||
      plan['approvalPolicy'] !=
          'native-configured; no qualification override' ||
      args is! List<Object?> ||
      args.isEmpty ||
      args.first != 'app-server' ||
      args.any((argument) => argument is! String)) {
    throw const FormatException(
      'schema2 with explicit native argv and native-configured policy required',
    );
  }
  return List<String>.unmodifiable(args.cast<String>());
}

/// The result of matching one native command-approval request against the
/// approved canary request: the option to answer with (null refuses) and a
/// content-free record of every match check.
///
/// [checks] is observational only. It never takes part in selection: the
/// option is chosen when, and only when, the request is not truncated, carries
/// the command-approval title, and every check passes.
///
/// Encoding of [checks]: one boolean per check. A check that has nothing to
/// examine is vacuously true, so each check can fail alone: `reasonLineValid`
/// when there is no reason line, `decisionsLineValid` when there is no
/// decisions line, `decisionsMatchOptions` when there is no valid decisions
/// list to compare, and `commandSingleLine` when the configured command is not
/// a string. `decisionsLinePresent` says whether a decisions line was seen.
/// `observedCommandContainsApproved` and `observedCommandStartsWithApproved`
/// are present only when the approved command is a string that the first
/// preview line does not match. `previewLineCount` and `optionCount` are
/// clamped to 99. No command, path, option name or decision value is stored.
class CanaryApprovalEvaluation {
  const CanaryApprovalEvaluation(this.optionId, this.checks);
  final String? optionId;
  final Json checks;
}

CanaryApprovalEvaluation evaluateCanaryApproval(
  AgentPermissionRequestedParams request,
  Json plan,
  int operation, {
  List<String> trustedShells = const [],
}) {
  const decisionsPrefix = 'Native decisions: ';
  const commandPrefix = 'Command: ';
  const directoryPrefix = 'Working directory: ';
  final validOperation = operation >= 1 && operation <= 2;
  final command = plan[operation == 1 ? 'canaryCommand' : 'stopCommand'];
  final preview = request.preview;
  final allLines = preview?.split('\n');
  var lines = allLines;
  // The host appends one canonical `Native decisions: [...]` line only for a
  // decision list containing JSON objects. Without it the original strict
  // two/three-line layout applies unchanged.
  var decisionsLinePresent = false;
  var decisionsLineValid = true;
  List<Object?>? decisions;
  if (lines != null &&
      lines.length > 1 &&
      lines.last.startsWith(decisionsPrefix)) {
    decisionsLinePresent = true;
    final line = lines.last;
    lines = lines.sublist(0, lines.length - 1);
    try {
      final parsed = jsonDecode(line.substring(decisionsPrefix.length));
      if (parsed is! List<Object?> ||
          jsonEncode(parsed) != line.substring(decisionsPrefix.length) ||
          !parsed.any((entry) => entry is Map) ||
          parsed.any((entry) => entry is! String && entry is! Map)) {
        decisionsLineValid = false;
      } else {
        decisions = parsed;
      }
    } on FormatException {
      decisionsLineValid = false;
    }
  }
  final commandConfigured = command is String;
  final commandSingleLine =
      command is! String || !(command.contains('\n') || command.contains('\r'));
  final previewLayoutValid =
      lines != null &&
      (lines.length == 2 || lines.length == 3) &&
      !lines.any((line) => line.startsWith(decisionsPrefix));
  final commandMatches =
      lines != null && lines.isNotEmpty && lines[0] == '$commandPrefix$command';
  final workspace = plan['workspace'];
  var workingDirectoryMatches = false;
  if (lines != null &&
      lines.length > 1 &&
      lines[1].startsWith(directoryPrefix)) {
    final cwd = lines[1].substring(directoryPrefix.length);
    workingDirectoryMatches =
        workspace is String &&
        p.windows.isAbsolute(cwd) &&
        p.windows.isAbsolute(workspace) &&
        p.windows.equals(cwd, workspace);
  }
  final reasonLineValid =
      lines == null || lines.length < 3 || lines[2].startsWith('Reason: ');
  final options = request.options;
  var decisionsMatchOptions = true;
  if (decisions != null) {
    // Entries correspond one-to-one to the displayed options. Objects are
    // indexed placeholders with the conservative persistent kind; a label
    // index or an allow_once kind alone never selects anything.
    if (options.length != decisions.length) {
      decisionsMatchOptions = false;
    } else {
      for (var i = 0; i < decisions.length; i++) {
        final entry = decisions[i];
        if (entry is String
            ? options[i].name != entry
            : options[i].name != 'Native option ${i + 1}' ||
                  options[i].kind != 'allow_always') {
          decisionsMatchOptions = false;
          break;
        }
      }
    }
  }
  final accepted = [
    for (final option in options)
      if (option.name == 'accept') option,
  ];
  final singleOneShotAccept =
      accepted.length == 1 && accepted.single.kind == 'allow_once';
  final checks = <String, Object?>{
    'validOperation': validOperation,
    'commandConfigured': commandConfigured,
    'commandSingleLine': commandSingleLine,
    'previewPresent': preview != null,
    'previewLayoutValid': previewLayoutValid,
    'commandMatches': commandMatches,
    'workingDirectoryMatches': workingDirectoryMatches,
    'reasonLineValid': reasonLineValid,
    'decisionsLinePresent': decisionsLinePresent,
    'decisionsLineValid': decisionsLineValid,
    'decisionsMatchOptions': decisionsMatchOptions,
    'singleOneShotAccept': singleOneShotAccept,
  };
  var wrapperMatches = false;
  if (command is String && !commandMatches) {
    final first = lines != null && lines.isNotEmpty ? lines[0] : null;
    final observed = first != null && first.startsWith(commandPrefix)
        ? first.substring(commandPrefix.length)
        : null;
    checks['observedCommandContainsApproved'] =
        observed != null && command.isNotEmpty && observed.contains(command);
    checks['observedCommandStartsWithApproved'] =
        observed != null && command.isNotEmpty && observed.startsWith(command);
    // The native command wrapper rule: the observed command decodes to a
    // trusted PowerShell, an optional -NoProfile, -Command and the approved
    // command exactly. Only the shape is recorded, never a word.
    final words = observed == null ? null : splitPosixShellWords(observed);
    final count = words?.length ?? 0;
    final shellTrusted =
        words != null && trustedPowerShellWord(words.first, trustedShells);
    final noProfile = count >= 2 && words![1] == '-NoProfile';
    final flagAt = noProfile ? 2 : 1;
    final commandFlag = count > flagAt && words![flagAt] == '-Command';
    final scriptMatches = words != null && words.last == command;
    wrapperMatches =
        words != null &&
        shellTrusted &&
        commandFlag &&
        scriptMatches &&
        count == (noProfile ? 4 : 3);
    checks['observedArgvParsed'] = words != null;
    checks['observedArgvWordCount'] = count.clamp(0, 99);
    checks['wrapperShellTrusted'] = shellTrusted;
    checks['wrapperNoProfile'] = noProfile;
    checks['wrapperCommandFlag'] = commandFlag;
    checks['wrapperScriptMatches'] = scriptMatches;
    checks['wrapperMatches'] = wrapperMatches;
    checks['trustedShellCount'] = trustedShells.length.clamp(0, 9);
  }
  checks['previewLineCount'] = (allLines?.length ?? 0).clamp(0, 99);
  checks['optionCount'] = options.length.clamp(0, 99);
  final matches =
      !request.truncated &&
      request.title == 'Command approval' &&
      validOperation &&
      commandConfigured &&
      commandSingleLine &&
      previewLayoutValid &&
      (commandMatches || wrapperMatches) &&
      workingDirectoryMatches &&
      reasonLineValid &&
      decisionsLineValid &&
      decisionsMatchOptions &&
      singleOneShotAccept;
  return CanaryApprovalEvaluation(
    matches ? accepted.single.optionId : null,
    Map<String, Object?>.unmodifiable(checks),
  );
}

String? allowedCanaryApproval(
  AgentPermissionRequestedParams request,
  Json plan,
  int operation, {
  List<String> trustedShells = const [],
}) => evaluateCanaryApproval(
  request,
  plan,
  operation,
  trustedShells: trustedShells,
).optionId;

/// Decodes a single-line POSIX shell-word string into its words without
/// executing, expanding, globbing or stripping comments. Returns null when the
/// input has a control character, an unquoted operator or expansion
/// character, an unescaped `$` or backquote inside double quotes, a trailing
/// backslash, an unterminated quote, or no words.
List<String>? splitPosixShellWords(String input) {
  const active = r';&|<>()$`*?[#~{}!';
  for (final unit in input.codeUnits) {
    if (unit < 0x20 || unit == 0x7f) return null;
  }
  final words = <String>[];
  StringBuffer? word;
  var i = 0;
  while (i < input.length) {
    final ch = input[i];
    if (ch == ' ') {
      if (word != null) words.add(word.toString());
      word = null;
      i++;
      continue;
    }
    word ??= StringBuffer();
    if (ch == r'\') {
      if (i + 1 >= input.length) return null;
      word.write(input[i + 1]);
      i += 2;
    } else if (ch == "'") {
      final end = input.indexOf("'", i + 1);
      if (end < 0) return null;
      word.write(input.substring(i + 1, end));
      i = end + 1;
    } else if (ch == '"') {
      i++;
      while (true) {
        if (i >= input.length) return null;
        final inner = input[i];
        if (inner == '"') {
          i++;
          break;
        }
        if (inner == r'$' || inner == '`') return null;
        if (inner == r'\') {
          if (i + 1 >= input.length) return null;
          final next = input[i + 1];
          if (!const [r'$', '`', '"', r'\'].contains(next)) word.write(inner);
          word.write(next);
          i += 2;
          continue;
        }
        word.write(inner);
        i++;
      }
    } else if (active.contains(ch)) {
      return null;
    } else {
      word.write(ch);
      i++;
    }
  }
  if (word != null) words.add(word.toString());
  return words.isEmpty ? null : words;
}

/// A drive-letter absolute Windows path with backslash separators only and
/// no empty, `.` or `..` segment; long-path, device and UNC forms never match.
bool _plainDrivePath(String path) {
  if (!RegExp(r'^[A-Za-z]:\\').hasMatch(path) || path.contains('/')) {
    return false;
  }
  return path
      .substring(3)
      .split(r'\')
      .every((part) => part.isNotEmpty && part != '.' && part != '..');
}

bool _asciiEqualsIgnoreCase(String a, String b) {
  if (a.length != b.length) return false;
  int lower(int c) => c >= 0x41 && c <= 0x5a ? c + 0x20 : c;
  for (var i = 0; i < a.length; i++) {
    final x = a.codeUnitAt(i);
    final y = b.codeUnitAt(i);
    if (x == y) continue;
    if (x >= 0x80 || y >= 0x80 || lower(x) != lower(y)) return false;
  }
  return true;
}

/// Whether [word] names one of [trusted] in the plain drive-letter form,
/// compared ASCII case-insensitively.
bool trustedPowerShellWord(String word, List<String> trusted) =>
    _plainDrivePath(word) &&
    trusted.any((shell) => _asciiEqualsIgnoreCase(word, shell));

/// Machine-registry sources of trusted PowerShell locations. Null or a throw
/// means the query failed and contributes no candidate.
abstract interface class PowerShellRegistry {
  String? systemRoot();
  List<String>? powerShellInstallLocations();
}

/// Reads HKLM through the system `reg.exe`, 64-bit view.
final class RegPowerShellRegistry implements PowerShellRegistry {
  List<String>? _values(String key, String name, {bool recurse = false}) {
    final windows = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final result = Process.runSync(
      p.windows.join(windows, 'System32', 'reg.exe'),
      ['query', key, if (recurse) '/s', '/v', name, '/reg:64'],
    );
    if (result.exitCode != 0) return null;
    final value = RegExp(
      '^\\s+${RegExp.escape(name)}\\s+REG_(?:EXPAND_)?SZ\\s+(.*?)\\s*\$',
      multiLine: true,
    );
    return [
      for (final match in value.allMatches(result.stdout as String))
        match.group(1)!,
    ];
  }

  @override
  String? systemRoot() {
    final values = _values(
      r'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion',
      'SystemRoot',
    );
    return values == null || values.length != 1 ? null : values.single;
  }

  @override
  List<String>? powerShellInstallLocations() => _values(
    r'HKLM\SOFTWARE\Microsoft\PowerShellCore\InstalledVersions',
    'InstallLocation',
    recurse: true,
  );
}

/// The trusted PowerShell executables, each candidate judged on its own: a
/// plain drive-letter path to an existing regular file with no reparse point
/// in the file or any ancestor directory. Never throws.
List<String> resolveTrustedPowerShells(PowerShellRegistry registry) {
  String? root;
  List<String>? locations;
  try {
    root = registry.systemRoot();
  } on Object {
    root = null;
  }
  try {
    locations = registry.powerShellInstallLocations();
  } on Object {
    locations = null;
  }
  final candidates = [
    if (root != null && root.isNotEmpty)
      p.windows.join(
        root,
        'System32',
        'WindowsPowerShell',
        'v1.0',
        'powershell.exe',
      ),
    for (final location in locations ?? const <String>[])
      if (location.isNotEmpty) p.windows.join(location, 'pwsh.exe'),
  ];
  return [
    for (final candidate in candidates)
      if (_admitTrustedShell(candidate)) candidate,
  ];
}

const _reparsePointAttribute = 0x400;
const _directoryAttribute = 0x10;

bool _admitTrustedShell(String path) {
  try {
    if (!_plainDrivePath(path) ||
        FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.file) {
      return false;
    }
    // Every component below the drive root, checked on its own entry without
    // following links: ancestors are plain directories, the leaf a plain file.
    final parts = path.substring(3).split(r'\');
    var current = path.substring(0, 2);
    for (var i = 0; i < parts.length; i++) {
      current = '$current\\${parts[i]}';
      final record = windowsFindData(current);
      if (record == null ||
          record.attributes & _reparsePointAttribute != 0 ||
          (record.attributes & _directoryAttribute != 0) !=
              (i < parts.length - 1)) {
        return false;
      }
    }
    return true;
  } on Object {
    return false;
  }
}

/// Refuses a walk before its claim when no trusted shell resolved, so the
/// approval stays unspent.
void verifyCodexTrustedShells(List<String> trusted) {
  if (trusted.isEmpty) {
    throw StateError(
      'no trusted PowerShell resolved for the approval wrapper rule',
    );
  }
}

bool approvedCodexManifest(List<int> bytes, String digest) =>
    RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) &&
    sha256.convert(bytes).toString() == digest;

Never rejectCodexWalkPermission(
  Json observations,
  AgentPermissionRequestedParams request, {
  required int operation,
  required bool answered,
  required bool matchesApprovedRequest,
  Json? approvalChecks,
}) {
  observations['commandApprovalDiagnostic'] = {
    'stage': 'command-approval',
    'operation': operation.clamp(0, 2) + 1,
    'reason': answered ? 'additional-request' : 'outside-approved-request',
    'commandTitle': request.title == 'Command approval',
    'truncated': request.truncated,
    'hasOneShotAccept': request.options.any(
      (option) => option.kind == 'allow_once' && option.name == 'accept',
    ),
    'matchesApprovedRequest': matchesApprovedRequest,
    // Observational match checks, content-free; they never select an option.
    ...?approvalChecks,
  };
  throw StateError('unapproved native permission; stopping walk');
}

bool nativeStreamingObserved(List<int> perTurnEvents) =>
    perTurnEvents.any((count) => count > 1);

bool nativeDescendantSettled({
  required bool aliveBefore,
  required bool aliveAfter,
}) => aliveBefore && !aliveAfter;

void recordCodexMissingSession(Json observations) {
  // A baseline-preflight abort happens before App Server starts, so launch
  // was never attempted and stays unverified.
  if (!observations.containsKey('baselinePreflight')) {
    observations['launch'] = 'fail';
  }
  observations['canaryAudit'] = {
    'complete': false,
    'scanned': false,
    'reason': observations.containsKey('baselinePreflight')
        ? 'native baseline incomplete before provider work; no content scan'
        : 'startup failed without a registered session id; grant delivery and persistence were not audited',
  };
}

void recordCodexRpcFailure(
  Json observations,
  RpcException error, {
  required bool hasSession,
}) {
  observations['nativeDiagnostic'] = {
    'reason': clampUtf8(error.reason, 256),
    'message': clampUtf8(error.message, 4096),
    'messageTruncated': clampUtf8(error.message, 4096) != error.message,
    if (error.data['stage'] case final String stage)
      'stage': clampUtf8(stage, 64),
    if (error.data['status'] is int) 'status': error.data['status'],
    if (error.data['detail'] case final String detail)
      'detail': clampUtf8(detail, 4096),
    if (error.data['nativeCode'] is int) 'code': error.data['nativeCode'],
    if (error.data['nativeMessage'] case final String nativeMessage)
      'nativeMessage': clampUtf8(nativeMessage, 4096),
    'truncated':
        error.data['nativeMessageTruncated'] == true ||
        (error.data['nativeMessage'] is String &&
            clampUtf8(error.data['nativeMessage']! as String, 4096) !=
                error.data['nativeMessage']),
  };
  if (!hasSession) {
    recordCodexMissingSession(observations);
  }
}

class CodexWalkDiagnostics {
  static const _knownReasons = {
    'invalid approval timestamp': 'invalid-approval-timestamp',
    'missing approval turn': 'missing-approval-turn',
    'invalid native approval': 'invalid-native-approval',
    'invalid additional permissions': 'invalid-additional-permissions',
    'unknown additional permission grant':
        'unknown-additional-permission-grant',
    'unsupported native request': 'unsupported-native-request',
    'retired native turn': 'retired-native-turn',
    'offered decisions missing or unsupported': 'offered-decisions-unavailable',
    'control capacity exceeded': 'control-capacity-exceeded',
  };
  static const _displayPrefix =
      'Native approval unavailable: full details exceed display capacity; request cancelled.';
  final _displayRefusals = <Json>[];
  bool _displayRefusalsTruncated = false;
  bool get displayRefused => _noticeFlags['approvalDisplayUnavailable'] == true;
  Json? _displaySnapshot(String text) {
    const marker = ' [display-v1 ';
    if (!text.startsWith('$_displayPrefix$marker') ||
        !text.endsWith(']') ||
        utf8.encode(text).length > 1024) {
      return null;
    }
    try {
      final raw = jsonDecode(
        text.substring(_displayPrefix.length + marker.length, text.length - 1),
      );
      const booleans = [
        'isChild',
        'titleLoss',
        'previewLoss',
        'namesLoss',
        'countLoss',
        'encodedLoss',
      ];
      const sizes = [
        'titleBytes',
        'previewBytes',
        'maxNameBytes',
        'optionCount',
      ];
      const keys = {'category', ...booleans, ...sizes};
      if (raw is! Json ||
          raw.length != keys.length ||
          raw.keys.any((key) => !keys.contains(key)) ||
          !const [
            'command',
            'file-change',
            'additional-permissions',
            'other',
          ].contains(raw['category']) ||
          booleans.any((key) => raw[key] is! bool) ||
          sizes.any(
            (key) =>
                raw[key] is! int ||
                (raw[key]! as int) < 0 ||
                (raw[key]! as int) > (key == 'optionCount' ? 1024 : 1048576),
          )) {
        return null;
      }
      return {for (final key in keys) key: raw[key]};
    } on FormatException {
      return null;
    }
  }

  final _turnEnds = <Json>[];
  final _noticeFlags = <String, bool>{};
  bool _turnEndsTruncated = false;

  void recordTurnEnd(AgentTurnEndedParams turn) {
    if (_turnEnds.length == 3) {
      _turnEndsTruncated = true;
      return;
    }
    final reasons = [
      for (final reason in _knownReasons.entries)
        if ((turn.message?.contains(reason.key) ?? false) ||
            (turn.nativeMessage?.contains(reason.key) ?? false))
          reason.value,
    ];
    _turnEnds.add({
      'stopReason': switch (turn.stopReason) {
        null => 'none',
        'end_turn' => 'end_turn',
        'cancelled' => 'cancelled',
        'error' => 'error',
        _ => 'other',
      },
      'error': switch (turn.error) {
        null => 'none',
        'adapter-error' => 'adapter-error',
        ErrorCode.authRequired => ErrorCode.authRequired,
        _ => 'other',
      },
      'hasStopReason': turn.stopReason != null,
      'hasError': turn.error != null,
      'hasMessage': turn.message != null,
      'hasNativeMessage': turn.nativeMessage != null,
      'nativeMessageTruncated': turn.nativeMessageTruncated,
      if (turn.nativeCode != null) 'nativeCode': turn.nativeCode,
      'errorReasons': reasons.isNotEmpty
          ? reasons
          : [
              if (turn.message != null || turn.nativeMessage != null)
                'other'
              else
                'none',
            ],
    });
  }

  void recordEvent(AgentEvent event) {
    if (event.kind != AgentEventKind.notice) return;
    final text = event.text ?? '';
    if (text == _displayPrefix ||
        text.startsWith('$_displayPrefix [display-v1 ')) {
      _noticeFlags['approvalDisplayUnavailable'] = true;
      final snapshot = _displaySnapshot(text);
      if (snapshot != null) {
        if (_displayRefusals.length < 3) {
          _displayRefusals.add(snapshot);
        } else {
          _displayRefusalsTruncated = true;
        }
      }
    }
    final category = switch (text) {
      'Native approval unavailable: offered decisions missing or unsupported.' =>
        'approvalDecisionsUnavailable',
      _
          when text == _displayPrefix ||
              text.startsWith('$_displayPrefix [display-v1 ') =>
        'approvalDisplayUnavailable',
      'Native interaction refused: control capacity exceeded.' =>
        'controlCapacityRefused',
      'Codex unsupported native request refused.' => 'unsupportedRequest',
      'MCP elicitation unavailable: unsupported form or URL request.' =>
        'mcpElicitationCancelled',
      _
          when text.startsWith(
            'Native interaction capacity or turn unavailable',
          ) =>
        'interactionUnavailable',
      _ when text.startsWith('codex-protocol: ') => 'protocolError',
      _
          when text.startsWith('Codex error: ') ||
              RegExp(r'^Codex error -?\d+: ').hasMatch(text) =>
        'nativeError',
      _ => null,
    };
    if (category != null) _noticeFlags[category] = true;
    for (final reason in _knownReasons.entries) {
      if (text.contains(reason.key)) _noticeFlags[reason.value] = true;
    }
    if (event.truncated && category != null) {
      _noticeFlags['knownNoticeTruncated'] = true;
    }
  }

  void persist(Json observations) {
    observations['walkDiagnostics'] = {
      'turnEnds': [for (final turn in _turnEnds) Map<String, Object?>.of(turn)],
      'turnEndsTruncated': _turnEndsTruncated,
      'noticeFlags': Map<String, bool>.of(_noticeFlags),
      if (_displayRefusals.isNotEmpty)
        'approvalDisplayRefusals': [
          for (final snapshot in _displayRefusals)
            Map<String, Object?>.of(snapshot),
        ],
      if (_displayRefusalsTruncated) 'approvalDisplayRefusalsTruncated': true,
    };
  }
}

/// Reads the qualification command markers from command tool events.
///
/// Codex streams command output as untagged `toolUpdate` deltas that carry
/// only the tool-call id; the kind arrives on the item events. Each id keeps a
/// short raw carry so a marker split across deltas (or across a CRLF) is still
/// found, and its marker flags, so deltas seen before the command item count
/// once the item names the id a command. Only booleans and counts leave this
/// class; the carry stays in memory.
final class CodexCommandOutputTracker {
  static const running = 'KUMIKO_QUALIFICATION_RUNNING';
  static const isolated = 'KUMIKO_QUALIFICATION_CANARY\nFalse\nFalse';
  static const maxTrackedIds = 256;
  static const carryChars = 64;

  final _commandIds = <String>{};
  final _otherIds = <String>{};
  final _carry = <String, String>{};
  final _running = <String>{};
  final _isolated = <String>{};

  bool get runningCanary => _running.any(_commandIds.contains);
  bool get commandEnvironmentIsolated => _isolated.any(_commandIds.contains);
  int get trackedIds => _carry.length;
  int get retainedChars =>
      _carry.values.fold(0, (sum, carry) => sum + carry.length);

  void add(AgentEvent event) {
    if (event.kind != AgentEventKind.tool &&
        event.kind != AgentEventKind.toolUpdate) {
      return;
    }
    final id = event.toolCallId;
    if (id == null) return;
    final kind = event.toolKind;
    if (kind != null) {
      if (kind == 'commandExecution') {
        _commandIds.add(id);
        _otherIds.remove(id);
        for (final text in _texts(event)) {
          _scan(id, _normalize(text));
        }
      } else if (!_commandIds.contains(id)) {
        _otherIds.add(id);
        _forget(id);
      }
      return;
    }
    if (_otherIds.contains(id)) return;
    if (!_carry.containsKey(id) && _carry.length >= maxTrackedIds) {
      if (!_commandIds.contains(id)) return;
      final unknown = _carry.keys.where((key) => !_commandIds.contains(key));
      if (unknown.isNotEmpty) _forget(unknown.first);
    }
    for (final text in _texts(event)) {
      final joined = '${_carry[id] ?? ''}$text';
      _scan(id, _normalize(joined));
      _carry[id] = joined.length <= carryChars
          ? joined
          : joined.substring(joined.length - carryChars);
    }
  }

  void _scan(String id, String text) {
    if (text.contains(running)) _running.add(id);
    if (text.contains(isolated)) _isolated.add(id);
  }

  void _forget(String id) {
    _carry.remove(id);
    _running.remove(id);
    _isolated.remove(id);
  }

  static String _normalize(String text) => text.replaceAll('\r\n', '\n');

  static Iterable<String> _texts(AgentEvent event) sync* {
    for (final content in event.content) {
      final inner = content['content'];
      if (inner is Json && inner['text'] is String) {
        yield inner['text']! as String;
      }
    }
  }
}

/// The furthest stage the independent MCP probe recorded in its report:
/// `none`, `started`, `initialized`, `listed` or `called`. Reads only the
/// boolean stage flags.
String codexMcpProbeStage(Json? facts) {
  if (facts == null) return 'none';
  if (facts['called'] == true) return 'called';
  if (facts['listed'] == true) return 'listed';
  if (facts['initialized'] == true) return 'initialized';
  if (facts['started'] == true) return 'started';
  return 'none';
}

class _WalkHost {
  _WalkHost(this.session) {
    notifications = session.notifications.listen((event) {
      if (event.method == Method.cleanupState) {
        final state = CleanupState.fromJson(event.params);
        if (!state.reconciling && !ready.isCompleted) {
          if (state.unresolvedUnits != 0 || state.unresolvedWorkspaces != 0) {
            ready.completeError(StateError('unresolved cleanup'));
          } else {
            ready.complete();
          }
        }
      }
      switch (event.method) {
        case Method.agentPermissionRequested:
          permission = AgentPermissionRequestedParams.fromJson(event.params);
        case Method.agentPermissionResolved:
          permission = null;
        case Method.agentTurnEnded:
          final ended = AgentTurnEndedParams.fromJson(event.params);
          lastTurnEnd = ended;
          diagnostics.recordTurnEnd(ended);
          turns++;
          captureStreaming = false;
        case Method.agentStopResult:
          stop = AgentStopResultParams.fromJson(event.params);
        case Method.agentExited:
          exited = event.params['reason'] == 'closed';
        case Method.agentCloseFailed:
          closeFailed = true;
        case Method.agentState:
          final state = AgentStateParams.fromJson(event.params);
          tools = state.tools ?? tools;
          unexpectedDelegation |= state.delegated?.hasWork ?? false;
      }
    });
  }
  final HostSession session;
  final diagnostics = CodexWalkDiagnostics();
  final ready = Completer<void>();
  late final StreamSubscription<HostNotification> notifications;
  StreamSubscription<List<int>>? stream;
  AgentPermissionRequestedParams? permission;
  AgentTools? tools;
  AgentStopResultParams? stop;
  AgentTurnEndedParams? lastTurnEnd;
  int turns = 0, textEvents = 0, toolEvents = 0;
  int firstTurnIncrementalEvents = 0;
  bool captureStreaming = false;
  bool unexpectedDelegation = false;
  bool exited = false, closeFailed = false;
  final commandOutput = CodexCommandOutputTracker();
  bool get runningCanary => commandOutput.runningCanary;
  bool get commandEnvironmentIsolated =>
      commandOutput.commandEnvironmentIsolated;
  Object? decodeFailure;

  static Future<_WalkHost> open(
    String executable,
    String profile,
    Map<String, String> environment, {
    bool includeParentEnvironment = true,
  }) async {
    final host = _WalkHost(
      await HostLauncher(
        executable: executable,
        profileDir: profile,
        capabilities: {
          Capability.workbench,
          Capability.agent,
          Capability.codex,
          Capability.agentExtensionsV1,
          Capability.testUnits,
          Capability.testFaults,
        },
        environment: environment,
        includeParentEnvironment: includeParentEnvironment,
      ).start(),
    );
    try {
      await host.ready.future.timeout(const Duration(seconds: 60));
      return host;
    } on Object {
      await host.dispose();
      rethrow;
    }
  }

  Future<Json> call(String method, [Json params = const {}]) async =>
      (await session.connection.request(method, params)) as Json;
  Future<void> wait(bool Function() condition, {int seconds = 75}) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (!condition()) {
      if (decodeFailure != null) throw StateError('event decoding failed');
      if (DateTime.now().isAfter(end)) {
        throw TimeoutException('native observation deadline');
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  Future<AgentStartResult> start(
    Json plan, {
    List<String>? fixtureArgs,
    List<String>? args,
    Map<String, String> env = const {},
  }) async {
    final workspace = WorkspaceOpenResult.fromJson(
      await call(Method.workspaceOpen, {'path': plan['workspace']}),
    );
    final profile = RuntimeProfile(
      id: 'qualification-native',
      name: 'Qualification native',
      runtimeKind: 'codex',
      executable: plan['nativeExecutable']! as String,
      args: fixtureArgs ?? args ?? nativeArgsForManifest(plan),
      env: env,
    );
    await call(Method.runtimeSave, RuntimeSaveParams(profile).toJson());
    final result = AgentStartResult.fromJson(
      await call(Method.agentStart, {
        'workspaceId': workspace.workspace.id,
        'runtimeProfileId': profile.id,
      }),
    );
    if (result.adapter.name != 'codex-app-server' ||
        result.adapter.version != plan['nativeVersion']) {
      throw StateError('native identity changed after approval');
    }
    tools = result.tools;
    final decoder = AgentEventDecoder();
    stream = session.connection
        .attachInbound(result.eventChannel, grantInitial: false)
        .listen(
          (bytes) {
            try {
              for (final event in decoder.add(bytes)) {
                diagnostics.recordEvent(event);
                if (event.kind == AgentEventKind.agentText) {
                  textEvents++;
                  if (captureStreaming && (event.text?.isNotEmpty ?? false)) {
                    firstTurnIncrementalEvents++;
                  }
                }
                if (event.kind == AgentEventKind.child) {
                  unexpectedDelegation = true;
                }
                if (event.kind == AgentEventKind.tool ||
                    event.kind == AgentEventKind.toolUpdate) {
                  toolEvents++;
                }
                commandOutput.add(event);
              }
            } on Object catch (error) {
              decodeFailure = error;
            }
          },
          onError: (Object error) {
            decodeFailure = error;
          },
          onDone: () {
            try {
              decoder.close();
            } on Object catch (error) {
              decodeFailure = error;
            }
          },
        );
    await call(Method.agentAttach, {'sessionId': result.sessionId});
    session.connection.grantInitial(result.eventChannel);
    return result;
  }

  Future<void> dispose() async {
    try {
      final result = await session.quit();
      if (result.timedOut || result.exitCode != 0) {
        throw StateError('host cleanup unresolved');
      }
    } finally {
      await stream?.cancel();
      await notifications.cancel();
    }
  }
}

Map<String, String> _environment(
  String executable, {
  String? home,
  List<String>? probeArgs,
}) => {
  'KUMIKO_TEST_RUNTIME_PATH': '',
  'KUMIKO_TEST_RUNTIME_DIRS': '',
  'KUMIKO_TEST_SHELL_PATH': '',
  'KUMIKO_TEST_SHELL_DIRS': '',
  'KUMIKO_TEST_CODEX_QUALIFICATION_EXECUTABLE': executable,
  'KUMIKO_TEST_CODEX_AUDIT_HOME': home ?? '',
  'KUMIKO_TEST_CODEX_PROBE_ARGS': jsonEncode(probeArgs ?? ['--version']),
  'KUMIKO_TEST_CODEX_AUTH_SIGNATURES': jsonEncode([
    ...{for (final row in confirmedCodexAuthSignatures) row.$3},
  ]),
};

Future<String> _buildHost() async {
  final previous = Directory.current;
  try {
    Directory.current = p.join(previous.path, 'packages', 'host');
    await builder.buildTestHost();
    return builder.testHostExecutable();
  } finally {
    Directory.current = previous;
  }
}

Future<void> _dryRun(String executable) async {
  final owned = await Directory.systemTemp.createTemp(
    'kumiko_codex_qualification_',
  );
  _WalkHost? host;
  try {
    final work = await Directory(p.join(owned.path, 'workspace')).create();
    final profile = p.join(owned.path, 'profile');
    final home = await Directory(p.join(owned.path, 'native-home')).create();
    final script = File(p.join(work.path, 'fixture.json'))
      ..writeAsStringSync(
        jsonEncode({
          'reportFile': p.join(work.path, 'fixture.report.jsonl'),
          'initialize': {
            'userAgent': 'codex/0.166.0',
            'platformFamily': 'windows',
            'platformOs': 'windows',
            'codexHome': home.path,
          },
          'kumikoTool': {'when': 'session/new', 'call': 'kumiko_session_info'},
          'turns': [
            {
              'actions': [
                {
                  'send': {
                    'method': 'item/agentMessage/delta',
                    'params': {
                      'threadId': r'$thread',
                      'turnId': r'$turn',
                      'itemId': 'message',
                      'delta': 'fixture only',
                    },
                  },
                },
                {
                  'send': {
                    'method': 'turn/completed',
                    'params': {
                      'threadId': r'$thread',
                      'turn': {
                        'id': r'$turn',
                        'status': 'completed',
                        'items': <Object?>[],
                        'error': null,
                      },
                    },
                  },
                },
              ],
            },
          ],
        }),
      );
    final fixtureArgs = [
      '--test-fixture',
      'codex-agent',
      '--script',
      script.path,
    ];
    host = await _WalkHost.open(
      executable,
      profile,
      _environment(
        executable,
        home: home.path,
        probeArgs: [...fixtureArgs, '--probe'],
      ),
    );
    final identity = await host.call('test/codex.probe');
    await prepareCodexAuditBinding(
      scan: {
        ...AuditBudget.defaults.echo,
        'nativeSelection': NativeSelection.legacy.wire,
      },
      observations: {},
      call: host.call,
    );
    final plan = makeCodexWalkPlan(
      workspace: work.path,
      profile: profile,
      executable: executable,
      nativeHome: home.path,
      version: identity['version']! as String,
      hostExecutable: executable,
      canaryCommand: 'fixture-only',
      stopCommand: 'fixture-only',
    );
    final agent = await host.start(plan, fixtureArgs: fixtureArgs);
    await host.call(Method.agentPrompt, {
      'sessionId': agent.sessionId,
      'text': 'fixture only',
    });
    await host.wait(
      () =>
          host!.turns == 1 && host.tools?.status == AgentToolsStatus.connected,
    );
    await host.call(Method.agentClose, {'sessionId': agent.sessionId});
    await host.wait(() => host!.exited || host.closeFailed);
    if (!host.exited || host.closeFailed) {
      throw StateError('fixture close unresolved');
    }
    final stats = await host.call('test/agent.stats', {
      'secretScanSessionId': agent.sessionId,
      'secretScanRoots': [work.path, profile, home.path],
    });
    final audit = stats['secretAudit']! as Json;
    if (audit['complete'] != true || audit['matchedFiles'] != 0) {
      throw StateError('fixture audit incomplete');
    }
    stdout.writeln('FIXTURE ONLY: shared native path; no provider evidence');
    stdout.writeln(
      'secret audit complete=${audit['complete']} matchedFiles=${audit['matchedFiles']}',
    );
  } finally {
    try {
      await host?.dispose();
    } finally {
      await owned.delete(recursive: true);
    }
  }
}

Future<void> _prepare(Map<String, String> args, String hostExecutable) async {
  final budget = AuditBudget.named(args['--audit-profile'] ?? 'default');
  final selection = NativeSelection.named(
    args['--native-selection'] ?? 'legacy',
  );
  final workspace = Directory(args['--workspace']!).absolute;
  if (workspace.existsSync() && workspace.listSync().isNotEmpty) {
    throw StateError('qualification workspace must be empty and owned');
  }
  await workspace.create(recursive: true);
  final manifest = File(args['--manifest']!).absolute;
  if (manifest.existsSync()) throw StateError('manifest already exists');
  await manifest.parent.create(recursive: true);
  final profile = p.join(manifest.parent.path, 'profile');
  if (Directory(profile).existsSync()) {
    throw StateError('qualification profile already exists');
  }
  final executable = File(args['--native']!).absolute.path;
  final home =
      args['--native-home'] ??
      Platform.environment['CODEX_HOME'] ??
      p.join(
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME']!,
        '.codex',
      );
  final host = await _WalkHost.open(
    hostExecutable,
    profile,
    _environment(executable),
  );
  late String version;
  try {
    version = (await host.call('test/codex.probe'))['version']! as String;
  } finally {
    await host.dispose();
  }
  final powershell = p.join(
    Platform.environment['SystemRoot'] ?? r'C:\Windows',
    'System32',
    'WindowsPowerShell',
    'v1.0',
    'powershell.exe',
  );
  final quotedPowerShell = "'${powershell.replaceAll("'", "''")}'";
  final command =
      '& $quotedPowerShell -NoLogo -NoProfile -NonInteractive -Command '
      "'[Console]::WriteLine(\"KUMIKO_QUALIFICATION_CANARY\"); "
      '[Console]::WriteLine([bool]\$env:KUMIKO_TOOL_SECRET); '
      '[Console]::WriteLine([bool]\$env:KUMIKO_TOOL_ENDPOINT)'
      "'";
  final stopCommand =
      '& $quotedPowerShell -NoLogo -NoProfile -NonInteractive '
      '-Command \'[Console]::WriteLine("KUMIKO_QUALIFICATION_RUNNING"); Start-Sleep -Seconds 60\'';
  final plan = makeCodexWalkPlan(
    workspace: workspace.path,
    profile: profile,
    executable: executable,
    nativeHome: p.normalize(home),
    version: version,
    hostExecutable: hostExecutable,
    canaryCommand: command,
    stopCommand: stopCommand,
    auditProfile: budget.auditProfile,
    nativeSelection: selection.wire,
  );
  final bytes = utf8.encode(
    '${const JsonEncoder.withIndent('  ').convert(plan)}\n',
  );
  await manifest.writeAsBytes(bytes, flush: true);
  stdout.writeln(
    'PREPARED ONLY: version=$version; no App Server/provider/auth/home-file action',
  );
  stdout.writeln(
    codexPreparationSummary(
      manifest: manifest.path,
      sha256Hex: sha256.convert(bytes).toString(),
      budget: budget,
      nativeSelection: selection.wire,
    ),
  );
}

Future<void> _appendAttempt(
  File marker,
  String phase, {
  String? errorKind,
}) async {
  final handle = await marker.open(mode: FileMode.append);
  var locked = false;
  try {
    await handle.lock(FileLock.exclusive);
    locked = true;
    if (phase == 'claimed' && await handle.length() != 0) {
      throw StateError('approved manifest attempt already consumed');
    }
    if (await handle.length() > 2048) {
      throw StateError('attempt record exceeds bound');
    }
    await handle.writeString(
      '${jsonEncode({'phase': phase, 'at': DateTime.now().toUtc().toIso8601String(), 'errorKind': ?errorKind})}\n',
    );
    await handle.flush();
  } finally {
    if (locked) await handle.unlock();
    await handle.close();
  }
}

/// The manifest's workspace must still be an existing, empty, ordinary
/// directory (not a link) before the claim. Preparation created it empty; if
/// it vanished or changed since, the walk is refused without consuming the
/// approval, so an environment fault cannot spend an owner approval.
void verifyCodexWalkWorkspace(Json plan) {
  final workspace = plan['workspace'];
  if (workspace is! String ||
      FileSystemEntity.typeSync(workspace, followLinks: false) !=
          FileSystemEntityType.directory ||
      Directory(workspace).listSync().isNotEmpty) {
    throw StateError(
      'qualification workspace must still exist, empty and owned; '
      'prepare again',
    );
  }
}

Future<void> _walk(File manifest, String approvedHash) async {
  if (await File(p.join(manifest.parent.path, 'observations.json')).exists()) {
    throw StateError(
      'walk manifest already used; fresh preparation and approval required',
    );
  }
  final bytes = await manifest.readAsBytes();
  if (!approvedCodexManifest(bytes, approvedHash)) {
    throw StateError('exact approved manifest SHA256 required');
  }
  final plan = jsonDecode(utf8.decode(bytes)) as Json;
  if (plan['schema'] != 2 ||
      plan['maxTurns'] != 3 ||
      plan['turnDeadlineSeconds'] != 75) {
    throw StateError('unsupported walk bounds');
  }
  nativeArgsForManifest(plan);
  validatedCodexAuditScan(plan);
  verifyCodexWalkWorkspace(plan);
  final trustedShells = resolveTrustedPowerShells(RegPowerShellRegistry());
  verifyCodexTrustedShells(trustedShells);
  final marker = File(p.join(manifest.parent.path, 'attempt.jsonl'));
  await runClaimedCodexAttempt(
    marker,
    () => _runWalk(manifest, plan, trustedShells),
  );
}

/// Exclusive claim and durable nonempty marker precede even host startup and
/// any native-home metadata read. Completion/failure is appended without
/// truncating the consumed claim, so an incomplete attempt cannot be replayed.
Future<void> runClaimedCodexAttempt(
  File marker,
  Future<void> Function() run,
) async {
  await _appendAttempt(marker, 'claimed');
  try {
    await run();
    await _appendAttempt(marker, 'finished');
  } on Object catch (error) {
    try {
      await _appendAttempt(
        marker,
        'failed',
        errorKind: error.runtimeType.toString(),
      );
    } on Object {
      // The durable claim still prevents replay if status recording fails.
    }
    rethrow;
  }
}

Future<void> finalizeCodexWalk({
  required Json observations,
  required Future<void> Function() cleanup,
  required Future<void> Function() persist,
  required Future<void> Function() dispose,
}) async {
  try {
    try {
      await cleanup();
    } on Object catch (error) {
      observations['canaryAudit'] = {
        'complete': false,
        'scanned': false,
        'reason': 'cleanup or audit failed; persistence was not verified',
      };
      if (observations['kumiko tool call'] != 'fail') {
        observations['kumiko tool call'] = 'unverified';
      }
      if (error is RpcException) {
        final secondary = <String, Object?>{};
        recordCodexRpcFailure(secondary, error, hasSession: true);
        observations['cleanupDiagnostic'] = secondary['nativeDiagnostic'];
      } else {
        observations['cleanupDiagnostic'] = {
          'errorKind': clampUtf8(error.runtimeType.toString(), 128),
        };
      }
      rethrow;
    } finally {
      await persist();
    }
  } finally {
    await dispose();
  }
}

Future<void> runCodexObservedOperations({
  required Future<void> Function() operations,
  required void Function() recordProgress,
}) async {
  try {
    await operations();
  } finally {
    recordProgress();
  }
}

Future<void> runCodexWalkPrompts({
  required CodexWalkDiagnostics diagnostics,
  required Json observations,
  required Future<void> Function(int operation) prompt,
}) async {
  for (var operation = 0; operation < 3; operation++) {
    ensureCodexDisplayAvailable(diagnostics, observations);
    await prompt(operation);
    diagnostics.persist(observations);
    ensureCodexDisplayAvailable(diagnostics, observations);
  }
}

void ensureCodexDisplayAvailable(
  CodexWalkDiagnostics diagnostics,
  Json observations,
) {
  if (diagnostics.displayRefused) {
    observations['walkAbortedReason'] = 'approval-display-unavailable';
    throw StateError('approval display refused; walk aborted');
  }
}

void recordCodexWalkProgress(
  Json observations, {
  required int textEvents,
  required int firstTurnIncrementalEvents,
  required int toolEvents,
}) {
  observations['textEvents'] = textEvents;
  observations['firstTurnIncrementalEvents'] = firstTurnIncrementalEvents;
  observations['toolEvents'] = toolEvents;
  if (observations['streaming'] != 'fail') {
    observations['streaming'] =
        nativeStreamingObserved([firstTurnIncrementalEvents])
        ? 'pass'
        : 'unverified';
  }
  if (observations['tool activity'] != 'fail') {
    observations['tool activity'] = toolEvents > 0 ? 'pass' : 'unverified';
  }
}

Future<void> _runWalk(
  File manifest,
  Json plan,
  List<String> trustedShells,
) async {
  final scan = validatedCodexAuditScan(plan);
  _WalkHost? ownedHost;
  String? id;
  final observations = <String, Object?>{
    for (final item in [
      'launch',
      'streaming',
      'tool activity',
      'command approval',
      'Stop',
      'close/descendant containment',
      'kumiko tool call',
    ])
      item: 'unverified',
    'auth-required': 'unverified',
    'recovery': 'unverified',
    'steering': 'unverified',
    'structured question': 'unverified',
    'child attribution': 'unverified',
  };
  try {
    await runCodexObservedOperations(
      operations: () async {
        final host = await _WalkHost.open(
          plan['hostExecutable']! as String,
          plan['profile']! as String,
          _environment(
            plan['nativeExecutable']! as String,
            home: plan['nativeHome']! as String,
          ),
        );
        ownedHost = host;
        if ((await host.call('test/codex.probe'))['version'] !=
            plan['nativeVersion']) {
          throw StateError('selected native version changed after approval');
        }
        await prepareCodexAuditBinding(
          scan: scan,
          observations: observations,
          call: (method, params) => host.call(method, params),
        );
        final agent = await host.start(plan);
        id = agent.sessionId;
        observations['launch'] = 'pass';
        await runCodexWalkPrompts(
          diagnostics: host.diagnostics,
          observations: observations,
          prompt: (operation) async {
            if (host.unexpectedDelegation) {
              throw StateError('unapproved delegated activity');
            }
            final before = host.turns;
            host.captureStreaming = operation == 0;
            await host.call(Method.agentPrompt, {
              'sessionId': id,
              'text': (plan['prompts'] as List)[operation],
            });
            var answered = false;
            final deadline = DateTime.now().add(const Duration(seconds: 75));
            while (host.turns == before) {
              ensureCodexDisplayAvailable(host.diagnostics, observations);
              if (host.unexpectedDelegation) {
                throw StateError('unapproved delegated activity');
              }
              if (DateTime.now().isAfter(deadline)) {
                throw TimeoutException('75 second turn bound');
              }
              if (host.permission case final request?) {
                final evaluation = evaluateCanaryApproval(
                  request,
                  plan,
                  operation,
                  trustedShells: trustedShells,
                );
                final option = evaluation.optionId;
                if (answered || option == null) {
                  rejectCodexWalkPermission(
                    observations,
                    request,
                    operation: operation,
                    answered: answered,
                    matchesApprovedRequest: option != null,
                    approvalChecks: evaluation.checks,
                  );
                }
                await host.call(Method.agentPermissionReply, {
                  'sessionId': id,
                  'requestId': request.requestId,
                  'optionId': option,
                });
                host.permission = null;
                answered = true;
                observations['command approval'] = 'pass';
              }
              if (operation == 2 && host.runningCanary) {
                await host.call(Method.agentStop, {'sessionId': id});
                await host.wait(() => host.stop != null, seconds: 20);
                observations['Stop'] =
                    host.stop!.outcome == AgentStopOutcome.stopped
                    ? 'pass'
                    : 'unverified';
                break;
              }
              await Future<void>.delayed(const Duration(milliseconds: 25));
            }
          },
        );
        observations['kumiko tool call'] =
            host.tools?.status == AgentToolsStatus.connected
            ? 'pass'
            : 'unverified';
      },
      recordProgress: () {
        if (ownedHost case final host?) {
          host.diagnostics.persist(observations);
          recordCodexWalkProgress(
            observations,
            textEvents: host.textEvents,
            firstTurnIncrementalEvents: host.firstTurnIncrementalEvents,
            toolEvents: host.toolEvents,
          );
        }
      },
    );
  } on RpcException catch (error) {
    recordCodexRpcFailure(observations, error, hasSession: id != null);
    rethrow;
  } finally {
    if (id == null) recordCodexMissingSession(observations);
    final host = ownedHost;
    await finalizeCodexWalk(
      observations: observations,
      cleanup: () async {
        if (id != null && host != null) {
          final probeReport = File(plan['envProbeReport']! as String);
          Json? envFacts;
          if (await probeReport.exists() &&
              await probeReport.length() <= 4096) {
            envFacts = jsonDecode(await probeReport.readAsString()) as Json;
          }
          final probeAliveBefore =
              envFacts?['pid'] is int &&
              envFacts?['startTime'] is int &&
              isProcessAlive(
                envFacts!['pid']! as int,
                envFacts['startTime']! as int,
              );
          await host.call(Method.agentClose, {'sessionId': id});
          await host.wait(() => host.exited || host.closeFailed, seconds: 40);
          final probeAliveAfter =
              envFacts?['pid'] is int &&
              envFacts?['startTime'] is int &&
              isProcessAlive(
                envFacts!['pid']! as int,
                envFacts['startTime']! as int,
              );
          observations['close/descendant containment'] =
              host.exited &&
                  !host.closeFailed &&
                  nativeDescendantSettled(
                    aliveBefore: probeAliveBefore,
                    aliveAfter: probeAliveAfter,
                  )
              ? 'pass'
              : 'unverified';
          observations['mcpProbeStage'] = codexMcpProbeStage(envFacts);
          observations['unrelatedMcpEnvironmentIsolated'] =
              envFacts?['called'] == true &&
              envFacts?['secretPresent'] == false &&
              envFacts?['endpointPresent'] == false;
          observations['unrelatedCommandEnvironmentIsolated'] =
              host.commandEnvironmentIsolated;
          observations['textEvents'] = host.textEvents;
          observations['firstTurnIncrementalEvents'] =
              host.firstTurnIncrementalEvents;
          observations['toolEvents'] = host.toolEvents;
          final stats = await host.call('test/agent.stats', {
            'secretScanSessionId': id,
            'secretScanRoots': scan['roots'],
          });
          recordCodexCanaryAudit(
            observations,
            scan,
            stats['secretAudit'] is Json ? stats['secretAudit']! as Json : {},
          );
        }
      },
      persist: () async {
        host?.diagnostics.persist(observations);
        final output = File(p.join(manifest.parent.path, 'observations.json'));
        await output.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(observations)}\n',
        );
        stdout.writeln(
          'Observations written; review exact evidence before editing qualification registry/docs.',
        );
      },
      dispose: () async {
        await host?.dispose();
      },
    );
  }
}

/// Isolated Codex authentication experiment (design D7, structured
/// authentication signals, item 5). A separate scope with its own manifest and
/// exact approval: an owned empty `CODEX_HOME` per operation, an in-memory
/// credential store, and a host environment with no OpenAI or Codex variables.
const codexAuthSchema = 'codex-auth-1';
const codexAuthNativeArgs = [
  'app-server',
  '-c',
  'cli_auth_credentials_store="ephemeral"',
];
const codexAuthPrompt = 'Reply with the single word ok.';

bool _authSensitiveName(String name) {
  final upper = name.toUpperCase();
  return !upper.startsWith('KUMIKO_TEST_') &&
      (upper.contains('OPENAI') || upper.contains('CODEX'));
}

/// The complete host environment for the experiment: [parent] without any
/// variable whose name contains OPENAI or CODEX (case-insensitive), plus the
/// helper's own [overrides]. Refuses if a sensitive name would remain.
Map<String, String> isolatedCodexAuthEnvironment(
  Map<String, String> parent,
  Map<String, String> overrides,
) {
  final environment = {
    for (final entry in parent.entries)
      if (!_authSensitiveName(entry.key)) entry.key: entry.value,
    ...overrides,
  };
  if (environment.keys.any(_authSensitiveName)) {
    throw StateError('experiment host environment carries a Codex variable');
  }
  return environment;
}

bool _sameOrInside(p.Context paths, String path, String root) =>
    paths.equals(path, root) || paths.isWithin(root, path);

Json makeCodexAuthPlan({
  required String workspace,
  required String profile,
  required String executable,
  required String executableSha256,
  required String version,
  required String hostExecutable,
  required String hostSha256,
  required String nativeHome,
}) => {
  'schema': codexAuthSchema,
  'workspace': workspace,
  'profile': profile,
  'homes': [p.join(profile, 'codex-home-a'), p.join(profile, 'codex-home-b')],
  'nativeExecutable': executable,
  'nativeExecutableSha256': executableSha256,
  'nativeVersion': version,
  'hostExecutable': hostExecutable,
  'hostSha256': hostSha256,
  'ownerNativeHome': nativeHome,
  'ownerNativeHomeUse': 'never read, scanned or written; homes must differ',
  'nativeArgs': codexAuthNativeArgs,
  'profileEnvironment': 'CODEX_HOME only: the operation home',
  'hostEnvironment':
      'parent environment without any variable whose name contains OPENAI or '
      'CODEX (case-insensitive), plus KUMIKO_TEST_* settings',
  'operations': [
    {
      'name': 'A',
      'candidates': ['account-unauthenticated'],
      'home': 0,
      'expect': 'Start fails auth-required before thread/start; no prompt',
    },
    {
      'name': 'B',
      'candidates': ['turn-http-401'],
      'home': 1,
      'prompt': codexAuthPrompt,
      'turnDeadlineSeconds': 75,
      'expect': 'the prompt turn ends auth-required, then close',
    },
  ],
  'cost':
      'At most one prompt (operation B), sent without credentials: Codex '
      'retries it and each request gets HTTP 401. No billing is expected.',
  'scanRoots': [workspace, profile],
};

/// Refuses a manifest that is not exactly the prepared experiment shape, with
/// its homes owned under the profile and distinct from the owner's home.
Json validatedCodexAuthPlan(Json plan) {
  final strings = [
    'workspace',
    'profile',
    'nativeExecutable',
    'nativeExecutableSha256',
    'nativeVersion',
    'hostExecutable',
    'hostSha256',
    'ownerNativeHome',
  ];
  if (plan['schema'] != codexAuthSchema ||
      strings.any((key) => plan[key] is! String) ||
      plan['homes'] is! List ||
      (plan['homes']! as List).length != 2 ||
      (plan['homes']! as List).any((home) => home is! String)) {
    throw const FormatException('unsupported authentication experiment');
  }
  final expected = makeCodexAuthPlan(
    workspace: plan['workspace']! as String,
    profile: plan['profile']! as String,
    executable: plan['nativeExecutable']! as String,
    executableSha256: plan['nativeExecutableSha256']! as String,
    version: plan['nativeVersion']! as String,
    hostExecutable: plan['hostExecutable']! as String,
    hostSha256: plan['hostSha256']! as String,
    nativeHome: plan['ownerNativeHome']! as String,
  );
  if (jsonEncode(plan) != jsonEncode(expected)) {
    throw const FormatException('noncanonical authentication experiment');
  }
  final paths = p.windows.isAbsolute(plan['workspace']! as String)
      ? p.windows
      : p.context;
  final owner = paths.normalize(plan['ownerNativeHome']! as String);
  for (final root in [
    plan['workspace']! as String,
    plan['profile']! as String,
    ...(plan['homes']! as List).cast<String>(),
  ]) {
    if (!paths.isAbsolute(root)) {
      throw const FormatException('experiment folders must be absolute');
    }
    final normalized = paths.normalize(root);
    if (_sameOrInside(paths, normalized, owner) ||
        _sameOrInside(paths, owner, normalized)) {
      throw const FormatException('experiment folder overlaps native home');
    }
  }
  return plan;
}

/// Each isolated home must be an existing, empty, ordinary directory.
void requireEmptyCodexAuthHome(String home) {
  if (FileSystemEntity.typeSync(home, followLinks: false) !=
          FileSystemEntityType.directory ||
      Directory(home).listSync().isNotEmpty) {
    throw StateError('isolated Codex home must exist, empty and owned');
  }
}

/// The signals a content-free experiment receipt supports, in record order.
List<String> codexAuthSignalsObserved(Json receipt) => [
  if ((receipt['A'] as Json?)?['outcome'] == 'auth-required')
    'account-unauthenticated',
  if ((receipt['B'] as Json?)?['outcome'] == 'auth-required') 'turn-http-401',
];

Future<String> _sha256File(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

Map<String, String> _authHostEnvironment(
  String executable,
  List<String> candidates,
) => isolatedCodexAuthEnvironment(Platform.environment, {
  ..._environment(executable),
  'KUMIKO_TEST_CODEX_AUTH_SIGNATURES': jsonEncode(candidates),
});

Future<void> _prepareAuth(
  Map<String, String> args,
  String hostExecutable,
) async {
  final workspace = Directory(args['--workspace']!).absolute;
  if (workspace.existsSync() && workspace.listSync().isNotEmpty) {
    throw StateError('experiment workspace must be empty and owned');
  }
  final manifest = File(args['--manifest']!).absolute;
  if (manifest.existsSync()) throw StateError('manifest already exists');
  final profile = p.join(manifest.parent.path, 'profile');
  if (Directory(profile).existsSync()) {
    throw StateError('experiment profile already exists');
  }
  final executable = File(args['--native']!).absolute.path;
  final ownerHome = p.normalize(
    args['--native-home'] ??
        Platform.environment['CODEX_HOME'] ??
        p.join(
          Platform.environment['USERPROFILE'] ?? Platform.environment['HOME']!,
          '.codex',
        ),
  );
  // Validate the shape (and the owner-home distinction) before any folder or
  // host exists.
  validatedCodexAuthPlan(
    makeCodexAuthPlan(
      workspace: workspace.path,
      profile: profile,
      executable: executable,
      executableSha256: '',
      version: '',
      hostExecutable: hostExecutable,
      hostSha256: '',
      nativeHome: ownerHome,
    ),
  );
  await workspace.create(recursive: true);
  await manifest.parent.create(recursive: true);
  final host = await _WalkHost.open(
    hostExecutable,
    profile,
    _authHostEnvironment(executable, const []),
    includeParentEnvironment: false,
  );
  late String version;
  try {
    version = (await host.call('test/codex.probe'))['version']! as String;
  } finally {
    await host.dispose();
  }
  final plan = validatedCodexAuthPlan(
    makeCodexAuthPlan(
      workspace: workspace.path,
      profile: profile,
      executable: executable,
      executableSha256: await _sha256File(executable),
      version: version,
      hostExecutable: hostExecutable,
      hostSha256: await _sha256File(hostExecutable),
      nativeHome: ownerHome,
    ),
  );
  for (final home in (plan['homes']! as List).cast<String>()) {
    if (Directory(home).existsSync()) {
      throw StateError('isolated Codex home already exists');
    }
    await Directory(home).create();
  }
  final bytes = utf8.encode(
    '${const JsonEncoder.withIndent('  ').convert(plan)}\n',
  );
  await manifest.writeAsBytes(bytes, flush: true);
  stdout.writeln(
    'PREPARED ONLY: version=$version; no App Server/provider/auth action',
  );
  stdout.writeln('Manifest: ${manifest.path}');
  stdout.writeln('SHA256: ${sha256.convert(bytes)}');
}

Future<void> _walkAuth(File manifest, String approvedHash) async {
  final receiptFile = File(p.join(manifest.parent.path, 'auth-receipt.json'));
  if (await receiptFile.exists()) {
    throw StateError('experiment manifest already used; prepare again');
  }
  final bytes = await manifest.readAsBytes();
  if (!approvedCodexManifest(bytes, approvedHash)) {
    throw StateError('exact approved manifest SHA256 required');
  }
  final plan = validatedCodexAuthPlan(jsonDecode(utf8.decode(bytes)) as Json);
  final executable = plan['nativeExecutable']! as String;
  final hostExecutable = plan['hostExecutable']! as String;
  if (await _sha256File(executable) != plan['nativeExecutableSha256'] ||
      await _sha256File(hostExecutable) != plan['hostSha256']) {
    throw StateError('native or test host changed after approval');
  }
  verifyCodexWalkWorkspace(plan);
  final homes = (plan['homes']! as List).cast<String>();
  homes.forEach(requireEmptyCodexAuthHome);
  final operations = (plan['operations']! as List).cast<Json>();
  for (final operation in operations) {
    _authHostEnvironment(
      executable,
      (operation['candidates']! as List).cast<String>(),
    );
  }
  final marker = File(p.join(manifest.parent.path, 'attempt.jsonl'));
  final receipt = <String, Object?>{
    'schema': codexAuthSchema,
    'nativeVersion': plan['nativeVersion'],
    'hostSha256': plan['hostSha256'],
  };
  try {
    await runClaimedCodexAttempt(marker, () async {
      for (final operation in operations) {
        final name = operation['name']! as String;
        final home = homes[operation['home']! as int];
        requireEmptyCodexAuthHome(home);
        receipt[name] = await _runAuthOperation(
          plan,
          operation,
          home,
          scan: name == 'B',
        );
      }
    });
  } finally {
    var deleted = true;
    for (final home in homes) {
      try {
        if (Directory(home).existsSync()) {
          await Directory(home).delete(recursive: true);
        }
      } on Object {
        deleted = false;
      }
    }
    receipt['homesDeleted'] = deleted;
    receipt['signalsObserved'] = codexAuthSignalsObserved(receipt);
    await receiptFile.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(receipt)}\n',
    );
    stdout.writeln('Authentication receipt written: ${receiptFile.path}');
  }
}

/// One operation on a fresh host. Records outcomes only, never content.
Future<Json> _runAuthOperation(
  Json plan,
  Json operation,
  String home, {
  required bool scan,
}) async {
  final result = <String, Object?>{'outcome': 'unverified'};
  final host = await _WalkHost.open(
    plan['hostExecutable']! as String,
    plan['profile']! as String,
    _authHostEnvironment(
      plan['nativeExecutable']! as String,
      (operation['candidates']! as List).cast<String>(),
    ),
    includeParentEnvironment: false,
  );
  String? id;
  try {
    if ((await host.call('test/codex.probe'))['version'] !=
        plan['nativeVersion']) {
      throw StateError('selected native version changed after approval');
    }
    try {
      final agent = await host.start(
        plan,
        args: codexAuthNativeArgs,
        env: {'CODEX_HOME': home},
      );
      id = agent.sessionId;
      result['started'] = true;
    } on RpcException catch (error) {
      result['started'] = false;
      result['outcome'] = error.reason == ErrorCode.authRequired
          ? 'auth-required'
          : 'start-${error.reason}';
      return result;
    }
    final prompt = operation['prompt'];
    if (prompt is! String) {
      result['outcome'] = 'started';
      return result;
    }
    await host.call(Method.agentPrompt, {'sessionId': id, 'text': prompt});
    try {
      await host.wait(() => host.turns > 0, seconds: 75);
    } on TimeoutException {
      result['outcome'] = 'turn-timeout';
      return result;
    }
    final ended = host.lastTurnEnd;
    result['outcome'] = ended?.error == ErrorCode.authRequired
        ? 'auth-required'
        : 'turn-${ended?.error ?? 'completed'}';
    result['nativeCodePresent'] = ended?.nativeCode != null;
    return result;
  } finally {
    if (id != null) {
      await host.call(Method.agentClose, {'sessionId': id});
      await host.wait(() => host.exited || host.closeFailed, seconds: 40);
      result['closed'] = host.exited && !host.closeFailed;
      if (scan) {
        final stats = await host.call('test/agent.stats', {
          'secretScanSessionId': id,
          'secretScanRoots': plan['scanRoots'],
        });
        final audit = stats['secretAudit'];
        result['canaryAudit'] = audit is Json ? audit : {'complete': false};
      }
    }
    await host.dispose();
  }
}

Future<void> main(List<String> args) async {
  try {
    if (args.length == 1 && args.single == '--help') {
      stdout.writeln(
        'Repository root via mise: --dry-run; --prepare --workspace <owned-empty-dir> --native <native-exe> --manifest <new-file> [--native-home <path>] [--audit-profile <default|large-native-home>] [--native-selection <legacy|changed-artifacts-v1|changed-artifacts-v2|changed-artifacts-v3|changed-artifacts-v4>]; --walk --manifest <file> --approved-sha256 <owner-approved-exact-file-hash>; --prepare-auth --workspace <owned-empty-dir> --native <native-exe> --manifest <new-file> [--native-home <path>]; --walk-auth --manifest <file> --approved-sha256 <hash>. Prepare runs only a contained identity probe. Walk and walk-auth require exact owner approval first. The auth experiment uses owned empty Codex homes and an in-memory credential store.',
      );
      return;
    }
    if (args.length == 1 && args.single == '--dry-run') {
      try {
        await _dryRun(await _buildHost());
      } on Object catch (error, stack) {
        // The dry run talks only to the fixture, so its error and the first
        // frames are safe to show and are what a CI failure needs.
        final detail = '$error\n$stack';
        stderr.writeln(
          'FAILED: dry run ${detail.length > 4096 ? detail.substring(0, 4096) : detail}',
        );
        exitCode = 1;
      }
      return;
    }
    const modes = ['--prepare', '--walk', '--prepare-auth', '--walk-auth'];
    if (args.isEmpty || !modes.contains(args.first)) {
      throw const FormatException(
        'explicit --prepare or approved --walk required',
      );
    }
    final values = <String, String>{};
    for (var i = 1; i < args.length; i += 2) {
      if (i + 1 >= args.length ||
          !const [
            '--workspace',
            '--native',
            '--manifest',
            '--native-home',
            '--audit-profile',
            '--native-selection',
            '--approved-sha256',
          ].contains(args[i]) ||
          values.containsKey(args[i])) {
        throw const FormatException('invalid or repeated argument');
      }
      values[args[i]] = args[i + 1];
    }
    if (!values.containsKey('--manifest')) {
      throw const FormatException('--manifest required');
    }
    if (args.first == '--prepare-auth') {
      if (!values.containsKey('--workspace') ||
          !values.containsKey('--native') ||
          values.keys.any(
            (key) => !const [
              '--workspace',
              '--native',
              '--manifest',
              '--native-home',
            ].contains(key),
          )) {
        throw const FormatException(
          'prepare-auth requires owned workspace/native and accepts no approval',
        );
      }
      await _prepareAuth(values, await _buildHost());
    } else if (args.first == '--walk-auth') {
      if (values.length != 2 || !values.containsKey('--approved-sha256')) {
        throw const FormatException(
          'walk-auth requires only manifest and exact owner-approved SHA256',
        );
      }
      await _walkAuth(
        File(values['--manifest']!),
        values['--approved-sha256']!,
      );
    } else if (args.first == '--prepare') {
      if (!values.containsKey('--workspace') ||
          !values.containsKey('--native') ||
          values.containsKey('--approved-sha256')) {
        throw const FormatException(
          'prepare requires owned workspace/native and accepts no approval',
        );
      }
      AuditBudget.named(values['--audit-profile'] ?? 'default');
      NativeSelection.named(values['--native-selection'] ?? 'legacy');
      await _prepare(values, await _buildHost());
    } else {
      if (values.length != 2 || !values.containsKey('--approved-sha256')) {
        throw const FormatException(
          'walk requires only manifest and exact owner-approved SHA256',
        );
      }
      await _walk(File(values['--manifest']!), values['--approved-sha256']!);
    }
  } on Object catch (error) {
    // Do not dump arbitrary provider messages or config/credential values.
    stderr.writeln(
      'FAILED: native qualification ${error.runtimeType}; no automatic retry',
    );
    exitCode = 1;
  }
}
