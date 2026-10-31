import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/bar/vttest.dart';

/// The vttest fixtures the bar judges against (task 6.10): every judged
/// screen has an expected grid and no screen outside the bar has one, so a
/// lost fixture cannot quietly narrow the subset.
void main() {
  final fixtures = Directory('integration_test/bar/vttest');

  test('the screens outside the bar are the six named ones', () {
    expect(vttestOutsideBar, {'1.2', '1.4', '2.3', '2.4', '2.5', '2.14'});
  });

  test('the checked-in fixtures match the judged screens', () {
    expect(vttestFixtureProblems(fixtures), isEmpty);
  });

  group('a copy of the fixtures', () {
    late Directory copy;

    setUp(() {
      copy = Directory.systemTemp.createTempSync('vttest_fixtures');
      for (final f in fixtures.listSync().whereType<File>()) {
        f.copySync('${copy.path}/${f.uri.pathSegments.last}');
      }
    });

    tearDown(() => copy.deleteSync(recursive: true));

    test('without a judged grid fails, naming the screen', () {
      File('${copy.path}/2.7.txt').deleteSync();
      expect(vttestFixtureProblems(copy), [contains('2.7')]);
      expect(() => ExpectedScreen.load(copy, '2.7'), throwsStateError);
    });

    test('with a grid for a screen outside the bar fails', () {
      File('${copy.path}/2.7.txt').copySync('${copy.path}/1.2.txt');
      expect(vttestFixtureProblems(copy), [contains('1.2')]);
    });

    test('loads no grid for a screen outside the bar', () {
      expect(ExpectedScreen.load(copy, '1.2'), isNull);
    });
  });
}
