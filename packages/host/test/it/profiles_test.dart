import 'dart:io';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

/// The probe order of the platform the test runs on (design D6).
List<String> get probeOrder => switch (Platform.operatingSystem) {
  'windows' => ['pwsh', 'powershell', 'nu', 'bash', 'fish'],
  'macos' => ['zsh', 'bash', 'fish', 'nu', 'pwsh'],
  _ => ['bash', 'zsh', 'fish', 'nu', 'pwsh'],
};

String get exeSuffix => Platform.isWindows ? '.exe' : '';

ShellProfile userProfile(
  String id, {
  String name = 'Elvish',
  String executable = r'C:\tools\elvish.exe',
  List<String> args = const [],
  Map<String, String> env = const {},
}) => ShellProfile(
  id: id,
  name: name,
  executable: executable,
  args: args,
  env: env,
);

void main() {
  setUpAll(buildTestHost);

  late Directory profile;
  late Directory bin;
  setUp(() {
    profile = tempDir('prof_profile_');
    bin = tempDir('prof_bin_');
  });
  tearDown(() async {
    await deleteTree(bin);
    await deleteTree(profile);
  });

  /// A stub shell in the fake PATH directory. Detection looks for a file with
  /// the executable name (and, off Windows, an execute bit), so the stubs are
  /// empty files made here: a committed file would lose its mode in git.
  String install(String name) {
    final file = File(joinPath(bin.path, '$name$exeSuffix'))
      ..writeAsStringSync('');
    if (!Platform.isWindows) Process.runSync('chmod', ['+x', file.path]);
    return file.path;
  }

  void uninstall(String name) =>
      File(joinPath(bin.path, '$name$exeSuffix')).deleteSync();

  Future<Desktop> start() async {
    final desktop = await Desktop.start(
      profile,
      environment: {'KUMIKO_TEST_SHELL_PATH': bin.path},
    );
    addTearDown(desktop.dispose);
    await desktop.waitState();
    return desktop;
  }

  Future<void> restart(Desktop desktop) async {
    await desktop.session.quit();
    await desktop.restart();
    await desktop.waitState();
  }

  Future<RpcException> failure(Future<Object?> call) async {
    try {
      await call;
    } on RpcException catch (e) {
      return e;
    }
    fail('expected an RpcException');
  }

  List<String> builtinNames(ProfileListResult r) => [
    for (final p in r.profiles)
      if (p.isBuiltin) p.id.substring('builtin:'.length),
  ];

  List<String> userIds(ProfileListResult r) => [
    for (final p in r.profiles)
      if (!p.isBuiltin) p.id,
  ];

  group('detection', () {
    test('Windows with pwsh and Nushell installed: three built-ins with '
        'resolved paths', () async {
      // On Windows the spec scenario: pwsh, powershell and nu. Elsewhere the
      // same shape with that platform's names.
      final names = Platform.isWindows
          ? ['pwsh', 'powershell', 'nu']
          : [probeOrder.first, 'nu', 'pwsh'];
      final paths = {for (final n in names) n: install(n)};
      final desktop = await start();

      final list = await desktop.listProfiles();

      expect(builtinNames(list), [
        for (final n in probeOrder)
          if (names.contains(n)) n,
      ]);
      for (final p in list.profiles) {
        final name = p.id.substring('builtin:'.length);
        expect(p.isBuiltin, isTrue);
        expect(p.args, isEmpty);
        expect(
          p.executable.toLowerCase(),
          paths[name]!.toLowerCase(),
          reason: 'resolved path of $name',
        );
      }
      expect(list.profiles.map((p) => p.name).toSet(), hasLength(3));
    });

    test('fish is not installed: no fish built-in, the others are', () async {
      for (final n in probeOrder) {
        if (n != 'fish') install(n);
      }
      final desktop = await start();

      final list = await desktop.listProfiles();

      expect(builtinNames(list), isNot(contains('fish')));
      expect(builtinNames(list), [
        for (final n in probeOrder)
          if (n != 'fish') n,
      ]);
    });

    test('a detected shell removed later is not offered after the next '
        'start', () async {
      final keep = probeOrder.last;
      final gone = probeOrder.first;
      install(keep);
      install(gone);
      final desktop = await start();
      expect(builtinNames(await desktop.listProfiles()), contains(gone));

      uninstall(gone);
      await restart(desktop);

      final list = await desktop.listProfiles();
      expect(builtinNames(list), [keep]);
    });

    test('built-ins are never written to the store', () async {
      install(probeOrder.first);
      final desktop = await start();
      await desktop.listProfiles();
      expect(LedgerView(profile).profiles(), isEmpty);
    });

    test('no shell detected and no profile: nothing is available', () async {
      final desktop = await start();

      final list = await desktop.listProfiles();

      expect(list.profiles, isEmpty);
      expect(list.defaultId, isNull);
      expect(list.defaultAvailable, isFalse);
    });
  });

  group('user profiles', () {
    test('Save a profile with arguments: two separate arguments survive a '
        'restart', () async {
      final desktop = await start();
      await desktop.saveProfile(
        userProfile(
          'u1',
          name: 'fish',
          executable: '/usr/bin/fish',
          args: ['--login', '--private'],
          env: {'EDITOR': 'hx'},
        ),
      );
      await restart(desktop);

      final p = (await desktop.listProfiles()).profiles.single;

      expect(p.args, ['--login', '--private']);
      expect(p.env, {'EDITOR': 'hx'});
      final row = LedgerView(profile).profiles().single;
      expect(row['args_json'], '["--login","--private"]');
    });

    test('Add a profile for an unknown shell: listed after a restart '
        '(the terminal half needs group 5)', () async {
      final desktop = await start();
      await desktop.saveProfile(userProfile('u1'));
      await restart(desktop);

      final list = await desktop.listProfiles();

      expect(userIds(list), ['u1']);
      expect(list.profiles.single.executable, r'C:\tools\elvish.exe');
      expect(list.profiles.single.args, isEmpty);
    });

    test('Profile with an empty executable: refused, nothing stored', () async {
      final desktop = await start();

      final e = await failure(
        desktop.saveProfile(userProfile('u1', executable: '')),
      );

      expect(e.reason, ErrorCode.invalidParams);
      expect(e.message.toLowerCase(), contains('executable'));
      expect(e.message.toLowerCase(), contains('required'));
      expect(LedgerView(profile).profiles(), isEmpty);
      expect((await desktop.listProfiles()).profiles, isEmpty);
    });

    test('Invalid variable name: empty name refused, nothing stored', () async {
      final desktop = await start();

      final e = await failure(
        desktop.saveProfile(userProfile('u1', env: {'': 'x'})),
      );

      expect(e.reason, ErrorCode.invalidParams);
      expect(e.message, contains('""'));
      expect(LedgerView(profile).profiles(), isEmpty);
    });

    test('Invalid variable name: a name with = is refused and named', () async {
      final desktop = await start();

      final e = await failure(
        desktop.saveProfile(userProfile('u1', env: {'A=B': 'x'})),
      );

      expect(e.reason, ErrorCode.invalidParams);
      expect(e.message, contains('A=B'));
      expect(LedgerView(profile).profiles(), isEmpty);
    });

    test(
      'Edit a profile while a terminal uses it: the edit is stored and '
      'keeps the creation time (the running-terminal half needs group 5)',
      () async {
        final desktop = await start();
        await desktop.saveProfile(userProfile('u1', args: ['-a']));
        final created = LedgerView(profile).profiles().single['created_at'];

        await desktop.saveProfile(userProfile('u1', args: ['-a', '-b']));

        final list = await desktop.listProfiles();
        expect(list.profiles.single.args, ['-a', '-b']);
        final row = LedgerView(profile).profiles().single;
        expect(row['created_at'], created);
      },
    );

    test('Try to edit a built-in profile: refused', () async {
      final name = probeOrder.first;
      install(name);
      final desktop = await start();
      final builtin = (await desktop.listProfiles()).profiles.single;

      final e = await failure(
        desktop.saveProfile(
          ShellProfile(
            id: builtin.id,
            name: builtin.name,
            executable: builtin.executable,
            args: const ['--changed'],
          ),
        ),
      );

      expect(e.reason, ErrorCode.invalidParams);
      expect(e.data['detail'], 'builtin-profile');
      expect((await desktop.listProfiles()).profiles.single.args, isEmpty);
      expect(LedgerView(profile).profiles(), isEmpty);
    });

    test('a built-in cannot be removed', () async {
      install(probeOrder.first);
      final desktop = await start();
      final builtin = (await desktop.listProfiles()).profiles.single;

      final e = await failure(desktop.removeProfile(builtin.id));

      expect(e.data['detail'], 'builtin-profile');
      expect((await desktop.listProfiles()).profiles, hasLength(1));
    });

    test('removing an unknown profile is refused', () async {
      final desktop = await start();
      final e = await failure(desktop.removeProfile('nope'));
      expect(e.reason, ErrorCode.invalidParams);
      expect(e.data['detail'], 'unknown-profile');
    });

    test('Store write fails: store-error and the list is unchanged', () async {
      final desktop = await start();
      await desktop.saveProfile(userProfile('u1', args: ['-a']));
      await desktop.setFault(TestFault.profileWriteFails);

      final save = await failure(
        desktop.saveProfile(userProfile('u2', name: 'Other')),
      );
      final edit = await failure(
        desktop.saveProfile(userProfile('u1', args: ['-changed'])),
      );
      final remove = await failure(desktop.removeProfile('u1'));

      expect(save.reason, ErrorCode.storeError);
      expect(edit.reason, ErrorCode.storeError);
      expect(remove.reason, ErrorCode.storeError);
      final list = await desktop.listProfiles();
      expect(userIds(list), ['u1']);
      expect(list.profiles.single.args, ['-a']);
      expect(LedgerView(profile).profiles(), hasLength(1));

      await desktop.setFault(TestFault.profileWriteFails, enabled: false);
      await desktop.saveProfile(userProfile('u2', name: 'Other'));
      expect(userIds(await desktop.listProfiles()), ['u1', 'u2']);
    });

    test('the 65th user profile is refused, the 64 stay', () async {
      final desktop = await start();
      for (var i = 0; i < 64; i++) {
        await desktop.saveProfile(userProfile('u$i', name: 'P$i'));
      }

      final e = await failure(desktop.saveProfile(userProfile('u64')));

      expect(e.reason, ErrorCode.invalidParams);
      expect(e.data['detail'], 'profile-cap');
      expect(userIds(await desktop.listProfiles()), hasLength(64));
      // Editing an existing one still works at the cap.
      await desktop.saveProfile(userProfile('u0', name: 'Renamed'));
    });
  });

  group('default profile', () {
    test('First launch: the default is the first detected built-in in probe '
        'order', () async {
      // On Windows the spec scenario: pwsh and powershell detected, pwsh wins.
      final names = probeOrder.take(2).toList();
      for (final n in names.reversed) {
        install(n);
      }
      final desktop = await start();

      final list = await desktop.listProfiles();

      expect(list.defaultId, 'builtin:${names.first}');
      expect(list.defaultAvailable, isTrue);
      if (Platform.isWindows) expect(list.defaultId, 'builtin:pwsh');
      expect(LedgerView(profile).settings(), {
        'default_profile': 'builtin:${names.first}',
      });
    });

    test('Choose a new default: it survives a restart', () async {
      for (final n in probeOrder.take(2)) {
        install(n);
      }
      final second = probeOrder[1];
      final desktop = await start();

      await desktop.setDefaultProfile('builtin:$second');
      await restart(desktop);

      final list = await desktop.listProfiles();
      expect(list.defaultId, 'builtin:$second');
      expect(list.defaultAvailable, isTrue);
    });

    test('Change the default terminal profile: only default_profile is '
        'written', () async {
      install(probeOrder.first);
      final desktop = await start();
      await desktop.saveProfile(userProfile('u1'));
      await desktop.listProfiles();
      final before = LedgerView(profile).settings().keys.toSet();

      await desktop.setDefaultProfile('u1');

      final after = LedgerView(profile).settings();
      expect(before, {'default_profile'});
      expect(after, {'default_profile': 'u1'});
    });

    test('setting an unknown profile as the default is refused', () async {
      final desktop = await start();
      final e = await failure(desktop.setDefaultProfile('nope'));
      expect(e.reason, ErrorCode.invalidParams);
      expect(e.data['detail'], 'unknown-profile');
      expect(LedgerView(profile).settings(), isEmpty);
    });

    test(
      'Default profile removed: reported unavailable, never replaced',
      () async {
        install(probeOrder.first);
        final desktop = await start();
        await desktop.saveProfile(userProfile('u1'));
        await desktop.setDefaultProfile('u1');

        await desktop.removeProfile('u1');

        final list = await desktop.listProfiles();
        expect(list.defaultId, 'u1');
        expect(list.defaultAvailable, isFalse);
        expect(list.profiles.map((p) => p.id), isNot(contains('u1')));
        expect(LedgerView(profile).settings(), {'default_profile': 'u1'});
      },
    );

    test('a default built-in that is uninstalled is unavailable, not '
        'replaced', () async {
      final first = probeOrder.first;
      final other = probeOrder.last;
      install(first);
      install(other);
      final desktop = await start();
      expect((await desktop.listProfiles()).defaultId, 'builtin:$first');

      uninstall(first);
      await restart(desktop);

      final list = await desktop.listProfiles();
      expect(list.defaultId, 'builtin:$first');
      expect(list.defaultAvailable, isFalse);
    });
  });
}
