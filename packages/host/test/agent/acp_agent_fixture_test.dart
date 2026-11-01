import 'dart:async';
import 'dart:convert';

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
        expect(
          (await client.prompt('fixture-native', 'hello')).stopReason,
          'end_turn',
        );
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
        final result = await prompt;
        expect(result.stopReason, mode == 'honour' ? 'cancelled' : 'end_turn');
        expect(result.isCancelled, mode == 'honour');
        expect(result.truncated, isFalse);
      });
    });
  }
  for (final waitPermission in [true, false]) {
    for (final responseFirst in [true, false]) {
      test('script fixture records coalesced permission response and cancel in '
          'wire order (waitPermission: $waitPermission, '
          'responseFirst: $responseFirst)', () async {
        final input = StreamController<List<int>>();
        final permissionWritten = Completer<Json>();
        final releasePermissionWrite = Completer<void>();
        final cancelReceived = Completer<void>();
        final promptResult = Completer<Json>();
        final reports = <Json>[];
        final errors = <String>[];
        final run = runAcpAgentScript(
          script: {
            'prompt': [
              {
                'permission': {
                  'toolCall': {'toolCallId': 't'},
                  'options': [
                    {
                      'optionId': 'opaque',
                      'name': 'Allow',
                      'kind': 'allow_once',
                    },
                  ],
                },
                'waitPermission': waitPermission,
              },
            ],
            'holdPrompt': true,
          },
          args: [],
          input: input.stream,
          write: (bytes) async {
            final message = jsonDecode(utf8.decode(bytes)) as Json;
            if (message['method'] == 'session/request_permission') {
              permissionWritten.complete(message);
              // A peer can reply after receiving the bytes but before the
              // fixture's asynchronous write/flush has completed.
              await releasePermissionWrite.future;
            } else if (message['id'] == 'prompt') {
              promptResult.complete(message['result'] as Json);
            }
          },
          writeError: errors.add,
          report: (value) {
            reports.add(value);
            if (value['cancelReceived'] == true) {
              cancelReceived.complete();
            }
          },
        );
        try {
          input.add(
            utf8.encode(
              '${jsonEncode({
                'jsonrpc': '2.0',
                'id': 'prompt',
                'method': 'session/prompt',
                'params': {'sessionId': 'native', 'prompt': <Object?>[]},
              })}\n',
            ),
          );
          final permission = await permissionWritten.future;
          final response = {
            'jsonrpc': '2.0',
            'id': permission['id'],
            'result': {
              'outcome': {'outcome': 'cancelled'},
            },
          };
          final cancel = {
            'jsonrpc': '2.0',
            'method': 'session/cancel',
            'params': {'sessionId': 'native'},
          };
          final messages = responseFirst
              ? [response, cancel]
              : [cancel, response];
          // One input chunk, not separate stream events or timed writes.
          input.add(utf8.encode('${messages.map(jsonEncode).join('\n')}\n'));
          await cancelReceived.future;
          releasePermissionWrite.complete();
          expect(await promptResult.future, {'stopReason': 'cancelled'});
          final observations = reports.where(
            (value) =>
                value.containsKey('permissionOutcome') ||
                value.containsKey('cancelReceived'),
          );
          final outcome = {
            'permissionOutcome': {'outcome': 'cancelled'},
          };
          final cancellation = {'cancelReceived': true};
          expect(
            observations,
            responseFirst ? [outcome, cancellation] : [cancellation, outcome],
          );
          expect(errors, isEmpty);
        } finally {
          if (!releasePermissionWrite.isCompleted) {
            releasePermissionWrite.complete();
          }
          await input.close();
          expect(await run, 0);
        }
      });
    }
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
  test('script fixture closes stdout but keeps handling stdin until containment ends', () async {
    final input = StreamController<List<int>>();
    final output = StreamController<List<int>>();
    final cancelReceived = Completer<void>();
    final errors = <String>[];
    var finished = false;
    final run =
        runAcpAgentScript(
          script: {
            'prompt': [
              {'closeStdout': true},
            ],
          },
          args: [],
          input: input.stream,
          write: (bytes) async => output.add(bytes),
          closeOutput: output.close,
          writeError: errors.add,
          report: (value) {
            if (value['cancelReceived'] == true) cancelReceived.complete();
          },
        ).then((status) {
          finished = true;
          return status;
        });
    final client = AcpClient(
      input: output.stream,
      write: (bytes) async => input.add(bytes),
    );
    final prompt = client
        .prompt('native', 'pending')
        .then<Object?>((_) => null, onError: (Object error) => error);
    try {
      expect(await prompt, isA<AcpClosedException>());
      expect(finished, isFalse);
      input.add(
        utf8.encode(
          '${jsonEncode({
            'jsonrpc': '2.0',
            'method': 'session/cancel',
            'params': {'sessionId': 'native'},
          })}\n',
        ),
      );
      await cancelReceived.future;
      expect(finished, isFalse);
      expect(errors, isEmpty);
    } finally {
      await client.close();
      await input.close();
      expect(await run, 0);
      await output.close();
    }
  });

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
          expect(
            (await client.prompt('native', 'hello')).stopReason,
            'end_turn',
          );
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
