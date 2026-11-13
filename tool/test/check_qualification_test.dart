import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../check_qualification.dart';

const _name = 'fixture-acp';
const _version = '1.2.3';
const _items = <String>[
  'launch',
  'streaming',
  'tool activity',
  'permission request',
  'Stop',
  'close with confirmation',
  'load',
  'resume',
  'auth-required observed',
  'kumiko tool call',
];
const _toolItem = 'kumiko tool call';
const _finder = 'launch from Finder or the Dock';
const _oses = <String>['windows', 'linux', 'macos'];

String _source({
  String entries = "('$_name', '$_version', <String>['load', 'resume']),",
  String? failures = '',
}) =>
    'const qualifiedAdapters = <(String, String, List<String>)>[\n$entries\n];\n'
    '${failures == null ? '' : 'const toolDeliveryFailures = <(String, String, String)>[\n$failures\n];\n'}';

String _failure(
  String text, {
  String name = _name,
  String version = _version,
}) => "('$name', '$version', '$text'),";

/// A results document whose [os] tool call row is a `fail`.
String _toolFail(String os, String notes, {String others = 'pass'}) => _results(
  result: (o, i) => i == _toolItem ? (o == os ? 'fail' : others) : 'pass',
  notes: (o, i) => i == _toolItem && o == os ? notes : 'synthetic fixture',
);

/// The tool call fails with the same notes on every OS.
String _toolFailEverywhere(String notes) => _results(
  result: (o, i) => i == _toolItem ? 'fail' : 'pass',
  notes: (o, i) => i == _toolItem ? notes : 'synthetic fixture',
);

String _results({
  String name = _name,
  String version = _version,
  String Function(String os, String item)? result,
  String Function(String os, String item)? notes,
  bool Function(String os, String item)? omit,
}) {
  final out = StringBuffer(
    '# Fixture evidence only\n\n## adapter $name $version\n',
  );
  for (final os in _oses) {
    out.writeln('\n### $os\n');
    out.writeln('| Item | Kind | Result | Notes | Auth code | Auth message |');
    out.writeln('|---|---|---|---|---|---|');
    for (final item in [..._items, if (os == 'macos') _finder]) {
      if (omit?.call(os, item) ?? false) continue;
      final auth = item == 'auth-required observed';
      out.writeln(
        '| $item | user | ${result?.call(os, item) ?? 'pass'} | '
        '${notes?.call(os, item) ?? 'synthetic fixture observation'} | ${auth ? '-32000' : ''} | '
        '${auth ? 'fixture sign-in required' : ''} |',
      );
    }
  }
  return out.toString();
}

String _oneCell(String os, String item, String value) =>
    _results(result: (o, i) => o == os && i == item ? value : 'pass');

const _nativeItems = [
  'launch',
  'streaming',
  'tool activity',
  'command approval',
  'Stop',
  'close/descendant containment',
  'kumiko tool call',
  'auth-required',
];
const _emptyAuth =
    'const confirmedCodexAuthSignatures = <(String, String, String)>[];';

String _nativeLiteral(String value) =>
    "'${value.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$').replaceAll('\n', r'\n').replaceAll('\r', r'\r').replaceAll('\t', r'\t')}'";
String _nativeCell(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll('|', r'\|')
    .replaceAll('\n', r'\n')
    .replaceAll('\r', r'\r')
    .replaceAll('\t', r'\t');
String _authSource({
  String version = '0.166.0',
  String os = 'windows',
  String signal = 'turn-http-401',
}) =>
    'const confirmedCodexAuthSignatures = <(String, String, String)>['
    "('$version', '$os', '$signal'),];";

String _nativeResults({
  String version = '0.166.0',
  String os = 'windows',
  String? omit,
  String status = 'pass',
  bool auth = false,
  String? item,
  String? result,
  String extra = '',
  String? notes,
}) {
  return '## native codex-app-server codex $version\n### $os\n'
      '| Item | Kind | Result | Notes | Auth code | Auth message |\n'
      '|---|---|---|---|---|---|\n'
      '${_nativeItems.where((i) => i != omit).map((i) {
        final r = i == item
            ? result!
            : i == 'auth-required' && !auth
            ? 'unverified'
            : status;
        return '| $i | user | $r | ${notes ?? 'synthetic parser evidence only'} | '
            '${i == 'auth-required' && auth ? 'turn-http-401' : ''} |  |';
      }).join('\n')}\n$extra';
}

QualificationReport _nativeCheck(
  String text, {
  String auth = _emptyAuth,
  String failures = '',
  String? claude,
}) => checkQualification(
  claude ?? '# No Claude claims\n',
  _source(
    entries: claude == null
        ? ''
        : "('$_name', '$_version', <String>['load', 'resume']),",
    failures: failures,
  ),
  codexMarkdown: text,
  codexAuthSource: auth,
);

void _fails(QualificationReport report, Iterable<String> details) {
  expect(report.verdict, isNull);
  expect(report.exitCode, 1);
  expect(report.failures, isNotEmpty);
  final output = report.failures.join('\n');
  for (final detail in details) {
    expect(output, contains(detail));
  }
}

