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
];
const _finder = 'launch from Finder or the Dock';
const _oses = <String>['windows', 'linux', 'macos'];

String _source({
  String entries = "('$_name', '$_version', <String>['load', 'resume']),",
}) =>
    'const qualifiedAdapters = <(String, String, List<String>)>[\n$entries\n];\n';

String _results({
  String name = _name,
  String version = _version,
  String Function(String os, String item)? result,
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
        'synthetic fixture observation | ${auth ? '-32000' : ''} | '
        '${auth ? 'fixture sign-in required' : ''} |',
      );
    }
  }
  return out.toString();
}

String _oneCell(String os, String item, String value) =>
    _results(result: (o, i) => o == os && i == item ? value : 'pass');

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
