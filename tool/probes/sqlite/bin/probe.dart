// Throwaway SQLite binding probe (task 1.1). Not shipped.
//
//   probe info            prints the compile-time define and the SQLite version
//   probe write <db>      WAL + synchronous=FULL, commits batches forever and
//                         prints "committed <max id>" after each commit
//   probe check <db>      prints journal mode, integrity and max id
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

const probeDefine = String.fromEnvironment(
  'probe.define',
  defaultValue: 'unset',
);

void main(List<String> args) {
  switch (args) {
    case ['info']:
      stdout.writeln('define=$probeDefine');
      stdout.writeln('sqlite=${sqlite3.version.libVersion}');
    case ['write', final path]:
      final db = sqlite3.open(path);
      final journal = db.select('PRAGMA journal_mode=WAL').first.values.first;
      db.execute('PRAGMA synchronous=FULL');
      final sync = db.select('PRAGMA synchronous').first.values.first;
      db.execute(
        'CREATE TABLE IF NOT EXISTS t(id INTEGER PRIMARY KEY, payload BLOB)',
      );
      stdout.writeln('journal=$journal synchronous=$sync');
      final insert = db.prepare('INSERT INTO t(payload) VALUES (?)');
      final blob = Uint8List(4096);
      while (true) {
        db.execute('BEGIN');
        for (var i = 0; i < 50; i++) {
          insert.execute([blob]);
        }
        db.execute('COMMIT');
        final max = db.select('SELECT max(id) FROM t').first.values.first;
        stdout.writeln('committed $max');
      }
    case ['check', final path]:
      final db = sqlite3.open(path);
      final journal = db.select('PRAGMA journal_mode').first.values.first;
      final integrity = db.select('PRAGMA integrity_check').first.values.first;
      final max = db.select('SELECT max(id) FROM t').first.values.first;
      stdout.writeln('journal=$journal integrity=$integrity max=$max');
      db.close();
    default:
      stderr.writeln('usage: probe info | write <db> | check <db>');
      exitCode = 64;
  }
}
