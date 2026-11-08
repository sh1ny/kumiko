import 'dart:async';
import 'dart:io';

// Root-only tooling intentionally consumes the workspace's public protocol API
// without adding a production dependency to the workspace root.
// ignore: depend_on_referenced_packages
import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import '../check_qualification.dart';
import '../qualification_support.dart';

const candidate = ('observed-adapter', '0.99.1');
const _noFailures =
    'const toolDeliveryFailures = <(String, String, String)>[];';
const _emptySource =
    'const qualifiedAdapters = <(String, String, List<String>)>[];\n'
    '$_noFailures';

Map<String, QualificationObservation> observations({String os = 'windows'}) => {
  for (final item in qualificationItems(os))
    item: QualificationObservation.confirmed(
      passed: true,
      confirmed: true,
      authCode: item == 'auth-required observed' ? '-32123' : '',
      authMessage: item == 'auth-required observed'
          ? 'Observed signed-out error'
          : '',
    ),
};

String merge(
  String original,
  String os,
  Map<String, QualificationObservation> rows, {
  bool fixture = false,
}) => mergeQualificationEvidence(
  original,
  adapter: candidate,
  os: os,
  observations: rows,
  fixture: fixture,
  date: DateTime.utc(2026, 10, 31),
);

class _AuthProbe {
  bool fixture = false;
  Object? startError;
  Object? attachError;
  Object? promptError;
  int starts = 0;
  int attaches = 0;
  final prompts = <String>[];
  final questions = <String>[];
  final reports = <String>[];
  final answers = <bool>[];
  final turn = Completer<AgentTurnEndedParams>();
  final waiting = Completer<void>();

  Future<QualificationObservation?> run() => runQualificationAuthProbe(
    fixture: fixture,
    start: () async {
      starts++;
      if (startError != null) throw startError!;
    },
    attach: () async {
      attaches++;
      if (attachError != null) throw attachError!;
    },
    approve: (question) async {
      questions.add(question);
      return answers.isEmpty ? true : answers.removeAt(0);
    },
    prompt: (text) async {
      prompts.add(text);
      if (promptError != null) throw promptError!;
    },
    waitForTurn: () {
      waiting.complete();
      return turn.future;
    },
    report: reports.add,
  );
}

AgentTurnEndedParams _nativeTurn({
  String? message = 'Exact native authentication refusal',
  int? code = -32123,
  bool truncated = false,
}) => AgentTurnEndedParams.fromJson({
  'sessionId': 'isolated',
  'error': 'acp-error',
  'message': 'Bounded presentation, not native evidence',
  'nativeCode': ?code,
  'nativeMessage': ?message,
  'nativeMessageTruncated': truncated,
});

RpcException _nativeRpc(String stage) =>
    RpcException(ErrorCode.adapterStartFailed, 'Native refusal', {
      'stage': stage,
      'nativeCode': -32123,
      'nativeMessage': 'Exact native authentication refusal',
      'nativeMessageTruncated': false,
    });

