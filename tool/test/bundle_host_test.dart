import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../bundle_host.dart';

void main() {
  test('default bundle directories per OS', () {
    expect(
      defaultBundleDir('windows'),
      endsWith(p.join('x64', 'runner', 'Release')),
    );
    expect(
      defaultBundleDir('linux'),
      endsWith(p.join('x64', 'release', 'bundle')),
    );
    expect(
      defaultBundleDir('macos'),
      endsWith(p.join('Kumiko.app', 'Contents', 'MacOS')),
    );
  });

  test('copies bin and lib into host/ and replaces an earlier copy', () {
    final temp = Directory.systemTemp.createTempSync('bundle_host_test_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final exe = Platform.isWindows ? 'kumiko_host.exe' : 'kumiko_host';
    final source = Directory(p.join(temp.path, 'src'));
    File(p.join(source.path, 'bin', exe)).createSync(recursive: true);
    File(p.join(source.path, 'lib', 'sqlite3.lib')).createSync(recursive: true);
    final app = Directory(p.join(temp.path, 'app'))..createSync();
    File(p.join(app.path, 'host', 'stale.txt')).createSync(recursive: true);

    final dest = copyHostBundle(hostBundle: source, bundleDir: app);

    expect(dest.path, p.join(app.path, 'host'));
    expect(File(p.join(dest.path, 'bin', exe)).existsSync(), isTrue);
    expect(File(p.join(dest.path, 'lib', 'sqlite3.lib')).existsSync(), isTrue);
    expect(File(p.join(dest.path, 'stale.txt')).existsSync(), isFalse);
  });

  test('fails when the app bundle is missing', () {
    expect(
      () => copyHostBundle(
        hostBundle: Directory('nope'),
        bundleDir: Directory('also_nope'),
      ),
      throwsStateError,
    );
  });
}
