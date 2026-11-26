import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:host_protocol/host_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:process_containment/process_containment.dart';

const ompLocatorUnavailable = 'omp-locator-unavailable';
const ompLocatorMismatch = 'omp-locator-mismatch';
const _headerBytes = 8 * 1024;
final _controls = RegExp(r'[\x00-\x1f]');
final _windowsDrive = RegExp(r'^[a-zA-Z]:[/\\]');
final _windowsDevice = RegExp(
  r'^(?:CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)',
  caseSensitive: false,
);

/// Native path syntax only. OMP can report a location before creating it.
String? ompSessionPath(Object? value) {
  if (value is! String ||
      !p.isAbsolute(value) ||
      value.length > 4096 ||
      jsonStringContentBytes(value) > 4096 ||
      _controls.hasMatch(value)) {
    return null;
  }
  final components = p.split(value).skip(1);
  // Lexically collapsing '..' through a symlink can change the file.
  if (components.contains('..')) return null;
  if (Platform.isWindows) {
    // Reject drive-relative paths, UNC/device names and alternate streams.
    if (!_windowsDrive.hasMatch(value) || value.indexOf(':', 2) != -1) {
      return null;
    }
    for (final part in components) {
      if (part == '.') continue;
      if (_windowsDevice.hasMatch(part) ||
          part.endsWith('.') ||
          part.endsWith(' ')) {
        return null;
      }
    }
  }
  return p.normalize(value);
}

bool sameOmpSessionPath(String expected, Object? actual) {
  final path = ompSessionPath(actual);
  return path != null && p.equals(path, expected);
}

/// Only the passive flags understood by the pinned native CLI can accompany
/// a host-owned session selector. Start retains the original profile behavior.
bool supportsOmpContinue(List<String> args) {
  const values = {
    '--config',
    '--session-dir',
    '--provider',
    '--model',
    '--thinking',
    '--tools',
    '--approval-mode',
  };
  const bare = {
    '--no-extensions',
    '--no-skills',
    '--no-rules',
    '--no-context-files',
    '--no-lsp',
    '--no-pty',
    '--no-tools',
    '--no-prewalk',
    '--no-title',
    '--no-ui',
    '--offline',
  };
  var rpc = false;
  for (var i = 0; i < args.length; i++) {
    final argument = args[i];
    if (bare.contains(argument)) continue;
    final eq = argument.indexOf('=');
    final flag = eq < 0 ? argument : argument.substring(0, eq);
    if (flag != '--mode' && !values.contains(flag)) return false;
    if (eq < 0 && i + 1 == args.length) return false;
    final value = eq < 0 ? args[++i] : argument.substring(eq + 1);
    if (value.trim().isEmpty ||
        value.startsWith('-') ||
        value.startsWith('@') ||
        _controls.hasMatch(value)) {
      return false;
    }
    if (flag == '--mode') {
      if (rpc || value != 'rpc') return false;
      rpc = true;
    }
  }
  return rpc;
}

Future<String?> probeOmpSessionFile(String path, String id, String target) =>
    Isolate.run(() {
      try {
        if (FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.file) {
          return ompLocatorUnavailable;
        }
        if (!Platform.isWindows &&
            (FileStat.statSync(path).mode & 0xf000) != 0x8000) {
          return ompLocatorUnavailable;
        }
        final file = File(path).openSync();
        try {
          final prefix = file.readSync(_headerBytes);
          var end = prefix.indexOf(10);
          if (end < 0) return ompLocatorUnavailable;
          Object? record(int from, int to) =>
              jsonDecode(utf8.decoder.convert(prefix, from, to));
          var header = record(0, end);
          if (header
              case {
                'type': 'title',
                'v': 1,
                'title': String(),
                'updatedAt': String(),
                'pad': String(),
              }
              when end == 255) {
            final start = end + 1;
            end = prefix.indexOf(10, start);
            if (end < 0) return ompLocatorUnavailable;
            header = record(start, end);
          }
          if (header
              case {
                'type': 'session',
                'id': final String nativeId,
                'cwd': final String cwd,
              }
              when nativeId == id && ompSessionPath(cwd) != null) {
            if (directoryIdentity(cwd) case ResolvedDirectory(:final id)
                when id == target) {
              return null;
            }
          }
          return ompLocatorMismatch;
        } finally {
          file.closeSync();
        }
      } on FileSystemException {
        return ompLocatorUnavailable;
      } on FormatException {
        return ompLocatorMismatch;
      }
    });
