import 'dart:io';

import 'package:test/test.dart';

import 'it/support/harness.dart';

void main() {
  test('only renamed, complete fixture reports are read', () {
    final dir = tempDir('reports_');
    addTearDown(() => deleteTree(dir));
    void write(String name, String text) =>
        File(joinPath(dir.path, name)).writeAsStringSync(text);
    write('${fixtureReportPrefix}11$fixtureReportSuffix', 'tree 11 22 m 33\n');
    write('${fixtureReportPrefix}12$fixtureReportSuffix', 'child 12 23 m 33\n');
    // Still being written: not renamed yet, or no line end yet.
    write('${fixtureReportPrefix}13.tmp', 'child 13 24 m 33\n');
    write('${fixtureReportPrefix}14$fixtureReportSuffix', 'child 14 2');

    final reports = readReports(dir);

    expect(reports.map((r) => r.pid).toList()..sort(), [11, 12]);
  });
}
