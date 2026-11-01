import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:host/src/agent/executable_resolver.dart';
import 'package:host/src/host_faults.dart';
import 'package:host_protocol/host_protocol.dart';
import 'package:process_containment/process_containment.dart';
import 'package:test/test.dart';

class _ProbeFaults extends HostFaults {
  final ready = Completer<void>();
  int registered = 0;

  @override
  void registerHung(String path, SendPort port) {
    super.registerHung(path, port);
    if (++registered == 4) ready.complete();
  }
}

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('kumiko_resolver_'));
  tearDown(() => root.deleteSync(recursive: true));
  String file(String relative, {bool executable = true}) {
    final f = File('${root.path}/$relative')..createSync(recursive: true);
    if (!Platform.isWindows) chmodPath(f.path, executable ? 0x1c0 : 0x180);
    return f.absolute.path;
  }

  ExecutableResolver resolver({
    List<String>? paths,
    List<String> known = const [],
    String? os,
    String pathext = '.COM;.EXE;.BAT;.CMD',
  }) => ExecutableResolver(
    os: os ?? Platform.operatingSystem,
    pathDirs: paths ?? [root.path],
    wellKnownDirs: known,
    pathExt: pathext,
  );
  Matcher refused(String code, String path) => throwsA(
    isA<RpcException>()
        .having((e) => e.reason, 'code', code)
        .having((e) => e.data['executable'], 'path', path),
  );

  test('absolute paths are used as is, missing files name that path', () {
    final path = file(Platform.isWindows ? 'node.exe' : 'node');
    expect(resolver(paths: []).resolve(path), path);
    final missing = '${root.path}/missing';
    expect(
      () => resolver().resolve(missing),
      refused(ErrorCode.executableNotFound, missing),
    );
    expect(
      () => resolver().resolve('absent'),
      refused(ErrorCode.executableNotFound, 'absent'),
    );
  });
  test(
    'PATH precedes well-known directories and relative entries are ignored',
    () {
      final name = Platform.isWindows ? 'node.exe' : 'node';
      final first = file('path/$name');
      file('known/$name');
      expect(
        resolver(
          paths: ['.', '${root.path}/path'],
          known: ['${root.path}/known'],
        ).resolve('node'),
        first,
      );
      expect(
        resolver(paths: [], known: ['${root.path}/known']).resolve('node'),
        File('${root.path}/known/$name').absolute.path,
      );
    },
  );
  test('bare node resolves through PATH and PATHEXT to the .exe', () {
    final node = file('node.exe');
    expect(resolver(os: 'windows', pathext: '.CMD;.EXE').resolve('node'), node);
    expect(resolver(os: 'windows').resolve('node.exe'), node);
  });
  test('an absolute .cmd or .bat executable is refused with the batch-file reason and the node.exe form', () {
    for (final ext in ['cmd', 'bat']) {
      final path = file('npx.$ext');
      expect(
        () => resolver(os: 'windows').resolve(path),
        throwsA(
          isA<RpcException>()
              .having((e) => e.reason, 'code', ErrorCode.notExecutable)
              .having((e) => e.data['executable'], 'path', path)
              .having(
                (e) => e.message,
                'guidance',
                allOf(contains('node.exe'), contains('npx-cli.js')),
              ),
        ),
      );
    }
  });
  test('bare npx whose first match is npx.cmd is refused, naming npx.cmd and the npx-cli.js form, and a later .exe is not used', () {
    final batch = file('first/npx.cmd');
    file('later/npx.exe');
    expect(
      () => resolver(
        os: 'windows',
        paths: ['${root.path}/first', '${root.path}/later'],
      ).resolve('npx'),
      throwsA(
        isA<RpcException>()
            .having((e) => e.reason, 'code', ErrorCode.notExecutable)
            .having((e) => e.data['executable'], 'path', batch)
            .having((e) => e.message, 'guidance', contains('npx-cli.js')),
      ),
    );
    file('first/npx.exe');
    expect(
      () => resolver(
        os: 'windows',
        paths: ['${root.path}/first'],
        pathext: '.CMD;.EXE',
      ).resolve('npx'),
      refused(ErrorCode.notExecutable, batch),
    );
  });
  test('Windows first non-exe regular file is refused rather than skipped', () {
    final com = file('node.com');
    file('node.exe');
    expect(
      () => resolver(os: 'windows').resolve('node'),
      refused(ErrorCode.notExecutable, com),
    );
  });
  test(
    'POSIX not-executable fails before launch and never searches past first match',
    () {
      final path = file('first/node', executable: false);
      file('later/node');
      expect(
        () =>
            resolver(paths: ['${root.path}/first', '${root.path}/later'])
                .resolve('node'),
        refused(ErrorCode.notExecutable, path),
      );
      expect(
        () => resolver().resolve(path),
        refused(ErrorCode.notExecutable, path),
      );
    },
    skip: Platform.isWindows
        ? 'POSIX access(X_OK), pending three-OS CI'
        : false,
  );
  test('launch worker preserves first-match batch refusal across the isolate', () async {
    final batch = file('first/npx.cmd');
    file('later/npx.exe');
    final launch = LaunchExecutableResolver(
      faults: HostFaults(),
      resolver: resolver(os: 'windows', paths: ['${root.path}/first', '${root.path}/later']),
    );
    await expectLater(launch.resolve('npx'), refused(ErrorCode.notExecutable, batch));
  });

  test('launch probes retain all four slots after timeout until their workers return', () async {
    final executable = file(Platform.isWindows ? 'node.exe' : 'node');
    final faults = _ProbeFaults();
    final launch = LaunchExecutableResolver(
      faults: faults,
      timeout: const Duration(milliseconds: 100),
    );
    final pending = <Future<void>>[];
    try {
      for (var i = 0; i < 4; i++) {
        faults.setResolveFault(executable, const ResolveFault(hang: true));
        pending.add(expectLater(launch.resolve(executable), refused(ErrorCode.busy, executable)));
      }
      await faults.ready.future.timeout(const Duration(seconds: 5));
      await Future.wait(pending);
      await expectLater(launch.resolve(executable), refused(ErrorCode.busy, executable));
    } finally {
      faults.releaseResolve(executable);
      await Future.wait(pending);
    }
    String? resolved;
    await Future.doWhile(() async {
      try {
        resolved = await launch.resolve(executable);
        return false;
      } on RpcException catch (error) {
        if (error.reason != ErrorCode.busy) rethrow;
        await Future<void>(() {});
        return true;
      }
    }).timeout(const Duration(seconds: 5));
    expect(resolved, executable);
  });

  test('D11 well-known directories use platform install locations and newest numeric nvm version', () {
    for (final v in ['v9.9.0', 'v22.1.0', 'v22.10.0']) {
      Directory('${root.path}/.nvm/versions/node/$v/bin')
          .createSync(recursive: true);
    }
    final home = root.path;
    final common = [
      '$home/.npm-global/bin',
      '$home/.volta/bin',
      '$home/.nvm/versions/node/v22.10.0/bin',
    ];
    expect(wellKnownRuntimeDirs('macos', {'HOME': home}), [
      '/opt/homebrew/bin',
      '/usr/local/bin',
      ...common,
    ]);
    expect(wellKnownRuntimeDirs('linux', {'HOME': home}), [
      '/usr/local/bin',
      '$home/.local/bin',
      ...common,
    ]);
    expect(
      wellKnownRuntimeDirs('windows', {'APPDATA': home, 'ProgramFiles': home}),
      ['$home/npm', '$home/nodejs'],
    );
  });
}
