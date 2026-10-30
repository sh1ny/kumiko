import 'dart:convert';

import 'package:domain/domain.dart';
import 'package:test/test.dart';

ProfileDefinition profile({
  String id = 'user-1',
  String name = 'fish',
  String executable = '/usr/bin/fish',
  List<String> args = const [],
  String? cwd,
  Map<String, String> env = const {},
}) => ProfileDefinition(
  id: id,
  name: name,
  executable: executable,
  args: args,
  cwd: cwd,
  env: env,
);

void main() {
  group('shell-profiles: Save a profile with arguments', () {
    test('the arguments round-trip as separate list entries', () {
      final p = profile(args: ['--login', '--private']);
      expect(p.validate(), isEmpty);

      final back = ProfileDefinition.fromJson(
        jsonDecode(jsonEncode(p.toJson())) as Map<String, Object?>,
      );
      expect(back.args, ['--login', '--private']);

      // The stored form is a JSON list, never one command string.
      expect(jsonDecode(encodeProfileArgs(p.args)), ['--login', '--private']);
      expect(decodeProfileArgs(encodeProfileArgs(p.args)), p.args);
    });

    test('an argument containing spaces stays one entry', () {
      final p = profile(args: ['-c', 'echo "a b"']);
      expect(decodeProfileArgs(encodeProfileArgs(p.args)), [
        '-c',
        'echo "a b"',
      ]);
    });
  });

  group('shell-profiles: Profile with an empty executable', () {
    test('an empty executable is invalid and says it is required', () {
      final issues = profile(executable: '').validate();
      expect(issues, hasLength(1));
      expect(issues.single.field, 'executable');
      expect(issues.single.message, contains('required'));
    });

    test('a blank executable is invalid', () {
      expect(profile(executable: '   ').validate(), isNotEmpty);
    });

    test('an empty name is invalid', () {
      expect(profile(name: '').validate().single.field, 'name');
    });
  });

  group('shell-profiles: Invalid variable name', () {
    test('an empty name is invalid and is named', () {
      final issues = profile(env: {'': 'x'}).validate();
      expect(issues.single.field, 'env');
      expect(issues.single.message, contains('""'));
    });

    test('a name containing = is invalid and is named', () {
      final issues = profile(env: {'A=B': 'x'}).validate();
      expect(issues.single.field, 'env');
      expect(issues.single.message, contains('A=B'));
    });

    test('ordinary names are valid', () {
      expect(profile(env: {'EDITOR': 'hx', 'PATH_2': ''}).validate(), isEmpty);
    });
  });

  group('Resource Bounds: user profiles', () {
    test('64 profiles per store', () {
      expect(maxUserProfiles, 64);
    });

    test('256 arguments are valid, 257 are not', () {
      expect(profile(args: List.filled(256, 'a')).validate(), isEmpty);
      expect(profile(args: List.filled(257, 'a')).validate(), isNotEmpty);
    });

    test('an argument of 4 KiB is valid, one byte more is not', () {
      expect(profile(args: ['a' * 4096]).validate(), isEmpty);
      expect(profile(args: ['a' * 4097]).validate(), isNotEmpty);
    });

    test('the argument bound counts UTF-8 bytes', () {
      // 2049 two-byte characters are 4098 bytes.
      expect(profile(args: ['é' * 2049]).validate(), isNotEmpty);
      expect(profile(args: ['é' * 2048]).validate(), isEmpty);
    });

    test('128 environment entries are valid, 129 are not', () {
      Map<String, String> env(int n) => {
        for (var i = 0; i < n; i++) 'K$i': 'v',
      };
      expect(profile(env: env(128)).validate(), isEmpty);
      expect(profile(env: env(129)).validate(), isNotEmpty);
    });

    test('a profile over 12 KiB is invalid even within the other bounds', () {
      // Three arguments of 4 KiB are just over 12 KiB.
      final big = profile(args: List.filled(3, 'a' * 4096));
      expect(big.validate().single.message, contains('12 KiB'));
      final fits = profile(args: List.filled(2, 'a' * 4096));
      expect(fits.validate(), isEmpty);
    });
  });

  test('built-in ids are recognised', () {
    expect(isBuiltinProfileId('builtin:pwsh'), isTrue);
    expect(isBuiltinProfileId('user-1'), isFalse);
  });
}