void main() {
  group('qualification arguments and approval', () {
    test('dry-run cannot target a real workspace profile or evidence file', () {
      for (final flag in [
        '--workspace',
        '--profile-dir',
        '--profile',
        '--evidence',
      ]) {
        expect(
          () => QualificationOptions.parse(['--dry-run', flag, 'private']),
          throwsFormatException,
          reason: flag,
        );
      }
      expect(QualificationOptions.parse(['--dry-run']).dryRun, isTrue);
    });
    test('unknown switches missing values and approval bypass are refused', () {
      for (final args in [
        ['--yes'],
        ['--workspace'],
        ['--profile', '--dry-run'],
        ['--unknown'],
        ['--dry-run', '--dry-run'],
      ]) {
        expect(() => QualificationOptions.parse(args), throwsFormatException);
      }
    });
    test('real action requires a terminal and the exact explicit approval', () {
      expect(approvedAction(interactive: false, answer: 'yes'), isFalse);
      expect(approvedAction(interactive: true, answer: null), isFalse);
      expect(approvedAction(interactive: true, answer: ''), isFalse);
      expect(approvedAction(interactive: true, answer: 'y'), isFalse);
      expect(approvedAction(interactive: true, answer: 'yes'), isTrue);
    });
    test(
      'isolated auth environment blanks only present documented credentials',
      () {
        final profile = RuntimeProfile(
          id: 'chosen',
          name: 'Chosen',
          runtimeKind: 'claude-code',
          executable: 'node',
          args: ['adapter.js'],
          env: {
            'ANTHROPIC_AUTH_TOKEN': 'profile-secret',
            'ANTHROPIC_BASE_URL': 'gateway',
            'KEEP': 'value',
          },
        );
        final env = isolatedAuthEnvironment(
          profile.env,
          {'ANTHROPIC_API_KEY': 'inherited-secret', 'UNRELATED': 'untouched'},
          'isolated-config',
          os: 'windows',
        );
        expect(env, {
          'ANTHROPIC_AUTH_TOKEN': '',
          'ANTHROPIC_API_KEY': '',
          'ANTHROPIC_BASE_URL': 'gateway',
          'KEEP': 'value',
          'CLAUDE_CONFIG_DIR': 'isolated-config',
        });
        expect(profile.env['ANTHROPIC_AUTH_TOKEN'], 'profile-secret');
      },
    );
    test('Windows auth isolation blanks every credential spelling supplied only by the profile', () {
      final original = {
        'anthropic_api_key': 'profile-only-key',
        'AnThRoPiC_AuTh_ToKeN': 'profile-only-token',
        'claude_code_oauth_token': 'profile-only-oauth',
        'ANTHROPIC_BASE_URL': 'gateway',
        'KEEP': 'value',
      };
      final env = isolatedAuthEnvironment(
        original,
        {},
        'isolated-config',
        os: 'windows',
      );
      for (final key in original.keys.take(3)) {
        expect(
          env[key],
          isEmpty,
          reason: 'credential spelling $key escaped isolation',
        );
      }
      expect(env['ANTHROPIC_BASE_URL'], 'gateway');
      expect(env['KEEP'], 'value');
      expect(env['CLAUDE_CONFIG_DIR'], 'isolated-config');
      expect(original['anthropic_api_key'], 'profile-only-key');
      expect(original['AnThRoPiC_AuTh_ToKeN'], 'profile-only-token');
      expect(original['claude_code_oauth_token'], 'profile-only-oauth');
    });

    test('Windows auth isolation blanks inherited mixed-case credentials without copying unrelated values', () {
      final env = isolatedAuthEnvironment(
        {},
        {
          'Anthropic_Api_Key': 'inherited-key',
          'claude_CODE_oauth_TOKEN': 'inherited-oauth',
          'UNRELATED': 'do not copy',
        },
        'isolated-config',
        os: 'windows',
      );
      expect(env, {
        'Anthropic_Api_Key': '',
        'claude_CODE_oauth_TOKEN': '',
        'CLAUDE_CONFIG_DIR': 'isolated-config',
      });
    });
    for (final os in ['linux', 'macos']) {
      test(
        '$os auth isolation preserves case-sensitive noncredential names',
        () {
          final env = isolatedAuthEnvironment(
            {
              'anthropic_api_key': 'case-sensitive custom value',
              'ANTHROPIC_AUTH_TOKEN': 'real documented token',
            },
            {
              'claude_code_oauth_token': 'case-sensitive inherited value',
              'CLAUDE_CODE_OAUTH_TOKEN': 'real documented inherited token',
            },
            'isolated-config',
            os: os,
          );
          expect(env['anthropic_api_key'], 'case-sensitive custom value');
          expect(env['ANTHROPIC_AUTH_TOKEN'], '');
          expect(env['CLAUDE_CODE_OAUTH_TOKEN'], '');
          expect(env.containsKey('claude_code_oauth_token'), isFalse);
          expect(env.containsKey('ANTHROPIC_API_KEY'), isFalse);
        },
      );
    }

    test('selected and unavailable default profiles never fall back', () {
      const p = RuntimeProfile(
        id: 'present',
        name: 'Present',
        runtimeKind: 'claude-code',
        executable: 'node',
      );
      const list = RuntimeListResult(
        profiles: [p],
        defaultId: 'gone',
        defaultAvailable: false,
      );
      expect(() => selectQualificationProfile(list, null), throwsStateError);
      expect(
        () => selectQualificationProfile(list, 'missing'),
        throwsStateError,
      );
      expect(selectQualificationProfile(list, 'present').id, 'present');
    });
  });

  group('isolated authentication probe', () {
    test('approved minimal prompt waits for native turn error before evidence', () async {
      final probe = _AuthProbe();
      final result = probe.run();
      var completed = false;
      result.then((_) => completed = true);
      // The old startup-only path completes without sending or awaiting a turn.
      await Future.any([result.then<void>((_) {}), probe.waiting.future]);
      expect(probe.prompts, ['Reply only OK; no tools or file changes.']);
      expect(probe.questions.first, contains(probe.prompts.single));
      expect(
        completed,
        isFalse,
        reason: 'Prompt acceptance is not a turn result',
      );
      probe.turn.complete(_nativeTurn());
      final row = await result;
      expect(row?.result, 'pass');
      expect(row?.authCode, '-32123');
      expect(row?.authMessage, 'Exact native authentication refusal');
      expect(probe.questions, hasLength(3));
    });
    test('successful model turn is honest and never an auth pass', () async {
      final probe = _AuthProbe()
        ..turn.complete(
          const AgentTurnEndedParams(
            sessionId: 'isolated',
            stopReason: 'end_turn',
          ),
        );
      expect(await probe.run(), isNull);
      expect(probe.prompts, hasLength(1));
      expect(probe.questions, hasLength(1));
      expect(probe.reports.join('\n'), contains('completed successfully'));
    });
    test(
      'cancelled or unspecified turn endings do not claim model success',
      () async {
        for (final reason in ['cancelled', null]) {
          final probe = _AuthProbe()
            ..turn.complete(
              AgentTurnEndedParams(sessionId: 'isolated', stopReason: reason),
            );
          expect(await probe.run(), isNull);
          expect(probe.prompts, hasLength(1));
          expect(
            probe.reports.join('\n'),
            isNot(contains('completed successfully')),
          );
          expect(probe.questions, hasLength(1));
        }
      },
    );
    test('declined separate prompt approval leaves auth unrecorded', () async {
      final probe = _AuthProbe()..answers.add(false);
      expect(await probe.run(), isNull);
      expect(probe.starts, 1);
      expect(probe.attaches, 1);
      expect(probe.questions, hasLength(1));
      expect(probe.prompts, isEmpty);
      expect(probe.waiting.isCompleted, isFalse);
    });
    test(
      'native prompt diagnostics must be exact complete and nontruncated',
      () async {
        for (final turn in [
          _nativeTurn(code: null),
          _nativeTurn(message: null),
          _nativeTurn(message: ''),
          _nativeTurn(truncated: true),
        ]) {
          final probe = _AuthProbe()..turn.complete(turn);
          expect(await probe.run(), isNull);
          expect(probe.prompts, hasLength(1));
          expect(
            probe.questions,
            hasLength(1),
            reason: 'No evidence confirmation',
          );
        }
        final exact = 'native-${'x' * 700}';
        final probe = _AuthProbe()..turn.complete(_nativeTurn(message: exact));
        expect((await probe.run())?.authMessage, exact);
        expect(probe.reports.join('\n'), contains(exact));
      },
    );
    test(
      'native auth semantics and evidence each require human confirmation',
      () async {
        for (final answers in [
          [true, false],
          [true, true, false],
        ]) {
          final probe = _AuthProbe()
            ..answers.addAll(answers)
            ..turn.complete(_nativeTurn());
          expect(await probe.run(), isNull);
          expect(probe.prompts, hasLength(1));
        }
      },
    );
    test('session new errors qualify separately without a prompt', () async {
      final probe = _AuthProbe()..startError = _nativeRpc('session/new');
      final row = await probe.run();
      expect(row?.authCode, '-32123');
      expect(row?.authMessage, 'Exact native authentication refusal');
      expect(probe.attaches, 0);
      expect(probe.prompts, isEmpty);
      expect(probe.questions, hasLength(2));
    });
    test(
      'session new requires complete nontruncated native diagnostics too',
      () async {
        for (final data in [
          {'stage': 'session/new', 'nativeMessage': 'No native code'},
          {'stage': 'session/new', 'nativeCode': -32123},
          {
            'stage': 'session/new',
            'nativeCode': -32123,
            'nativeMessage': 'Shortened native message',
            'nativeMessageTruncated': true,
          },
        ]) {
          final probe = _AuthProbe()
            ..startError = RpcException(
              ErrorCode.adapterStartFailed,
              'Failure',
              data,
            );
          expect(await probe.run(), isNull);
          expect(probe.prompts, isEmpty);
          expect(probe.questions, isEmpty);
        }
      },
    );
    test(
      'unrelated start attach and prompt failures cannot pose as session new',
      () async {
        final startup = _AuthProbe()..startError = _nativeRpc('initialize');
        final attach = _AuthProbe()..attachError = _nativeRpc('session/new');
        final prompt = _AuthProbe()..promptError = _nativeRpc('session/new');
        for (final probe in [startup, attach, prompt]) {
          expect(await probe.run(), isNull);
          expect(probe.questions.length, lessThanOrEqualTo(1));
        }
      },
    );
    test('generic turn errors cannot substitute their display message for native evidence', () async {
      final probe = _AuthProbe()
        ..turn.complete(
          const AgentTurnEndedParams(
            sessionId: 'isolated',
            error: 'protocol-error',
            message: 'Authentication required: a generic display is not native evidence',
          ),
        );
      expect(await probe.run(), isNull);
      expect(probe.prompts, hasLength(1));
      expect(probe.questions, hasLength(1));
    });
    test(
      'explicit native prompt RPC errors require their own prompt stage',
      () async {
        final probe = _AuthProbe()..promptError = _nativeRpc('session/prompt');
        final row = await probe.run();
        expect(row?.authCode, '-32123');
        expect(probe.prompts, hasLength(1));
        expect(probe.waiting.isCompleted, isFalse);
        expect(probe.questions, hasLength(3));
      },
    );
    test('incomplete turn failure remains unqualified', () async {
      final probe = _AuthProbe()
        ..turn.completeError(TimeoutException('deadline expired'));
      // Attach an error handler immediately; the probe must consume this future.
      probe.turn.future.ignore();
      expect(await probe.run(), isNull);
      expect(probe.prompts, hasLength(1));
      expect(probe.reports.join('\n'), contains('deadline expired'));
    });
    test(
      'scripted native errors are categorically not real evidence',
      () async {
        for (final startupError in [false, true]) {
          final probe = _AuthProbe()
            ..fixture = true
            ..turn.complete(_nativeTurn());
          if (startupError) probe.startError = _nativeRpc('session/new');
          expect(await probe.run(), isNull);
          expect(probe.reports.join('\n'), contains('FIXTURE ONLY'));
        }
      },
    );
  });

  group('structured qualification diagnostics', () {
    test(
      'RPC failure retains native status without exposing arbitrary data',
      () {
        final text = qualificationRpcDiagnostic(
          RpcException(ErrorCode.adapterStartFailed, 'engine refused', {
            'stage': 'session/new',
            'status': 127,
            'nativeCode': -32123,
            'nativeMessage': 'Actual native refusal',
            'nativeMessageTruncated': true,
            'detail': 'bounded engine detail',
            'private': 'secret must not appear',
          }),
        );
        expect(text, contains('reason=adapter-start-failed'));
        expect(text, contains('stage=session/new'));
        expect(text, contains('status=127'));
        expect(text, contains('nativeCode=-32123'));
        expect(text, contains('nativeMessageTruncated=true'));
        expect(text, contains('Actual native refusal'));
        expect(text, contains('bounded engine detail'));
        expect(text, isNot(contains('secret must not appear')));
      },
    );
    test(
      'diagnostic presentation is bounded and does not disguise truncation',
      () {
        final text = qualificationRpcDiagnostic(
          RpcException(ErrorCode.resumeUnavailable, 'x' * 2000, {
            'resumeReason': 'not-qualified',
            'status': 1,
          }),
        );
        expect(text, contains('resumeReason=not-qualified'));
        expect(text, contains('status=1'));
        expect(text, contains('[display truncated]'));
        expect(text.length, lessThan(2048));
        expect(
          qualificationDisplay('safe\u001b[2J\runsafe'),
          'safe?[2J?unsafe',
        );
      },
    );
  });

  group('real evidence boundaries', () {
    test('user pass and fail both require an actual confirmation', () {
      for (final passed in [true, false]) {
        expect(
          () => QualificationObservation.confirmed(
            passed: passed,
            confirmed: false,
          ),
          throwsStateError,
        );
      }
    });
    test('fixture observations can never become version evidence', () {
      expect(
        () => merge('# Evidence\n', 'windows', observations(), fixture: true),
        throwsStateError,
      );
    });
    test(
      'authentication failure cannot substitute for an unobserved auth error',
      () {
        final rows = observations()
          ..['auth-required observed'] = QualificationObservation.confirmed(
            passed: false,
            confirmed: true,
          );
        expect(() => merge('# Evidence\n', 'windows', rows), throwsStateError);
      },
    );
    test('untried Windows never receives invented rows', () {
      expect(
        () => merge('# Evidence\n', 'linux', observations(os: 'linux')),
        throwsStateError,
      );
      final incomplete = observations()..remove('auth-required observed');
      expect(
        () => merge('# Evidence\n', 'windows', incomplete),
        throwsStateError,
      );
    });
    test('Windows unproven is refused even when every item is supplied', () {
      final rows = observations()
        ..['Stop'] = const QualificationObservation.unproven();
      expect(() => merge('# Evidence\n', 'windows', rows), throwsStateError);
    });
    test(
      'fenced OS headings cannot replace or damage real OS observations',
      () {
        final recorded = merge('# Evidence\n', 'windows', observations());
        final original = recorded.replaceFirst(
          '### linux',
          '```markdown\n### linux\nfake table, not evidence\n```\n\n### linux',
        );
        final updated = merge(original, 'linux', observations(os: 'linux'));
        expect(
          updated,
          contains('```markdown\n### linux\nfake table, not evidence\n```'),
        );
        expect(
          updated.substring(
            updated.indexOf('### windows'),
            updated.indexOf('```markdown'),
          ),
          recorded.substring(
            recorded.indexOf('### windows'),
            recorded.indexOf('### linux'),
          ),
        );
        expect(checkQualification(updated, _emptySource).failures, isEmpty);
      },
    );
    test('auth pass requires exact observed nontruncated native error', () {
      for (final auth in [
        QualificationObservation.confirmed(passed: true, confirmed: true),
        QualificationObservation.confirmed(
          passed: true,
          confirmed: true,
          authCode: '-32123',
          authMessage: 'shortened',
          authTruncated: true,
        ),
      ]) {
        final rows = observations()..['auth-required observed'] = auth;
        expect(() => merge('# Evidence\n', 'windows', rows), throwsStateError);
      }
    });
    test(
      'confirmed Windows creates only honest Linux and macOS unproven rows',
      () {
        final text = merge('# Evidence\n', 'windows', observations());
        final report = checkQualification(
          text,
          "const qualifiedAdapters = <(String, String, List<String>)>["
          "('observed-adapter', '0.99.1', <String>['load', 'resume']),];"
          "\n$_noFailures",
        );
        expect(report.failures, isEmpty);
        expect(report.verdict, 'ACCEPTED');
        expect(report.unproven, hasLength(21));
        expect(text, contains('| auth-required observed | user | pass |'));
        expect(text, contains('-32123 | Observed signed-out error'));
      },
    );
    test('extending one OS preserves other OS records and unrelated sections verbatim', () {
      final original = merge('# Evidence\n', 'windows', observations());
      final windows = original.substring(
        original.indexOf('### windows'),
        original.indexOf('### linux'),
      );
      const other =
          '\n## adapter untouched 9\n\n### windows\n\n'
          '| launch | user | fail | Existing observation | | |\n';
      final updated = merge(
        '$original$other',
        'linux',
        observations(os: 'linux'),
      );
      expect(updated, contains(windows));
      expect(updated.endsWith(other), isTrue);
      expect(updated.split('## adapter observed-adapter 0.99.1'), hasLength(2));
      expect(updated, contains('| launch | user | pass |'));
    });
    test(
      'format control characters and identity interpolation are refused',
      () {
        final rows = observations()
          ..['auth-required observed'] = QualificationObservation.confirmed(
            passed: true,
            confirmed: true,
            authCode: '-32123',
            authMessage: 'private|unrepresentable\nmessage',
          );
        expect(
          () => merge('# Evidence\n', 'windows', rows),
          throwsFormatException,
        );
        expect(
          () => mergeQualificationEvidence(
            '# Evidence\n',
            adapter: ('name with spaces', '1'),
            os: 'windows',
            observations: observations(),
            fixture: false,
            date: DateTime.utc(2026),
          ),
          throwsFormatException,
        );
      },
    );
    test(
      'final write gate refuses fixture declined and noninteractive writes',
      () {
        expect(
          mayWriteEvidence(fixture: true, interactive: true, answer: 'yes'),
          isFalse,
        );
        expect(
          mayWriteEvidence(fixture: false, interactive: false, answer: 'yes'),
          isFalse,
        );
        expect(
          mayWriteEvidence(fixture: false, interactive: true, answer: 'no'),
          isFalse,
        );
        expect(
          mayWriteEvidence(fixture: false, interactive: true, answer: 'yes'),
          isTrue,
        );
      },
    );
  });

  group('kumiko tool call qualification', () {
    const connected = AgentTools(AgentToolsStatus.connected);
    const ended = AgentTurnEndedParams(
      sessionId: 'tool',
      stopReason: 'end_turn',
    );

    test(
      'item is part of every OS item list and the tool prompt names the tool',
      () {
        for (final os in qualificationOses) {
          expect(qualificationItems(os), contains('kumiko tool call'));
        }
        expect(toolCallQualificationItem, 'kumiko tool call');
        expect(qualificationToolPrompt, contains(qualificationToolName));
        expect(qualificationToolName, 'kumiko_session_info');
      },
    );

    test('connected status after a clean turn passes and names the tool', () {
      final result = evaluateQualificationToolCall(
        tools: connected,
        toolTitles: ['mcp__kumiko__kumiko_session_info'],
        turn: ended,
      );
      expect(result.passed, isTrue);
      expect(result.detail, contains('connected'));
      expect(result.detail, contains('mcp__kumiko__kumiko_session_info'));
    });

    test(
      'any other status or a failed turn is a failure with checker-safe text',
      () {
        for (final (tools, turn) in [
          (const AgentTools(AgentToolsStatus.notYetUsed), ended),
          (const AgentTools(AgentToolsStatus.notStarted), ended),
          (const AgentTools(AgentToolsStatus.unknown), ended),
          (null, ended),
          (connected, null),
          (
            connected,
            const AgentTurnEndedParams(sessionId: 'tool', error: 'acp-error'),
          ),
          (
            const AgentTools(
              AgentToolsStatus.unavailable,
              reason: 'endpoint-unavailable: it\'s "bad" | \\ \$x\nnext',
            ),
            ended,
          ),
        ]) {
          final result = evaluateQualificationToolCall(
            tools: tools,
            toolTitles: const [],
            turn: turn,
          );
          expect(result.passed, isFalse, reason: '$tools $turn');
          expect(result.observed, isNotEmpty);
          expect(
            result.observed,
            isNot(matches(RegExp(r'''['"|\\$\x00-\x1f]'''))),
          );
          expect(result.observed.length, lessThanOrEqualTo(200));
        }
      },
    );

    test(
      'failure observed text is recorded in Notes and accepted by the checker',
      () {
        const text = 'tools status notStarted; adapter did not start the entry';
        Map<String, QualificationObservation> rows(String os) =>
            observations(os: os)
              ..[toolCallQualificationItem] =
                  QualificationObservation.confirmed(
                    passed: false,
                    confirmed: true,
                    observed: text,
                  );
        // A listed failure needs the observation on every OS (design D8).
        var recorded = '# Evidence\n';
        for (final os in ['windows', 'linux', 'macos']) {
          recorded = merge(recorded, os, rows(os));
        }
        expect(recorded, contains('observed: "$text"'));
        final report = checkQualification(
          recorded,
          "const qualifiedAdapters = <(String, String, List<String>)>["
          "('observed-adapter', '0.99.1', <String>['load', 'resume']),];\n"
          "const toolDeliveryFailures = <(String, String, String)>["
          "('observed-adapter', '0.99.1', '$text'),];",
        );
        expect(report.failures, isEmpty);
        expect(report.verdict, 'QUALIFIED');
      },
    );

    test('a failed tool call without observed text, or with unsafe text, cannot be recorded', () {
      for (final observed in ['', 'has "quote"', 'a|b', 'multi\nline']) {
        final rows = observations()
          ..[toolCallQualificationItem] = QualificationObservation.confirmed(
            passed: false,
            confirmed: true,
            observed: observed,
          );
        expect(
          () => merge('# Evidence\n', 'windows', rows),
          throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
          reason: observed,
        );
      }
    });

    test('dry run records kumiko tool call pass from the fixture', () async {
      var flutterRoot = Platform.environment['FLUTTER_ROOT'];
      if (flutterRoot == null || flutterRoot.isEmpty) {
        // <flutter>/bin/cache/dart-sdk/bin/dart
        flutterRoot = File(Platform.resolvedExecutable)
            .parent
            .parent
            .parent
            .parent
            .parent
            .path;
      }
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['tool/qualify_claude_acp.dart', '--dry-run'],
        environment: {'FLUTTER_ROOT': flutterRoot},
      );
      final output = '${result.stdout}\n${result.stderr}';
      expect(result.exitCode, 0, reason: output);
      expect(output, contains('FIXTURE kumiko tool call: pass'));
      expect(output, contains('DRY-RUN PASSED'));
      expect(output, isNot(contains('FIXTURE kumiko tool call: fail')));
    }, timeout: const Timeout(Duration(minutes: 15)));
  });
}
