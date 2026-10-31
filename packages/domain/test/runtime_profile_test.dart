import 'dart:convert';

import 'package:domain/domain.dart';
import 'package:test/test.dart';

RuntimeProfileDefinition profile({
  String id = 'user-1',
  String name = 'Claude Code',
  String runtimeKind = 'claude-code',
  String executable = 'node',
  List<String> args = const [],
  Map<String, String> env = const {},
}) => RuntimeProfileDefinition(
  id: id,
  name: name,
  runtimeKind: runtimeKind,
  executable: executable,
  args: args,
  env: env,
);

void main() {
  test('args and overrides round-trip without command parsing or cwd', () {
    final p = profile(
      args: ['', '--setting="a b"', r'c:\a b\c'],
      env: {'ANTHROPIC_LOG': 'debug'},
    );
    expect(p.validate(), isEmpty);
    final back = RuntimeProfileDefinition.fromJson(
      jsonDecode(jsonEncode(p.toJson())) as Map<String, Object?>,
    );
    expect(back.toJson(), p.toJson());
    expect(back.args, ['', '--setting="a b"', r'c:\a b\c']);
    expect(back.toJson(), isNot(contains('cwd')));
    expect(decodeProfileArgs(encodeProfileArgs(p.args)), p.args);
  });
  test('empty executable and env name with = are invalid', () {
    for (final executable in ['', '  ']) {
      expect(
        profile(executable: executable).validate().single.field,
        'executable',
      );
    }
    for (final name in ['', 'A=B']) {
      expect(profile(env: {name: 'x'}).validate().single.field, 'env');
    }
  });
  test('runtimeKind required', () {
    expect(profile(runtimeKind: '').validate().single.field, 'runtimeKind');
    expect(profile(runtimeKind: '  ').validate().single.field, 'runtimeKind');
    final json = profile().toJson()..remove('runtimeKind');
    expect(
      () => RuntimeProfileDefinition.fromJson(json),
      throwsA(isA<TypeError>()),
    );
  });
  test('shared shell-profile bounds include runtimeKind in encoded size', () {
    expect(maxUserProfiles, 64);
    expect(profile(args: List.filled(256, 'a')).validate(), isEmpty);
    expect(profile(args: List.filled(257, 'a')).validate().first.field, 'args');
    expect(profile(args: ['é' * 2048]).validate(), isEmpty);
    expect(profile(args: ['é' * 2048 + 'a']).validate().first.field, 'args');
    Map<String, String> env(int n) => {for (var i = 0; i < n; i++) 'K$i': 'v'};
    expect(profile(env: env(128)).validate(), isEmpty);
    expect(profile(env: env(129)).validate().first.field, 'env');
    expect(profile(id: 'a' * 128, name: 'a' * 256).validate(), isEmpty);
    expect(profile(id: 'a' * 129).validate().first.field, 'id');
    expect(profile(name: 'a' * 257).validate().first.field, 'name');
    final overhead = utf8.encode(jsonEncode(profile().toJson())).length;
    final fits = profile(env: {'K': 'a' * (maxProfileBytes - overhead - 6)});
    expect(utf8.encode(jsonEncode(fits.toJson())).length, maxProfileBytes);
    expect(fits.validate(), isEmpty);
    expect(
      profile(env: {'K': '${fits.env['K']}a'}).validate().single.field,
      'profile',
    );
  });
  test('built-in identity is shared with shell profiles', () {
    expect(profile(id: 'builtin:claude-code').isBuiltin, isTrue);
    expect(profile().isBuiltin, isFalse);
  });
}
