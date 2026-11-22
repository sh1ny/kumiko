import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/omp_support.dart';

void main() {
  setUpAll(buildTestHost);

  test('scripted OMP fixture reports version, command, cwd and EOF', () async {
    final profile = tempDir('omp_fixture_profile');
    final work = tempDir('omp_fixture_work');
    addTearDown(() => deleteTree(profile));
    addTearDown(() => deleteTree(work));
    final fixture = OmpFixture(
      profile,
      work,
      script: {
        'versionOutput': 'omp/19.1.2',
        'commands': {
          'prompt': [
            [
              {
                'type': 'prompt_result',
                'id': r'$prompt',
                'status': 'completed',
              },
              {'type': 'response', 'id': r'$id', 'success': true},
            ],
          ],
        },
      },
    )..writeScript();
    final probe = await Process.run(testHostExecutable(), [
      ...fixture.argv,
      '--version',
    ], workingDirectory: profile.path);
    expect(probe.exitCode, 0);
    expect((probe.stdout as String).trim(), 'omp/19.1.2');

    final root = await Process.start(
      testHostExecutable(),
      fixture.argv,
      workingDirectory: work.path,
      environment: {'OMP_PARENT_CANARY': 'smoke'},
    );
    var exited = false;
    addTearDown(() async {
      if (!exited) root.kill(ProcessSignal.sigkill);
      await root.exitCode;
    });
    final stderr = root.stderr.transform(utf8.decoder).join();
    final output = StreamIterator(
      root.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    addTearDown(output.cancel);
    Future<Json> frame() async {
      expect(await output.moveNext(), isTrue);
      return jsonDecode(output.current) as Json;
    }

    expect((await frame())['type'], 'ready');
    root.stdin.writeln('{"type":"prompt","id":"k7","message":"smoke"}');
    await root.stdin.flush();
    expect(await frame(), {
      'type': 'prompt_result',
      'id': 'k7',
      'status': 'completed',
    });
    expect(await frame(), {'type': 'response', 'id': 'k7', 'success': true});
    await root.stdin.close();
    expect(await output.moveNext(), isFalse);
    final exitCode = await root.exitCode;
    exited = true;
    expect(exitCode, 0, reason: await stderr);
    final reports = fixture.reports;
    expect(reports.map((row) => row['launch']).whereType<String>(), [
      'probe',
      'root',
    ]);
    expect(
      Directory(reports[1]['cwd']! as String).resolveSymbolicLinksSync(),
      work.resolveSymbolicLinksSync(),
    );
    expect(reports[1]['parentCanary'], 'smoke');
    expect(reports[1]['argv'], fixture.argv);
    expect(fixture.commands.single['id'], 'k7');
    expect(reports.last['stdin'], 'eof');
  });
}
