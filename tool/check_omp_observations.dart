import 'dart:convert';
import 'dart:io';

const _maxBytes = 1024 * 1024;
const _items = {
  'launch',
  'prompt',
  'streaming',
  'immutable target',
  'Stop',
  'one-shot approval',
  'denial',
  'tool activity',
  'kumiko tool call',
  'exact Continue',
  'history restore',
  'read-only child pane',
  'close',
  'ordinary quit',
};
final _version = RegExp(
  r'(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)'
  r'(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?',
);
final _revision = RegExp(r'[0-9a-f]{40}');
final _model = RegExp(
  r'[a-zA-Z0-9_-]+/[a-zA-Z0-9_.:@+-]+(?:/[a-zA-Z0-9_.:@+-]+)*',
);
final _sha256 = RegExp(r'[0-9a-f]{64}');
final _utc = RegExp(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?Z');
final _multiline = RegExp(r'[\x00-\x1f\x7f\u0085\u2028\u2029]');

/// Reads a bounded offline record. A [FormatException] contains only a field,
/// index or known item name, not user-provided notes or source data.
List<String> checkOmpObservations(File record) {
  final file = record.openSync();
  final String text;
  try {
    final length = file.lengthSync();
    if (length > _maxBytes) {
      throw const FormatException('record exceeds 1 MiB');
    }
    final bytes = file.readSync(length);
    if (bytes.length != length || file.lengthSync() != length) {
      throw const FormatException('record size changed while reading');
    }
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      throw const FormatException('record is not UTF-8');
    }
  } finally {
    file.closeSync();
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    throw const FormatException('record is not valid JSON');
  }
  if (decoded is! List<Object?>) {
    throw const FormatException('record must be an array of attempts');
  }
  if (decoded.isEmpty) return const ['OMP OBSERVATIONS: none recorded'];

  final ids = <DateTime>{};
  final approvals = <String>{};
  return [
    for (var i = 0; i < decoded.length; i++)
      _checkAttempt(decoded[i], i + 1, ids, approvals),
  ];
}

String _checkAttempt(
  Object? value,
  int index,
  Set<DateTime> ids,
  Set<String> approvals,
) {
  Never invalid(String message) =>
      throw FormatException('attempt $index: $message');

  if (value is! Map<String, Object?>) invalid('expected an object');
  final id = value['id'];
  final start = _utcInstant(id);
  if (start == null) invalid('invalid id; expected UTC timestamp');
  if (!ids.add(start)) invalid('duplicate attempt id');
  final version = value['version'];
  if (!_matches(version, _version)) invalid('invalid version');
  if (value['os'] != 'windows') invalid('os must be windows');
  if (!_matches(value['revision'], _revision)) invalid('invalid revision');
  if (!_matches(value['model'], _model)) invalid('invalid model');

  final approval = value['approval'];
  if (approval is! Map<String, Object?>) invalid('missing or invalid approval');
  final digest = approval['sha256'];
  if (digest is! String || !_matches(digest, _sha256)) {
    invalid('invalid approval.sha256');
  }
  final approvedAt = _utcInstant(approval['approvedAt']);
  if (approvedAt == null || approvedAt.isAfter(start)) {
    invalid('invalid approval.approvedAt');
  }
  if (!approvals.add(digest)) invalid('duplicate approval reference');

  final rows = value['items'];
  if (rows is! List<Object?>) invalid('items must be an array');
  final seen = <String>{};
  var failed = false;
  var incomplete = false;
  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    final location = 'item ${i + 1}';
    if (row is! Map<String, Object?>) invalid('$location must be an object');
    final item = row['item'];
    if (item is! String || !_items.contains(item)) {
      invalid('$location has unknown item name');
    }
    if (!seen.add(item)) invalid('duplicate item: $item');
    switch (row['result']) {
      case 'pass':
        break;
      case 'fail':
        failed = true;
      case 'unverified':
        incomplete = true;
      default:
        invalid('$item: invalid result');
    }
    final notes = row['notes'];
    if (notes is! String ||
        notes.trim().isEmpty ||
        notes.length > 512 ||
        _multiline.hasMatch(notes) ||
        utf8.encode(notes).length > 512) {
      invalid('$item: notes must be nonempty, single-line, at most 512 bytes');
    }
  }
  for (final item in _items) {
    if (!seen.contains(item)) invalid('missing required item: $item');
  }
  final status = failed ? 'FAIL' : (incomplete ? 'INCOMPLETE' : 'PASS');
  return 'OMP OBSERVATIONS: $id $version windows: $status';
}

bool _matches(Object? value, RegExp pattern) =>
    value is String && pattern.matchAsPrefix(value)?.end == value.length;

DateTime? _utcInstant(Object? value) {
  if (value is! String || !_matches(value, _utc)) return null;
  final time = DateTime.tryParse(value);
  // Dart normalizes overflowing date components instead of rejecting them.
  return time != null &&
          time.toIso8601String().startsWith(value.substring(0, 19))
      ? time
      : null;
}
