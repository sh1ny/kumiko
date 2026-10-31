import 'dart:async';

import 'package:host/src/agent/acp/acp_client.dart';
import 'package:host/src/test_hooks/acp_agent_fixture.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

void main() {
  Future<void> withFixture(
    Json script,
    Future<void> Function(AcpClient, List<Json>, List<String>) body,
  ) async {
    final input = StreamController<List<int>>();
    final output = StreamController<List<int>>();
    final reports = <Json>[];
    final errors = <String>[];
    final run = runAcpAgentScript(
      script: script,
      args: ['space arg', ''],
      input: input.stream,
      write: (bytes) async {
        output.add(bytes);
      },
      writeError: errors.add,
      report: reports.add,
      environment: {'EXPLICIT': 'yes', 'SECRET': 'never report'},
      cwd: '/fixture',
    );
    run.whenComplete(() => output.close()).ignore();
    final client = AcpClient(
      input: output.stream,
      write: (bytes) async {
        input.add(bytes);
      },
    );
    try {
      await body(client, reports, errors);
    } finally {
      await client.close();
      await input.close();
      await run;
      await output.close();
    }
  }

  test('script fixture speaks initialize new streamed updates permission and prompt completion', () async {
    await withFixture(
      {
        'agentInfo': {'name': 'script', 'version': 'test'},
        'reportEnv': ['EXPLICIT'],
        'reportLaunch': true,
        'prompt': [
          {
            'update': {
              'sessionUpdate': 'tool_call',
              'toolCallId': 't',
              'title': 'Run',
            },
          },
          {
            'permission': {
              'toolCall': {'toolCallId': 't'},
              'options': [
                {'optionId': 'opaque', 'name': 'Allow', 'kind': 'allow_once'},
              ],
            },
          },
          {
            'update': {
              'sessionUpdate': 'agent_message_chunk',
              'content': {'type': 'text', 'text': 'canary'},
            },
          },
          {'stderr': 'canary'},
        ],
      },
      (client, reports, errors) async {
        final updates = <Json>[];
        client.normalizeNotification = (_, p) {
          updates.add(p);
          return null;
        };
        client.onPermissionRequest = (id, params) {
          client.reply(id, {
            'outcome': {'outcome': 'selected', 'optionId': 'opaque'},
          }).ignore();
          return null;
        };
        expect((await client.initialize()).adapterName, 'script');
        expect(await client.newSession('/fixture'), 'fixture-native');
        expect(await client.prompt('fixture-native', 'hello'), 'end_turn');
        expect(updates, hasLength(2));
        expect(errors, ['canary']);
        expect(reports.first['argv'], ['space arg', '']);
        expect(reports.first['env'], {'EXPLICIT': 'yes'});
        expect(reports.last['permissionOutcome'], {
          'outcome': 'selected',
          'optionId': 'opaque',
        });
      },
    );
  });
  test(
    'script fixture load replays without prompt and resume does not replay',
    () async {
      await withFixture(
        {
          'load': [
            {
              'update': {
                'sessionUpdate': 'user_message_chunk',
                'content': {'type': 'text', 'text': 'history'},
              },
            },
          ],
        },
        (client, reports, errors) async {
          var count = 0;
          client.normalizeNotification = (_, p) {
            count++;
            return null;
          };
          await client.loadSession('native', '/fixture');
          expect(count, 1);
          await client.resumeSession('native', '/fixture');
          expect(count, 1);
        },
      );
    },
  );
  for (final mode in ['honour', 'race']) {
    test('script fixture $mode cancel returns actual turn reason', () async {
      await withFixture({'cancel': mode, 'holdPrompt': true}, (
        client,
        reports,
        errors,
      ) async {
        final prompt = client.prompt('native', 'hello');
        await client.cancel('native');
        expect(await prompt, mode == 'honour' ? 'cancelled' : 'end_turn');
      });
    });
  }
  test(
    'script fixture ignore cancel does not invent a prompt result',
    () async {
      await withFixture({'cancel': 'ignore', 'holdPrompt': true}, (
        client,
        reports,
        errors,
      ) async {
        var answered = false;
        final prompt = client.prompt('native', 'hello');
        prompt.then<void>((_) {
          answered = true;
        }, onError: (Object _) {});
        await client.cancel('native');
        await Future<void>(() {});
        expect(reports, contains(containsPair('cancelReceived', true)));
        expect(answered, isFalse);
      });
    },
  );
  test(
    'script fixture engine exit before initialize reports status and stderr',
    () async {
      final errors = <String>[];
      final run = runAcpAgentScript(
        script: {
          'beforeInitializeExit': {
            'status': 1,
            'stderr': 'engine requires Node >=22',
          },
        },
        args: [],
        input: const Stream<List<int>>.empty(),
        write: (_) async {},
        writeError: errors.add,
        report: (_) {},
      );
      expect(await run, 1);
      expect(errors, ['engine requires Node >=22']);
    },
  );
  test(
    'script fixture unknown update precedes later text without ending turn',
    () async {
      await withFixture(
        {
          'prompt': [
            {
              'update': {'sessionUpdate': 'future'},
            },
            {
              'update': {
                'sessionUpdate': 'agent_message_chunk',
                'content': {'type': 'text', 'text': 'later'},
              },
            },
          ],
        },
        (client, reports, errors) async {
          final kinds = <Object?>[];
          client.normalizeNotification = (_, p) {
            kinds.add((p['update'] as Json)['sessionUpdate']);
            return null;
          };
          expect(await client.prompt('native', 'hello'), 'end_turn');
          expect(kinds, ['future', 'agent_message_chunk']);
        },
      );
    },
  );
  test(
    'script fixture synthetic auth error retains arbitrary code and message',
    () async {
      await withFixture(
        {
          'errors': {
            'session/new': {'code': -9876, 'message': 'synthetic only'},
          },
        },
        (client, reports, errors) async {
          await expectLater(
            client.newSession('/fixture'),
            throwsA(
              isA<AcpRemoteException>()
                  .having((e) => e.code, 'code', -9876)
                  .having((e) => e.message, 'message', 'synthetic only'),
            ),
          );
        },
      );
    },
  );
}
