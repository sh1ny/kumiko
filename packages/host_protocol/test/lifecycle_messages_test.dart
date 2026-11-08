import 'dart:convert';

import 'package:host_protocol/host_protocol.dart';
import 'package:test/test.dart';

import 'support/sinks.dart';

void expectReason(void Function() body, String reason) => expect(
  body,
  throwsA(isA<RpcException>().having((e) => e.reason, 'reason', reason)),
);

void main() {
  test('names and capability of the lifecycle methods', () {
    expect(Capability.lifecycle, 'lifecycle');
    expect(Method.appQuit, 'app/quit');
    expect(Method.appPreviousExit, 'app/previousExit');
    expect(methodCapability[Method.appQuit], Capability.lifecycle);
    expect(methodCapability[Method.appPreviousExit], Capability.lifecycle);
  });

  group('previous exit snapshot', () {
    test('every kind round-trips through JSON', () {
      final opened = DateTime.utc(2026, 11, 2, 10, 30, 15, 250);
      for (final result in [
        PreviousExitResult(kind: PreviousExitKind.quit, openedAt: opened),
        PreviousExitResult(kind: PreviousExitKind.unexpected, openedAt: opened),
        const PreviousExitResult(kind: PreviousExitKind.none),
      ]) {
        final back = PreviousExitResult.fromJson(
          jsonDecode(jsonEncode(result.toJson())) as Json,
        );
        expect(back.kind, result.kind);
        expect(back.openedAt, result.openedAt);
      }
    });

    test('none carries no time on the wire', () {
      expect(const PreviousExitResult(kind: PreviousExitKind.none).toJson(), {
        'kind': 'none',
      });
    });

    test('unknown kinds and bad times are invalid-params', () {
      expectReason(
        () => PreviousExitResult.fromJson({'kind': 'crashed'}),
        ErrorCode.invalidParams,
      );
      expectReason(
        () => PreviousExitResult.fromJson({}),
        ErrorCode.invalidParams,
      );
      expectReason(
        () => PreviousExitResult.fromJson({
          'kind': 'quit',
          'openedAt': 'yesterday',
        }),
        ErrorCode.invalidParams,
      );
    });
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

    test('lifecycle methods round-trip when both advertise it', () async {
      final (desktop, host) = await pair(
        desktop: {Capability.lifecycle},
        host: {Capability.lifecycle},
      );
      for (final m in [Method.appQuit, Method.appPreviousExit]) {
        expect(await desktop.request(m, {}), {'ok': m});
      }
      await desktop.close();
      await host.close();
    });

    test('a host without lifecycle answers method-not-available and the '
        'session keeps working', () async {
      final (desktop, host) = await pair(
        desktop: {Capability.lifecycle, Capability.workbench},
        host: {Capability.workbench},
      );
      for (final m in [Method.appQuit, Method.appPreviousExit]) {
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

    test('a desktop without lifecycle cannot send it either', () async {
      final (desktop, host) = await pair(
        desktop: {Capability.workbench},
        host: {Capability.lifecycle, Capability.workbench},
      );
      await expectLater(
        desktop.request(Method.appPreviousExit, {}),
        throwsA(
          isA<RpcException>().having(
            (e) => e.reason,
            'reason',
            ErrorCode.methodNotAvailable,
          ),
        ),
      );
      await desktop.close();
      await host.close();
    });
  });
}
