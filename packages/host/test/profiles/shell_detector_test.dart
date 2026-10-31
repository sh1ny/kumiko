import 'dart:io';

import 'package:host/src/profiles/shell_detector.dart';
import 'package:test/test.dart';

void main() {
  late Directory bin;
  setUp(() => bin = Directory.systemTemp.createTempSync('kumiko_detect_'));
  tearDown(() => bin.deleteSync(recursive: true));

  void install(String name) {
    final file = File(
      '${bin.path}${Platform.pathSeparator}$name'
      '${Platform.isWindows ? '.exe' : ''}',
    )..writeAsStringSync('');
    if (!Platform.isWindows) Process.runSync('chmod', ['+x', file.path]);
  }

  DetectionConfig config({int maxProbes = 20, Duration? cap}) =>
      DetectionConfig(
        os: Platform.operatingSystem,
        pathDirs: [bin.path],
        wellKnownDirs: const [],
        maxProbes: maxProbes,
        cap: cap ?? const Duration(seconds: 2),
      );

  test('probe order is per operating system', () {
    expect(probeOrder('windows'), ['pwsh', 'powershell', 'nu', 'bash', 'fish']);
    expect(probeOrder('linux'), ['bash', 'zsh', 'fish', 'nu', 'pwsh']);
    expect(probeOrder('macos'), ['zsh', 'bash', 'fish', 'nu', 'pwsh']);
  });

  test('found shells come back in probe order', () {
    final order = probeOrder(Platform.operatingSystem);
    for (final name in order.reversed) {
      install(name);
    }
    final result = detectShells(config());
    expect([for (final s in result.found) s.name], order);
    expect(result.skipped, isEmpty);
  });

  test('probes beyond the limit are skipped and reported', () {
    final order = probeOrder(Platform.operatingSystem);
    order.forEach(install);
    final result = detectShells(config(maxProbes: 2));
    expect([for (final s in result.found) s.name], order.take(2));
    expect(result.skipped, order.skip(2));
  });

  test('probes after the time cap are skipped and reported', () {
    final order = probeOrder(Platform.operatingSystem);
    order.forEach(install);
    final result = detectShells(config(cap: Duration.zero));
    expect(result.found, isEmpty);
    expect(result.skipped, order);
  });

  test('a relative or empty PATH entry is never searched, so a shell in '
      'the working directory is not detected', () {
    probeOrder(Platform.operatingSystem).forEach(install);
    final before = Directory.current;
    Directory.current = bin;
    addTearDown(() => Directory.current = before);

    final result = detectShells(
      DetectionConfig(
        os: Platform.operatingSystem,
        pathDirs: const ['.', '', 'sub/..'],
        wellKnownDirs: const ['.'],
        maxProbes: 20,
        cap: const Duration(seconds: 2),
      ),
    );

    expect(result.found, isEmpty);
  });

  test('a file that is not executable is not a shell', () {
    if (Platform.isWindows) return; // Windows has no execute bit.
    final name = probeOrder(Platform.operatingSystem).first;
    File('${bin.path}/$name').writeAsStringSync('');
    expect(detectShells(config()).found, isEmpty);
  });
}
