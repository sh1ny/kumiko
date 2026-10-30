import 'dart:async';
import 'dart:convert';

import 'package:domain/domain.dart' show maxUserProfiles;
import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/sinks.dart';

void expectReason(void Function() f, String reason) => expect(
  f,
  throwsA(isA<RpcException>().having((e) => e.reason, 'reason', reason)),
);

const profile = ShellProfile(
  id: 'p1',
  name: 'fish',
  executable: '/usr/bin/fish',
  args: ['--login', '--private'],
  cwd: '/home/u',
  env: {'EDITOR': 'hx'},
);

void main() {
  test('names and capability', () {
    expect(Capability.terminal, 'terminal');
    expect(Method.profileList, 'profile/list');
    expect(Method.profileSave, 'profile/save');
    expect(Method.profileRemove, 'profile/remove');
    expect(Method.profileSetDefault, 'profile/setDefault');
    expect(Method.terminalOpen, 'terminal/open');
    expect(Method.terminalAttach, 'terminal/attach');
    expect(Method.terminalResize, 'terminal/resize');
    expect(Method.terminalClose, 'terminal/close');
    expect(Method.terminalRelease, 'terminal/release');
    expect(Method.terminalExited, 'terminal/exited');
    expect(Method.terminalCloseFailed, 'terminal/closeFailed');
  });

  test('every request method needs the terminal capability; notifications '
      'are not gated', () {
    for (final m in [
      Method.profileList,
      Method.profileSave,
      Method.profileRemove,
      Method.profileSetDefault,
      Method.terminalOpen,
      Method.terminalAttach,
      Method.terminalResize,
      Method.terminalClose,
      Method.terminalRelease,
    ]) {
      expect(methodCapability[m], Capability.terminal, reason: m);
    }
    expect(methodCapability.containsKey(Method.terminalExited), isFalse);
    expect(methodCapability.containsKey(Method.terminalCloseFailed), isFalse);
  });

  test('error reasons keep their wire names through RpcException', () {
    const reasons = {
      ErrorCode.unknownTerminal: 'unknown-terminal',
      ErrorCode.invalidSize: 'invalid-size',
      ErrorCode.executableNotFound: 'executable-not-found',
      ErrorCode.spawnFailed: 'spawn-failed',
      ErrorCode.channelLimit: 'channel-limit',
      ErrorCode.notAttached: 'not-attached',
      ErrorCode.consoleCleanupPending: 'console-cleanup-pending',
    };
    reasons.forEach((constant, wire) {
      expect(constant, wire);
      expect(
        RpcException.fromJson(RpcException(constant, 'm').toJson()).reason,
        wire,
      );
    });
  });

  test('spawn-failed carries stage and osError', () {
    final back = RpcException.fromJson(
      spawnFailed('dup2', 13, 'denied').toJson(),
    );
    expect(back.reason, ErrorCode.spawnFailed);
    expect(back.data['stage'], 'dup2');
    expect(back.data['osError'], 13);
    expect(back.message, 'denied');
  });

  test('ShellProfile round-trips and derives built-in from the id', () {
    expect(ShellProfile.fromJson(profile.toJson()).toJson(), profile.toJson());
    final back = ShellProfile.fromJson(profile.toJson());
    expect(back.args, ['--login', '--private']);
    expect(back.env, {'EDITOR': 'hx'});
    expect(back.cwd, '/home/u');
    expect(back.isBuiltin, isFalse);

    const minimal = ShellProfile(
      id: 'builtin:pwsh',
      name: 'pwsh',
      executable: r'C:\pwsh.exe',
    );
    final m = ShellProfile.fromJson(minimal.toJson());
    expect(m.cwd, isNull);
    expect(m.args, isEmpty);
    expect(m.env, isEmpty);
    expect(m.isBuiltin, isTrue);
  });

  test('64 user profiles at the size bound and every detected shell fit in '
      'one profile/list response', () {
    int sizeOf(ShellProfile p) => utf8.encode(jsonEncode(p.toJson())).length;
    ShellProfile atBound(int i) {
      final args = <String>[];
      ShellProfile make() => ShellProfile(
        id: 'user-$i',
        name: 'Profile $i',
        executable: 'sh',
        args: args,
      );
      // Each further argument costs its bytes plus quotes and a comma.
      while (sizeOf(make()) + maxProfileArgBytes + 3 <= maxProfileBytes) {
        args.add('a' * maxProfileArgBytes);
      }
      args.add('a' * (maxProfileBytes - sizeOf(make()) - 3));
      final p = ShellProfile.fromJson(make().toJson()); // within the bound
      expect(sizeOf(p), greaterThan(maxProfileBytes - 8));
      return p;
    }

    final result = ProfileListResult(
      profiles: [
        // The five probed shells, each at a long resolved path.
        for (final name in ['pwsh', 'powershell', 'nu', 'bash', 'fish'])
          ShellProfile(
            id: 'builtin:$name',
            name: name,
            executable: '/${'p' * 1024}/$name',
          ),
        for (var i = 0; i < maxUserProfiles; i++) atBound(i),
      ],
      defaultId: 'user-0',
      defaultAvailable: true,
    );
    final response = jsonEncode({
      'jsonrpc': '2.0',
      'id': 1 << 31,
      'result': result.toJson(),
    });

    expect(utf8.encode(response).length, lessThan(maxControlMessage));
  });

  test('ShellProfile rejects a wrong shape and over-size content', () {
    Json base() => {...profile.toJson()};
    expectReason(
      () => ShellProfile.fromJson(base()..['args'] = 'a b'),
      ErrorCode.invalidParams,
    );
    expectReason(
      () => ShellProfile.fromJson(base()..['env'] = {'A': 1}),
      ErrorCode.invalidParams,
    );
    expectReason(
      () => ShellProfile.fromJson(base()..remove('executable')),
      ErrorCode.invalidParams,
    );
    expectReason(
      () => ShellProfile.fromJson(
        base()..['args'] = List.filled(maxProfileArgs + 1, 'a'),
      ),
      ErrorCode.invalidParams,
    );
    expectReason(
      () => ShellProfile.fromJson(
        base()..['args'] = ['a' * (maxProfileArgBytes + 1)],
      ),
      ErrorCode.invalidParams,
    );
    expectReason(
      () => ShellProfile.fromJson(
        base()..['env'] = {for (var i = 0; i <= maxProfileEnv; i++) 'K$i': 'v'},
      ),
      ErrorCode.invalidParams,
    );
  });

  test('profile messages round-trip', () {
    final list = ProfileListResult(
      profiles: [profile],
      defaultId: 'p1',
      defaultAvailable: true,
    );
    final listBack = ProfileListResult.fromJson(list.toJson());
    expect(listBack.profiles.single.toJson(), profile.toJson());
    expect(listBack.defaultId, 'p1');
    expect(listBack.defaultAvailable, isTrue);

    final none = ProfileListResult.fromJson(
      const ProfileListResult(
        profiles: [],
        defaultId: 'gone',
        defaultAvailable: false,
      ).toJson(),
    );
    expect(none.defaultId, 'gone');
    expect(none.defaultAvailable, isFalse);
    expect(
      ProfileListResult.fromJson(
        const ProfileListResult(profiles: [], defaultAvailable: false).toJson(),
      ).defaultId,
      isNull,
    );

    expect(
      ProfileSaveParams.fromJson(ProfileSaveParams(profile).toJson()).profile
          .toJson(),
      profile.toJson(),
    );
    expect(
      ProfileSaveResult.fromJson(ProfileSaveResult(profile).toJson()).profile
          .toJson(),
      profile.toJson(),
    );
    expect(
      ProfileRemoveParams.fromJson(const ProfileRemoveParams('p1').toJson()).id,
      'p1',
    );
    expect(
      ProfileSetDefaultParams.fromJson(
        const ProfileSetDefaultParams('p1').toJson(),
      ).id,
      'p1',
    );
  });

  test('terminal messages round-trip', () {
    final open = TerminalOpenParams.fromJson(
      const TerminalOpenParams(
        profileId: 'p1',
        workspaceId: 'w1',
        cols: 120,
        rows: 40,
      ).toJson(),
    );
    expect(
      (open.profileId, open.workspaceId, open.cols, open.rows),
      ('p1', 'w1', 120, 40),
    );
    final bare = TerminalOpenParams.fromJson(
      const TerminalOpenParams(profileId: 'p1', cols: 80, rows: 24).toJson(),
    );
    expect(bare.workspaceId, isNull);

    final result = TerminalOpenResult.fromJson(
      const TerminalOpenResult(
        terminalId: 't1',
        outputChannel: 3,
        inputChannel: 4,
      ).toJson(),
    );
    expect(
      (result.terminalId, result.outputChannel, result.inputChannel),
      ('t1', 3, 4),
    );

    expect(
      TerminalAttachParams.fromJson(const TerminalAttachParams('t1').toJson())
          .terminalId,
      't1',
    );
    expect(
      TerminalCloseParams.fromJson(const TerminalCloseParams('t1').toJson())
          .terminalId,
      't1',
    );
    expect(
      TerminalReleaseParams.fromJson(const TerminalReleaseParams('t1').toJson())
          .terminalId,
      't1',
    );
    final resize = TerminalResizeParams.fromJson(
      const TerminalResizeParams(
        terminalId: 't1',
        cols: 1000,
        rows: 500,
      ).toJson(),
    );
    expect((resize.terminalId, resize.cols, resize.rows), ('t1', 1000, 500));
  });

  test('terminal notifications round-trip with every exit reason', () {
    for (final reason in TerminalExitReason.values) {
      final back = TerminalExited.fromJson(
        TerminalExited(
          terminalId: 't1',
          status: 3,
          reason: reason,
          outputComplete: reason != TerminalExitReason.ioError,
        ).toJson(),
      );
      expect(back.terminalId, 't1');
      expect(back.status, 3);
      expect(back.reason, reason);
      expect(back.outputComplete, reason != TerminalExitReason.ioError);
    }
    expect(
      [for (final r in TerminalExitReason.values) r.wire],
      ['exited', 'closed', 'io-error'],
    );
    final noStatus = TerminalExited.fromJson(
      const TerminalExited(
        terminalId: 't1',
        reason: TerminalExitReason.closed,
        outputComplete: true,
      ).toJson(),
    );
    expect(noStatus.status, isNull);
    expectReason(
      () => TerminalExited.fromJson({
        'terminalId': 't1',
        'reason': 'vanished',
        'outputComplete': true,
      }),
      ErrorCode.invalidParams,
    );

    final failed = TerminalCloseFailed.fromJson(
      const TerminalCloseFailed(
        terminalId: 't1',
        reason: 'unresolved',
      ).toJson(),
    );
    expect((failed.terminalId, failed.reason), ('t1', 'unresolved'));
    expect(
      TerminalCloseFailed(
        terminalId: 't1',
        reason: 'é' * 1000,
      ).toJson()['reason']!.toString().length,
      lessThanOrEqualTo(maxReasonBytes),
    );
  });

  test('size bounds: 1..1000 columns and 1..500 rows, else invalid-size', () {
    Json size(int cols, int rows) => {
      'terminalId': 't1',
      'cols': cols,
      'rows': rows,
    };
    for (final (c, r) in [(1, 1), (1000, 500), (80, 24)]) {
      final p = TerminalResizeParams.fromJson(size(c, r));
      expect((p.cols, p.rows), (c, r));
    }
    for (final (c, r) in [(0, 24), (1001, 24), (80, 0), (80, 501), (-1, 24)]) {
      expectReason(
        () => TerminalResizeParams.fromJson(size(c, r)),
        ErrorCode.invalidSize,
      );
      expectReason(
        () => TerminalOpenParams.fromJson({
          'profileId': 'p',
          'cols': c,
          'rows': r,
        }),
        ErrorCode.invalidSize,
      );
    }
    // A non-integer is a malformed message, not a size.
    expectReason(
      () => TerminalResizeParams.fromJson({
        'terminalId': 't1',
        'cols': '80',
        'rows': 24,
      }),
      ErrorCode.invalidParams,
    );
    expectReason(
      () => TerminalResizeParams.fromJson({'terminalId': 't1', 'cols': 80}),
      ErrorCode.invalidParams,
    );
  });

  group('capability gating over a connection', () {
    Future<(Connection, Connection)> pair({
      required Set<String> desktop,
      required Set<String> host,
    }) async {
      final p = connectedPair(
        capabilitiesA: desktop,
        capabilitiesB: host,
        onRequestB: (method, params) => <String, Object?>{'ok': method},
      );
      await p.$1.hello();
      return p;
    }

    test(
      'both peers advertise terminal: profile and terminal methods work',
      () async {
        final (desktop, host) = await pair(
          desktop: {Capability.terminal},
          host: {Capability.terminal},
        );
        for (final m in [Method.profileList, Method.terminalOpen]) {
          expect(await desktop.request(m, {}), {'ok': m});
        }
        await desktop.close();
        await host.close();
      },
    );

    test('a host without it answers method-not-available and the session '
        'keeps working', () async {
      final (desktop, host) = await pair(
        desktop: {Capability.terminal, Capability.workbench},
        host: {Capability.workbench},
      );
      for (final m in [Method.profileList, Method.terminalOpen]) {
        await expectLater(
          desktop.request(m, {}),
          throwsA(
            isA<RpcException>().having(
              (e) => e.reason,
              'reason',
              ErrorCode.methodNotAvailable,
            ),
          ),
        );
      }
      expect(await desktop.request(Method.workbenchLoad, {}), {
        'ok': Method.workbenchLoad,
      });
      await desktop.close();
      await host.close();
    });
  });
}
