import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'harness.dart';

const permissionAction = <String, Object?>{
  'permission': {
    'toolCall': {'toolCallId': 'tool-1', 'title': 'Change file'},
    'options': [
      {'optionId': 'yes', 'name': 'Allow once', 'kind': 'allow_once'},
      {'optionId': 'no', 'name': 'Reject', 'kind': 'reject_once'},
    ],
  },
};
Json textUpdate(String text) => {
  'sessionUpdate': 'agent_message_chunk',
  'content': {'type': 'text', 'text': text},
};

List<Json> agentRows(Directory profile) {
  final db = sqlite3.open(joinPath(profile.path, 'kumiko.db'), mode: OpenMode.readOnly);
  try {
    return [for (final row in db.select('SELECT * FROM agent_session ORDER BY rowid')) Map<String, Object?>.of(row)];
  } finally {
    db.close();
  }
}

/// One real contained adapter, not an in-memory transport or launch substitute.
class AgentPeer {
  AgentPeer(this.desktop) {
    subscription = desktop.session.notifications.listen((n) {
      if (n.method.startsWith('agent/')) notifications.add(n);
    });
    addTearDown(() async {
      await data?.cancel();
      await subscription.cancel();
    });
  }
  final Desktop desktop;
  final notifications = <HostNotification>[];
  final events = <Json>[];
  late final StreamSubscription<HostNotification> subscription;
  StreamSubscription<String>? data;
  late AgentStartResult started;
  String get id => started.sessionId;
  Future<Json> call(String method, [Json? params]) async =>
      (await desktop.connection.request(method, params ?? {'sessionId': id})) as Json;
  Future<AgentStartResult> start(String workspace, {String? runtime}) async {
    started = AgentStartResult.fromJson(await call(Method.agentStart, {
      'workspaceId': workspace,
      'runtimeProfileId': ?runtime,
    }));
    return started;
  }
  Future<void> attach({bool credit = true}) async {
    final stream = desktop.connection.attachInbound(started.eventChannel, grantInitial: false);
    data = stream.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      events.add(jsonDecode(line) as Json);
    });
    await call(Method.agentAttach);
    if (credit) desktop.connection.grantInitial(started.eventChannel);
  }
  List<Json> of(String method) => [
    for (final n in notifications)
      if (n.method == method && n.params['sessionId'] == id) n.params,
  ];
  Future<Json> wait(String method, {bool Function(Json)? where, Duration within = const Duration(seconds: 20)}) async {
    bool matches(Json p) => where?.call(p) ?? true;
    await eventually(() => of(method).any(matches), within: within, reason: 'no $method for $id');
    return of(method).lastWhere(matches);
  }
  Future<void> prompt([String text = 'hello']) async {
    await call(Method.agentPrompt, {'sessionId': id, 'text': text});
  }
  Future<void> close() async {
    await call(Method.agentClose);
    await wait(Method.agentExited, where: (p) => p['reason'] == 'closed');
  }
}

/// Scripts and fixture reports live in the workspace, outside Kumiko's private
/// profile. In particular conversation canaries never enter runtime/env_json.
Future<File> saveAgentFixture(Desktop d, Directory work, {
  String id = 'acp', Json script = const {}, List<String> args = const [],
  Map<String, String> env = const {}, String? executable,
}) async {
  final file = File(joinPath(work.path, '$id.script.json'));
  final report = File(joinPath(work.path, '$id.report.jsonl'));
  file.writeAsStringSync(jsonEncode({'reportFile': report.path, ...script}));
  await d.connection.request(Method.runtimeSave, RuntimeSaveParams(RuntimeProfile(
    id: id, name: 'Scripted $id', runtimeKind: 'claude-code',
    executable: executable ?? testHostExecutable(),
    args: ['--test-fixture', 'acp-agent', '--script', file.path, ...args],
    env: env,
  )));
  return report;
}
List<Json> fixtureReports(File file) => file.existsSync()
    ? [for (final line in file.readAsLinesSync()) if (line.isNotEmpty) jsonDecode(line) as Json]
    : [];
Future<Json> waitFixture(File report, bool Function(Json) test) async {
  await eventually(() => fixtureReports(report).any(test), reason: 'fixture report missing: ${report.path}');
  return fixtureReports(report).lastWhere(test);
}
Matcher rpcCode(String reason) => throwsA(isA<RpcException>().having((e) => e.reason, 'reason', reason));
