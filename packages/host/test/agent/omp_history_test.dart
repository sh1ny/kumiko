import 'dart:convert';
import 'dart:io';

import 'package:host/src/agent/omp/omp_client.dart';
import 'package:host/src/agent/omp/omp_driver.dart';
import 'package:host/src/agent/omp/omp_session_file.dart';
import 'package:host/src/agent/runtime_driver.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

import 'support/omp_peer.dart';

void main() {
  final file = p.join(
    Directory.systemTemp.absolute.path,
    'saved-native-session.jsonl',
  );
  Json state({String id = 'saved', String? path}) => {
    'sessionId': id,
    'sessionFile': path ?? file,
    'isSettled': true,
    'hasPendingAsyncWork': false,
  };

  late OmpPeer peer;
  late OmpRuntimeDriver driver;
  late List<Json> events;
  late int nextCommand;

  Future<Json> next(String type) async {
    final command = await peer.commandAt(nextCommand++);
    expect(command['type'], type);
    return command;
  }

  Future<void> respond(String type, [Json? data]) async {
    peer.result((await next(type))['id']! as String, data);
  }

  setUp(() async {
    peer = OmpPeer();
    addTearDown(peer.dispose);
    driver = OmpRuntimeDriver(peer.client, '18.20.1', runId: 'test-run');
    nextCommand = 0;
    events = [];
    driver.consumeNotification = (value) {
      final delivery = value as RuntimeDelivery;
      events.addAll(
        delivery.lines.map((line) => jsonDecode(utf8.decode(line)) as Json),
      );
    };
    final starting = driver.initialize();
    peer.send({
      'type': 'ready',
      'supportedProtocolVersions': [1],
    });
    await respond('set_event_filter');
    await starting;
  });

  for (final changedState in [state(id: 'other'), state(path: '$file.other')]) {
    test(
      'OMP: Mismatched native identity refuses before history or tool registration (${changedState['sessionId']})',
      () async {
        final reopened = driver.prepareContinue('saved', file);
        final refusal = expectLater(
          reopened,
          throwsA(isA<OmpProtocolException>()),
        );
        await respond('get_state', changedState);
        await refusal;
        expect(peer.writes.map((command) => command['type']), [
          'set_event_filter',
          'get_state',
        ]);
        expect(events, isEmpty);
      },
    );
  }

  for (final historyFailure in [
    'stale_cursor',
    'v1 overflow',
    'repeated cursor',
    'changed count',
  ]) {
    test(
      'OMP: Invalid or oversized history stages no partial replay ($historyFailure)',
      () async {
        final reopened = driver.prepareContinue('saved', file);
        await respond('get_state', state());
        await respond('get_messages_page', {
          'messages': [
            {'role': 'user', 'content': 'must not be shown'},
          ],
          'totalMessages': 3,
          'nextCursor': 'cursor',
        });
        final second = await next('get_messages_page');
        expect(second['cursor'], 'cursor');
        final id = second['id']! as String;
        if (historyFailure == 'stale_cursor' ||
            historyFailure == 'v1 overflow') {
          peer.send({
            'type': 'response',
            'id': id,
            'success': false,
            'error': historyFailure == 'stale_cursor'
                ? 'stale'
                : 'RPC response exceeded the transport limit',
            if (historyFailure == 'stale_cursor') 'code': 'stale_cursor',
          });
        } else {
          peer.result(id, {
            'messages': [
              {'role': 'user', 'content': 'not a valid second page'},
            ],
            'totalMessages': historyFailure == 'changed count' ? 2 : 3,
            'nextCursor': 'cursor',
          });
        }
        await respond('get_state', state());
        expect(await reopened, AgentContinueMode.resume);
        await driver.resumeSession('saved', Directory.systemTemp.path);
        expect(
          events.single['text'],
          startsWith('earlier messages not shown:'),
        );
        expect(events.single['text'], isNot(contains('must not be shown')));
        expect(peer.client.isClosed, isFalse);
      },
    );
  }

  test(
    'OMP: Active native work invalidates an otherwise complete snapshot',
    () async {
      final reopened = driver.prepareContinue('saved', file);
      await respond('get_state', state());
      final page = await next('get_messages_page');
      peer.send({'type': 'agent_start'});
      peer.result(page['id']! as String, {
        'messages': <Object?>[],
        'totalMessages': 0,
      });
      await respond('get_state', state());
      expect(await reopened, AgentContinueMode.resume);
    },
  );

  group('OMP Continue profile arguments', () {
    test('preserves passive profile flags including joined values', () {
      expect(
        supportsOmpContinue([
          '--mode=rpc',
          '--model',
          'my-model',
          '--provider=name',
          '--no-context-files',
          '--approval-mode=write',
        ]),
        isTrue,
      );
    });
    for (final unsupported in [
      ['--continue'],
      ['--resume', file],
      ['--fork', file],
      ['--mode=rpc'],
      ['--no-session'],
      ['--cwd', 'another-target'],
      ['--'],
      ['prompt'],
      ['--unknown'],
      ['--config'],
      ['--config='],
      ['--config', '--offline'],
    ]) {
      test('refuses target or session overrides: ${unsupported.first}', () {
        expect(supportsOmpContinue(['--mode', 'rpc', ...unsupported]), isFalse);
      });
    }
  });

  test('OMP: Bounded native header refuses wrong id, cwd, empty and incomplete files', () async {
    final work = Directory.systemTemp.createTempSync('kumiko_omp_header_');
    addTearDown(() => work.deleteSync(recursive: true));
    final other = Directory(p.join(work.path, 'other'))..createSync();
    final localFile = File(p.join(work.path, 'history.jsonl'));
    final target = (directoryIdentity(work.path) as ResolvedDirectory).id;
    Future<String?> probe() =>
        probeOmpSessionFile(localFile.path, 'native', target);
    Json header(String id, String cwd) => {
      'type': 'session',
      'id': id,
      'cwd': cwd,
    };
    expect(await probe(), ompLocatorUnavailable);
    for (final data in [
      '',
      jsonEncode(header('native', work.path)),
      '${'x' * 8192}\n',
    ]) {
      localFile.writeAsStringSync(data);
      expect(await probe(), ompLocatorUnavailable);
    }
    for (final data in [
      header('different', work.path),
      header('native', other.path),
    ]) {
      localFile.writeAsStringSync('${jsonEncode(data)}\n');
      expect(await probe(), ompLocatorMismatch);
    }
    localFile.writeAsStringSync('${jsonEncode(header('native', work.path))}\n');
    expect(await probe(), isNull);
  });
}