void main() {
  group('native observations', () {
    for (final malformed in [false, true]) {
      test(
        'later native auth pass requires valid original provenance missing=${!malformed}',
        () {
          final original = malformed
              ? '${_nativeResults(auth: true, omit: 'launch')}\n'
              : '';
          final report = _nativeCheck(
            '$original${_nativeResults(version: '0.167.0', auth: true)}',
            auth: _authSource(),
          );
          expect(report.exitCode, 1);
          expect(
            report.failures.any((failure) => failure.contains('provenance')),
            true,
          );
          expect(
            report.codexObservations.last,
            'CODEX OBSERVATIONS: 0.167.0 windows: FAIL',
          );
        },
      );
    }
    test('valid auth provenance remains independent of other version observation outcomes', () {
      for (final status in ['fail', 'unverified']) {
        final report = _nativeCheck(
          '${_nativeResults(auth: true, item: 'Stop', result: status)}\n'
          '${_nativeResults(version: '0.167.0', auth: true)}',
          auth: _authSource(),
        );
        expect(
          report.failures.any((failure) => failure.contains('provenance')),
          false,
        );
        expect(
          report.codexObservations.last,
          'CODEX OBSERVATIONS: 0.167.0 windows: PASS',
        );
      }
    });
    test('later native auth pass uses confirmed pair without a provenance-version gate', () {
      final report = _nativeCheck(
        '${_nativeResults(auth: true)}\n${_nativeResults(version: '0.167.0', auth: true)}',
        auth: _authSource(),
      );
      expect(report.failures, isEmpty);
      expect(report.codexObservations, [
        'CODEX OBSERVATIONS: 0.166.0 windows: PASS',
        'CODEX OBSERVATIONS: 0.167.0 windows: PASS',
      ]);
    });
    test('native auth pass may record both signals in fixed order', () {
      final markdown = _nativeResults(auth: true).replaceAll(
        '| turn-http-401 |',
        '| account-unauthenticated, turn-http-401 |',
      );
      final auth =
          'const confirmedCodexAuthSignatures = <(String, String, String)>['
          "('0.166.0', 'windows', 'account-unauthenticated'),"
          "('0.166.0', 'windows', 'turn-http-401'),];";
      expect(_nativeCheck(markdown, auth: auth).failures, isEmpty);
      _fails(_nativeCheck(markdown, auth: _authSource()), [
        'account-unauthenticated',
        'registry',
      ]);
    });
    test('unclosed native evidence fence cannot print a passing section', () {
      final report = _nativeCheck(
        '${_nativeResults(auth: true)}\n```\n',
        auth: _authSource(),
      );
      expect(report.exitCode, 1);
      expect(report.codexObservations, [
        'CODEX OBSERVATIONS: 0.166.0 windows: FAIL',
      ]);
    });
    test(
      'native exact diagnostics decode quotes slashes Unicode and delimiters',
      () {
        const diagnostic =
            '\nNative isn\'t signed in: C:\\路径\\user | "login" \$value\r\t';
        final failure = _nativeResults(item: 'kumiko tool call', result: 'fail')
            .replaceAll(
              'synthetic parser evidence only',
              _nativeCell('observed: ${jsonEncode(diagnostic)}'),
            );
        final failed = _nativeCheck(
          failure,
          failures:
              "('codex-app-server', '0.166.0', ${_nativeLiteral(diagnostic)}),",
        );
        expect(failed.toolDeliveryFailures, [
          'codex-app-server 0.166.0 windows: $diagnostic',
        ]);
        expect(failed.failures, hasLength(1));
        expect(failed.codexObservations, [
          'CODEX OBSERVATIONS: 0.166.0 windows: FAIL',
        ]);
      },
    );
    test(
      'native JSON diagnostic preserves embedded quote boundaries exactly',
      () {
        const diagnostic = 'native "first" then "second"';
        final failure = _nativeResults(
          item: 'kumiko tool call',
          result: 'fail',
          notes: _nativeCell('observed: ${jsonEncode(diagnostic)}'),
        );
        final report = _nativeCheck(
          failure,
          failures:
              "('codex-app-server', '0.166.0', ${_nativeLiteral(diagnostic)}),",
        );
        expect(report.toolDeliveryFailures, [
          'codex-app-server 0.166.0 windows: $diagnostic',
        ]);
        expect(report.failures, hasLength(1));
      },
    );
    test('default unrecorded native document is optional but an existing blank document fails', () {
      final dir = Directory.systemTemp.createTempSync(
        'kumiko_default_checker_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final script = File('tool/check_qualification.dart').absolute.path;
      File.fromUri(dir.uri.resolve(defaultQualificationResultsPath))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('# No claims');
      File.fromUri(dir.uri.resolve(defaultQualifiedAdaptersPath))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(_source(entries: ''));
      File.fromUri(dir.uri.resolve(defaultCodexAuthSourcePath))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(_emptyAuth);
      ProcessResult run() => Process.runSync(Platform.resolvedExecutable, [
        script,
      ], workingDirectory: dir.path);
      final missing = run();
      expect(
        missing.exitCode,
        0,
        reason: '${missing.stdout}\n${missing.stderr}',
      );
      expect(missing.stdout, isNot(contains('CODEX OBSERVATIONS')));
      File.fromUri(dir.uri.resolve(defaultCodexResultsPath))
          .writeAsStringSync(' \n');
      final blank = run();
      expect(blank.exitCode, 1, reason: '${blank.stdout}\n${blank.stderr}');
      expect(blank.stdout, contains('Codex results: document is blank'));
    });
    test('native escape grammar refuses malformed escapes and conflicting JSON diagnostics', () {
      for (final bad in [r'\q', r'\u00zz', '\\']) {
        final source =
            "const confirmedCodexAuthSignatures = <(String, String, String)>[("
            "'0.166.0', 'windows', '$bad'),];";
        _fails(_nativeCheck('# No observations', auth: source), [
          'source',
          'auth',
        ]);
      }
      for (final bad in [r'\q', '\\']) {
        final text = _nativeResults().replaceAll(
          'synthetic parser evidence only',
          bad,
        );
        _fails(_nativeCheck(text), ['escape']);
      }
      const diagnostic = 'one "quoted" | exact';
      final failure = _nativeResults(
        item: 'kumiko tool call',
        result: 'fail',
        notes: _nativeCell(
          'observed: ${jsonEncode(diagnostic)}; observed: "second"',
        ),
      );
      _fails(
        _nativeCheck(
          failure,
          failures:
              "('codex-app-server', '0.166.0', ${_nativeLiteral(diagnostic)}),",
        ),
        ['observed'],
      );
    });
    test(
      'native CLI prints native status and rejects explicitly missing inputs',
      () {
        final dir = Directory.systemTemp.createTempSync(
          'kumiko_native_checker_',
        );
        addTearDown(() => dir.deleteSync(recursive: true));
        final claude = File.fromUri(dir.uri.resolve('claude.md'))
          ..writeAsStringSync('# No claims');
        final native = File.fromUri(dir.uri.resolve('native.md'))
          ..writeAsStringSync(_nativeResults());
        final source = File.fromUri(dir.uri.resolve('qualified.dart'))
          ..writeAsStringSync(_source(entries: ''));
        final auth = File.fromUri(dir.uri.resolve('auth.dart'))
          ..writeAsStringSync(_emptyAuth);
        final out = StringBuffer();
        expect(
          runQualificationCheck(
            [claude.path, source.path],
            out: out,
            codexResultsPath: native.path,
            codexAuthSourcePath: auth.path,
          ),
          0,
        );
        expect(
          out.toString(),
          contains('CODEX OBSERVATIONS: 0.166.0 windows: INCOMPLETE'),
        );
        for (final missingAuth in [false, true]) {
          final failed = StringBuffer();
          expect(
            runQualificationCheck(
              [claude.path, source.path],
              out: failed,
              codexResultsPath: missingAuth
                  ? native.path
                  : '${native.path}.missing',
              codexAuthSourcePath: missingAuth
                  ? '${auth.path}.missing'
                  : auth.path,
            ),
            1,
          );
          expect(
            failed.toString(),
            contains(missingAuth ? 'auth' : 'Codex results'),
          );
        }
      },
    );
    test('native claims cannot enter the qualified-adapter allowlist', () {
      _fails(
        checkQualification(
          _nativeResults(),
          _source(entries: "('codex-app-server', '0.166.0', <String>[]),"),
        ),
        ['source', 'Codex', 'qualifiedAdapters'],
      );
    });
    test('blank explicit native document is malformed', () {
      _fails(_nativeCheck(' \r\n'), ['Codex', 'blank']);
    });
    test('Codex: Real Windows evidence passes (checker)', () {
      final report = _nativeCheck(
        _nativeResults(auth: true),
        auth: _authSource(),
      );
      expect(report.failures, isEmpty);
      expect(report.codexObservations, [
        'CODEX OBSERVATIONS: 0.166.0 windows: PASS',
      ]);
      expect(report.verdict, 'NO CLAIMS (no adapter qualified)');
    });
    test('required unverified is INCOMPLETE without admission failure', () {
      final report = _nativeCheck(_nativeResults());
      expect(report.exitCode, 0);
      expect(report.codexObservations, [
        'CODEX OBSERVATIONS: 0.166.0 windows: INCOMPLETE',
      ]);
      expect(
        report.unproven,
        contains('codex-app-server codex 0.166.0: windows: auth-required'),
      );
    });
    test(
      'absent native observations do not gate later compatible versions',
      () {
        final report = _nativeCheck(
          '# Research only; installed 0.167.0 unobserved\n',
        );
        expect(report.failures, isEmpty);
        expect(report.codexObservations, isEmpty);
      },
    );
    test('each required item is mandatory in every recorded section', () {
      for (final item in _nativeItems) {
        final report = _nativeCheck(_nativeResults(omit: item));
        _fails(report, ['0.166.0', 'windows', item, 'missing']);
        expect(report.codexObservations, [
          'CODEX OBSERVATIONS: 0.166.0 windows: FAIL',
        ]);
      }
    });
    test('any required failure is FAIL', () {
      final report = _nativeCheck(_nativeResults(item: 'Stop', result: 'fail'));
      _fails(report, ['0.166.0', 'windows', 'Stop', 'fail']);
      expect(report.codexObservations, [
        'CODEX OBSERVATIONS: 0.166.0 windows: FAIL',
      ]);
    });
    test('optional claims each need their own valid result', () {
      for (final item in [
        'recovery',
        'steering',
        'structured question',
        'child attribution',
      ]) {
        for (final result in ['pass', 'unverified', 'fail', '']) {
          final report = _nativeCheck(
            _nativeResults(
              auth: true,
              extra:
                  '| $item | user | $result | synthetic optional evidence | | |\n',
            ),
            auth: _authSource(),
          );
          expect(report.codexObservations, [
            'CODEX OBSERVATIONS: 0.166.0 windows: ${result == 'fail' || result.isEmpty ? 'FAIL' : 'PASS'}',
          ]);
          expect(report.exitCode, result == 'fail' || result.isEmpty ? 1 : 0);
        }
      }
    });
    test('auth pass requires ordered known signal names, no message and registry provenance', () {
      _fails(_nativeCheck(_nativeResults(auth: true)), ['auth-required']);
      for (final code in [
        '',
        'login',
        '-32001',
        'unauthorized',
        'Turn-Http-401',
        'turn-http-401, account-unauthenticated',
        'turn-http-401, turn-http-401',
        'turn-http-401,',
      ]) {
        _fails(
          _nativeCheck(
            _nativeResults(auth: true)
                .replaceAll('| turn-http-401 |', '| $code |'),
            auth: _authSource(),
          ),
          ['auth-required'],
        );
      }
      _fails(
        _nativeCheck(
          _nativeResults(auth: true)
              .replaceAll('| turn-http-401 |  |', '| turn-http-401 | 401 |'),
          auth: _authSource(),
        ),
        ['auth-required', 'Message'],
      );
      _fails(
        _nativeCheck(
          _nativeResults(auth: true),
          auth: _authSource(signal: 'account-unauthenticated'),
        ),
        ['auth'],
      );
      _fails(
        _nativeCheck(
          _nativeResults(auth: true),
          auth: _authSource(os: 'linux'),
        ),
        ['auth'],
      );
      _fails(
        _nativeCheck(
          _nativeResults(auth: true),
          auth: _authSource(version: '0.167.0'),
        ),
        ['auth'],
      );
    });
    test('auth signature provenance needs its matching recorded auth pass', () {
      for (final text in [
        '# No observations',
        _nativeResults(),
        _nativeResults(omit: 'auth-required'),
      ]) {
        _fails(_nativeCheck(text, auth: _authSource()), [
          'auth',
          '0.166.0',
          'windows',
        ]);
      }
      final report = _nativeCheck(
        '${_nativeResults(auth: true)}\n${_nativeResults(version: '0.167.0')}',
        auth: _authSource(),
      );
      expect(report.failures, isEmpty);
      expect(report.codexObservations, [
        'CODEX OBSERVATIONS: 0.166.0 windows: PASS',
        'CODEX OBSERVATIONS: 0.167.0 windows: INCOMPLETE',
      ]);
    });
    test('unverified auth cannot claim a code or message', () {
      _fails(
        _nativeCheck(
          _nativeResults().replaceAll(
            RegExp(r'\| auth-required \| user \| unverified \|[^\n]*'),
            '| auth-required | user | unverified | synthetic parser evidence only | turn-http-401 | |',
          ),
        ),
        ['auth-required'],
      );
    });
    test(
      'native Windows evidence does not manufacture other OS observations',
      () {
        final report = _nativeCheck(
          _nativeResults(auth: true),
          auth: _authSource(),
        );
        expect(report.codexObservations, hasLength(1));
        expect(report.unproven, isEmpty);
        expect(report.failures, isEmpty);
      },
    );
    test('malformed duplicate and missing native cells or sections fail', () {
      for (final text in [
        _nativeResults().replaceAll('codex 0.166.0', 'codex latest'),
        _nativeResults().replaceAll('codex-app-server codex', 'unknown codex'),
        _nativeResults().replaceAll('### windows', '### plan9'),
        _nativeResults().replaceAll('### windows\n', ''),
        _nativeResults().replaceAll(
          RegExp(r'\| launch \| user \| pass \|[^\n]*'),
          '| launch | user | pass |',
        ),
        _nativeResults().replaceAll(
          '| launch | user | pass',
          '| launch | robot | pass',
        ),
        _nativeResults().replaceAll(
          '| launch | user | pass',
          '| launch | user | qualified',
        ),
        _nativeResults(notes: ''),
        '${_nativeResults()}\n### windows\n',
        '${_nativeResults()}\n${_nativeResults()}',
        '${_nativeResults()}\n| launch | user | pass | repeated | | |\n',
        '${_nativeResults()}\n| invented capability | user | pass | invented | | |\n',
        '## native codex-app-server codex 0.166.0\n',
      ]) {
        expect(_nativeCheck(text).failures, isNotEmpty, reason: text);
      }
    });
    test('native CRLF and fences cannot invent evidence', () {
      expect(
        _nativeCheck(_nativeResults().replaceAll('\n', '\r\n'))
            .codexObservations,
        ['CODEX OBSERVATIONS: 0.166.0 windows: INCOMPLETE'],
      );
      for (final fence in ['```', '~~~~']) {
        final report = _nativeCheck(
          '$fence markdown\n${_nativeResults()}$fence\n',
        );
        expect(report.codexObservations, isEmpty);
        expect(report.failures, isEmpty);
      }
      _fails(_nativeCheck('```\n${_nativeResults()}'), ['fence']);
    });
    test('matched native tool failure is FAIL with exact diagnostic on observed OS only', () {
      const text = 'native MCP failed exactly';
      final results = _nativeResults(item: 'kumiko tool call', result: 'fail')
          .replaceAll(
            '| kumiko tool call | user | fail | synthetic parser evidence only |',
            '| kumiko tool call | user | fail | observed: "$text" |',
          );
      final report = _nativeCheck(
        results,
        failures: _failure(text, name: 'codex-app-server', version: '0.166.0'),
      );
      expect(report.codexObservations, [
        'CODEX OBSERVATIONS: 0.166.0 windows: FAIL',
      ]);
      expect(report.toolDeliveryFailures, [
        'codex-app-server 0.166.0 windows: $text',
      ]);
      expect(report.failures, hasLength(1));
      expect(report.failures.single, contains('kumiko tool call: fail'));
    });
    test('native failure diagnostics cannot be absent unsigned contradictory or mismatched', () {
      final listed = _failure(
        'native failure',
        name: 'codex-app-server',
        version: '0.166.0',
      );
      for (final text in [
        '# Unrun',
        _nativeResults(),
        _nativeResults(item: 'kumiko tool call', result: 'fail'),
        _nativeResults(
          item: 'kumiko tool call',
          result: 'fail',
          notes: 'observed: "different"',
        ),
      ]) {
        _fails(_nativeCheck(text, failures: listed), [
          'codex-app-server',
          '0.166.0',
          'kumiko tool call',
        ]);
      }
      _fails(
        _nativeCheck(
          _nativeResults(
            item: 'kumiko tool call',
            result: 'fail',
            notes: 'observed: "native failure"',
          ),
        ),
        ['kumiko tool call', 'not listed'],
      );
      _fails(
        _nativeCheck(
          _nativeResults(
            item: 'kumiko tool call',
            result: 'fail',
            notes: 'observed: "one"; observed: "two"',
          ),
          failures: listed,
        ),
        ['kumiko tool call', 'observed'],
      );
    });
    test('native auth registry grammar is strict and cannot hide unused signatures', () {
      for (final auth in [
        '',
        'const confirmedCodexAuthSignatures = arbitrary;',
        '$_emptyAuth const ignored = 1;',
        _authSource(signal: 'unauthorized'),
        _authSource(signal: 'Turn-Http-401'),
        _authSource(version: 'latest'),
        _authSource(os: 'plan9'),
        _authSource(signal: ''),
        _authSource(signal: r'$secret'),
        _authSource().replaceAll(
          '];',
          "('0.166.0', 'windows', 'turn-http-401'),];",
        ),
        _authSource().replaceAll(', String)', ', int, String)'),
      ]) {
        _fails(_nativeCheck('# Unrun', auth: auth), ['source', 'auth']);
      }
    });
    test('Claude and native evidence retain independent semantics', () {
      final report = _nativeCheck(_nativeResults(), claude: _results());
      expect(report.failures, isEmpty);
      expect(report.verdict, 'QUALIFIED');
      expect(report.codexObservations, [
        'CODEX OBSERVATIONS: 0.166.0 windows: INCOMPLETE',
      ]);
    });
  });

  test('Codex: Tests pass but walk is unrun', () {
    final report = checkQualification(
      '# Contract research only\n\n'
      '## native codex-app-server codex 0.166.0\n\n'
      '### windows\n\n'
      '| Item | Kind | Result | Notes | Auth code | Auth message |\n'
      '|---|---|---|---|---|---|\n'
      '${['launch', 'streaming', 'tool activity', 'command approval', 'Stop', 'close/descendant containment', 'kumiko tool call', 'auth-required'].map((item) => '| $item | user | unverified | walk unrun | | |').join('\n')}\n',
      _source(entries: ''),
    );
    expect(
      report.unproven,
      contains('codex-app-server codex 0.166.0: windows: launch'),
    );
  });

  group('qualification check', () {
    test('every checked item pass prints QUALIFIED', () {
      final report = checkQualification(_results(), _source());
      expect(report.exitCode, 0);
      expect(report.failures, isEmpty);
      expect(report.verdict, 'QUALIFIED');
      expect(report.unproven, isEmpty);
    });

    test(
      'Linux and macOS user items unproven prints ACCEPTED and lists them',
      () {
        final report = checkQualification(
          _results(result: (os, item) => os == 'windows' ? 'pass' : 'unproven'),
          _source(),
        );
        expect(report.exitCode, 0);
        expect(report.failures, isEmpty);
        expect(report.verdict, 'ACCEPTED');
        expect(report.unproven, hasLength(_items.length * 2 + 1));
        for (final os in ['linux', 'macos']) {
          for (final item in [..._items, if (os == 'macos') _finder]) {
            expect(report.unproven, contains('$_name $_version: $os: $item'));
          }
        }
      },
    );

    for (final os in _oses) {
      for (final value in ['fail', '', 'unknown']) {
        test('$os "$value" fails naming version OS and item', () {
          _fails(
            checkQualification(_oneCell(os, 'streaming', value), _source()),
            [_name, _version, os, 'streaming'],
          );
        });
      }
    }

    test('Windows unproven fails naming version OS and item', () {
      _fails(
        checkQualification(
          _oneCell('windows', 'launch', 'unproven'),
          _source(),
        ),
        [_version, 'windows', 'launch'],
      );
    });

    test('Linux agent item cannot be unproven', () {
      final text = _oneCell('linux', 'streaming', 'unproven').replaceFirst(
        '| streaming | user | unproven |',
        '| streaming | agent | unproven |',
      );
      _fails(checkQualification(text, _source()), [
        _version,
        'linux',
        'streaming',
      ]);
    });

    test('blank results fail even with an empty qualified list', () {
      _fails(checkQualification(' \n', _source(entries: '')), [
        'results',
        'blank',
      ]);
    });

    test('listed pair with no section fails naming version OS and item', () {
      _fails(checkQualification('# No observations\n', _source()), [
        _name,
        _version,
        'windows',
        'launch',
      ]);
    });

    test('missing baseline row fails naming version OS and item', () {
      _fails(
        checkQualification(
          _results(
            omit: (os, item) => os == 'linux' && item == 'permission request',
          ),
          _source(),
        ),
        [_version, 'linux', 'permission request'],
      );
    });

    test(
      'the macOS Finder/Dock item is recorded pass or unproven (user-verified)',
      () {
        for (final value in ['pass', 'unproven']) {
          final report = checkQualification(
            _oneCell('macos', _finder, value),
            _source(),
          );
          expect(report.failures, isEmpty);
          expect(report.verdict, value == 'pass' ? 'QUALIFIED' : 'ACCEPTED');
          if (value == 'unproven') {
            expect(report.unproven, ['$_name $_version: macos: $_finder']);
          }
        }
      },
    );

    test('missing Finder/Dock row fails naming version OS and item', () {
      _fails(
        checkQualification(
          _results(omit: (os, item) => item == _finder),
          _source(),
        ),
        [_version, 'macos', _finder],
      );
    });

    test('auth pass requires both observed code and message', () {
      for (final cells in [
        '| | fixture sign-in required |',
        '| -32000 | |',
        '| | |',
      ]) {
        final text = _results().replaceFirst(
          '| -32000 | fixture sign-in required |',
          cells,
        );
        _fails(checkQualification(text, _source()), [
          _version,
          'windows',
          'auth-required observed',
          'code',
          'message',
        ]);
      }
    });

    for (final capability in ['load', 'resume']) {
      test('claimed $capability needs its own passing evidence', () {
        _fails(
          checkQualification(
            _oneCell('windows', capability, 'fail'),
            _source(),
          ),
          [_version, 'windows', capability],
        );
        _fails(
          checkQualification(
            _results(omit: (os, item) => os == 'macos' && item == capability),
            _source(),
          ),
          [_version, 'macos', capability],
        );
      });
    }

    test('unclaimed load and resume failures or unproven do not block other claims', () {
      final source = _source(entries: "('$_name', '$_version', <String>[]),");
      final report = checkQualification(
        _results(
          result: (os, item) {
            if (item == 'load') return 'fail';
            if (item == 'resume') return 'unproven';
            return 'pass';
          },
        ),
        source,
      );
      expect(report.failures, isEmpty);
      expect(report.verdict, 'QUALIFIED');
      expect(report.unproven, isEmpty);
    });

    test('unclaimed load failure does not block a resume claim', () {
      final report = checkQualification(
        _results(result: (os, item) => item == 'load' ? 'fail' : 'pass'),
        _source(entries: "('$_name', '$_version', <String>['resume']),"),
      );
      expect(report.failures, isEmpty);
      expect(report.verdict, 'QUALIFIED');
    });

    test('duplicate item rows fail naming version OS and item', () {
      const row =
          '| streaming | user | pass | synthetic fixture observation |  |  |';
      _fails(
        checkQualification(
          _results().replaceFirst(row, '$row\n$row'),
          _source(),
        ),
        [_version, 'windows', 'streaming', 'duplicate'],
      );
    });

    test('duplicate OS sections fail naming version OS and section item', () {
      _fails(checkQualification('${_results()}\n### macos\n', _source()), [
        _version,
        'macos',
        'section',
        'duplicate',
      ]);
    });

    test('duplicate adapter sections fail instead of merging evidence', () {
      _fails(checkQualification('${_results()}\n${_results()}', _source()), [
        _name,
        _version,
        'section',
        'duplicate',
      ]);
    });

    test('unknown item fails naming version OS and item', () {
      _fails(
        checkQualification(
          _results().replaceFirst('| launch |', '| typo |'),
          _source(),
        ),
        [_version, 'windows', 'typo'],
      );
    });

    test('unknown OS fails naming version OS and section item', () {
      _fails(
        checkQualification(
          _results().replaceFirst('### windows', '### other'),
          _source(),
        ),
        [_version, 'other', 'section'],
      );
    });

    test(
      'malformed table and unknown kind fail naming version OS and item',
      () {
        for (final replacement in [
          '| launch | user | pass | extra |',
          '| launch | robot | pass |',
        ]) {
          _fails(
            checkQualification(
              _results().replaceFirst('| launch | user | pass |', replacement),
              _source(),
            ),
            [_version, 'windows', 'launch'],
          );
        }
      },
    );

    test('CRLF results and source have the same meaning', () {
      final report = checkQualification(
        _results().replaceAll('\n', '\r\n'),
        _source().replaceAll('\n', '\r\n'),
      );
      expect(report.failures, isEmpty);
      expect(report.verdict, 'QUALIFIED');
    });

    test('every exact listed pair requires its own evidence', () {
      final source = _source(
        entries:
            "('$_name', '$_version', <String>['load']),\n"
            "('$_name', '2.0.0', <String>['resume']),",
      );
      _fails(checkQualification(_results(), source), [
        _name,
        '2.0.0',
        'windows',
        'launch',
      ]);
      final report = checkQualification(
        '${_results()}\n${_results(version: '2.0.0')}',
        source,
      );
      expect(report.failures, isEmpty);
      expect(report.verdict, 'QUALIFIED');
      _fails(checkQualification(_results(name: 'other-acp'), _source()), [
        _name,
        _version,
        'windows',
        'launch',
      ]);
    });

    test(
      'missing qualified source fails instead of becoming an empty list',
      () {
        _fails(checkQualification(_results(), null), ['source', 'missing']);
      },
    );

    test('unrecognised qualified source fails closed', () {
      _fails(
        checkQualification(
          _results(),
          'const qualifiedAdapters = someOtherList;',
        ),
        ['source', 'unrecognised'],
      );
    });

    test('empty qualified list reports NO CLAIMS and no adapter qualified', () {
      final report = checkQualification(
        '# Format template only\n',
        _source(entries: ''),
      );
      expect(report.exitCode, 0);
      expect(report.failures, isEmpty);
      expect(report.verdict, 'NO CLAIMS (no adapter qualified)');
      expect(report.verdict, isNot(contains('QUALIFIED')));
      expect(report.verdict, isNot(contains('ACCEPTED')));
    });

    test('fenced version templates never count as evidence', () {
      for (final fence in ['```', '~~~~']) {
        final text = '# Template\n\n${fence}markdown\n${_results()}$fence\n';
        _fails(checkQualification(text, _source()), [
          _name,
          _version,
          'windows',
          'launch',
        ]);
        final report = checkQualification(text, _source(entries: ''));
        expect(report.failures, isEmpty);
        expect(report.verdict, 'NO CLAIMS (no adapter qualified)');
      }
    });
  });

  group('kumiko tool call', () {
    const text = 'adapter ignored the kumiko entry';
    final observed = 'Real run; observed: "$text"; user confirmed fail.';

    test('missing kumiko tool call fails naming version, OS, item', () {
      for (final os in _oses) {
        _fails(
          checkQualification(
            _results(omit: (o, i) => o == os && i == _toolItem),
            _source(),
          ),
          [_name, _version, os, _toolItem],
        );
      }
    });

    test('linux and macOS tool call may be unproven, Windows may not', () {
      final report = checkQualification(
        _oneCell('linux', _toolItem, 'unproven'),
        _source(),
      );
      expect(report.failures, isEmpty);
      expect(report.verdict, 'ACCEPTED');
      expect(report.unproven, ['$_name $_version: linux: $_toolItem']);
      _fails(
        checkQualification(
          _oneCell('windows', _toolItem, 'unproven'),
          _source(),
        ),
        [_name, _version, 'windows', _toolItem],
      );
    });

    test('fail without observed text fails', () {
      for (final notes in [
        'synthetic fixture observation',
        'observed: ""',
        'observed:"$text"',
        'observed: $text',
      ]) {
        _fails(
          checkQualification(
            _toolFail('windows', notes),
            _source(failures: _failure(text)),
          ),
          [_name, _version, 'windows', _toolItem, 'observed'],
        );
      }
    });

    test('matched failure is QUALIFIED and printed', () {
      final report = checkQualification(
        _toolFailEverywhere(observed),
        _source(failures: _failure(text)),
      );
      expect(report.failures, isEmpty);
      expect(report.exitCode, 0);
      expect(report.verdict, 'QUALIFIED');
      expect(report.unproven, isEmpty);
      final dir = Directory.systemTemp.createTempSync('qualification_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final results = File.fromUri(dir.uri.resolve('results.md'))
        ..writeAsStringSync(_toolFailEverywhere(observed));
      final source = File.fromUri(dir.uri.resolve('qualified_adapters.dart'))
        ..writeAsStringSync(_source(failures: _failure(text)));
      final out = StringBuffer();
      expect(runQualificationCheck([results.path, source.path], out: out), 0);
      expect(
        out.toString(),
        contains(
          'TOOL DELIVERY FAILURE RECORDED: $_name $_version windows: $text',
        ),
      );
      expect(out.toString(), contains('QUALIFIED'));
      expect(out.toString(), isNot(contains('FAILED')));
    });

    test('listed failure with unproven or missing on another OS fails', () {
      // A failure-list entry needs the observed failure on every OS: unproven
      // or missing evidence elsewhere fails, even though unproven is
      // otherwise allowed for the tool call on Linux and macOS.
      for (final os in ['linux', 'macos']) {
        _fails(
          checkQualification(
            _results(
              result: (o, i) =>
                  i == _toolItem ? (o == os ? 'unproven' : 'fail') : 'pass',
              notes: (o, i) =>
                  i == _toolItem && o != os ? observed : 'synthetic fixture',
            ),
            _source(failures: _failure(text)),
          ),
          [_name, _version, os, _toolItem, 'unproven'],
        );
        _fails(
          checkQualification(
            _results(
              result: (o, i) => i == _toolItem ? 'fail' : 'pass',
              notes: (o, i) => i == _toolItem ? observed : 'synthetic fixture',
              omit: (o, i) => i == _toolItem && o == os,
            ),
            _source(failures: _failure(text)),
          ),
          [_name, _version, os, _toolItem, 'missing'],
        );
      }
    });

    test('unlisted fail fails', () {
      for (final failures in ['', _failure(text, version: '9.9.9')]) {
        _fails(
          checkQualification(
            _toolFail('windows', observed),
            _source(failures: failures),
          ),
          [_name, _version, 'windows', _toolItem],
        );
      }
    });

    test('list entry with pass or different text fails', () {
      // pass
      _fails(
        checkQualification(_results(), _source(failures: _failure(text))),
        [_name, _version, 'windows'],
      );
      // unproven everywhere it is allowed
      _fails(
        checkQualification(
          _results(
            result: (o, i) =>
                i == _toolItem && o != 'windows' ? 'unproven' : 'pass',
          ),
          _source(failures: _failure(text)),
        ),
        [_name, _version, 'windows'],
      );
      // missing evidence
      _fails(
        checkQualification(
          _results(omit: (o, i) => i == _toolItem),
          _source(failures: _failure(text)),
        ),
        [_name, _version, 'windows', _toolItem],
      );
      // different text
      _fails(
        checkQualification(
          _toolFail('windows', observed),
          _source(failures: _failure('some other failure')),
        ),
        [_name, _version, 'windows', _toolItem],
      );
      // a matching failure on one OS does not excuse a pass on another
      for (final os in ['linux', 'macos']) {
        _fails(
          checkQualification(
            _results(
              result: (o, i) => i == _toolItem && o != os ? 'fail' : 'pass',
              notes: (o, i) =>
                  i == _toolItem && o != os ? observed : 'synthetic fixture',
            ),
            _source(failures: _failure(text)),
          ),
          [_name, _version, os, _toolItem],
        );
      }
    });

    test('toolDeliveryFailures literal accepts spaces and an empty list', () {
      expect(
        checkQualification(_results(), _source(failures: '')).failures,
        isEmpty,
      );
      expect(
        checkQualification(
          _toolFailEverywhere(observed),
          _source(failures: '// recorded\n${_failure(text)}\n'),
        ).verdict,
        'QUALIFIED',
      );
    });

    test('missing toolDeliveryFailures literal fails the checker', () {
      _fails(checkQualification(_results(), _source(failures: null)), [
        'source',
        'toolDeliveryFailures',
      ]);
    });

    test('unparseable toolDeliveryFailures literal fails the checker', () {
      for (final failures in [
        "('$_name', '$_version'),",
        "('$_name', '$_version', 'it\\'s'),",
        "('$_name', '$_version', 'it's'),",
        "('$_name', '$_version', 'a\\\\b'),",
        "('$_name', '$_version', 'two\nlines'),",
        "('$_name', '$_version', ''),",
        "('$_name', '$_version', 'a' + 'b'),",
        _failure(text) + _failure(text),
      ]) {
        _fails(checkQualification(_results(), _source(failures: failures)), [
          'source',
          'toolDeliveryFailures',
        ]);
      }
      for (final source in [
        'const qualifiedAdapters = <(String, String, List<String>)>[];\n'
            'const toolDeliveryFailures = someList;\n',
        'const qualifiedAdapters = <(String, String, List<String>)>[];\n'
            'const toolDeliveryFailures = <(String, String, String)>[];\n'
            'const extra = 1;\n',
      ]) {
        _fails(checkQualification(_results(), source), [
          'source',
          'toolDeliveryFailures',
        ]);
      }
    });
  });

  test('CLI smoke: empty list exits zero with NO CLAIMS', () {
    final dir = Directory.systemTemp.createTempSync('qualification_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final results = File.fromUri(dir.uri.resolve('results.md'))
      ..writeAsStringSync('# Format template only\n');
    final source = File.fromUri(dir.uri.resolve('qualified_adapters.dart'))
      ..writeAsStringSync(_source(entries: ''));
    final result = Process.runSync(Platform.resolvedExecutable, [
      'run',
      'tool/check_qualification.dart',
      results.path,
      source.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('NO CLAIMS (no adapter qualified)'));
    expect(result.stdout, isNot(contains('QUALIFIED')));
    expect(result.stdout, isNot(contains('ACCEPTED')));
  });
}
