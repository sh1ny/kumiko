import 'package:desktop/src/host_location.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveHostExecutable', () {
    test('bundled host sits at <app>/host/bin/kumiko_host', () {
      expect(
        resolveHostExecutable(
          override: '',
          appExecutable: '/opt/kumiko/kumiko',
          os: HostOs.linux,
        ),
        '/opt/kumiko/host/bin/kumiko_host',
      );
    });

    test('Windows bundled host has the .exe suffix', () {
      expect(
        resolveHostExecutable(
          override: '',
          appExecutable: r'C:\Program Files\Kumiko\kumiko.exe',
          os: HostOs.windows,
        ),
        r'C:\Program Files\Kumiko\host\bin\kumiko_host.exe',
      );
    });

    test('the KUMIKO_HOST define overrides the bundled path', () {
      expect(
        resolveHostExecutable(
          override: '/dev/kumiko_host',
          appExecutable: '/opt/kumiko/kumiko',
          os: HostOs.linux,
        ),
        '/dev/kumiko_host',
      );
    });
  });

  group('defaultProfileDir', () {
    test('Windows uses LOCALAPPDATA', () {
      expect(
        defaultProfileDir(
          os: HostOs.windows,
          env: {'LOCALAPPDATA': r'C:\Users\a\AppData\Local'},
          home: r'C:\Users\a',
        ),
        r'C:\Users\a\AppData\Local\Kumiko',
      );
    });

    test('Linux uses XDG_DATA_HOME when set', () {
      expect(
        defaultProfileDir(
          os: HostOs.linux,
          env: {'XDG_DATA_HOME': '/data'},
          home: '/home/a',
        ),
        '/data/kumiko',
      );
    });

    test('Linux falls back to ~/.local/share', () {
      expect(
        defaultProfileDir(os: HostOs.linux, env: {}, home: '/home/a'),
        '/home/a/.local/share/kumiko',
      );
      expect(
        defaultProfileDir(
          os: HostOs.linux,
          env: {'XDG_DATA_HOME': ''},
          home: '/home/a',
        ),
        '/home/a/.local/share/kumiko',
      );
    });

    test('a relative base directory is ignored', () {
      // A relative one would resolve against the working directory, which
      // could be a checkout that ships its own profile and shell profiles.
      expect(
        defaultProfileDir(
          os: HostOs.linux,
          env: {'XDG_DATA_HOME': 'data'},
          home: '/home/a',
        ),
        '/home/a/.local/share/kumiko',
      );
      for (final relative in [r'AppData\Local', r'C:AppData', r'\AppData']) {
        expect(
          defaultProfileDir(
            os: HostOs.windows,
            env: {'LOCALAPPDATA': relative},
            home: r'C:\Users\a',
          ),
          r'C:\Users\a\AppData\Local\Kumiko',
          reason: relative,
        );
      }
      expect(
        defaultProfileDir(
          os: HostOs.windows,
          env: {'LOCALAPPDATA': r'\\server\share\a'},
          home: r'C:\Users\a',
        ),
        r'\\server\share\a\Kumiko',
      );
    });

    test('no profile directory when the home it would use is not absolute', () {
      expect(
        defaultProfileDir(os: HostOs.linux, env: {}, home: 'evil'),
        isNull,
      );
      expect(defaultProfileDir(os: HostOs.macos, env: {}, home: ''), isNull);
      expect(
        defaultProfileDir(os: HostOs.windows, env: {}, home: r'Users\a'),
        isNull,
      );
      // An absolute base directory does not need the home.
      expect(
        defaultProfileDir(
          os: HostOs.linux,
          env: {'XDG_DATA_HOME': '/data'},
          home: '',
        ),
        '/data/kumiko',
      );
    });

    test('macOS uses Application Support', () {
      expect(
        defaultProfileDir(os: HostOs.macos, env: {}, home: '/Users/a'),
        '/Users/a/Library/Application Support/Kumiko',
      );
    });
  });
}
