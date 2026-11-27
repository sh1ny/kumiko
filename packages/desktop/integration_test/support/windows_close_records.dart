import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sql;

({int pid, String? exitKind, int agentCount}) readCloseRecords(Directory root) {
  final db = sql.sqlite3.open(
    File.fromUri(root.uri.resolve('profile/kumiko.db')).path,
    mode: sql.OpenMode.readOnly,
  );
  try {
    final host = db
        .select('SELECT host_pid, exit_kind FROM host_instance')
        .single;
    final units = db.select(
      "SELECT COUNT(*) AS n FROM unit WHERE kind='agent'",
    );
    return (
      pid: host['host_pid'] as int,
      exitKind: host['exit_kind'] as String?,
      agentCount: units.single['n'] as int,
    );
  } finally {
    db.close();
  }
}
