import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:crypto/crypto.dart';
// ignore: depend_on_referenced_packages
import 'package:host_protocol/host_protocol.dart';
// ignore: depend_on_referenced_packages
import 'package:host/src/agent/codex/native_home_audit.dart';
// ignore: depend_on_referenced_packages
import 'package:host/src/agent/tool_file_audit.dart' show AuditBudget;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../qualify_codex_app_server.dart';

Json plan() => makeCodexWalkPlan(
  workspace: r'F:\owned\work',
  profile: r'F:\owned\profile',
  executable: r'F:\native\codex.exe',
  nativeHome: r'C:\user\.codex',
  version: '0.166.0',
  hostExecutable: r'F:\test\kumiko_host_test.exe',
  canaryCommand: 'inert canary command',
  stopCommand: 'inert long command',
);

void main() {
  group('Codex authentication experiment:', () {
    Json authPlan({String owner = r'C:\user\.codex'}) => makeCodexAuthPlan(
      workspace: r'F:\owned\auth\work',
      profile: r'F:\owned\auth\profile',
      executable: r'F:\native\codex.exe',
      executableSha256: 'a' * 64,
      version: '0.166.0',
      hostExecutable: r'F:\test\kumiko_host_test.exe',
      hostSha256: 'b' * 64,
      nativeHome: owner,
    );
    test('host environment drops every OpenAI or Codex variable', () {
      final environment = isolatedCodexAuthEnvironment(
        {
          'PATH': 'path',
          'OPENAI_API_KEY': 'never',
          'codex_home': 'never',
          'My_OpenAi_Proxy': 'never',
          'CODEX_SANDBOX': 'never',
          'KUMIKO_TEST_CODEX_INHERITED': 'kept',
          'SystemRoot': 'root',
        },
        {'KUMIKO_TEST_CODEX_AUTH_SIGNATURES': '["turn-http-401"]'},
      );
      expect(environment, {
        'PATH': 'path',
        'KUMIKO_TEST_CODEX_INHERITED': 'kept',
        'SystemRoot': 'root',
        'KUMIKO_TEST_CODEX_AUTH_SIGNATURES': '["turn-http-401"]',
      });
    });
    test('host environment refuses a Codex override before any claim', () {
      expect(
        () => isolatedCodexAuthEnvironment({}, {'CODEX_HOME': 'home'}),
        throwsStateError,
      );
      expect(
        () => isolatedCodexAuthEnvironment({}, {'OPENAI_BASE_URL': 'x'}),
        throwsStateError,
      );
    });
    test(
      'the canonical plan names isolated homes, ephemeral store and cost',
      () {
        final plan = validatedCodexAuthPlan(authPlan());
        expect(plan['nativeArgs'], [
          'app-server',
          '-c',
          'cli_auth_credentials_store="ephemeral"',
        ]);
        expect(plan['homes'], [
          p.join(r'F:\owned\auth\profile', 'codex-home-a'),
          p.join(r'F:\owned\auth\profile', 'codex-home-b'),
        ]);
        final operations = (plan['operations']! as List).cast<Json>();
        expect(
          [for (final o in operations) o['candidates']],
          [
            ['account-unauthenticated'],
            ['turn-http-401'],
          ],
        );
        expect(operations.first.containsKey('prompt'), isFalse);
        expect(operations.last['turnDeadlineSeconds'], 75);
        expect(plan['scanRoots'], [
          r'F:\owned\auth\work',
          r'F:\owned\auth\profile',
        ]);
        expect(plan['cost'], contains('No billing is expected'));
      },
    );
    test('an edited plan is refused', () {
      for (final edit in <void Function(Json)>[
        (plan) => plan['nativeArgs'] = ['app-server'],
        (plan) => plan['cost'] = 'free',
        (plan) => plan['schema'] = 2,
        (plan) => (plan['operations']! as List).removeLast(),
        (plan) => plan['homes'] = [r'C:\user\.codex', r'F:\other'],
        (plan) => plan['extra'] = true,
      ]) {
        final plan = jsonDecode(jsonEncode(authPlan())) as Json;
        edit(plan);
        expect(() => validatedCodexAuthPlan(plan), throwsFormatException);
      }
    });
    test('experiment folders may not overlap the owner native home', () {
      for (final owner in [
        r'F:\owned\auth\profile\codex-home-a',
        r'F:\owned\auth',
        r'F:\owned\auth\work\.codex',
      ]) {
        expect(
          () => validatedCodexAuthPlan(authPlan(owner: owner)),
          throwsFormatException,
          reason: owner,
        );
      }
    });
    test('an isolated home must exist empty and ordinary', () async {
      final dir = await Directory.systemTemp.createTemp('kumiko-auth-home-');
      addTearDown(() => dir.delete(recursive: true));
      final home = p.join(dir.path, 'home');
      expect(() => requireEmptyCodexAuthHome(home), throwsStateError);
      File(home).writeAsStringSync('');
      expect(() => requireEmptyCodexAuthHome(home), throwsStateError);
      File(home).deleteSync();
      Directory(home).createSync();
      requireEmptyCodexAuthHome(home);
      File(p.join(home, 'auth.json')).writeAsStringSync('{}');
      expect(() => requireEmptyCodexAuthHome(home), throwsStateError);
    });
    test('observed signals follow outcomes in record order', () {
      expect(
        codexAuthSignalsObserved({
          'A': {'outcome': 'auth-required'},
          'B': {'outcome': 'auth-required'},
        }),
        ['account-unauthenticated', 'turn-http-401'],
      );
      expect(
        codexAuthSignalsObserved({
          'A': {'outcome': 'started'},
          'B': {'outcome': 'auth-required'},
        }),
        ['turn-http-401'],
      );
      expect(
        codexAuthSignalsObserved({
          'A': {'outcome': 'start-adapter-start-failed'},
          'B': {'outcome': 'turn-timeout'},
        }),
        isEmpty,
      );
    });
  });
  test('Codex diagnostic suffix: malformed unknown and oversized suffixes never persist snapshots', () {
    const prefix =
        'Native approval unavailable: full details exceed display capacity; request cancelled.';
    final safe = <String, Object?>{
      'category': 'command',
      'isChild': false,
      'titleBytes': 16,
      'previewBytes': 600,
      'maxNameBytes': 700,
      'optionCount': 2,
      'titleLoss': false,
      'previewLoss': false,
      'namesLoss': true,
      'countLoss': false,
      'encodedLoss': false,
    };
    for (final invalid in [
      jsonEncode({...safe, 'private': 'PRIVATE_PATH'}),
      jsonEncode({...safe, 'category': 'PRIVATE_PROVIDER'}),
      jsonEncode({...safe, 'previewBytes': -1}),
      jsonEncode({...safe, 'previewBytes': 1048577}),
      jsonEncode({...safe, 'optionCount': 1025}),
      jsonEncode({...safe, 'optionCount': 2.0}),
      jsonEncode({...safe, 'isChild': 'false'}),
      'PRIVATE_INVALID_JSON',
      'PRIVATE_${'x' * 5000}',
    ]) {
      final diagnostics = CodexWalkDiagnostics();
      diagnostics.recordEvent(
        AgentEvent.notice('$prefix [display-v1 $invalid]'),
      );
      final obs = <String, Object?>{};
      diagnostics.persist(obs);
      final saved = obs['walkDiagnostics'] as Json;
      expect(saved.containsKey('approvalDisplayRefusals'), false);
      expect(jsonEncode(saved), isNot(contains('PRIVATE_')));
      expect(
        (saved['noticeFlags'] as Json)['approvalDisplayUnavailable'],
        true,
      );
    }
  });
  test('Codex diagnostic suffix: all fixed diagnostics together fit four KiB', () {
    const prefix =
        'Native approval unavailable: full details exceed display capacity; request cancelled.';
    final diagnostics = CodexWalkDiagnostics();
    const reasons = [
      'invalid approval timestamp',
      'missing approval turn',
      'invalid native approval',
      'invalid additional permissions',
      'unknown additional permission grant',
      'unsupported native request',
      'retired native turn',
      'offered decisions missing or unsupported',
      'control capacity exceeded',
    ];
    for (var i = 0; i < 3; i++) {
      diagnostics.recordTurnEnd(
        AgentTurnEndedParams(
          sessionId: 'PRIVATE_SESSION',
          stopReason: 'error',
          error: 'adapter-error',
          message: reasons.join('; '),
          nativeMessage: reasons.join('; '),
          nativeCode: -2147483648,
          nativeMessageTruncated: true,
        ),
      );
    }
    for (final notice in [
      'Native approval unavailable: offered decisions missing or unsupported.',
      'Native interaction refused: control capacity exceeded.',
      'Codex unsupported native request refused.',
      'Native interaction capacity or turn unavailable',
      'codex-protocol: ${reasons.join('; ')}',
      'Codex error -1: PRIVATE_TEXT',
    ]) {
      diagnostics.recordEvent(
        AgentEvent.fromJson({
          'kind': 'notice',
          'text': notice,
          'truncated': true,
        }),
      );
    }
    final metrics = <String, Object?>{
      'category': 'additional-permissions',
      'isChild': true,
      'titleBytes': 1048576,
      'previewBytes': 1048576,
      'maxNameBytes': 1048576,
      'optionCount': 1024,
      'titleLoss': true,
      'previewLoss': true,
      'namesLoss': true,
      'countLoss': true,
      'encodedLoss': true,
    };
    for (var i = 0; i < 100; i++) {
      diagnostics.recordEvent(
        AgentEvent.notice('$prefix [display-v1 ${jsonEncode(metrics)}]'),
      );
    }
    final obs = <String, Object?>{};
    diagnostics.persist(obs);
    expect(
      utf8.encode(jsonEncode(obs['walkDiagnostics'])).length,
      lessThanOrEqualTo(4096),
    );
    expect(jsonEncode(obs), isNot(contains('PRIVATE_')));
  });

  test('Codex diagnostic abort: confirmed refusal prevents later prompts and preserves finalization', () async {
    final diagnostics = CodexWalkDiagnostics();
    final observations = <String, Object?>{
      'launch': 'pass',
      'kumiko tool call': 'fail',
    };
    var prompts = 0, audits = 0, persisted = 0, disposed = 0;
    Object? failure;
    try {
      await runCodexObservedOperations(
        operations: () => runCodexWalkPrompts(
          diagnostics: diagnostics,
          observations: observations,
          prompt: (operation) async {
            prompts++;
            if (operation == 1) {
              diagnostics.recordEvent(
                AgentEvent.notice(
                  'Native approval unavailable: full details exceed display capacity; request cancelled.',
                ),
              );
            }
          },
        ),
        recordProgress: () => recordCodexWalkProgress(
          observations,
          textEvents: 43,
          firstTurnIncrementalEvents: 43,
          toolEvents: 4,
        ),
      );
    } on Object catch (error) {
      failure = error;
    } finally {
      await finalizeCodexWalk(
        observations: observations,
        cleanup: () async {
          audits++;
          observations['canaryAudit'] = {'complete': false};
        },
        persist: () async {
          persisted++;
        },
        dispose: () async {
          disposed++;
        },
      );
    }
    expect(prompts, 2);
    expect(failure, isA<StateError>());
    expect(observations['walkAbortedReason'], 'approval-display-unavailable');
    expect(observations['launch'], 'pass');
    expect(observations['kumiko tool call'], 'fail');
    expect(observations['textEvents'], 43);
    expect(audits, 1);
    expect(persisted, 1);
    expect(disposed, 1);
  });

  test('Codex diagnostic suffix: strict safe snapshots remain bounded and reject hostile data', () {
    final diagnostics = CodexWalkDiagnostics();
    const prefix =
        'Native approval unavailable: full details exceed display capacity; request cancelled.';
    final safe = <String, Object?>{
      'category': 'command',
      'isChild': false,
      'titleBytes': 16,
      'previewBytes': 600,
      'maxNameBytes': 700,
      'optionCount': 2,
      'titleLoss': false,
      'previewLoss': false,
      'namesLoss': true,
      'countLoss': false,
      'encodedLoss': false,
    };
    for (var i = 0; i < 100; i++) {
      diagnostics.recordEvent(
        AgentEvent.notice('$prefix [display-v1 ${jsonEncode(safe)}]'),
      );
    }
    for (final invalid in [
      <String, Object?>{...safe, 'private': 'PRIVATE_PATH'},
      <String, Object?>{...safe, 'category': 'PRIVATE_PROVIDER'},
      <String, Object?>{...safe, 'previewBytes': -1},
      <String, Object?>{...safe, 'isChild': 'false'},
    ]) {
      diagnostics.recordEvent(
        AgentEvent.notice('$prefix [display-v1 ${jsonEncode(invalid)}]'),
      );
    }
    final obs = <String, Object?>{};
    diagnostics.persist(obs);
    final result = obs['walkDiagnostics'] as Json;
    expect(result['approvalDisplayRefusals'], hasLength(3));
    expect(result['approvalDisplayRefusalsTruncated'], true);
    expect((result['noticeFlags'] as Json)['approvalDisplayUnavailable'], true);
    expect(jsonEncode(result), isNot(contains('PRIVATE_')));
    expect(utf8.encode(jsonEncode(result)).length, lessThan(4096));
  });

  test('Codex audit manifest: prior privacy failure survives later incomplete or mismatched metadata', () {
    final scan = validatedCodexAuditScan(plan());
    for (final mode in ['incomplete', 'missing', 'mismatched']) {
      final result = <String, Object?>{
        ...scan,
        'complete': mode != 'incomplete',
        'matchedFiles': 0,
      };
      if (mode == 'missing') result.remove('maxFileBytes');
      if (mode == 'mismatched') result['auditProfile'] = 'other';
      final observations = <String, Object?>{
        'kumiko tool call': 'fail',
        'unrelatedMcpEnvironmentIsolated': true,
        'unrelatedCommandEnvironmentIsolated': true,
      };
      recordCodexCanaryAudit(observations, scan, result);
      expect(observations['kumiko tool call'], 'fail', reason: mode);
      final retained = observations['canaryAudit'] as Json;
      expect(retained['complete'], false);
      expect(retained['matchedFiles'], 0);
      if (mode == 'missing') {
        expect(retained.containsKey('maxFileBytes'), false);
      }
      if (mode == 'mismatched') expect(retained['auditProfile'], 'other');
    }
  });

  test('Codex audit manifest: default large and legacy preserve host profile directory', () {
    final value = plan();
    final scan = validatedCodexAuditScan(value);
    expect(scan['auditProfile'], 'default');
    expect(scan['maxFileBytes'], 16 * 1024 * 1024);
    expect(value['profile'], r'F:\owned\profile');
    (value['scan'] as Json).remove('auditProfile');
    expect(validatedCodexAuditScan(value)['auditProfile'], 'default');
    final large = plan();
    (large['scan'] as Json).addAll({
      'auditProfile': 'large-native-home',
      'maxFileBytes': 256 * 1024 * 1024,
      'maxTotalBytes': 512 * 1024 * 1024,
    });
    expect(validatedCodexAuditScan(large)['auditProfile'], 'large-native-home');
    (large['scan'] as Json).remove('auditProfile');
    expect(() => validatedCodexAuditScan(large), throwsFormatException);
  });
  for (final change in <Json>[
    {'auditProfile': 'other'},
    {'auditProfile': null},
    {'maxFiles': 4097},
    {'maxFiles': 4096.0},
    {'maxFileBytes': 17},
    {'maxTotalBytes': 42},
    {'roots': []},
    {
      'roots': [r'F:\owned\work', r'F:\owned\profile', r'C:\other'],
    },
    {
      'roots': [1, 2, 3],
    },
  ]) {
    test('Codex audit manifest: invalid scan tuple ${jsonEncode(change)}', () {
      final value = plan();
      (value['scan'] as Json).addAll(change);
      expect(() => validatedCodexAuditScan(value), throwsFormatException);
    });
  }
  test(
    'Codex audit manifest: validated roots are passed as an immutable snapshot',
    () {
      final value = plan();
      final scan = validatedCodexAuditScan(value);
      expect(scan['roots'], (value['scan'] as Json)['roots']);
      expect(
        () => (scan['roots'] as List).add('unapproved'),
        throwsUnsupportedError,
      );
    },
  );
  test('Codex audit manifest: stale missing or mismatched prepare echo stops before startup', () {
    final scan = validatedCodexAuditScan(plan());
    var started = 0;
    final good = <String, Object?>{
      for (final key in [
        'auditProfile',
        'maxFiles',
        'maxFileBytes',
        'maxTotalBytes',
        'nativeSelection',
      ])
        key: scan[key],
    };
    requireCodexAuditPreparation(scan, good);
    for (final key in good.keys) {
      for (final missing in [true, false]) {
        final echo = {...good};
        if (missing) {
          echo.remove(key);
        } else {
          echo[key] = 'wrong';
        }
        expect(() {
          requireCodexAuditPreparation(scan, echo);
          started++;
        }, throwsStateError);
      }
    }
    expect(started, 0);
  });
  test('Codex audit manifest: every scan echo mismatch stays incomplete and match failure dominates', () {
    final scan = validatedCodexAuditScan(plan());
    for (final key in [
      'auditProfile',
      'maxFiles',
      'maxFileBytes',
      'maxTotalBytes',
    ]) {
      for (final matches in [0, 1]) {
        for (final missing in [true, false]) {
          final result = {...scan, 'complete': true, 'matchedFiles': matches};
          if (missing) {
            result.remove(key);
          } else {
            result[key] = 'wrong';
          }
          final obs = <String, Object?>{
            'kumiko tool call': 'pass',
            'unrelatedMcpEnvironmentIsolated': true,
            'unrelatedCommandEnvironmentIsolated': true,
          };
          recordCodexCanaryAudit(obs, scan, result);
          expect((obs['canaryAudit'] as Json)['complete'], false);
          expect(obs['kumiko tool call'], matches == 1 ? 'fail' : 'unverified');
        }
      }
    }
  });
  test('Codex audit manifest: valid echo cannot hide incomplete or matched results', () {
    final scan = validatedCodexAuditScan(plan());
    for (final complete in [true, false]) {
      for (final matched in [0, 1]) {
        final obs = <String, Object?>{
          'kumiko tool call': 'pass',
          'unrelatedMcpEnvironmentIsolated': true,
          'unrelatedCommandEnvironmentIsolated': true,
        };
        recordCodexCanaryAudit(obs, scan, {
          ...scan,
          'complete': complete,
          'matchedFiles': matched,
        });
        expect(
          obs['kumiko tool call'],
          matched == 1
              ? 'fail'
              : complete
              ? 'pass'
              : 'unverified',
        );
      }
    }
  });
  test(
    'Codex audit manifest: invalid prepare profile creates no artifacts',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'kumiko_invalid_prepare_',
      );
      addTearDown(() => dir.delete(recursive: true));
      final result = await Process.run(Platform.resolvedExecutable, [
        'tool/qualify_codex_app_server.dart',
        '--prepare',
        '--workspace',
        '${dir.path}/workspace',
        '--native',
        '${dir.path}/never-native',
        '--manifest',
        '${dir.path}/artifact/manifest.json',
        '--audit-profile',
        'unknown',
      ]);
      expect(result.exitCode, 1);
      expect(dir.listSync(), isEmpty);
    },
  );
  test(
    'Codex audit manifest: walk refuses budget option before claim',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'kumiko_override_walk_',
      );
      addTearDown(() => dir.delete(recursive: true));
      final bytes = utf8.encode(jsonEncode(plan()));
      final manifest = File('${dir.path}/manifest.json')
        ..writeAsBytesSync(bytes);
      final result = await Process.run(Platform.resolvedExecutable, [
        'tool/qualify_codex_app_server.dart',
        '--walk',
        '--manifest',
        manifest.path,
        '--approved-sha256',
        sha256.convert(bytes).toString(),
        '--audit-profile',
        'large-native-home',
      ]);
      expect(result.exitCode, 1);
      expect(File('${dir.path}/attempt.jsonl').existsSync(), false);
    },
  );

  Json planFor(String selection) => makeCodexWalkPlan(
    workspace: r'F:\owned\work',
    profile: r'F:\owned\profile',
    executable: r'F:\native\codex.exe',
    nativeHome: r'C:\user\.codex',
    version: '0.166.0',
    hostExecutable: r'F:\test\kumiko_host_test.exe',
    canaryCommand: 'inert canary command',
    stopCommand: 'inert long command',
    nativeSelection: selection,
  );
  const wider = 'changed-artifacts-v1';
  Json preparedEcho(Json scan, {Json extra = const {}}) => {
    for (final key in [
      'auditProfile',
      'maxFiles',
      'maxFileBytes',
      'maxTotalBytes',
      'nativeSelection',
    ])
      key: scan[key],
    'baselineComplete': true,
    'baselineErrorCount': 0,
    ...extra,
  };

  test('Codex changed artifacts: selection manifest records the explicit selection and the canonical wider scope', () {
    final scan = validatedCodexAuditScan(planFor(wider));
    expect(scan['nativeSelection'], wider);
    expect(scan['nativeScope'], changedArtifactsDisclosure);
    expect(scan['maxFiles'], 4096);
    expect(scan['maxFileBytes'], 16 * 1024 * 1024);
    final legacy = validatedCodexAuditScan(planFor('legacy'));
    expect(legacy['nativeSelection'], 'legacy');
    expect(legacy['nativeScope'], isNot(changedArtifactsDisclosure));
    expect(legacy['nativeScope'], contains('no credential/config contents'));
  });
  test('Codex changed artifacts: selection disclosure enumerates the effective protected set and warns that other stores may be read', () {
    final text =
        validatedCodexAuditScan(planFor(wider))['nativeScope']! as String;
    for (final name in [
      'auth.json',
      'config.toml',
      '.credentials.json',
      'managed_config.toml',
      'requirements.toml',
      'environments.toml',
      '.env',
    ]) {
      expect(text, contains(name));
    }
    expect(protectedNativeBasenames.length, 7);
    expect(text, contains('other credential-bearing stores may be read'));
    expect(text, contains('metadata-equality'));
    expect(text, contains('ASCII/UTF-8'));
    expect(text, contains('never printed'));
    expect(utf8.encode(text).every((byte) => byte < 128), true);
  });
  test('Codex changed artifacts: selection canary match in a selected file fails the tool call and keeps the detector limits', () {
    final scan = validatedCodexAuditScan(planFor(wider));
    final observations = <String, Object?>{
      'kumiko tool call': 'pass',
      'unrelatedMcpEnvironmentIsolated': true,
      'unrelatedCommandEnvironmentIsolated': true,
    };
    recordCodexCanaryAudit(observations, scan, {
      ...scan,
      'complete': false,
      'matchedFiles': 1,
      'nativeDetectorLimits': nativeDetectorLimits,
      'nativeSelectionCounters': {'selectedFiles': 2},
    });
    expect(observations['kumiko tool call'], 'fail');
    final retained = observations['canaryAudit']! as Json;
    expect(retained['nativeDetectorLimits'], nativeDetectorLimits);
    expect(retained['nativeSelection'], wider);
    expect(retained['complete'], false);
  });
  test('Codex changed artifacts: selection summary text is content-free', () {
    final text = codexPreparationSummary(
      manifest: r'F:\owned\manifest.json',
      sha256Hex: 'a' * 64,
      budget: AuditBudget.defaults,
      nativeSelection: wider,
    );
    expect(text, isNot(contains('PRIVATE')));
    expect(text, contains(wider));
  });

  test('Codex changed artifacts: binding old manifests and legacy default keep legacy and cannot gain wider coverage', () {
    final value = planFor('legacy');
    (value['scan'] as Json).remove('nativeSelection');
    expect(validatedCodexAuditScan(value)['nativeSelection'], 'legacy');
    expect(validatedCodexAuditScan(plan())['nativeSelection'], 'legacy');
    // Dropping the field from a wider manifest must not leave a wider scope.
    final broadened = planFor(wider);
    (broadened['scan'] as Json).remove('nativeSelection');
    expect(() => validatedCodexAuditScan(broadened), throwsFormatException);
  });
  for (final bad in <Object?>[
    'unknown',
    'Changed-Artifacts-V1',
    'changed-artifacts-v5',
    '',
    1,
    null,
    true,
    ['legacy'],
  ]) {
    test(
      'Codex changed artifacts: binding invalid manifest selection ${jsonEncode(bad)} is rejected',
      () {
        final value = planFor('legacy');
        (value['scan'] as Json)['nativeSelection'] = bad;
        expect(() => validatedCodexAuditScan(value), throwsFormatException);
      },
    );
  }
  test('Codex changed artifacts: binding noncanonical or mismatched scope is rejected before claim', () {
    for (final scope in <Object?>[
      null,
      7,
      '',
      'metadata only',
      '$changedArtifactsDisclosure extra',
      changedArtifactsDisclosure.replaceFirst('requirements.toml, ', ''),
      changedArtifactsDisclosure.replaceFirst(
        'other credential-bearing stores may be read',
        'no other stores',
      ),
      (planFor('legacy')['scan'] as Json)['nativeScope'],
    ]) {
      final value = planFor(wider);
      (value['scan'] as Json)['nativeScope'] = scope;
      expect(
        () => validatedCodexAuditScan(value),
        throwsFormatException,
        reason: '$scope',
      );
    }
    final legacy = planFor('legacy');
    (legacy['scan'] as Json)['nativeScope'] = changedArtifactsDisclosure;
    expect(() => validatedCodexAuditScan(legacy), throwsFormatException);
  });
  test('Codex changed artifacts: binding tampered wider scope creates no attempt claim', () async {
    final directory = await Directory.systemTemp.createTemp(
      'kumiko_scope_walk_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final value = planFor(wider);
    (value['scan'] as Json)['nativeScope'] = 'metadata only';
    final bytes = utf8.encode(jsonEncode(value));
    final manifest = File('${directory.path}/manifest.json')
      ..writeAsBytesSync(bytes);
    final result = await Process.run(Platform.resolvedExecutable, [
      'tool/qualify_codex_app_server.dart',
      '--walk',
      '--manifest',
      manifest.path,
      '--approved-sha256',
      sha256.convert(bytes).toString(),
    ]);
    expect(result.exitCode, 1);
    expect(File('${directory.path}/attempt.jsonl').existsSync(), false);
  });
  test('Codex changed artifacts: binding prepare validates the selection option before creating artifacts', () async {
    for (final value in ['unknown', 'Changed-Artifacts-V1', '']) {
      final dir = await Directory.systemTemp.createTemp(
        'kumiko_invalid_selection_',
      );
      addTearDown(() => dir.delete(recursive: true));
      final result = await Process.run(Platform.resolvedExecutable, [
        'tool/qualify_codex_app_server.dart',
        '--prepare',
        '--workspace',
        '${dir.path}/workspace',
        '--native',
        '${dir.path}/never-native',
        '--manifest',
        '${dir.path}/artifact/manifest.json',
        '--native-selection',
        value,
      ]);
      expect(result.exitCode, 1, reason: value);
      expect(dir.listSync(), isEmpty, reason: value);
    }
    final dir = await Directory.systemTemp.createTemp(
      'kumiko_repeat_selection_',
    );
    addTearDown(() => dir.delete(recursive: true));
    final repeated = await Process.run(Platform.resolvedExecutable, [
      'tool/qualify_codex_app_server.dart',
      '--prepare',
      '--workspace',
      '${dir.path}/workspace',
      '--native',
      '${dir.path}/never-native',
      '--manifest',
      '${dir.path}/artifact/manifest.json',
      '--native-selection',
      'legacy',
      '--native-selection',
      wider,
    ]);
    expect(repeated.exitCode, 1);
    expect(dir.listSync(), isEmpty);
  });
  test('Codex changed artifacts: binding walk refuses a selection override before claim', () async {
    final dir = await Directory.systemTemp.createTemp(
      'kumiko_override_selection_',
    );
    addTearDown(() => dir.delete(recursive: true));
    final bytes = utf8.encode(jsonEncode(plan()));
    final manifest = File('${dir.path}/manifest.json')..writeAsBytesSync(bytes);
    final result = await Process.run(Platform.resolvedExecutable, [
      'tool/qualify_codex_app_server.dart',
      '--walk',
      '--manifest',
      manifest.path,
      '--approved-sha256',
      sha256.convert(bytes).toString(),
      '--native-selection',
      wider,
    ]);
    expect(result.exitCode, 1);
    expect(File('${dir.path}/attempt.jsonl').existsSync(), false);
  });
  test('Codex changed artifacts: binding preparation prints the fixed disclosure beside selection limits and hash only in changed-artifacts-v1', () {
    final hash = 'ab' * 32;
    final text = codexPreparationSummary(
      manifest: r'F:\owned\manifest.json',
      sha256Hex: hash,
      budget: AuditBudget.large,
      nativeSelection: wider,
    );
    expect(text, contains(hash));
    expect(text, contains('large-native-home'));
    expect(text, contains('536870912'));
    expect(text, contains('NativeSelection: $wider'));
    expect(text, contains(changedArtifactsDisclosure));
    final legacy = codexPreparationSummary(
      manifest: r'F:\owned\manifest.json',
      sha256Hex: hash,
      budget: AuditBudget.defaults,
      nativeSelection: 'legacy',
    );
    expect(legacy, contains('NativeSelection: legacy'));
    expect(legacy, contains(hash));
    expect(legacy, isNot(contains('disclosure')));
    expect(legacy, isNot(contains('credential-bearing')));
    for (final name in protectedNativeBasenames) {
      expect(legacy, isNot(contains(name)));
    }
  });
  test('Codex changed artifacts: binding preparation request carries exactly the two bound keys and validates every echo', () async {
    for (final selection in ['legacy', wider]) {
      final scan = validatedCodexAuditScan(planFor(selection));
      final requests = <Json>[];
      await prepareCodexAuditBinding(
        scan: scan,
        observations: {},
        call: (method, params) async {
          expect(method, 'test/codex.audit.prepare');
          requests.add(params);
          return preparedEcho(scan);
        },
      );
      expect(requests.single, {
        'auditProfile': 'default',
        'nativeSelection': selection,
      });
      for (final key in ['nativeSelection', 'auditProfile', 'maxFileBytes']) {
        for (final missing in [true, false]) {
          final echo = preparedEcho(scan);
          if (missing) {
            echo.remove(key);
          } else {
            echo[key] = 'wrong';
          }
          var providerStarted = false;
          await expectLater(
            () async {
              await prepareCodexAuditBinding(
                scan: scan,
                observations: {},
                call: (_, _) async => echo,
              );
              providerStarted = true;
            }(),
            throwsStateError,
            reason: '$selection $key missing=$missing',
          );
          expect(providerStarted, false);
        }
      }
    }
  });
  test('Codex changed artifacts: binding scan echo mismatch of the selection stays incomplete and a match still fails', () {
    final scan = validatedCodexAuditScan(planFor(wider));
    for (final matches in [0, 1]) {
      for (final missing in [true, false]) {
        final result = {...scan, 'complete': true, 'matchedFiles': matches};
        if (missing) {
          result.remove('nativeSelection');
        } else {
          result['nativeSelection'] = 'legacy';
        }
        final obs = <String, Object?>{
          'kumiko tool call': 'pass',
          'unrelatedMcpEnvironmentIsolated': true,
          'unrelatedCommandEnvironmentIsolated': true,
        };
        recordCodexCanaryAudit(obs, scan, result);
        expect((obs['canaryAudit'] as Json)['complete'], false);
        expect(obs['kumiko tool call'], matches == 1 ? 'fail' : 'unverified');
      }
    }
  });

  Json baselineEcho(Json scan, Object? complete, Object? count) {
    final echo = preparedEcho(scan)
      ..remove('baselineComplete')
      ..remove('baselineErrorCount');
    return {
      ...echo,
      'baselineComplete': ?complete,
      'baselineErrorCount': ?count,
    };
  }

  test('Codex changed artifacts: refusal incomplete wider baseline aborts before provider work with a content-free receipt', () async {
    final scan = validatedCodexAuditScan(planFor(wider));
    for (final (complete, count) in <(Object?, Object?)>[
      (false, 3),
      (true, 2),
      (false, 0),
      (null, 0),
      (true, null),
      ('yes', 0),
      (true, 'none'),
      (true, -1),
    ]) {
      final observations = <String, Object?>{};
      var providerStarted = false;
      await expectLater(
        () async {
          await prepareCodexAuditBinding(
            scan: scan,
            observations: observations,
            call: (_, _) async => baselineEcho(scan, complete, count),
          );
          providerStarted = true;
        }(),
        throwsStateError,
        reason: '$complete $count',
      );
      expect(providerStarted, false);
      final receipt = observations['baselinePreflight']! as Json;
      expect(receipt['stage'], 'baseline-preflight');
      expect(receipt['status'], 'INCOMPLETE');
      expect(receipt['providerWork'], false);
      expect(receipt['contentScan'], false);
      expect(receipt['baselineComplete'], false);
      expect(receipt['baselineErrorCount'], isA<int>());
      expect(jsonEncode(receipt), isNot(contains('Users')));
    }
  });
  test('Codex changed artifacts: refusal baseline receipt keeps only known content-free category counters', () async {
    final scan = validatedCodexAuditScan(planFor(wider));
    final observations = <String, Object?>{};
    await expectLater(
      prepareCodexAuditBinding(
        scan: scan,
        observations: observations,
        call: (_, _) async => {
          ...baselineEcho(scan, false, 8),
          'baselineErrorCategories': {
            'metadataLimit': 1,
            'nonRegular': 7,
            'C:/Users/secret/name': 3,
            'traversalIo': -2,
            'metadataIo': 'x',
          },
          'baselineIoErrorCategories': {'accessDenied': 2, 'other': 1.5},
        },
      ),
      throwsStateError,
    );
    final receipt = observations['baselinePreflight']! as Json;
    expect(receipt['baselineErrorCategories'], {
      'metadataLimit': 1,
      'nonRegular': 7,
    });
    expect(receipt['baselineIoErrorCategories'], {'accessDenied': 2});
    expect(jsonEncode(receipt), isNot(contains('Users')));
  });
  test('Codex changed artifacts: refusal baseline abort leaves launch unverified because App Server never started', () {
    final observations = <String, Object?>{
      'launch': 'unverified',
      'baselinePreflight': {'stage': 'baseline-preflight'},
    };
    recordCodexMissingSession(observations);
    expect(observations['launch'], 'unverified');
    final startup = <String, Object?>{'launch': 'unverified'};
    recordCodexMissingSession(startup);
    expect(startup['launch'], 'fail');
  });
  test('Codex changed artifacts: refusal complete wider baseline and legacy mode are not gated by the receipt', () async {
    final scan = validatedCodexAuditScan(planFor(wider));
    final observations = <String, Object?>{};
    await prepareCodexAuditBinding(
      scan: scan,
      observations: observations,
      call: (_, _) async => preparedEcho(scan),
    );
    expect(observations.containsKey('baselinePreflight'), false);
    final legacy = validatedCodexAuditScan(planFor('legacy'));
    await prepareCodexAuditBinding(
      scan: legacy,
      observations: observations,
      call: (_, _) async => baselineEcho(legacy, false, 5),
    );
    expect(observations.containsKey('baselinePreflight'), false);
  });
  test('Codex changed artifacts: refusal failed baseline consumes the claim records an INCOMPLETE receipt and refuses reuse', () async {
    final directory = Directory.systemTemp.createTempSync(
      'kumiko_baseline_claim_',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final marker = File('${directory.path}/attempt.jsonl');
    final scan = validatedCodexAuditScan(planFor(wider));
    final observations = <String, Object?>{};
    var providerStarted = false;
    var runs = 0;
    Future<void> attempt() => runClaimedCodexAttempt(marker, () async {
      runs++;
      try {
        await prepareCodexAuditBinding(
          scan: scan,
          observations: observations,
          call: (_, _) async => baselineEcho(scan, false, 4),
        );
        providerStarted = true;
      } finally {
        recordCodexMissingSession(observations);
        File('${directory.path}/observations.json')
            .writeAsStringSync(jsonEncode(observations));
      }
    });
    await expectLater(attempt(), throwsStateError);
    expect(providerStarted, false);
    final phases = [
      for (final line in marker.readAsLinesSync())
        (jsonDecode(line) as Json)['phase'],
    ];
    expect(phases, ['claimed', 'failed']);
    final receipt = jsonDecode(
      File('${directory.path}/observations.json').readAsStringSync(),
    ) as Json;
    final preflight = receipt['baselinePreflight']! as Json;
    expect(preflight['baselineErrorCount'], 4);
    expect(preflight['stage'], 'baseline-preflight');
    expect(preflight['providerWork'], false);
    expect(preflight['contentScan'], false);
    expect((receipt['canaryAudit']! as Json)['complete'], false);
    expect((receipt['canaryAudit']! as Json)['scanned'], false);
    final before = marker.readAsStringSync();
    // Reuse of the consumed approval is refused without running anything.
    await expectLater(attempt(), throwsStateError);
    expect(runs, 1);
    expect(marker.readAsStringSync(), before);
  });

  // ---- Codex normal home: changed-artifacts-v2 ----
  const normal = 'changed-artifacts-v2';

  test('Codex normal home: manifest records v2 with its own canonical disclosure and unchanged scanner limits', () {
    final scan = validatedCodexAuditScan(planFor(normal));
    expect(scan['nativeSelection'], normal);
    expect(scan['nativeScope'], changedArtifactsV2Disclosure);
    expect(scan['nativeScope'], isNot(changedArtifactsDisclosure));
    expect(scan['maxFiles'], 4096);
    expect(scan['maxFileBytes'], 16 * 1024 * 1024);
    expect(scan['maxTotalBytes'], 32 * 1024 * 1024);
    // v1 and legacy keep their recorded meaning and disclosure.
    expect(
      validatedCodexAuditScan(planFor(wider))['nativeScope'],
      changedArtifactsDisclosure,
    );
    expect(
      validatedCodexAuditScan(planFor('legacy'))['nativeScope'],
      isNot(changedArtifactsV2Disclosure),
    );
  });
  test('Codex normal home: the canonical disclosure states the bound the link limits the concurrent writers and the pause', () {
    final text =
        validatedCodexAuditScan(planFor(normal))['nativeScope']! as String;
    for (final name in protectedNativeBasenames) {
      expect(text, contains(name));
    }
    expect(protectedNativeBasenames.length, 7);
    expect(text, contains('65,536'));
    expect(text, contains('16 MiB'));
    expect(text, contains('32 MiB'));
    expect(text, contains('traversal through an unchanged link is excluded'));
    expect(text, contains('two observation times only'));
    expect(text, contains('other Codex sessions'));
    expect(text, contains('the owner pauses other Codex sessions'));
    expect(text, contains('other credential-bearing stores may be read'));
    expect(text, contains('metadata-equality'));
    expect(text, contains('ASCII/UTF-8'));
    expect(text, contains('never printed'));
    expect(utf8.encode(text).every((byte) => byte < 128), true);
    expect(nativeDetectorLimitsV2.take(2), nativeDetectorLimits);
    expect(nativeDetectorLimitsV2.length, 4);
    expect(nativeDetectorLimitsV2.join(' '), contains('other Codex sessions'));
    expect(nativeDetectorLimitsV2.join(' '), contains('unchanged link'));
  });
  test('Codex normal home: binding rejects a noncanonical or crossed scope before claim and keeps v1 and legacy unchanged', () {
    for (final scope in <Object?>[
      null,
      7,
      '',
      'metadata only',
      '$changedArtifactsV2Disclosure extra',
      changedArtifactsV2Disclosure.replaceFirst('65,536', '4096'),
      changedArtifactsV2Disclosure.replaceFirst(
        'the owner pauses other Codex sessions',
        'the owner may run other Codex sessions',
      ),
      changedArtifactsDisclosure,
      (planFor('legacy')['scan'] as Json)['nativeScope'],
    ]) {
      final value = planFor(normal);
      (value['scan'] as Json)['nativeScope'] = scope;
      expect(
        () => validatedCodexAuditScan(value),
        throwsFormatException,
        reason: '$scope',
      );
    }
    final crossed = planFor(wider);
    (crossed['scan'] as Json)['nativeScope'] = changedArtifactsV2Disclosure;
    expect(() => validatedCodexAuditScan(crossed), throwsFormatException);
    final legacy = planFor('legacy');
    (legacy['scan'] as Json)['nativeScope'] = changedArtifactsV2Disclosure;
    expect(() => validatedCodexAuditScan(legacy), throwsFormatException);
    final broadened = planFor(normal);
    (broadened['scan'] as Json).remove('nativeSelection');
    expect(() => validatedCodexAuditScan(broadened), throwsFormatException);
  });
  test(
    'Codex normal home: binding a tampered v2 scope creates no attempt claim',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'kumiko_v2_scope_walk_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final value = planFor(normal);
      (value['scan'] as Json)['nativeScope'] = changedArtifactsDisclosure;
      final bytes = utf8.encode(jsonEncode(value));
      final manifest = File('${directory.path}/manifest.json')
        ..writeAsBytesSync(bytes);
      final result = await Process.run(Platform.resolvedExecutable, [
        'tool/qualify_codex_app_server.dart',
        '--walk',
        '--manifest',
        manifest.path,
        '--approved-sha256',
        sha256.convert(bytes).toString(),
      ]);
      expect(result.exitCode, 1);
      expect(File('${directory.path}/attempt.jsonl').existsSync(), false);
    },
  );
  test('Codex normal home: binding preparation prints the v2 disclosure beside limits and hash and no other selection prints it', () {
    final hash = 'cd' * 32;
    final text = codexPreparationSummary(
      manifest: r'F:\owned\manifest.json',
      sha256Hex: hash,
      budget: AuditBudget.defaults,
      nativeSelection: normal,
    );
    expect(text, contains(hash));
    expect(text, contains('NativeSelection: $normal'));
    expect(text, contains(changedArtifactsV2Disclosure));
    expect(text, isNot(contains(changedArtifactsDisclosure)));
    for (final selection in [wider, 'legacy']) {
      final other = codexPreparationSummary(
        manifest: r'F:\owned\manifest.json',
        sha256Hex: hash,
        budget: AuditBudget.defaults,
        nativeSelection: selection,
      );
      expect(other, isNot(contains(changedArtifactsV2Disclosure)));
    }
    final v1 = codexPreparationSummary(
      manifest: r'F:\owned\manifest.json',
      sha256Hex: hash,
      budget: AuditBudget.defaults,
      nativeSelection: wider,
    );
    expect(v1, contains(changedArtifactsDisclosure));
  });
  test('Codex normal home: binding preparation request carries exactly the two bound keys and validates every echo', () async {
    final scan = validatedCodexAuditScan(planFor(normal));
    final requests = <Json>[];
    await prepareCodexAuditBinding(
      scan: scan,
      observations: {},
      call: (method, params) async {
        expect(method, 'test/codex.audit.prepare');
        requests.add(params);
        return preparedEcho(scan);
      },
    );
    expect(requests.single, {
      'auditProfile': 'default',
      'nativeSelection': normal,
    });
    for (final key in ['nativeSelection', 'auditProfile', 'maxFileBytes']) {
      for (final missing in [true, false]) {
        final echo = preparedEcho(scan);
        if (missing) {
          echo.remove(key);
        } else {
          // A v1 or legacy echo can never satisfy a v2 manifest.
          echo[key] = key == 'nativeSelection' ? wider : 'wrong';
        }
        var providerStarted = false;
        await expectLater(
          () async {
            await prepareCodexAuditBinding(
              scan: scan,
              observations: {},
              call: (_, _) async => echo,
            );
            providerStarted = true;
          }(),
          throwsStateError,
          reason: '$key missing=$missing',
        );
        expect(providerStarted, false);
      }
    }
  });
  test('Codex normal home: a scan echo mismatch stays incomplete a match still fails and the v2 limits are retained', () {
    final scan = validatedCodexAuditScan(planFor(normal));
    for (final matches in [0, 1]) {
      for (final missing in [true, false]) {
        final result = {
          ...scan,
          'complete': true,
          'matchedFiles': matches,
          'nativeDetectorLimits': nativeDetectorLimitsV2,
        };
        if (missing) {
          result.remove('nativeSelection');
        } else {
          result['nativeSelection'] = wider;
        }
        final obs = <String, Object?>{
          'kumiko tool call': 'pass',
          'unrelatedMcpEnvironmentIsolated': true,
          'unrelatedCommandEnvironmentIsolated': true,
        };
        recordCodexCanaryAudit(obs, scan, result);
        final retained = obs['canaryAudit']! as Json;
        expect(retained['complete'], false);
        expect(retained['nativeDetectorLimits'], nativeDetectorLimitsV2);
        expect(obs['kumiko tool call'], matches == 1 ? 'fail' : 'unverified');
      }
    }
    final matching = <String, Object?>{
      'kumiko tool call': 'pass',
      'unrelatedMcpEnvironmentIsolated': true,
      'unrelatedCommandEnvironmentIsolated': true,
    };
    recordCodexCanaryAudit(matching, scan, {
      ...scan,
      'complete': true,
      'matchedFiles': 1,
      'nativeDetectorLimits': nativeDetectorLimitsV2,
    });
    expect(matching['kumiko tool call'], 'fail');
    expect(
      (matching['canaryAudit']! as Json)['nativeDetectorLimits'],
      nativeDetectorLimitsV2,
    );
  });
  test('Codex normal home: an incomplete v2 baseline aborts before provider work with a content-free receipt', () async {
    final scan = validatedCodexAuditScan(planFor(normal));
    for (final (complete, count) in <(Object?, Object?)>[
      (false, 3),
      (true, 2),
      (null, 0),
      (true, 'none'),
    ]) {
      final observations = <String, Object?>{};
      var providerStarted = false;
      await expectLater(
        () async {
          await prepareCodexAuditBinding(
            scan: scan,
            observations: observations,
            call: (_, _) async => baselineEcho(scan, complete, count),
          );
          providerStarted = true;
        }(),
        throwsStateError,
        reason: '$complete $count',
      );
      expect(providerStarted, false);
      final receipt = observations['baselinePreflight']! as Json;
      expect(receipt['stage'], 'baseline-preflight');
      expect(receipt['status'], 'INCOMPLETE');
      expect(receipt['providerWork'], false);
      expect(receipt['contentScan'], false);
      expect(jsonEncode(receipt), isNot(contains('Users')));
    }
    final complete = <String, Object?>{};
    await prepareCodexAuditBinding(
      scan: scan,
      observations: complete,
      call: (_, _) async => preparedEcho(scan),
    );
    expect(complete.containsKey('baselinePreflight'), false);
  });
  test('Codex normal home: the baseline receipt allowlists metadataStorage and linkObservation and nothing else', () async {
    final scan = validatedCodexAuditScan(planFor(normal));
    final observations = <String, Object?>{};
    await expectLater(
      prepareCodexAuditBinding(
        scan: scan,
        observations: observations,
        call: (_, _) async => {
          ...baselineEcho(scan, false, 6),
          'baselineErrorCategories': {
            'metadataStorage': 2,
            'linkObservation': 3,
            'metadataLimit': 1,
            'PRIVATE_TARGET_TEXT': 4,
            'linkTarget': 9,
            'metadataIo': -1,
          },
          'baselineIoErrorCategories': {'accessDenied': 1},
        },
      ),
      throwsStateError,
    );
    final receipt = observations['baselinePreflight']! as Json;
    expect(receipt['baselineErrorCategories'], {
      'metadataStorage': 2,
      'linkObservation': 3,
      'metadataLimit': 1,
    });
    expect(jsonEncode(receipt), isNot(contains('PRIVATE')));
  });
  test('Codex normal home: a failed v2 baseline consumes the claim records an INCOMPLETE receipt and refuses reuse', () async {
    final directory = Directory.systemTemp.createTempSync(
      'kumiko_v2_baseline_claim_',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final marker = File('${directory.path}/attempt.jsonl');
    final scan = validatedCodexAuditScan(planFor(normal));
    final observations = <String, Object?>{};
    var providerStarted = false;
    var runs = 0;
    Future<void> attempt() => runClaimedCodexAttempt(marker, () async {
      runs++;
      try {
        await prepareCodexAuditBinding(
          scan: scan,
          observations: observations,
          call: (_, _) async => baselineEcho(scan, false, 2),
        );
        providerStarted = true;
      } finally {
        recordCodexMissingSession(observations);
      }
    });
    await expectLater(attempt(), throwsStateError);
    expect(providerStarted, false);
    final phases = [
      for (final line in marker.readAsLinesSync())
        (jsonDecode(line) as Json)['phase'],
    ];
    expect(phases, ['claimed', 'failed']);
    expect(
      (observations['baselinePreflight']! as Json)['status'],
      'INCOMPLETE',
    );
    expect(observations['launch'], isNot('pass'));
    await expectLater(attempt(), throwsStateError);
    expect(runs, 1);
  });

  // ---- Codex native sockets: changed-artifacts-v3 ----
  const sockets = 'changed-artifacts-v3';

  test('Codex native sockets: manifest records v3 with its own canonical disclosure and v2 v1 and legacy are unchanged', () {
    final scan = validatedCodexAuditScan(planFor(sockets));
    expect(scan['nativeSelection'], sockets);
    expect(scan['nativeScope'], changedArtifactsV3Disclosure);
    expect(scan['nativeScope'], isNot(changedArtifactsV2Disclosure));
    expect(scan['nativeScope'], isNot(changedArtifactsDisclosure));
    expect(scan['maxFiles'], 4096);
    expect(scan['maxFileBytes'], 16 * 1024 * 1024);
    expect(scan['maxTotalBytes'], 32 * 1024 * 1024);
    expect(
      validatedCodexAuditScan(planFor(normal))['nativeScope'],
      changedArtifactsV2Disclosure,
    );
    expect(
      validatedCodexAuditScan(planFor(wider))['nativeScope'],
      changedArtifactsDisclosure,
    );
    expect(
      validatedCodexAuditScan(planFor('legacy'))['nativeScope'],
      isNot(changedArtifactsV3Disclosure),
    );
    // Absent selection never means v3.
    final broadened = planFor(sockets);
    (broadened['scan'] as Json).remove('nativeSelection');
    expect(() => validatedCodexAuditScan(broadened), throwsFormatException);
  });
  test('Codex native sockets: the canonical disclosure states the socket handling beside the v2 bound and limits', () {
    final text =
        validatedCodexAuditScan(planFor(sockets))['nativeScope']! as String;
    expect(text, startsWith('changed-artifacts-v3 disclosure:'));
    expect(text, isNot(contains('changed-artifacts-v2')));
    expect(text, contains('Unix-domain sockets in the native home'));
    expect(text, contains('recorded without being opened'));
    expect(text, contains('counted but not scanned'));
    expect(text, contains('because it has no contents'));
    expect(text, contains('pipes, devices and unknown types stay incomplete'));
    for (final name in protectedNativeBasenames) {
      expect(text, contains(name));
    }
    expect(text, contains('65,536'));
    expect(text, contains('16 MiB'));
    expect(text, contains('32 MiB'));
    expect(text, contains('traversal through an unchanged link is excluded'));
    expect(text, contains('the owner pauses other Codex sessions'));
    expect(text, contains('other credential-bearing stores may be read'));
    expect(text, contains('metadata-equality'));
    expect(text, contains('ASCII/UTF-8'));
    expect(utf8.encode(text).every((byte) => byte < 128), true);
    expect(nativeDetectorLimitsV3.take(4), nativeDetectorLimitsV2);
    expect(nativeDetectorLimitsV3.length, 5);
    expect(nativeDetectorLimitsV3.last, contains('sockets'));
    expect(nativeDetectorLimitsV2.length, 4, reason: 'v2 limits are unchanged');
  });
  test('Codex native sockets: binding rejects a noncanonical or crossed scope before claim', () {
    for (final scope in <Object?>[
      null,
      7,
      '',
      'metadata only',
      '$changedArtifactsV3Disclosure extra',
      changedArtifactsV3Disclosure.replaceFirst('65,536', '4096'),
      changedArtifactsV3Disclosure.replaceFirst(
        'counted but not scanned',
        'scanned',
      ),
      changedArtifactsV3Disclosure.replaceFirst(
        'Unix-domain sockets in the native home are recorded without being opened',
        'Unix-domain sockets are opened',
      ),
      changedArtifactsV2Disclosure,
      changedArtifactsDisclosure,
      (planFor('legacy')['scan'] as Json)['nativeScope'],
    ]) {
      final value = planFor(sockets);
      (value['scan'] as Json)['nativeScope'] = scope;
      expect(
        () => validatedCodexAuditScan(value),
        throwsFormatException,
        reason: '$scope',
      );
    }
    for (final selection in [normal, wider, 'legacy']) {
      final crossed = planFor(selection);
      (crossed['scan'] as Json)['nativeScope'] = changedArtifactsV3Disclosure;
      expect(
        () => validatedCodexAuditScan(crossed),
        throwsFormatException,
        reason: selection,
      );
    }
  });
  test('Codex native sockets: binding a tampered v3 scope creates no attempt claim', () async {
    final directory = await Directory.systemTemp.createTemp(
      'kumiko_v3_scope_walk_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final value = planFor(sockets);
    (value['scan'] as Json)['nativeScope'] = changedArtifactsV2Disclosure;
    final bytes = utf8.encode(jsonEncode(value));
    final manifest = File('${directory.path}/manifest.json')
      ..writeAsBytesSync(bytes);
    final result = await Process.run(Platform.resolvedExecutable, [
      'tool/qualify_codex_app_server.dart',
      '--walk',
      '--manifest',
      manifest.path,
      '--approved-sha256',
      sha256.convert(bytes).toString(),
    ]);
    expect(result.exitCode, 1);
    expect(File('${directory.path}/attempt.jsonl').existsSync(), false);
  });
  test(
    'Codex native sockets: the usage text and the selection option admit v3',
    () async {
      final result = await Process.run(Platform.resolvedExecutable, [
        'tool/qualify_codex_app_server.dart',
        '--help',
      ]);
      expect(result.exitCode, 0);
      final usage = result.stdout as String;
      expect(
        usage,
        contains(
          '--native-selection <legacy|changed-artifacts-v1|changed-artifacts-v2|changed-artifacts-v3',
        ),
      );
      // An unknown selection is still refused before anything is created.
      final dir = await Directory.systemTemp.createTemp('kumiko_v3_selection_');
      addTearDown(() => dir.delete(recursive: true));
      final refused = await Process.run(Platform.resolvedExecutable, [
        'tool/qualify_codex_app_server.dart',
        '--prepare',
        '--workspace',
        '${dir.path}/workspace',
        '--native',
        '${dir.path}/never-native',
        '--manifest',
        '${dir.path}/artifact/manifest.json',
        '--native-selection',
        'changed-artifacts-v5',
      ]);
      expect(refused.exitCode, 1);
      expect(dir.listSync(), isEmpty);
    },
  );
  test('Codex native sockets: binding preparation prints the v3 disclosure beside limits and hash and no other selection prints it', () {
    final hash = 'ef' * 32;
    final text = codexPreparationSummary(
      manifest: r'F:\owned\manifest.json',
      sha256Hex: hash,
      budget: AuditBudget.defaults,
      nativeSelection: sockets,
    );
    expect(text, contains(hash));
    expect(text, contains('NativeSelection: $sockets'));
    expect(text, contains(changedArtifactsV3Disclosure));
    expect(text, isNot(contains(changedArtifactsV2Disclosure)));
    expect(text, isNot(contains(changedArtifactsDisclosure)));
    for (final selection in [normal, wider, 'legacy']) {
      final other = codexPreparationSummary(
        manifest: r'F:\owned\manifest.json',
        sha256Hex: hash,
        budget: AuditBudget.defaults,
        nativeSelection: selection,
      );
      expect(other, isNot(contains(changedArtifactsV3Disclosure)));
    }
    final v2 = codexPreparationSummary(
      manifest: r'F:\owned\manifest.json',
      sha256Hex: hash,
      budget: AuditBudget.defaults,
      nativeSelection: normal,
    );
    expect(v2, contains(changedArtifactsV2Disclosure));
  });
  test('Codex native sockets: binding preparation carries the two bound keys and validates every v3 echo', () async {
    final scan = validatedCodexAuditScan(planFor(sockets));
    final requests = <Json>[];
    await prepareCodexAuditBinding(
      scan: scan,
      observations: {},
      call: (method, params) async {
        requests.add(params);
        return preparedEcho(scan);
      },
    );
    expect(requests.single, {
      'auditProfile': 'default',
      'nativeSelection': sockets,
    });
    for (final other in [normal, wider, 'legacy', null]) {
      final echo = preparedEcho(scan);
      if (other == null) {
        echo.remove('nativeSelection');
      } else {
        // A v2, v1 or legacy echo can never satisfy a v3 manifest.
        echo['nativeSelection'] = other;
      }
      await expectLater(
        prepareCodexAuditBinding(
          scan: scan,
          observations: {},
          call: (_, _) async => echo,
        ),
        throwsStateError,
        reason: '$other',
      );
    }
    // A v3 echo never satisfies a v2 manifest either.
    final v2Scan = validatedCodexAuditScan(planFor(normal));
    await expectLater(
      prepareCodexAuditBinding(
        scan: v2Scan,
        observations: {},
        call: (_, _) async => preparedEcho(scan),
      ),
      throwsStateError,
    );
  });
  test('Codex native sockets: an incomplete v3 baseline aborts before provider work with a content-free receipt', () async {
    final scan = validatedCodexAuditScan(planFor(sockets));
    final observations = <String, Object?>{};
    await expectLater(
      prepareCodexAuditBinding(
        scan: scan,
        observations: observations,
        call: (_, _) async => {
          ...baselineEcho(scan, false, 6),
          'baselineErrorCategories': {
            'linkObservation': 3,
            'nonRegular': 1,
            'PRIVATE_SOCKET_NAME.sock': 4,
            'socketsChanged': 9,
            'socketsAccounted': 9,
          },
          'baselineIoErrorCategories': {'accessDenied': 1},
        },
      ),
      throwsStateError,
    );
    final receipt = observations['baselinePreflight']! as Json;
    expect(receipt['baselineErrorCategories'], {
      'linkObservation': 3,
      'nonRegular': 1,
    });
    expect(receipt['providerWork'], false);
    expect(jsonEncode(receipt), isNot(contains('PRIVATE')));
    expect(jsonEncode(receipt), isNot(contains('.sock')));
  });
  test('Codex native sockets: a v3 result keeps the socket counters and limits and a scan echo mismatch stays incomplete', () {
    final scan = validatedCodexAuditScan(planFor(sockets));
    final counters = {
      'inventoryEntries': 9,
      'linksAccounted': 1,
      'socketsAccounted': 2,
      'socketsChanged': 1,
    };
    for (final missing in [true, false]) {
      final result = {
        ...scan,
        'complete': true,
        'matchedFiles': 0,
        'nativeDetectorLimits': nativeDetectorLimitsV3,
        'nativeSelectionCounters': counters,
      };
      if (missing) {
        result.remove('nativeSelection');
      } else {
        result['nativeSelection'] = normal;
      }
      final obs = <String, Object?>{
        'kumiko tool call': 'pass',
        'unrelatedMcpEnvironmentIsolated': true,
        'unrelatedCommandEnvironmentIsolated': true,
      };
      recordCodexCanaryAudit(obs, scan, result);
      final retained = obs['canaryAudit']! as Json;
      expect(retained['complete'], false);
      expect(retained['nativeDetectorLimits'], nativeDetectorLimitsV3);
      expect(retained['nativeSelectionCounters'], counters);
      expect(obs['kumiko tool call'], 'unverified');
    }
    final matching = <String, Object?>{
      'kumiko tool call': 'pass',
      'unrelatedMcpEnvironmentIsolated': true,
      'unrelatedCommandEnvironmentIsolated': true,
    };
    recordCodexCanaryAudit(matching, scan, {
      ...scan,
      'complete': true,
      'matchedFiles': 0,
      'nativeDetectorLimits': nativeDetectorLimitsV3,
      'nativeSelectionCounters': counters,
    });
    expect((matching['canaryAudit']! as Json)['complete'], true);
    expect(matching['kumiko tool call'], 'pass');
  });

  test('Codex audit manifest: malformed scan rejected before attempt or host startup', () async {
    final directory = await Directory.systemTemp.createTemp(
      'kumiko_audit_manifest_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final value = plan()..['scan'] = {'roots': <String>[], 'maxFiles': 999999};
    final bytes = utf8.encode(jsonEncode(value));
    final manifest = File('${directory.path}/manifest.json')
      ..writeAsBytesSync(bytes);
    await Process.run(Platform.resolvedExecutable, [
      'tool/qualify_codex_app_server.dart',
      '--walk',
      '--manifest',
      manifest.path,
      '--approved-sha256',
      sha256.convert(bytes).toString(),
    ]);
    expect(File('${directory.path}/attempt.jsonl').existsSync(), false);
  });

  test(
    'walk diagnostics retain bounded turn-end errors without private content',
    () {
      final diagnostics = CodexWalkDiagnostics();
      final private = 'PRIVATE_TURN_${List.filled(5000, 'hostile').join()}';
      diagnostics.recordTurnEnd(
        AgentTurnEndedParams(
          sessionId: private,
          stopReason: 'error',
          error: 'adapter-error',
          message: 'codex-protocol: invalid approval timestamp $private',
          nativeCode: -32602,
          nativeMessage: private,
          nativeMessageTruncated: true,
        ),
      );
      diagnostics.recordTurnEnd(
        AgentTurnEndedParams(
          sessionId: private,
          stopReason: 'cancelled',
          error: ErrorCode.authRequired,
        ),
      );
      diagnostics.recordTurnEnd(
        AgentTurnEndedParams(
          sessionId: private,
          stopReason: private,
          error: private,
          message: private,
        ),
      );
      for (var i = 0; i < 1000; i++) {
        diagnostics.recordTurnEnd(
          AgentTurnEndedParams(sessionId: private, stopReason: 'end_turn'),
        );
        diagnostics.recordEvent(AgentEvent.notice(private));
      }
      final observations = <String, Object?>{
        'launch': 'pass',
        'command approval': 'unverified',
        'streaming': 'fail',
        'canaryAudit': {'complete': false, 'scanned': false},
      };
      final prior = Map<String, Object?>.of(observations);
      diagnostics.persist(observations);
      final safe = observations['walkDiagnostics'] as Json?;
      expect(
        safe,
        isNotNull,
        reason: 'turn-end error evidence must be retained',
      );
      final turns = safe!['turnEnds'] as List;
      expect(turns, hasLength(3));
      expect(turns[0], {
        'stopReason': 'error',
        'error': 'adapter-error',
        'hasStopReason': true,
        'hasError': true,
        'hasMessage': true,
        'hasNativeMessage': true,
        'nativeMessageTruncated': true,
        'nativeCode': -32602,
        'errorReasons': ['invalid-approval-timestamp'],
      });
      expect((turns[1] as Json)['stopReason'], 'cancelled');
      expect((turns[1] as Json)['error'], ErrorCode.authRequired);
      expect((turns[1] as Json)['hasNativeMessage'], false);
      expect((turns[1] as Json).containsKey('nativeCode'), false);
      expect((turns[2] as Json)['stopReason'], 'other');
      expect((turns[2] as Json)['error'], 'other');
      expect((turns[2] as Json)['errorReasons'], ['other']);
      expect(safe['turnEndsTruncated'], true);
      expect(safe['noticeFlags'], isEmpty);
      expect(utf8.encode(jsonEncode(safe)).length, lessThan(4096));
      expect(jsonEncode(observations), isNot(contains('PRIVATE_TURN')));
      expect(
        Map<String, Object?>.of(observations)..remove('walkDiagnostics'),
        prior,
      );
      expect(
        identical(observations['canaryAudit'], prior['canaryAudit']),
        true,
      );
    },
  );
  test('walk diagnostics bound all fixed reason and notice categories together', () {
    const phrases = [
      'invalid approval timestamp',
      'missing approval turn',
      'invalid native approval',
      'invalid additional permissions',
      'unknown additional permission grant',
      'unsupported native request',
      'retired native turn',
      'offered decisions missing or unsupported',
      'control capacity exceeded',
    ];
    final private = 'PRIVATE_ALL_${List.filled(5000, 'hostile').join()}';
    final diagnostics = CodexWalkDiagnostics();
    for (var i = 0; i < 3; i++) {
      diagnostics.recordTurnEnd(
        AgentTurnEndedParams(
          sessionId: private,
          stopReason: 'error',
          error: 'adapter-error',
          message: '${phrases.join('; ')} $private',
          nativeMessage: private,
          nativeCode: -32602,
          nativeMessageTruncated: true,
        ),
      );
    }
    for (final text in [
      'Native approval unavailable: offered decisions missing or unsupported.',
      'Native approval unavailable: full details exceed display capacity; request cancelled.',
      'Native interaction refused: control capacity exceeded.',
      'Codex unsupported native request refused.',
      'Native interaction capacity or turn unavailable for child $private; request cancelled.',
      'codex-protocol: ${phrases.join('; ')} $private',
      'Codex error -32602: $private',
    ]) {
      diagnostics.recordEvent(
        AgentEvent.fromJson({
          'kind': 'notice',
          'text': text,
          'truncated': true,
        }),
      );
    }
    final observations = <String, Object?>{};
    diagnostics.persist(observations);
    final safe = observations['walkDiagnostics']! as Json;
    final turns = (safe['turnEnds'] as List).cast<Json>();
    expect(turns, hasLength(3));
    for (final turn in turns) {
      expect(turn['errorReasons'], hasLength(9));
    }
    expect((safe['noticeFlags'] as Json).keys.toSet(), {
      'approvalDecisionsUnavailable',
      'approvalDisplayUnavailable',
      'controlCapacityRefused',
      'unsupportedRequest',
      'interactionUnavailable',
      'protocolError',
      'nativeError',
      'knownNoticeTruncated',
      'invalid-approval-timestamp',
      'missing-approval-turn',
      'invalid-native-approval',
      'invalid-additional-permissions',
      'unknown-additional-permission-grant',
      'unsupported-native-request',
      'retired-native-turn',
      'offered-decisions-unavailable',
      'control-capacity-exceeded',
    });
    expect(utf8.encode(jsonEncode(safe)).length, lessThan(4096));
    expect(jsonEncode(safe), isNot(contains('PRIVATE_ALL')));
  });
  test('walk diagnostics preserve only fixed host notice flags', () {
    final diagnostics = CodexWalkDiagnostics();
    final private = 'PRIVATE_NOTICE_${List.filled(5000, 'hostile').join()}';
    for (var i = 0; i < 1000; i++) {
      diagnostics.recordEvent(
        AgentEvent.notice(
          'Native approval unavailable: offered decisions missing or unsupported.',
        ),
      );
      diagnostics.recordEvent(
        AgentEvent.notice(
          'codex-protocol: invalid approval timestamp $private',
        ),
      );
      diagnostics.recordEvent(AgentEvent.notice(private));
      diagnostics.recordEvent(
        AgentEvent.text(AgentEventKind.agentText, 'codex-protocol: $private'),
      );
    }
    final observations = <String, Object?>{};
    diagnostics.persist(observations);
    final safe = observations['walkDiagnostics'] as Json?;
    expect(safe, isNotNull);
    expect(safe!['noticeFlags'], {
      'approvalDecisionsUnavailable': true,
      'protocolError': true,
      'invalid-approval-timestamp': true,
      'offered-decisions-unavailable': true,
    });
    expect(utf8.encode(jsonEncode(safe)).length, lessThan(4096));
    expect(jsonEncode(safe), isNot(contains('PRIVATE_NOTICE')));
  });
  test(
    'walk diagnostics persist an earlier turn error when later operations fail',
    () async {
      final diagnostics = CodexWalkDiagnostics();
      final later = StateError('PRIVATE_LATER_FAILURE');
      final observations = <String, Object?>{
        'streaming': 'unverified',
        'tool activity': 'fail',
        'canaryAudit': {'complete': false},
      };
      Json? persisted;
      await expectLater(
        runCodexObservedOperations(
          operations: () async {
            diagnostics.recordTurnEnd(
              const AgentTurnEndedParams(
                sessionId: 'PRIVATE_SESSION',
                stopReason: 'error',
                error: 'adapter-error',
              ),
            );
            throw later;
          },
          recordProgress: () => diagnostics.persist(observations),
        ),
        throwsA(same(later)),
      );
      await finalizeCodexWalk(
        observations: observations,
        cleanup: () async {},
        persist: () async {
          diagnostics.persist(observations);
          persisted = jsonDecode(jsonEncode(observations)) as Json;
        },
        dispose: () async {},
      );
      expect(
        (persisted!['walkDiagnostics'] as Json?)?['turnEnds'],
        hasLength(1),
      );
      expect(persisted!['streaming'], 'unverified');
      expect(persisted!['tool activity'], 'fail');
      expect(persisted!['canaryAudit'], {'complete': false});
      expect(jsonEncode(persisted), isNot(contains('PRIVATE_')));
    },
  );
  for (var operation = 0; operation < 3; operation++) {
    final index = operation;
    test(
      'command approval refusal records only safe metadata operation=${index + 1}',
      () {
        final private =
            'PRIVATE_CANARY_${List.filled(200, '<hostile>').join()}';
        final observations = <String, Object?>{
          'launch': 'pass',
          'streaming': 'pass',
          'command approval': 'unverified',
          'tool activity': 'fail',
          'kumiko tool call': 'unverified',
          'canaryAudit': {'complete': false, 'scanned': false},
        };
        final prior = Map<String, Object?>.of(observations);
        final request = AgentPermissionRequestedParams(
          sessionId: private,
          requestId: private,
          title: index == 0 ? private : 'Command approval',
          preview: index == 2
              ? 'Command: inert long command\nWorking directory: F:\\owned\\work\nReason: $private'
              : 'Command: $private\nWorking directory: $private',
          truncated: index == 0,
          options: [
            AgentPermissionOption(
              optionId: private,
              name: index == 0 ? private : 'accept',
              kind: index == 0 ? private : 'allow_once',
            ),
          ],
        );
        final matches = allowedCanaryApproval(request, plan(), index) != null;
        expect(matches, index == 2);
        StateError? refusal;
        try {
          rejectCodexWalkPermission(
            observations,
            request,
            operation: index,
            answered: index == 2,
            matchesApprovedRequest: matches,
          );
        } on StateError catch (error) {
          refusal = error;
        }
        expect(refusal, isNotNull, reason: 'the refusal must still throw');
        expect(refusal.message, 'unapproved native permission; stopping walk');
        expect(
          '${jsonEncode(observations)}$refusal',
          isNot(contains('PRIVATE_CANARY')),
        );
        expect(observations['commandApprovalDiagnostic'], {
          'stage': 'command-approval',
          'operation': index + 1,
          'reason': index == 2
              ? 'additional-request'
              : 'outside-approved-request',
          'commandTitle': index != 0,
          'truncated': index == 0,
          'hasOneShotAccept': index != 0,
          'matchesApprovedRequest': index == 2,
        });
        expect(
          utf8
              .encode(jsonEncode(observations['commandApprovalDiagnostic']))
              .length,
          lessThan(512),
        );
        expect(
          Map<String, Object?>.of(observations)
            ..remove('commandApprovalDiagnostic'),
          prior,
        );
        expect(
          identical(observations['canaryAudit'], prior['canaryAudit']),
          true,
        );
      },
    );
  }
  test('later operation timeout retains earlier observed counters without promoting audit', () async {
    final timeout = TimeoutException('synthetic later operation');
    final observations = <String, Object?>{
      'streaming': 'unverified',
      'tool activity': 'unverified',
      'command approval': 'fail',
      'kumiko tool call': 'unverified',
      'canaryAudit': {'complete': false},
    };
    await expectLater(
      runCodexObservedOperations(
        operations: () async {
          throw timeout;
        },
        recordProgress: () => recordCodexWalkProgress(
          observations,
          textEvents: 92,
          firstTurnIncrementalEvents: 62,
          toolEvents: 2,
        ),
      ),
      throwsA(same(timeout)),
    );
    expect(observations['textEvents'], 92);
    expect(observations['firstTurnIncrementalEvents'], 62);
    expect(observations['toolEvents'], 2);
    expect(observations['streaming'], 'pass');
    expect(observations['tool activity'], 'pass');
    expect(observations['command approval'], 'fail');
    expect(observations['kumiko tool call'], 'unverified');
    expect(observations['canaryAudit'], {'complete': false});
  });
  test('observed counters preserve explicit observation failures', () {
    final observations = <String, Object?>{
      'streaming': 'fail',
      'tool activity': 'fail',
      'kumiko tool call': 'fail',
    };
    recordCodexWalkProgress(
      observations,
      textEvents: 92,
      firstTurnIncrementalEvents: 62,
      toolEvents: 2,
    );
    expect(observations['streaming'], 'fail');
    expect(observations['tool activity'], 'fail');
    expect(observations['kumiko tool call'], 'fail');
  });
  for (final failure in [
    StateError('synthetic private cleanup text'),
    RpcException(
      ErrorCode.adapterProtocol,
      'bounded host-redacted audit failure',
      {'stage': 'audit'},
    ),
  ]) {
    test(
      'cleanup failure ${failure.runtimeType} persists incomplete audit and disposes',
      () async {
        final observations = <String, Object?>{
          'kumiko tool call': 'pass',
          'nativeDiagnostic': {'message': 'primary diagnostic'},
        };
        var persisted = false;
        var disposed = false;
        await expectLater(
          finalizeCodexWalk(
            observations: observations,
            cleanup: () async {
              throw failure;
            },
            persist: () async {
              persisted = true;
            },
            dispose: () async {
              disposed = true;
            },
          ),
          throwsA(same(failure)),
        );
        expect(disposed, true);
        expect(persisted, true);
        expect(observations['kumiko tool call'], 'unverified');
        expect((observations['canaryAudit'] as Json)['complete'], false);
        expect(observations['nativeDiagnostic'], {
          'message': 'primary diagnostic',
        });
        expect(
          jsonEncode(observations).contains('synthetic private cleanup text'),
          false,
        );
      },
    );
  }
  test('native manifest exposes complete argv and leaves approval policy native-configured', () {
    final value = plan();
    expect(value['schema'], 2);
    expect(
      value['approvalPolicy'],
      'native-configured; no qualification override',
    );
    expect(value['nativeArgs'], [
      'app-server',
      '-c',
      'mcp_servers.kumiko_qualification_probe.command=${jsonEncode(value['hostExecutable'])}',
      '-c',
      'mcp_servers.kumiko_qualification_probe.args=${jsonEncode(['--test-fixture', 'qualification-mcp-env', '--report', value['envProbeReport']])}',
    ]);
  });
  test('native argv excludes the rejected untrusted policy override', () {
    expect(
      nativeArgsForManifest(plan())
          .any((argument) => argument.contains('approval_policy')),
      false,
    );
  });
  test(
    'native start consumes exact reviewed manifest argv without reconstruction',
    () {
      final value = plan()..['schema'] = 2;
      final args = [
        'app-server',
        '--stdio',
        '-c',
        'reviewed.literal="quoted value with spaces"',
      ];
      value['nativeArgs'] = args;
      expect(nativeArgsForManifest(value), args);
    },
  );
  for (final invalid in [
    null,
    <Object?>[],
    <Object?>['app-server', 7],
    <Object?>['other-mode'],
  ]) {
    test(
      'native manifest refuses missing or malformed argv ${jsonEncode(invalid)}',
      () {
        final value = plan()
          ..['schema'] = 2
          ..['nativeArgs'] = invalid;
        expect(() => nativeArgsForManifest(value), throwsFormatException);
      },
    );
  }
  for (final schema in [1, 2]) {
    test(
      'schema$schema without argv is rejected before attempt or host startup',
      () async {
        final directory = Directory.systemTemp.createTempSync(
          'kumiko_legacy_manifest_',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        final value = plan()
          ..['schema'] = schema
          ..remove('nativeArgs')
          ..['hostExecutable'] = '${directory.path}/must-not-start.exe';
        final bytes = utf8.encode(jsonEncode(value));
        final manifest = File('${directory.path}/manifest.json')
          ..writeAsBytesSync(bytes);
        final result = await Process.run(Platform.resolvedExecutable, [
          File('tool/qualify_codex_app_server.dart').absolute.path,
          '--walk',
          '--manifest',
          manifest.path,
          '--approved-sha256',
          sha256.convert(bytes).toString(),
        ]);
        expect(result.exitCode, 1);
        expect(File('${directory.path}/attempt.jsonl').existsSync(), false);
        expect(File('${directory.path}/observations.json').existsSync(), false);
      },
    );
  }
  test('non-RPC identity failure records incomplete startup at the missing-id boundary', () {
    final observations = <String, Object?>{
      'launch': 'unverified',
      'streaming': 'unverified',
    };
    try {
      throw StateError('fixture private identity error must not be persisted');
    } on StateError {
      // The public/attempt path records only the non-RPC error kind.
    } finally {
      recordCodexMissingSession(observations);
    }
    expect(observations['launch'], 'fail');
    expect(observations['streaming'], 'unverified');
    final audit = observations['canaryAudit']! as Json;
    expect(audit['complete'], false);
    expect(audit['scanned'], false);
    expect(
      jsonEncode(observations).contains('fixture private identity error'),
      false,
    );
  });
  test('missing-id finalization preserves captured RPC diagnostics', () {
    final diagnostic = <String, Object?>{
      'reason': 'adapter-protocol',
      'message': 'fixture redacted message',
      'stage': 'initialize',
    };
    final observations = <String, Object?>{
      'launch': 'unverified',
      'nativeDiagnostic': diagnostic,
    };
    recordCodexMissingSession(observations);
    expect(observations['launch'], 'fail');
    expect(identical(observations['nativeDiagnostic'], diagnostic), true);
    expect((observations['canaryAudit']! as Json)['complete'], false);
  });
  test('fake host startup RPC retains private message stage and status with incomplete audit', () async {
    final observations = <String, Object?>{
      'launch': 'unverified',
      'streaming': 'unverified',
    };
    Future<void> fakeHostStart() => Future<void>.error(
      RpcException(
        ErrorCode.adapterProtocol,
        'fixture protocol closed; <redacted> stderr retained',
        {
          'stage': 'session/new',
          'status': 255,
          'detail': 'fixture stderr <redacted>',
          'unrelatedConfig': 'must not copy arbitrary data',
        },
      ),
    );
    try {
      await fakeHostStart();
    } on RpcException catch (error) {
      recordCodexRpcFailure(observations, error, hasSession: false);
    }
    final diagnostic = observations['nativeDiagnostic']! as Json;
    expect(
      diagnostic['message'],
      'fixture protocol closed; <redacted> stderr retained',
    );
    expect(diagnostic['stage'], 'session/new');
    expect(diagnostic['status'], 255);
    expect(diagnostic['detail'], 'fixture stderr <redacted>');
    expect(observations['launch'], 'fail');
    expect(observations['streaming'], 'unverified');
    final audit = observations['canaryAudit']! as Json;
    expect(audit['complete'], false);
    expect(audit['scanned'], false);
    expect(
      jsonEncode(observations).contains('must not copy arbitrary data'),
      false,
    );
  });
  test('private RPC diagnostic fields remain bounded and preserve exact native auth fields separately', () {
    final observations = <String, Object?>{'launch': 'pass'};
    recordCodexRpcFailure(
      observations,
      RpcException(ErrorCode.adapterProtocol, List.filled(5000, 'x').join(), {
        'stage': List.filled(100, 's').join(),
        'nativeCode': -32001,
        'nativeMessage': 'exact fixture native message',
        'nativeMessageTruncated': false,
      }),
      hasSession: true,
    );
    final diagnostic = observations['nativeDiagnostic']! as Json;
    expect(diagnostic['stage'], isA<String>());
    expect(
      utf8.encode(diagnostic['message']! as String).length,
      lessThanOrEqualTo(4096),
    );
    expect(
      utf8.encode(diagnostic['stage']! as String).length,
      lessThanOrEqualTo(64),
    );
    expect(diagnostic['nativeMessage'], 'exact fixture native message');
    expect(diagnostic['code'], -32001);
    expect(observations['launch'], 'pass');
  });
  test(
    'approved walk consumes attempt before host startup failure and rejects replay',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'kumiko_walk_attempt_',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      // An existing empty workspace passes the pre-claim check, so the walk
      // reaches the claim and then fails at host startup.
      final work = Directory(p.join(directory.path, 'work'))..createSync();
      final value = makeCodexWalkPlan(
        workspace: work.path,
        profile: p.join(directory.path, 'profile'),
        executable: r'F:\native\codex.exe',
        nativeHome: r'C:\user\.codex',
        version: '0.166.0',
        hostExecutable: '${directory.path}/missing-host.exe',
        canaryCommand: 'inert canary command',
        stopCommand: 'inert long command',
      );
      final bytes = utf8.encode(jsonEncode(value));
      final manifest = File('${directory.path}/manifest.json')
        ..writeAsBytesSync(bytes);
      final script = File('tool/qualify_codex_app_server.dart').absolute.path;
      final args = [
        script,
        '--walk',
        '--manifest',
        manifest.path,
        '--approved-sha256',
        sha256.convert(bytes).toString(),
      ];
      final first = await Process.run(Platform.resolvedExecutable, args);
      expect(first.exitCode, 1);
      final observationsFile = File('${directory.path}/observations.json');
      expect(observationsFile.existsSync(), true);
      final observations =
          jsonDecode(observationsFile.readAsStringSync()) as Json;
      expect(observations['launch'], 'fail');
      expect((observations['canaryAudit']! as Json)['complete'], false);
      expect((observations['canaryAudit']! as Json)['scanned'], false);
      expect(observations.containsKey('nativeDiagnostic'), false);
      final marker = File('${directory.path}/attempt.jsonl');
      expect(marker.existsSync(), true);
      final initial = marker.readAsStringSync();
      expect(initial, contains('failed'));
      final second = await Process.run(Platform.resolvedExecutable, args);
      expect(second.exitCode, 1);
      expect(marker.readAsStringSync() == initial, true);
    },
    // The walk resolves its trusted PowerShell from the Windows registry;
    // elsewhere it refuses before the claim (covered by "the walk refuses
    // before the claim when no shell is trusted").
    skip: Platform.isWindows
        ? false
        : 'the walk needs a registry-trusted PowerShell (Windows only)',
  );
  test('streaming requires incremental observations within a turn', () {
    expect(nativeStreamingObserved([1, 1, 1]), false);
    expect(nativeStreamingObserved([2, 0, 0]), true);
  });
  test(
    'close proves descendant settlement only from live identity before close',
    () {
      expect(
        nativeDescendantSettled(aliveBefore: false, aliveAfter: false),
        false,
      );
      expect(
        nativeDescendantSettled(aliveBefore: true, aliveAfter: false),
        true,
      );
      expect(
        nativeDescendantSettled(aliveBefore: true, aliveAfter: true),
        false,
      );
    },
  );
  test(
    'native walk manifest fixes three bounded prompts and leaves auth separate',
    () {
      final value = plan();
      expect(value['maxTurns'], 3);
      expect(value['turnDeadlineSeconds'], 75);
      expect(value['nativeVersion'], '0.166.0');
      expect(value['workspace'], r'F:\owned\work');
      expect(value['prompts'], hasLength(3));
      expect(value['authExperiment'], 'unapproved; separate scope');
      expect(jsonEncode(value), isNot(contains('KUMIKO_TOOL_SECRET=')));
      expect(value['cost'], contains('no hard monetary cap'));
    },
  );
  test('native walk approval is bound to exact immutable manifest bytes', () {
    final bytes = utf8.encode(jsonEncode(plan()));
    final digest = sha256.convert(bytes).toString();
    expect(approvedCodexManifest(bytes, digest), true);
    expect(approvedCodexManifest([...bytes, 32], digest), false);
    expect(approvedCodexManifest(bytes, ''), false);
  });
  test('native walk approves only exact inert command cwd and native one-shot choice', () {
    AgentPermissionRequestedParams request({
      String preview =
          'Command: inert canary command\nWorking directory: F:\\owned\\work',
      String title = 'Command approval',
      String kind = 'allow_once',
      String choice = 'accept',
      bool truncated = false,
    }) => AgentPermissionRequestedParams(
      sessionId: 's',
      requestId: 'r',
      title: title,
      preview: preview,
      truncated: truncated,
      options: [
        AgentPermissionOption(optionId: 'choice', name: choice, kind: kind),
      ],
    );
    expect(allowedCanaryApproval(request(), plan(), 1), 'choice');
    expect(
      allowedCanaryApproval(
        request(
          preview:
              'Command: inert canary command\nWorking directory: f:/OWNED/work',
        ),
        plan(),
        1,
      ),
      'choice',
    );
    for (final invalid in [
      request(preview: 'Command: destructive'),
      request(title: 'File change approval'),
      request(kind: 'allow_always'),
      request(choice: 'acceptForSession'),
      request(truncated: true),
      request(
        preview: 'Command: inert canary command\nWorking directory: F:\\owned\\work\nReason: safe\nCommand: unlisted',
      ),
    ]) {
      expect(allowedCanaryApproval(invalid, plan(), 1), null);
    }
    expect(allowedCanaryApproval(request(), plan(), 0), null);
  });
  group('Codex decision display:', () {
    const head =
        'Command: inert canary command\nWorking directory: F:\\owned\\work';
    AgentPermissionRequestedParams display(
      List<Object?> decisions, {
      String prefix = head,
      String? section,
      List<(String, String)>? options,
      String title = 'Command approval',
      bool truncated = false,
    }) => AgentPermissionRequestedParams(
      sessionId: 's',
      requestId: 'r',
      title: title,
      preview:
          '$prefix\n${section ?? 'Native decisions: ${jsonEncode(decisions)}'}',
      truncated: truncated,
      options: [
        for (var i = 0; i < (options?.length ?? decisions.length); i++)
          AgentPermissionOption(
            optionId: 'choice-$i',
            name: options != null
                ? options[i].$1
                : decisions[i] is String
                ? decisions[i]! as String
                : 'Native option ${i + 1}',
            kind: options != null
                ? options[i].$2
                : decisions[i] is! String || decisions[i] == 'acceptForSession'
                ? 'allow_always'
                : decisions[i] == 'cancel' || decisions[i] == 'decline'
                ? 'reject_once'
                : 'allow_once',
          ),
      ],
    );
    final scoped = {
      'acceptWithExecpolicyAmendment': {
        'execpolicy_amendment': ['inert', 'x' * 300],
      },
    };
    String? answer(AgentPermissionRequestedParams request) =>
        allowedCanaryApproval(request, plan(), 1);

    test('only the literal accept string is chosen beside object options', () {
      expect(answer(display(['accept', scoped, 'cancel'])), 'choice-0');
      expect(answer(display([scoped, 'cancel', 'accept'])), 'choice-2');
      expect(
        answer(display([scoped, 'accept'], prefix: '$head\nReason: safe')),
        'choice-1',
      );
      // Multibyte and escaped newlines stay canonical single-line JSON.
      expect(
        answer(
          display([
            {'t': 'caf\u00e9\n\u65e5'},
            'accept',
          ]),
        ),
        'choice-1',
      );
      // The host emits a section only for lists with objects.
      expect(answer(display(['accept', 'cancel'])), isNull);
    });
    test('object, session and policy-only lists never authorize', () {
      expect(answer(display([scoped, 'cancel'])), isNull);
      expect(answer(display([scoped, 'acceptForSession'])), isNull);
      expect(answer(display([scoped, 'decline'])), isNull);
      expect(answer(display([scoped])), isNull);
    });
    test('a label index or allow_once kind alone never authorizes', () {
      expect(
        answer(
          display(
            [scoped, 'cancel'],
            options: [
              ('Native option 1', 'allow_once'),
              ('cancel', 'reject_once'),
            ],
          ),
        ),
        isNull,
      );
      expect(
        answer(
          display(
            [scoped, 'accept'],
            options: [
              ('Native option 1', 'allow_once'),
              ('accept', 'allow_once'),
            ],
          ),
        ),
        isNull,
        reason: 'an object entry offered as allow_once is inconsistent',
      );
      expect(
        answer(
          display(
            [scoped, 'accept'],
            options: [
              ('Native option 1', 'allow_always'),
              ('accept', 'allow_always'),
            ],
          ),
        ),
        isNull,
      );
    });
    test('duplicate accept entries or options are refused', () {
      expect(answer(display(['accept', scoped, 'accept'])), isNull);
      expect(answer(display(['accept', 'accept'])), isNull);
    });
    test('appended, malformed and ambiguous sections are refused', () {
      final good = 'Native decisions: ${jsonEncode(['accept', scoped])}';
      expect(
        answer(display(['accept', scoped], section: '$good\n$good')),
        isNull,
      );
      expect(
        answer(display(['accept', scoped], section: '$good\nextra')),
        isNull,
      );
      expect(
        answer(
          display(
            ['accept', scoped],
            section: 'Native decisions: ${jsonEncode(['accept', scoped])}'
                .replaceAll(',', ', '),
          ),
        ),
        isNull,
        reason: 'only the canonical encoding is accepted',
      );
      expect(
        answer(
          display(['accept', scoped], section: 'Native decisions: ["accept",{'),
        ),
        isNull,
      );
      expect(
        answer(
          display(['accept', scoped], section: 'Native decisions: {"a":1}'),
        ),
        isNull,
      );
      expect(
        answer(
          display([
            'accept',
            scoped,
          ], section: 'Native decisions: [1,"accept"]'),
        ),
        isNull,
      );
      // A reason injecting its own section line adds a line.
      expect(
        answer(
          display([
            'accept',
            scoped,
          ], prefix: '$head\nReason: x\nNative decisions: ["accept",{"a":1}]'),
        ),
        isNull,
      );
      // String-only fake section from a reason never counts.
      expect(
        answer(
          display(
            ['accept'],
            prefix: '$head\nReason: x',
            section: 'Native decisions: ["accept"]',
          ),
        ),
        isNull,
      );
    });
    test('section entries must match displayed options one to one', () {
      expect(
        answer(
          display(['accept', scoped], options: [('accept', 'allow_once')]),
        ),
        isNull,
      );
      expect(
        answer(
          display(
            ['accept', scoped],
            options: [
              ('accept', 'allow_once'),
              ('Native option 1', 'allow_always'),
            ],
          ),
        ),
        isNull,
      );
      expect(
        answer(
          display(
            ['accept', scoped],
            options: [
              ('accept', 'allow_once'),
              ('Native option 2', 'allow_always'),
              ('extra', 'reject_once'),
            ],
          ),
        ),
        isNull,
      );
    });
    test(
      'different command, cwd, title, children and truncation are refused',
      () {
        expect(
          answer(
            display([
              'accept',
              scoped,
            ], prefix: 'Command: other\nWorking directory: F:\\owned\\work'),
          ),
          isNull,
        );
        expect(
          answer(
            display(
              ['accept', scoped],
              prefix: 'Command: inert canary command\nWorking directory: F:\\elsewhere',
            ),
          ),
          isNull,
        );
        expect(
          answer(display(['accept', scoped], title: 'File change approval')),
          isNull,
        );
        expect(
          answer(
            display(['accept', scoped], title: 'Child c1: Command approval'),
          ),
          isNull,
        );
        expect(answer(display(['accept', scoped], truncated: true)), isNull);
        expect(
          allowedCanaryApproval(display(['accept', scoped]), plan(), 0),
          isNull,
        );
      },
    );
  });
  group('Codex decision overflow:', () {
    test('a cut-off or oversized decision section never authorizes', () {
      final cut = 'Native decisions: ["accept",{"a":"${'x' * 200}';
      for (final request in [
        AgentPermissionRequestedParams(
          sessionId: 's',
          requestId: 'r',
          title: 'Command approval',
          preview:
              'Command: inert canary command\nWorking directory: F:\\owned\\work\n$cut',
          options: const [
            AgentPermissionOption(
              optionId: 'c0',
              name: 'accept',
              kind: 'allow_once',
            ),
          ],
        ),
        AgentPermissionRequestedParams(
          sessionId: 's',
          requestId: 'r',
          title: 'Command approval',
          preview:
              'Command: inert canary command\nWorking directory: F:\\owned\\work\nNative decisions: ${jsonEncode([
                'accept',
                {'a': 'y' * 20000},
              ])}',
          truncated: true,
          options: const [
            AgentPermissionOption(
              optionId: 'c0',
              name: 'accept',
              kind: 'allow_once',
            ),
            AgentPermissionOption(
              optionId: 'c1',
              name: 'Native option 2',
              kind: 'allow_always',
            ),
          ],
        ),
      ]) {
        expect(allowedCanaryApproval(request, plan(), 1), isNull);
      }
    });
  });
  test(
    'native qualifier dry run uses shared host and is never provider evidence',
    () async {
      final result = await Process.run(Platform.resolvedExecutable, [
        'tool/qualify_codex_app_server.dart',
        '--dry-run',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('FIXTURE ONLY: shared native path'));
      expect(
        result.stdout,
        contains('secret audit complete=true matchedFiles=0'),
      );
      expect(result.stdout, isNot(contains('CODEX OBSERVATIONS:')));
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  // ---- Codex removed entries: changed-artifacts-v4 ----
  const removed = 'changed-artifacts-v4';

  test('Codex removed entries: manifest records v4 with its own canonical disclosure and v3 v2 v1 and legacy are unchanged', () {
    final scan = validatedCodexAuditScan(planFor(removed));
    expect(scan['nativeSelection'], removed);
    expect(scan['nativeScope'], changedArtifactsV4Disclosure);
    expect(scan['nativeScope'], isNot(changedArtifactsV3Disclosure));
    expect(scan['maxFiles'], 4096);
    expect(
      validatedCodexAuditScan(planFor(sockets))['nativeScope'],
      changedArtifactsV3Disclosure,
    );
    expect(
      validatedCodexAuditScan(planFor(normal))['nativeScope'],
      changedArtifactsV2Disclosure,
    );
    expect(
      validatedCodexAuditScan(planFor('legacy'))['nativeScope'],
      isNot(changedArtifactsV4Disclosure),
    );
    // Absent selection never means v4.
    final broadened = planFor(removed);
    (broadened['scan'] as Json).remove('nativeSelection');
    expect(() => validatedCodexAuditScan(broadened), throwsFormatException);
    final text = scan['nativeScope']! as String;
    expect(text, startsWith('changed-artifacts-v4 disclosure:'));
    expect(
      text,
      contains('a removed non-protected entry is counted but not scanned'),
    );
    expect(text, contains('because no content remains'));
    expect(
      text,
      contains('a removed protected entry still makes the audit incomplete'),
    );
    expect(text, contains('Unix-domain sockets in the native home'));
    expect(text, contains('the owner pauses other Codex sessions'));
    expect(utf8.encode(text).every((byte) => byte < 128), true);
    expect(nativeDetectorLimitsV4.take(5), nativeDetectorLimitsV3);
    expect(nativeDetectorLimitsV4.length, 6);
    expect(nativeDetectorLimitsV3.length, 5, reason: 'v3 limits are unchanged');
  });
  test('Codex removed entries: binding rejects a noncanonical or crossed scope before claim', () async {
    for (final scope in <Object?>[
      null,
      7,
      '',
      '$changedArtifactsV4Disclosure extra',
      changedArtifactsV4Disclosure.replaceFirst('65,536', '4096'),
      changedArtifactsV4Disclosure.replaceFirst(
        'because no content remains',
        'because it is read',
      ),
      changedArtifactsV4Disclosure.replaceFirst(
        'a removed protected entry still makes the audit incomplete',
        'a removed protected entry is ignored',
      ),
      changedArtifactsV3Disclosure,
      changedArtifactsV2Disclosure,
      changedArtifactsDisclosure,
    ]) {
      final value = planFor(removed);
      (value['scan'] as Json)['nativeScope'] = scope;
      expect(
        () => validatedCodexAuditScan(value),
        throwsFormatException,
        reason: '$scope',
      );
    }
    for (final selection in [sockets, normal, wider, 'legacy']) {
      final crossed = planFor(selection);
      (crossed['scan'] as Json)['nativeScope'] = changedArtifactsV4Disclosure;
      expect(
        () => validatedCodexAuditScan(crossed),
        throwsFormatException,
        reason: selection,
      );
    }
    final directory = await Directory.systemTemp.createTemp(
      'kumiko_v4_scope_walk_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final value = planFor(removed);
    (value['scan'] as Json)['nativeScope'] = changedArtifactsV3Disclosure;
    final bytes = utf8.encode(jsonEncode(value));
    final manifest = File('${directory.path}/manifest.json')
      ..writeAsBytesSync(bytes);
    final result = await Process.run(Platform.resolvedExecutable, [
      'tool/qualify_codex_app_server.dart',
      '--walk',
      '--manifest',
      manifest.path,
      '--approved-sha256',
      sha256.convert(bytes).toString(),
    ]);
    expect(result.exitCode, 1);
    expect(File('${directory.path}/attempt.jsonl').existsSync(), false);
  });
  test('Codex removed entries: the usage text lists v4 and v5 is refused before anything is created', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'tool/qualify_codex_app_server.dart',
      '--help',
    ]);
    expect(result.exitCode, 0);
    expect(
      result.stdout as String,
      contains(
        '--native-selection <legacy|changed-artifacts-v1|changed-artifacts-v2|changed-artifacts-v3|changed-artifacts-v4>',
      ),
    );
    final dir = await Directory.systemTemp.createTemp('kumiko_v5_selection_');
    addTearDown(() => dir.delete(recursive: true));
    final refused = await Process.run(Platform.resolvedExecutable, [
      'tool/qualify_codex_app_server.dart',
      '--prepare',
      '--workspace',
      '${dir.path}/workspace',
      '--native',
      '${dir.path}/never-native',
      '--manifest',
      '${dir.path}/artifact/manifest.json',
      '--native-selection',
      'changed-artifacts-v5',
    ]);
    expect(refused.exitCode, 1);
    expect(dir.listSync(), isEmpty);
  });
  test('Codex removed entries: preparation prints the v4 disclosure alone and validates the v4 echo and an incomplete baseline', () async {
    final hash = 'ef' * 32;
    final text = codexPreparationSummary(
      manifest: r'F:\owned\manifest.json',
      sha256Hex: hash,
      budget: AuditBudget.defaults,
      nativeSelection: removed,
    );
    expect(text, contains('NativeSelection: $removed'));
    expect(text, contains(changedArtifactsV4Disclosure));
    expect(text, isNot(contains(changedArtifactsV3Disclosure)));
    for (final selection in [sockets, normal, wider, 'legacy']) {
      expect(
        codexPreparationSummary(
          manifest: r'F:\owned\manifest.json',
          sha256Hex: hash,
          budget: AuditBudget.defaults,
          nativeSelection: selection,
        ),
        isNot(contains(changedArtifactsV4Disclosure)),
      );
    }
    final scan = validatedCodexAuditScan(planFor(removed));
    final requests = <Json>[];
    await prepareCodexAuditBinding(
      scan: scan,
      observations: {},
      call: (method, params) async {
        requests.add(params);
        return preparedEcho(scan);
      },
    );
    expect(requests.single, {
      'auditProfile': 'default',
      'nativeSelection': removed,
    });
    for (final other in [sockets, normal, wider, 'legacy', null]) {
      final echo = preparedEcho(scan);
      if (other == null) {
        echo.remove('nativeSelection');
      } else {
        echo['nativeSelection'] = other;
      }
      await expectLater(
        prepareCodexAuditBinding(
          scan: scan,
          observations: {},
          call: (_, _) async => echo,
        ),
        throwsStateError,
        reason: '$other',
      );
    }
    final v3Scan = validatedCodexAuditScan(planFor(sockets));
    await expectLater(
      prepareCodexAuditBinding(
        scan: v3Scan,
        observations: {},
        call: (_, _) async => preparedEcho(scan),
      ),
      throwsStateError,
    );
    final observations = <String, Object?>{};
    await expectLater(
      prepareCodexAuditBinding(
        scan: scan,
        observations: observations,
        call: (_, _) async => {
          ...baselineEcho(scan, false, 2),
          'baselineErrorCategories': {
            'nonRegular': 2,
            'PRIVATE_REMOVED.tmp': 4,
            'removedEntries': 9,
          },
        },
      ),
      throwsStateError,
    );
    final receipt = observations['baselinePreflight']! as Json;
    expect(receipt['baselineErrorCategories'], {'nonRegular': 2});
    expect(receipt['providerWork'], false);
    expect(jsonEncode(receipt), isNot(contains('PRIVATE')));
  });
  test('Codex removed entries: a v4 result keeps the removal counter and limits and a scan echo mismatch stays incomplete', () {
    final scan = validatedCodexAuditScan(planFor(removed));
    final counters = {
      'inventoryEntries': 9,
      'linksAccounted': 1,
      'socketsAccounted': 2,
      'socketsChanged': 1,
      'removedEntries': 5,
    };
    final matching = <String, Object?>{
      'kumiko tool call': 'pass',
      'unrelatedMcpEnvironmentIsolated': true,
      'unrelatedCommandEnvironmentIsolated': true,
    };
    recordCodexCanaryAudit(matching, scan, {
      ...scan,
      'complete': true,
      'matchedFiles': 0,
      'nativeDetectorLimits': nativeDetectorLimitsV4,
      'nativeSelectionCounters': counters,
    });
    final retained = matching['canaryAudit']! as Json;
    expect(retained['complete'], true);
    expect(retained['nativeDetectorLimits'], nativeDetectorLimitsV4);
    expect(retained['nativeSelectionCounters'], counters);
    final mismatched = <String, Object?>{
      'kumiko tool call': 'pass',
      'unrelatedMcpEnvironmentIsolated': true,
      'unrelatedCommandEnvironmentIsolated': true,
    };
    recordCodexCanaryAudit(mismatched, scan, {
      ...scan,
      'nativeSelection': sockets,
      'complete': true,
      'matchedFiles': 0,
    });
    expect((mismatched['canaryAudit']! as Json)['complete'], false);
  });

  group('Codex removed entries: approval diagnostic', () {
    const command = 'inert canary command';
    const workdir = r'F:\owned\work';
    // Private markers: none of them may appear in any serialized diagnostic.
    const markers = [
      'PRIVATE_COMMAND',
      'PRIVATE_DIR',
      'PRIVATE_OPTION',
      'PRIVATE_DECISION',
      'PRIVATE_REASON',
      'PRIVATE_ID',
    ];
    AgentPermissionRequestedParams request({
      String? preview = 'Command: $command\nWorking directory: $workdir',
      String title = 'Command approval',
      bool truncated = false,
      List<(String, String)>? options,
    }) => AgentPermissionRequestedParams(
      sessionId: 's',
      requestId: 'r',
      title: title,
      preview: preview,
      truncated: truncated,
      options: [
        for (final (i, (name, kind))
            in (options ?? [('accept', 'allow_once')]).indexed)
          AgentPermissionOption(optionId: 'choice-$i', name: name, kind: kind),
      ],
    );
    Json checks(AgentPermissionRequestedParams r, {Json? value, int op = 1}) =>
        evaluateCanaryApproval(r, value ?? plan(), op).checks;
    const booleanChecks = [
      'validOperation',
      'commandConfigured',
      'commandSingleLine',
      'previewPresent',
      'previewLayoutValid',
      'commandMatches',
      'workingDirectoryMatches',
      'reasonLineValid',
      'decisionsLineValid',
      'decisionsMatchOptions',
      'singleOneShotAccept',
    ];

    test('every check passes for the approved request and the diagnostic is bounded', () {
      final evaluation = evaluateCanaryApproval(request(), plan(), 1);
      expect(evaluation.optionId, 'choice-0');
      for (final key in booleanChecks) {
        expect(evaluation.checks[key], true, reason: key);
      }
      expect(evaluation.checks['decisionsLinePresent'], false);
      expect(evaluation.checks['previewLineCount'], 2);
      expect(evaluation.checks['optionCount'], 1);
      expect(
        evaluation.checks.containsKey('observedCommandContainsApproved'),
        false,
        reason: 'only recorded when the command differs',
      );
      expect(
        evaluation.checks.values.every((v) => v is bool || v is int),
        true,
      );
      expect(utf8.encode(jsonEncode(evaluation.checks)).length, lessThan(512));
    });
    // Each case breaks exactly one check; every other boolean stays true.
    final cases = <String, (AgentPermissionRequestedParams, Json?, int)>{
      'validOperation': (
        request(
          preview: 'Command: inert long command\nWorking directory: $workdir',
        ),
        null,
        0,
      ),
      'commandConfigured': (
        request(preview: 'Command: 7\nWorking directory: $workdir'),
        (plan()..['canaryCommand'] = 7),
        1,
      ),
      'commandSingleLine': (
        request(preview: 'Command: a\nb\nWorking directory: $workdir'),
        (plan()..['canaryCommand'] = 'a\nb'),
        1,
      ),
      'previewPresent': (request(preview: null), null, 1),
      'previewLayoutValid': (
        request(
          preview:
              'Command: $command\nWorking directory: $workdir\nReason: r\nextra',
        ),
        null,
        1,
      ),
      'commandMatches': (
        request(preview: 'Command: other\nWorking directory: $workdir'),
        null,
        1,
      ),
      'workingDirectoryMatches': (
        request(preview: 'Command: $command\nWorking directory: F:\\elsewhere'),
        null,
        1,
      ),
      'reasonLineValid': (
        request(
          preview:
              'Command: $command\nWorking directory: $workdir\nWhy: because',
        ),
        null,
        1,
      ),
      'decisionsLineValid': (
        request(
          preview:
              'Command: $command\nWorking directory: $workdir\nNative decisions: [ "accept" ]',
        ),
        null,
        1,
      ),
      'decisionsMatchOptions': (
        request(
          preview:
              'Command: $command\nWorking directory: $workdir\nNative decisions: ["accept",{"x":1}]',
          options: [
            ('accept', 'allow_once'),
            ('Native option 9', 'allow_always'),
          ],
        ),
        null,
        1,
      ),
      'singleOneShotAccept': (
        request(options: [('accept', 'allow_always')]),
        null,
        1,
      ),
    };
    // These checks make the derived line checks false too: a missing preview
    // or a command with a line break can never match a single preview line.
    const entangled = {'previewPresent', 'commandSingleLine'};
    for (final MapEntry(:key, :value) in cases.entries) {
      test('$key failing alone refuses and flips only that check', () {
        final (r, override, op) = value;
        final evaluation = evaluateCanaryApproval(r, override ?? plan(), op);
        expect(evaluation.optionId, isNull, reason: key);
        expect(evaluation.checks[key], false, reason: key);
        if (entangled.contains(key)) return;
        for (final other in booleanChecks) {
          expect(
            evaluation.checks[other],
            other == key ? false : true,
            reason: '$key broke $other: ${evaluation.checks}',
          );
        }
      });
    }
    test('contains and starts-with flags are recorded only when the command differs', () {
      Json observed(String line) => checks(
        request(preview: 'Command: $line\nWorking directory: $workdir'),
      );
      var c = observed('$command --extra');
      expect(c['commandMatches'], false);
      expect(c['observedCommandContainsApproved'], true);
      expect(c['observedCommandStartsWithApproved'], true);
      c = observed('wrapper $command');
      expect(c['observedCommandContainsApproved'], true);
      expect(c['observedCommandStartsWithApproved'], false);
      c = observed('unrelated');
      expect(c['observedCommandContainsApproved'], false);
      expect(c['observedCommandStartsWithApproved'], false);
      c = checks(request(preview: 'no command line here'));
      expect(c['observedCommandContainsApproved'], false);
      expect(c['observedCommandStartsWithApproved'], false);
      expect(c['previewLineCount'], 1);
      c = checks(request());
      expect(c.containsKey('observedCommandContainsApproved'), false);
      expect(c.containsKey('observedCommandStartsWithApproved'), false);
    });
    test('line and option counts are small integers', () {
      final many = request(
        preview: List.filled(500, 'x').join('\n'),
        options: [for (var i = 0; i < 16; i++) ('o$i', 'allow_once')],
      );
      final c = checks(many);
      expect(c['previewLineCount'], 99);
      expect(c['optionCount'], many.options.length);
      expect(c['optionCount'] as int, lessThanOrEqualTo(99));
      expect(checks(request(preview: null))['previewLineCount'], 0);
      expect(checks(request(options: []))['optionCount'], 0);
      expect(
        checks(
          request(
            preview:
                'Command: $command\nWorking directory: $workdir\nReason: r\nNative decisions: ["accept"]',
          ),
        )['previewLineCount'],
        4,
      );
      expect(
        checks(
          request(
            preview:
                'Command: $command\nWorking directory: $workdir\nReason: r\nNative decisions: ["accept"]',
          ),
        )['decisionsLinePresent'],
        true,
      );
    });
    test('the serialized diagnostic carries no command path option or decision text', () {
      final r = AgentPermissionRequestedParams(
        sessionId: 'PRIVATE_ID',
        requestId: 'PRIVATE_ID',
        title: 'PRIVATE_COMMAND',
        preview:
            'Command: PRIVATE_COMMAND $command\nWorking directory: PRIVATE_DIR\nReason: PRIVATE_REASON\nNative decisions: ["PRIVATE_DECISION",{"PRIVATE_OPTION":1}]',
        truncated: false,
        options: [
          const AgentPermissionOption(
            optionId: 'PRIVATE_ID',
            name: 'PRIVATE_OPTION',
            kind: 'PRIVATE_OPTION',
          ),
        ],
      );
      final observations = <String, Object?>{};
      final evaluation = evaluateCanaryApproval(r, plan(), 1);
      expect(evaluation.optionId, isNull);
      expect(
        () => rejectCodexWalkPermission(
          observations,
          r,
          operation: 1,
          answered: false,
          matchesApprovedRequest: false,
          approvalChecks: evaluation.checks,
        ),
        throwsStateError,
      );
      final text = jsonEncode(observations);
      for (final marker in markers) {
        expect(text, isNot(contains(marker)));
      }
      expect(text, isNot(contains(command)));
      expect(text, isNot(contains('owned')));
      final diagnostic = observations['commandApprovalDiagnostic']! as Json;
      // The existing fields stay beside the new checks.
      expect(diagnostic['stage'], 'command-approval');
      expect(diagnostic['operation'], 2);
      expect(diagnostic['reason'], 'outside-approved-request');
      expect(diagnostic['truncated'], false);
      expect(diagnostic['hasOneShotAccept'], false);
      expect(diagnostic['matchesApprovedRequest'], false);
      expect(diagnostic['commandMatches'], false);
      expect(diagnostic['decisionsLineValid'], true);
      expect(diagnostic['decisionsMatchOptions'], false);
      for (final value in diagnostic.values) {
        expect(value is bool || value is int || value is String, true);
      }
      expect(utf8.encode(text).length, lessThan(1024));
      // Without checks the diagnostic is the original fixed shape.
      final plain = <String, Object?>{};
      expect(
        () => rejectCodexWalkPermission(
          plain,
          r,
          operation: 1,
          answered: false,
          matchesApprovedRequest: false,
        ),
        throwsStateError,
      );
      expect((plain['commandApprovalDiagnostic']! as Json).keys.toSet(), {
        'stage',
        'operation',
        'reason',
        'commandTitle',
        'truncated',
        'hasOneShotAccept',
        'matchesApprovedRequest',
      });
    });
    // Reference: the match rule exactly as it was before the diagnostic.
    String? legacyAllowedCanaryApproval(
      AgentPermissionRequestedParams request,
      Json plan,
      int operation,
    ) {
      if (request.truncated ||
          request.title != 'Command approval' ||
          operation < 1 ||
          operation > 2) {
        return null;
      }
      final command = plan[operation == 1 ? 'canaryCommand' : 'stopCommand'];
      final preview = request.preview;
      var lines = preview?.split('\n');
      const decisionsPrefix = 'Native decisions: ';
      List<Object?>? decisions;
      if (lines != null &&
          lines.length > 1 &&
          lines.last.startsWith(decisionsPrefix)) {
        final line = lines.last;
        lines = lines.sublist(0, lines.length - 1);
        try {
          final parsed = jsonDecode(line.substring(decisionsPrefix.length));
          if (parsed is! List<Object?> ||
              jsonEncode(parsed) != line.substring(decisionsPrefix.length) ||
              !parsed.any((entry) => entry is Map) ||
              parsed.any((entry) => entry is! String && entry is! Map)) {
            return null;
          }
          decisions = parsed;
        } on FormatException {
          return null;
        }
      }
      if (command is! String ||
          command.contains('\n') ||
          command.contains('\r') ||
          lines == null ||
          (lines.length != 2 && lines.length != 3) ||
          lines[0] != 'Command: $command' ||
          !lines[1].startsWith('Working directory: ') ||
          (lines.length == 3 && !lines[2].startsWith('Reason: ')) ||
          lines.any((line) => line.startsWith(decisionsPrefix))) {
        return null;
      }
      final cwd = lines[1].substring('Working directory: '.length);
      final workspace = plan['workspace'];
      if (workspace is! String ||
          !p.windows.isAbsolute(cwd) ||
          !p.windows.isAbsolute(workspace) ||
          !p.windows.equals(cwd, workspace)) {
        return null;
      }
      final options = request.options;
      if (decisions != null) {
        if (options.length != decisions.length) return null;
        for (var i = 0; i < decisions.length; i++) {
          final entry = decisions[i];
          if (entry is String
              ? options[i].name != entry
              : options[i].name != 'Native option ${i + 1}' ||
                    options[i].kind != 'allow_always') {
            return null;
          }
        }
      }
      final accepted = [
        for (final option in options)
          if (option.name == 'accept') option,
      ];
      if (accepted.length != 1 || accepted.single.kind != 'allow_once') {
        return null;
      }
      return accepted.single.optionId;
    }

    test('selection is unchanged against the pre-diagnostic match rule over a table of requests', () {
      final head = 'Command: $command\nWorking directory: $workdir';
      final previews = <String?>[
        null,
        '',
        head,
        '$head\nReason: r',
        '$head\nWhy: r',
        '$head\nReason: r\nextra',
        '$head\nNative decisions: ["accept",{"a":1}]',
        '$head\nReason: r\nNative decisions: [{"a":1},"accept"]',
        '$head\nNative decisions: ["accept"]',
        '$head\nNative decisions: [ "accept", {"a":1} ]',
        '$head\nNative decisions: not json',
        '$head\nNative decisions: ["accept",{"a":1}]\nNative decisions: ["x",{}]',
        'Native decisions: ["accept",{"a":1}]',
        'Command: other\nWorking directory: $workdir',
        'Command: $command\nWorking directory: f:/OWNED/work',
        'Command: $command\nWorking directory: relative',
        'Command: $command\nworking directory: $workdir',
        'Command: inert long command\nWorking directory: $workdir',
        'Command: $command\r\nWorking directory: $workdir',
      ];
      final optionSets = <List<(String, String)>>[
        [],
        [('accept', 'allow_once')],
        [('accept', 'allow_always')],
        [('accept', 'allow_once'), ('accept', 'allow_once')],
        [('Native option 1', 'allow_always'), ('accept', 'allow_once')],
        [('accept', 'allow_once'), ('Native option 2', 'allow_always')],
        [('accept', 'allow_once'), ('Native option 2', 'allow_once')],
        [('acceptForSession', 'allow_always')],
        [('decline', 'reject_once'), ('accept', 'allow_once')],
      ];
      final plans = <Json>[
        plan(),
        plan()..['canaryCommand'] = 5,
        plan()..['canaryCommand'] = 'a\nb',
        plan()..['workspace'] = 'relative',
        plan()..['workspace'] = null,
      ];
      var compared = 0, accepted = 0;
      for (final preview in previews) {
        for (final options in optionSets) {
          for (final title in ['Command approval', 'File change approval']) {
            for (final truncated in [false, true]) {
              for (final value in plans) {
                for (var op = -1; op <= 3; op++) {
                  final r = request(
                    preview: preview,
                    title: title,
                    truncated: truncated,
                    options: options,
                  );
                  final expected = legacyAllowedCanaryApproval(r, value, op);
                  expect(
                    allowedCanaryApproval(r, value, op),
                    expected,
                    reason: '$preview $options $title $truncated $op',
                  );
                  expect(
                    evaluateCanaryApproval(r, value, op).optionId,
                    expected,
                  );
                  compared++;
                  if (expected != null) accepted++;
                }
              }
            }
          }
        }
      }
      expect(compared, greaterThan(5000));
      expect(accepted, greaterThan(5), reason: 'the table must accept some');
    });
  });

  group('Codex approval wrapper:', () {
    const workdir = r'F:\owned\work';
    final canary = r'''& 'C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe' -NoLogo -NoProfile -NonInteractive -Command '[Console]::WriteLine("KUMIKO_QUALIFICATION_CANARY"); [Console]::WriteLine([bool]$env:KUMIKO_TOOL_SECRET)' '''
        .trimRight();
    final stop = r'''& 'C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe' -NoLogo -NoProfile -NonInteractive -Command '[Console]::WriteLine("KUMIKO_QUALIFICATION_RUNNING"); Start-Sleep -Seconds 60' '''
        .trimRight();
    const powershell =
        r'C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe';
    const pwsh = r'C:\Program Files\PowerShell\7\pwsh.exe';
    const trusted = [powershell, pwsh];
    Json wrapperPlan() => plan()
      ..['canaryCommand'] = canary
      ..['stopCommand'] = stop;
    // Test-side POSIX joins in three valid quoting styles. Words made only of
    // characters that never need quoting stay bare, as a join leaves them.
    final safe = RegExp(r'^[A-Za-z0-9_\-.,:/@%+=]+$');
    String singleDq(String w) => "'${w.replaceAll("'", "'\"'\"'")}'";
    String singleBs(String w) => "'${w.replaceAll("'", r"'\''")}'";
    String dbl(String w) =>
        '"${w.replaceAllMapped(RegExp(r'[\\"$`]'), (m) => '\\${m[0]}')}"';
    String join(List<String> argv, [String Function(String)? quote]) => argv
        .map(
          (w) => w.isNotEmpty && safe.hasMatch(w) ? w : (quote ?? singleDq)(w),
        )
        .join(' ');
    AgentPermissionRequestedParams request(
      String observed, {
      String dir = workdir,
      List<(String, String)>? options,
      String? tail,
      String title = 'Command approval',
      bool truncated = false,
    }) => AgentPermissionRequestedParams(
      sessionId: 's',
      requestId: 'r',
      title: title,
      preview:
          'Command: $observed\nWorking directory: $dir'
          '${tail == null ? '' : '\n$tail'}',
      truncated: truncated,
      options: [
        for (final (i, (name, kind))
            in (options ?? [('accept', 'allow_once')]).indexed)
          AgentPermissionOption(optionId: 'choice-$i', name: name, kind: kind),
      ],
    );
    CanaryApprovalEvaluation eval(
      String observed, {
      int op = 1,
      String dir = workdir,
      List<(String, String)>? options,
      String? tail,
      String title = 'Command approval',
      bool truncated = false,
      Json? value,
      List<String> shells = trusted,
    }) => evaluateCanaryApproval(
      request(
        observed,
        dir: dir,
        options: options,
        tail: tail,
        title: title,
        truncated: truncated,
      ),
      value ?? wrapperPlan(),
      op,
      trustedShells: shells,
    );
    String approved(int op) => op == 1 ? canary : stop;

    test('the exact rule still matches and records no wrapper fields', () {
      final e = eval(approved(1));
      expect(e.optionId, 'choice-0');
      expect(e.checks['commandMatches'], true);
      expect(
        e.checks.keys.where(
          (k) =>
              k.startsWith('wrapper') ||
              k.startsWith('observedArgv') ||
              k == 'trustedShellCount',
        ),
        isEmpty,
      );
      expect(eval(approved(1), shells: const []).optionId, 'choice-0');
    });

    for (final op in [1, 2]) {
      for (final (style, quote) in [
        ('single quotes and a double-quoted quote', singleDq),
        ('single quotes and an escaped quote', singleBs),
        ('double quotes', dbl),
      ]) {
        test(
          'operation $op matches the trusted wrapper joined with $style',
          () {
            for (final argv in [
              [powershell, '-Command', approved(op)],
              [powershell, '-NoProfile', '-Command', approved(op)],
              [pwsh, '-NoProfile', '-Command', approved(op)],
              [pwsh, '-Command', approved(op)],
              [
                r'c:\windows\system32\WINDOWSPOWERSHELL\V1.0\POWERSHELL.EXE',
                '-Command',
                approved(op),
              ],
            ]) {
              final observed = join(argv, quote);
              final e = eval(observed, op: op);
              expect(e.optionId, 'choice-0', reason: '$observed ${e.checks}');
              expect(e.checks['commandMatches'], false);
              expect(e.checks['wrapperMatches'], true);
              expect(e.checks['wrapperShellTrusted'], true);
              expect(e.checks['wrapperCommandFlag'], true);
              expect(e.checks['wrapperScriptMatches'], true);
              expect(e.checks['observedArgvParsed'], true);
              expect(e.checks['observedArgvWordCount'], argv.length);
              expect(e.checks['wrapperNoProfile'], argv.contains('-NoProfile'));
              expect(e.checks['trustedShellCount'], 2);
            }
          },
        );
      }
    }

    test('a wrapper around the other operation\'s command is refused', () {
      final e = eval(join([powershell, '-Command', approved(2)]), op: 1);
      expect(e.optionId, isNull);
      expect(e.checks['wrapperScriptMatches'], false);
      expect(e.checks['wrapperMatches'], false);
    });

    test('an empty trusted set never matches a wrapper', () {
      final e = eval(
        join([powershell, '-Command', approved(1)]),
        shells: const [],
      );
      expect(e.optionId, isNull);
      expect(e.checks['wrapperShellTrusted'], false);
      expect(e.checks['trustedShellCount'], 0);
    });

    final refusedShells = <String, String>{
      'untrusted PowerShell basename': r'C:\owned\work\powershell.exe',
      'untrusted pwsh basename': r'D:\tools\pwsh.exe',
      'relative': 'powershell.exe',
      'drive-relative':
          r'C:WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe',
      'root-relative':
          r'\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe',
      'UNC': r'\\server\share\pwsh.exe',
      'long-path prefix': r'\\?\C:\Program Files\PowerShell\7\pwsh.exe',
      'device prefix': r'\\.\C:\Program Files\PowerShell\7\pwsh.exe',
      'forward slashes': 'C:/Program Files/PowerShell/7/pwsh.exe',
      'dot segment': r'C:\Program Files\PowerShell\7\.\pwsh.exe',
      'dot-dot segment': r'C:\Program Files\PowerShell\8\..\7\pwsh.exe',
      'doubled separator': r'C:\Program Files\PowerShell\\7\pwsh.exe',
      'non-ASCII lookalike': r'C:\Program Files\PowerShell\7\pwſh.exe',
      'suffixed': r'C:\Program Files\PowerShell\7\pwsh.exe.evil',
    };
    for (final MapEntry(key: name, value: shell) in refusedShells.entries) {
      test('refuses shell: $name', () {
        final e = eval(join([shell, '-Command', canary]));
        expect(e.optionId, isNull, reason: '${e.checks}');
        expect(e.checks['wrapperShellTrusted'], false);
        expect(e.checks['wrapperMatches'], false);
      });
    }

    final refusedShapes = <String, List<String>>{
      'other flag': [powershell, '-NoLogo', '-Command', canary],
      'repeated flag': [
        powershell,
        '-NoProfile',
        '-NoProfile',
        '-Command',
        canary,
      ],
      'flag after -Command': [powershell, '-Command', '-NoProfile', canary],
      'lowercase -command': [powershell, '-command', canary],
      'lowercase -noprofile': [powershell, '-noprofile', '-Command', canary],
      'encoded command': [powershell, '-EncodedCommand', canary],
      'missing -Command': [powershell, canary],
      '-NoProfile without -Command': [powershell, '-NoProfile', canary],
      'extra word': [powershell, '-Command', canary, 'extra'],
      'script only': [canary],
      'last word differs by one code unit': [
        powershell,
        '-Command',
        '$canary ',
      ],
    };
    for (final MapEntry(key: name, value: argv) in refusedShapes.entries) {
      test('refuses shape: $name', () {
        final e = eval(join(argv));
        expect(e.optionId, isNull, reason: '${e.checks}');
        expect(e.checks['commandMatches'], false);
        expect(e.checks['wrapperMatches'], false);
        expect(e.checks['observedArgvParsed'], true);
      });
    }

    test('positional flags for parsed but malformed shapes', () {
      Json flags(List<String> argv) {
        final c = eval(join(argv)).checks;
        return {
          for (final k in [
            'wrapperShellTrusted',
            'wrapperNoProfile',
            'wrapperCommandFlag',
            'wrapperScriptMatches',
            'wrapperMatches',
          ])
            k: c[k],
          'words': c['observedArgvWordCount'],
        };
      }

      expect(flags([powershell, '-Command', canary, 'extra']), {
        'wrapperShellTrusted': true,
        'wrapperNoProfile': false,
        'wrapperCommandFlag': true,
        'wrapperScriptMatches': false,
        'wrapperMatches': false,
        'words': 4,
      });
      expect(
        flags([powershell, '-NoProfile', '-Command', '-NoProfile', canary]),
        {
          'wrapperShellTrusted': true,
          'wrapperNoProfile': true,
          'wrapperCommandFlag': true,
          'wrapperScriptMatches': true,
          'wrapperMatches': false,
          'words': 5,
        },
      );
      expect(flags([powershell, '-Command', '-NoProfile', canary]), {
        'wrapperShellTrusted': true,
        'wrapperNoProfile': false,
        'wrapperCommandFlag': true,
        'wrapperScriptMatches': true,
        'wrapperMatches': false,
        'words': 4,
      });
      expect(flags([powershell, '-NoProfile', canary]), {
        'wrapperShellTrusted': true,
        'wrapperNoProfile': true,
        'wrapperCommandFlag': false,
        'wrapperScriptMatches': true,
        'wrapperMatches': false,
        'words': 3,
      });
      expect(flags([canary]), {
        'wrapperShellTrusted': false,
        'wrapperNoProfile': false,
        'wrapperCommandFlag': false,
        'wrapperScriptMatches': true,
        'wrapperMatches': false,
        'words': 1,
      });
    });

    test('the walk refuses before the claim when no shell is trusted', () {
      expect(() => verifyCodexTrustedShells(const []), throwsStateError);
      verifyCodexTrustedShells(const [powershell]);
    });

    test('the decoder recovers words without executing anything', () {
      const cases = <String, List<String>>{
        'a b': ['a', 'b'],
        '  a   b  ': ['a', 'b'],
        "''": [''],
        '""': [''],
        "a '' b": ['a', '', 'b'],
        "ab'cd'\"ef\"gh": ['abcdefgh'],
        r"'it'\''s'": ["it's"],
        "'it'\"'\"'s'": ["it's"],
        r'a\;b \| \$x \`y \* \#': ['a;b', '|', r'$x', '`y', '*', '#'],
        r'"a\$b\`c\"d\\e"': [r'a$b`c"d\e'],
        r'''"a\b\nc\'d"''': [r"a\b\nc\'d"],
        // A synthetic full wrapper: a shell path with spaces and a script
        // with single quotes, dollar signs and backslashes.
        r'''"C:\\Program Files\\PowerShell\\7\\pwsh.exe" -NoProfile -Command '& '"'"'C:\x\y.exe'"'"' -Command '"'"'$env:A; \n'"'"'' ''':
            [
              r'C:\Program Files\PowerShell\7\pwsh.exe',
              '-NoProfile',
              '-Command',
              r"& 'C:\x\y.exe' -Command '$env:A; \n'",
            ],
        r"'a\b $c `d ; | \'": [r'a\b $c `d ; | \'],
        r'C:\\x': [r'C:\x'],
      };
      for (final MapEntry(key: input, value: words) in cases.entries) {
        expect(splitPosixShellWords(input), words, reason: input);
      }
    });

    test(
      'the decoder refuses shell syntax, control characters and broken quoting',
      () {
        final refused = <String>[
          '',
          '   ',
          'a\tb',
          'a\nb',
          'a\u0000b',
          'a\u007fb',
          "'a\tb'",
          r'a\',
          "'a",
          '"a',
          r'"a\"',
          r'"a$b"',
          '"a`b"',
          for (final ch in [
            ';',
            '&',
            '|',
            '<',
            '>',
            '(',
            ')',
            r'$',
            '`',
            '*',
            '?',
            '[',
            '#',
            '~',
            '{',
            '}',
            '!',
          ])
            'a${ch}b',
        ];
        for (final input in refused) {
          expect(
            splitPosixShellWords(input),
            isNull,
            reason: jsonEncode(input),
          );
        }
        expect(splitPosixShellWords(r"';&|<>()$`*?[#~{}!'"), [
          r';&|<>()$`*?[#~{}!',
        ]);
      },
    );

    test(
      'an undecodable observed command refuses with zeroed wrapper fields',
      () {
        final e = eval('${join([powershell, '-Command'])} "abc');
        expect(e.optionId, isNull);
        expect(e.checks['observedArgvParsed'], false);
        expect(e.checks['observedArgvWordCount'], 0);
        for (final key in [
          'wrapperShellTrusted',
          'wrapperNoProfile',
          'wrapperCommandFlag',
          'wrapperScriptMatches',
          'wrapperMatches',
        ]) {
          expect(e.checks[key], false, reason: key);
        }
        expect(e.checks['trustedShellCount'], 2);
        final missing = evaluateCanaryApproval(
          AgentPermissionRequestedParams(
            sessionId: 's',
            requestId: 'r',
            title: 'Command approval',
            preview: 'no command line\nWorking directory: $workdir',
            truncated: false,
            options: const [
              AgentPermissionOption(
                optionId: 'choice-0',
                name: 'accept',
                kind: 'allow_once',
              ),
            ],
          ),
          wrapperPlan(),
          1,
          trustedShells: trusted,
        );
        expect(missing.checks['observedArgvParsed'], false);
        expect(missing.checks['observedArgvWordCount'], 0);
      },
    );

    test('every unchanged check is still required for a wrapper match', () {
      final observed = join([powershell, '-Command', canary]);
      expect(eval(observed).optionId, 'choice-0');
      final refusals = <String, CanaryApprovalEvaluation>{
        'title': eval(observed, title: 'Other approval'),
        'truncation': eval(observed, truncated: true),
        'operation 0': eval(observed, op: 0),
        'operation 3': eval(observed, op: 3),
        'command not a string': eval(
          observed,
          value: wrapperPlan()..['canaryCommand'] = 7,
        ),
        'command with a line break': eval(
          observed,
          value: wrapperPlan()..['canaryCommand'] = '$canary\nx',
        ),
        'working directory': eval(observed, dir: r'F:\elsewhere'),
        'layout': eval(observed, tail: 'Reason: r\nextra'),
        'reason line': eval(observed, tail: 'Why: because'),
        'decisions line': eval(
          observed,
          tail: 'Native decisions: [ "accept" ]',
        ),
        'accept kind': eval(observed, options: [('accept', 'allow_always')]),
        'two accepts': eval(
          observed,
          options: [('accept', 'allow_once'), ('accept', 'allow_once')],
        ),
      };
      for (final MapEntry(:key, :value) in refusals.entries) {
        expect(value.optionId, isNull, reason: key);
      }
      expect(refusals['working directory']!.checks['wrapperMatches'], true);
    });

    test(
      'a second approval request is still refused after a wrapper match',
      () {
        final observations = <String, Object?>{};
        final r = request(join([powershell, '-Command', canary]));
        expect(
          () => rejectCodexWalkPermission(
            observations,
            r,
            operation: 1,
            answered: true,
            matchesApprovedRequest: true,
            approvalChecks: evaluateCanaryApproval(
              r,
              wrapperPlan(),
              1,
              trustedShells: trusted,
            ).checks,
          ),
          throwsStateError,
        );
        final diagnostic = observations['commandApprovalDiagnostic']! as Json;
        expect(diagnostic['reason'], 'additional-request');
        expect(diagnostic['wrapperMatches'], true);
      },
    );

    test('wrapper diagnostic fields are content-free and bounded', () {
      final checks = eval(join([pwsh, '-NoProfile', '-Command', canary]))
          .checks;
      expect(checks.values.every((v) => v is bool || v is int), true);
      final encoded = jsonEncode(checks);
      for (final fragment in [
        'KUMIKO',
        'pwsh',
        'PowerShell',
        'Command:',
        'Program Files',
        r'C:\\',
      ]) {
        expect(encoded.contains(fragment), false, reason: fragment);
      }
      expect(utf8.encode(encoded).length, lessThan(1024));
      expect(
        eval(List.filled(150, 'w').join(' ')).checks['observedArgvWordCount'],
        99,
      );
      expect(
        eval(
          join([powershell, '-Command', canary]),
          shells: List.filled(20, powershell),
        ).checks['trustedShellCount'],
        9,
      );
    });

    group('trusted shell resolution', () {
      late Directory root;
      setUp(() {
        root = Directory.systemTemp.createTempSync('kumiko_trusted_shell_');
      });
      tearDown(() => root.deleteSync(recursive: true));
      String file(String relative) {
        final f = File(p.join(root.path, relative))
          ..createSync(recursive: true);
        return f.path;
      }

      test('admits existing regular drive-letter files from the registry', () {
        final windows = Directory(p.join(root.path, 'Win'))..createSync();
        final system = file(
          r'Win\System32\WindowsPowerShell\v1.0\powershell.exe',
        );
        final seven = file(r'PS\7\pwsh.exe');
        final shells = resolveTrustedPowerShells(
          FakePowerShellRegistry(windows.path, [
            '${p.join(root.path, 'PS', '7')}\\',
            p.join(root.path, 'PS', 'missing'),
            r'\\server\share\PowerShell',
            'relative',
          ]),
        );
        expect(shells, [system, seven]);
      }, testOn: 'windows');

      test('leaves out links, missing files and failed queries', () {
        final windows = Directory(p.join(root.path, 'Win'))..createSync();
        final target = file('real.exe');
        final linkDir = Directory(p.join(root.path, 'PS', '7'))
          ..createSync(recursive: true);
        try {
          Link(p.join(linkDir.path, 'pwsh.exe')).createSync(target);
        } on FileSystemException {
          markTestSkipped('file links need developer mode');
          return;
        }
        expect(
          resolveTrustedPowerShells(
            FakePowerShellRegistry(windows.path, [linkDir.path]),
          ),
          isEmpty,
        );
        expect(
          resolveTrustedPowerShells(const FakePowerShellRegistry(null, null)),
          isEmpty,
        );
      }, testOn: 'windows');

      test('an ancestor junction excludes only its own candidate', () {
        final windows = Directory(p.join(root.path, 'Win'))..createSync();
        final system = file(
          r'Win\System32\WindowsPowerShell\v1.0\powershell.exe',
        );
        file(r'Real\7\pwsh.exe');
        // On Windows a directory link is created as a junction.
        Link(p.join(root.path, 'Jn')).createSync(p.join(root.path, 'Real'));
        expect(
          FileSystemEntity.typeSync(
            p.join(root.path, 'Jn', '7', 'pwsh.exe'),
            followLinks: false,
          ),
          FileSystemEntityType.file,
          reason: 'the terminal file is regular; only an ancestor is a link',
        );
        expect(
          resolveTrustedPowerShells(
            FakePowerShellRegistry(windows.path, [
              p.join(root.path, 'Jn', '7'),
            ]),
          ),
          [system],
        );
        expect(
          resolveTrustedPowerShells(
            FakePowerShellRegistry(p.join(root.path, 'Jn'), null),
          ),
          isEmpty,
          reason:
              'a junctioned SystemRoot ancestor excludes Windows PowerShell',
        );
      }, testOn: 'windows');

      test('a failed query or a bad candidate keeps the other valid one', () {
        final windows = Directory(p.join(root.path, 'Win'))..createSync();
        final system = file(
          r'Win\System32\WindowsPowerShell\v1.0\powershell.exe',
        );
        final seven = file(r'PS\7\pwsh.exe');
        expect(
          resolveTrustedPowerShells(FakePowerShellRegistry(windows.path, null)),
          [system],
        );
        expect(
          resolveTrustedPowerShells(
            FakePowerShellRegistry(p.join(root.path, 'Missing'), [
              p.join(root.path, 'PS', '7'),
            ]),
          ),
          [seven],
        );
      }, testOn: 'windows');

      test('real registry resolution finds Windows PowerShell', () {
        final shells = resolveTrustedPowerShells(RegPowerShellRegistry());
        expect(
          shells.any(
            (s) => p.windows.basename(s).toLowerCase() == 'powershell.exe',
          ),
          true,
          reason: '$shells',
        );
        for (final shell in shells) {
          expect(RegExp(r'^[A-Za-z]:\\').hasMatch(shell), true);
        }
      }, testOn: 'windows');
    });
  });

  group('Codex command output tracker:', () {
    AgentEvent item(
      String id,
      String kind, {
      String? text,
      bool update = false,
    }) => AgentEvent.tool(
      toolCallId: id,
      update: update,
      toolKind: kind,
      content: [
        if (text != null)
          {
            'type': 'content',
            'content': {'type': 'text', 'text': text},
          },
      ],
    );
    AgentEvent delta(String id, String text) => AgentEvent.tool(
      toolCallId: id,
      update: true,
      content: [
        {
          'type': 'content',
          'content': {'type': 'text', 'text': text},
        },
      ],
    );

    test(
      'untagged streamed deltas of a command item reveal the running marker',
      () {
        final tracker = CodexCommandOutputTracker();
        tracker.add(item('t:1', 'commandExecution'));
        expect(tracker.runningCanary, isFalse);
        tracker.add(delta('t:1', 'KUMIKO_QUALIFICATION_RUNNING\r\n'));
        expect(tracker.runningCanary, isTrue);
      },
    );

    test(
      'a marker split across deltas, including a CRLF split, is still found',
      () {
        final tracker = CodexCommandOutputTracker();
        tracker.add(item('t:1', 'commandExecution'));
        for (final chunk in ['KUMIKO_QUALI', 'FICATION_RUN', 'NING']) {
          tracker.add(delta('t:1', chunk));
        }
        expect(tracker.runningCanary, isTrue);
        final isolated = CodexCommandOutputTracker();
        isolated.add(item('t:2', 'commandExecution'));
        for (final chunk in [
          'KUMIKO_QUALIFICATION_CANARY\r',
          '\nFalse\r',
          '\nFalse\r\n',
        ]) {
          isolated.add(delta('t:2', chunk));
        }
        expect(isolated.commandEnvironmentIsolated, isTrue);
        expect(isolated.runningCanary, isFalse);
      },
    );

    test('deltas arriving before the command item are applied once the kind is known', () {
      final tracker = CodexCommandOutputTracker();
      tracker.add(delta('t:1', 'KUMIKO_QUALIFICATION_RUNNING'));
      expect(tracker.runningCanary, isFalse);
      tracker.add(item('t:1', 'commandExecution'));
      expect(tracker.runningCanary, isTrue);
    });

    test('deltas of other items, or of no known command, never count', () {
      final tracker = CodexCommandOutputTracker();
      tracker.add(item('t:1', 'commandExecution'));
      tracker.add(item('t:2', 'fileChange'));
      tracker.add(delta('t:2', 'KUMIKO_QUALIFICATION_RUNNING'));
      tracker.add(delta('t:3', 'KUMIKO_QUALIFICATION_CANARY\nFalse\nFalse'));
      tracker.add(
        AgentEvent.text(
          AgentEventKind.agentText,
          'KUMIKO_QUALIFICATION_RUNNING',
        ),
      );
      expect(tracker.runningCanary, isFalse);
      expect(tracker.commandEnvironmentIsolated, isFalse);
    });

    test('tagged command items keep their whole-content reading', () {
      final tracker = CodexCommandOutputTracker();
      tracker.add(
        item(
          't:1',
          'commandExecution',
          update: true,
          text: 'KUMIKO_QUALIFICATION_CANARY\r\nFalse\r\nFalse\r\n',
        ),
      );
      expect(tracker.commandEnvironmentIsolated, isTrue);
    });

    test('tracking stays bounded under many unknown ids and long output', () {
      final tracker = CodexCommandOutputTracker();
      for (var i = 0; i < 10000; i++) {
        tracker.add(delta('u:$i', 'x' * 100));
      }
      expect(
        tracker.trackedIds,
        lessThanOrEqualTo(CodexCommandOutputTracker.maxTrackedIds),
      );
      tracker.add(item('t:1', 'commandExecution'));
      tracker.add(delta('t:1', 'y' * (1 << 20)));
      tracker.add(delta('t:1', 'KUMIKO_QUALIFICATION_RUNNING'));
      expect(tracker.runningCanary, isTrue);
      expect(
        tracker.retainedChars,
        lessThanOrEqualTo(
          CodexCommandOutputTracker.maxTrackedIds *
              CodexCommandOutputTracker.carryChars,
        ),
      );
    });
  });

  test('Codex walk diagnostics: a cancelled MCP elicitation is flagged without content', () {
    final diagnostics = CodexWalkDiagnostics();
    diagnostics.recordEvent(
      AgentEvent.notice(
        'MCP elicitation unavailable: unsupported form or URL request.',
      ),
    );
    final observations = <String, Object?>{};
    diagnostics.persist(observations);
    final flags = (observations['walkDiagnostics']! as Json)['noticeFlags'];
    expect(flags, {'mcpElicitationCancelled': true});
  });

  group('Codex MCP probe stage:', () {
    test('the stage reads only the recorded flags', () {
      expect(codexMcpProbeStage(null), 'none');
      expect(codexMcpProbeStage({'started': true}), 'started');
      expect(
        codexMcpProbeStage({'started': true, 'initialized': true}),
        'initialized',
      );
      expect(
        codexMcpProbeStage({
          'started': true,
          'initialized': true,
          'listed': true,
        }),
        'listed',
      );
      expect(codexMcpProbeStage({'started': true, 'called': true}), 'called');
      expect(codexMcpProbeStage({'started': 'yes'}), 'none');
    });
  });

  group('Codex walk workspace:', () {
    late Directory owned;
    setUp(() async {
      owned = await Directory.systemTemp.createTemp('kumiko_walk_ws_');
    });
    tearDown(() async {
      if (owned.existsSync()) await owned.delete(recursive: true);
    });

    test('an existing empty owned workspace passes', () {
      final work = Directory(p.join(owned.path, 'workspace'))..createSync();
      expect(
        () => verifyCodexWalkWorkspace({'workspace': work.path}),
        returnsNormally,
      );
    });

    test(
      'a missing, non-empty, file, linked or untyped workspace is refused',
      () {
        final missing = p.join(owned.path, 'gone');
        expect(
          () => verifyCodexWalkWorkspace({'workspace': missing}),
          throwsStateError,
        );
        final full = Directory(p.join(owned.path, 'full'))..createSync();
        File(p.join(full.path, 'x')).writeAsStringSync('x');
        expect(
          () => verifyCodexWalkWorkspace({'workspace': full.path}),
          throwsStateError,
        );
        final file = File(p.join(owned.path, 'file'))..writeAsStringSync('x');
        expect(
          () => verifyCodexWalkWorkspace({'workspace': file.path}),
          throwsStateError,
        );
        final target = Directory(p.join(owned.path, 'target'))..createSync();
        final link = p.join(owned.path, 'link');
        try {
          Link(link).createSync(target.path);
          expect(
            () => verifyCodexWalkWorkspace({'workspace': link}),
            throwsStateError,
          );
        } on FileSystemException {
          // Creating a link may need privileges; the other cases still ran.
        }
        expect(
          () => verifyCodexWalkWorkspace({'workspace': 7}),
          throwsStateError,
        );
        expect(() => verifyCodexWalkWorkspace({}), throwsStateError);
      },
    );

    test(
      'a walk whose workspace vanished after preparation creates no claim',
      () async {
        final value = makeCodexWalkPlan(
          workspace: p.join(owned.path, 'vanished'),
          profile: p.join(owned.path, 'profile'),
          executable: r'F:\native\codex.exe',
          nativeHome: r'C:\user\.codex',
          version: '0.166.0',
          hostExecutable: r'F:\test\kumiko_host_test.exe',
          canaryCommand: 'inert canary command',
          stopCommand: 'inert long command',
          nativeSelection: 'changed-artifacts-v4',
        );
        final bytes = utf8.encode(jsonEncode(value));
        final manifest = File(p.join(owned.path, 'manifest.json'))
          ..writeAsBytesSync(bytes);
        final result = await Process.run(Platform.resolvedExecutable, [
          'tool/qualify_codex_app_server.dart',
          '--walk',
          '--manifest',
          manifest.path,
          '--approved-sha256',
          sha256.convert(bytes).toString(),
        ]);
        expect(result.exitCode, 1);
        expect('${result.stderr}', contains('StateError'));
        expect('${result.stdout}', isNot(contains('Observations written')));
        expect(File(p.join(owned.path, 'attempt.jsonl')).existsSync(), false);
        expect(
          File(p.join(owned.path, 'observations.json')).existsSync(),
          false,
        );
      },
    );
  });
}

class FakePowerShellRegistry implements PowerShellRegistry {
  const FakePowerShellRegistry(this.root, this.locations);
  final String? root;
  final List<String>? locations;
  @override
  String? systemRoot() => root;
  @override
  List<String>? powerShellInstallLocations() => locations;
}
