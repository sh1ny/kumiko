import 'dart:convert';
import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:test/test.dart';

import 'agent_support.dart';
import 'harness.dart';

/// The wire calls of the draft store, as a desktop makes them.
class Drafts {
  Drafts(this.desktop);
  final Desktop desktop;

  Future<AgentDraftSaveResult> save(
    String id,
    String text,
    int revision,
  ) async => AgentDraftSaveResult.fromJson(
    (await desktop.connection.request(
          Method.agentDraftSave,
          AgentDraftSaveParams(
            sessionId: id,
            text: text,
            revision: revision,
          ).toJson(),
        ))!
        as Json,
  );

  Future<AgentDraftLoadResult> load(String id) async =>
      AgentDraftLoadResult.fromJson(
        (await desktop.connection.request(
              Method.agentDraftLoad,
              AgentSessionParams(id).toJson(),
            ))!
            as Json,
      );

  Future<void> reset() async {
    await desktop.connection.request(
      Method.agentDraftReset,
      <String, Object?>{},
    );
  }

  /// A composer send: the prompt carries the revision being sent.
  Future<void> send(
    AgentPeer a,
    String text, {
    int? revision,
    bool? synced,
  }) async {
    await desktop.connection.request(
      Method.agentPrompt,
      AgentPromptParams(
        sessionId: a.id,
        text: text,
        draftRevision: revision,
        draftSynced: synced,
      ).toJson(),
    );
  }

  /// The host's draft store state, from the test hook.
  Future<Json> stats() async =>
      (await desktop.connection.request('test/draft.stats'))! as Json;
}

/// The [RpcException] [call] fails with; fails the test if it succeeds.
Future<RpcException> refusal(Future<Object?> call) async {
  try {
    await call;
  } on RpcException catch (e) {
    return e;
  }
  fail('the call succeeded');
}

/// The profile files whose bytes contain [needle], by name: the stores, their
/// journals, the logs, everything. The profile lock is skipped while the host
/// runs, because Windows denies reads of its range-locked file.
List<String> filesContaining(
  Directory profile,
  String needle, {
  required bool hostRunning,
}) {
  final lock = joinPath(profile.path, 'kumiko.lock');
  final found = <String>[];
  for (final entry
      in profile
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()) {
    if (hostRunning && entry.path == lock) continue;
    if (FileSystemEntity.typeSync(entry.path, followLinks: false) ==
        FileSystemEntityType.unixDomainSock) {
      continue;
    }
    final String text;
    try {
      text = latin1.decode(entry.readAsBytesSync());
    } on FileSystemException {
      continue; // a journal deleted between the listing and the read
    }
    if (text.contains(needle)) {
      found.add(entry.uri.pathSegments.last);
    }
  }
  return found..sort();
}

/// Inserts [count] session records (`seed-session-<n>`) into the main store.
/// No host may be running.
Future<List<String>> seedSessions(Directory profile, int count) async {
  final ids = [for (var i = 0; i < count; i++) 'seed-session-$i'];
  await withStore(profile, (store) {
    store.execute('BEGIN');
    for (final id in ids) {
      store.execute(
        'INSERT INTO agent_session(id, runtime_kind, runtime_profile_id, '
        'adapter_name, adapter_version, native_session_id, role, target_host, '
        'target_path, target_identity, workspace_id, created_at, updated_at) '
        "VALUES (?, 'claude-code', NULL, 'seed', '1', ?, 'coding', 'local', "
        "'/seed', 'seed:0', NULL, '2020-01-01T00:00:00.000Z', "
        "'2020-01-01T00:00:00.000Z')",
        [id, 'native-$id'],
      );
    }
    store.execute('COMMIT');
  });
  return ids;
}

File draftsFile(Directory profile) =>
    File(joinPath(profile.path, 'drafts.sqlite'));

/// The `draft` row of [session], read beside the running host; empty when
/// there is none.
Map<String, Object?> draftRow(Directory profile, String session) {
  final file = draftsFile(profile);
  if (!file.existsSync()) return {};
  final db = sql.sqlite3.open(file.path, mode: sql.OpenMode.readOnly);
  try {
    final rows = db.select('SELECT * FROM draft WHERE session_id = ?', [
      session,
    ]);
    return rows.isEmpty ? {} : Map.of(rows.single);
  } finally {
    db.close();
  }
}

/// The prompts the fixture adapter of [report] received.
List<Object?> receivedPrompts(File report) => [
  for (final p in fixtureReports(report))
    if (p.containsKey('prompt')) p['prompt'],
];
