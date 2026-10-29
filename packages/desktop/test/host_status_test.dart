import 'dart:async';

import 'package:desktop/src/host_controller.dart';
import 'package:desktop/src/host_link.dart';
import 'package:desktop/src/host_status_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:host_protocol/host_protocol.dart';

import 'support/fake_host.dart';

const hostPath = '/app/host/bin/kumiko_host';

Future<HostController> pumpStatus(
  WidgetTester tester,
  HostConnector connector, {
  void Function()? onExit,
}) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = HostController(
    connector: connector,
    onExit: onExit ?? () {},
  );
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: HostStatusPage(controller: controller, hostPath: hostPath),
    ),
  );
  unawaited(controller.start());
  await tester.pump();
  return controller;
}

HostConnector rejecting(HostStartException e) =>
    () async => throw e;

void main() {
  testWidgets('starting shows the host as starting and offers no action', (
    tester,
  ) async {
    final gate = Completer<HostLink>();
    await pumpStatus(tester, () => gate.future);

    expect(find.text('Starting the host...'), findsOneWidget);
    expect(find.byType(ButtonStyleButton), findsNothing);

    gate.complete(FakeHostLink());
    await tester.pumpAndSettle();
    expect(find.text('Starting the host...'), findsNothing);
  });

  testWidgets('connected shows the negotiated version and host version', (
    tester,
  ) async {
    await pumpStatus(tester, () async => FakeHostLink());
    await tester.pumpAndSettle();

    expect(find.text('Host connected'), findsOneWidget);
    expect(find.textContaining('Protocol version 1'), findsOneWidget);
    expect(find.textContaining('0.1.0'), findsOneWidget);
  });

  testWidgets('reconciling host shows cleaning up until cleanup state', (
    tester,
  ) async {
    final link = FakeHostLink(hello: helloResult(state: HostState.reconciling));
    await pumpStatus(tester, () async => link);
    await tester.pumpAndSettle();

    expect(find.textContaining('Cleaning up'), findsOneWidget);

    link.emitState();
    await tester.pumpAndSettle();
    expect(find.textContaining('Cleaning up'), findsNothing);
  });

  testWidgets('missing host shows start error with path', (tester) async {
    await pumpStatus(
      tester,
      rejecting(
        HostStartException(
          HostStartFailure.spawnFailed,
          'ProcessException: The system cannot find the file specified',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Host start error'), findsOneWidget);
    expect(find.textContaining(hostPath), findsOneWidget);
    expect(find.text('Restart host'), findsOneWidget);
  });

  testWidgets('hello timeout shows start error stating the timeout', (
    tester,
  ) async {
    var starts = 0;
    final link = FakeHostLink();
    await pumpStatus(tester, () async {
      starts++;
      if (starts == 1) {
        throw HostStartException(
          HostStartFailure.helloTimeout,
          'no hello answer in 30000 ms',
        );
      }
      return link;
    });
    await tester.pumpAndSettle();

    expect(find.text('Host start error'), findsOneWidget);
    expect(find.textContaining('timeout'), findsWidgets);

    await tester.tap(find.text('Restart host'));
    await tester.pumpAndSettle();
    expect(starts, 2);
    expect(find.text('Host connected'), findsOneWidget);
  });

  testWidgets('incompatible shows both ranges', (tester) async {
    final e = incompatibleVersions(
      const VersionRange(1, 1),
      const VersionRange(2, 4),
    );
    await pumpStatus(
      tester,
      rejecting(
        HostStartException(
          HostStartFailure.helloRejected,
          e.message,
          reason: e.reason,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Incompatible host'), findsOneWidget);
    expect(find.textContaining('1..1'), findsOneWidget);
    expect(find.textContaining('2..4'), findsOneWidget);
  });

  testWidgets('profile-locked shows already running and exits on dismiss', (
    tester,
  ) async {
    var exited = 0;
    await pumpStatus(
      tester,
      rejecting(
        HostStartException(
          HostStartFailure.helloRejected,
          'the profile is in use',
          reason: ErrorCode.profileLocked,
        ),
      ),
      onExit: () => exited++,
    );
    await tester.pumpAndSettle();

    expect(find.text('Kumiko is already running'), findsOneWidget);
    expect(find.text('Restart host'), findsNothing);
    expect(exited, 0);

    await tester.tap(find.text('Dismiss'));
    await tester.pump();
    expect(exited, 1);
  });

  testWidgets('store error shows the path and both versions', (tester) async {
    await pumpStatus(
      tester,
      rejecting(
        HostStartException(
          HostStartFailure.helloRejected,
          'store version 7 is newer than supported 5: /data/Kumiko/store.db',
          reason: ErrorCode.storeNewer,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Store error'), findsOneWidget);
    expect(find.textContaining('/data/Kumiko/store.db'), findsOneWidget);
    expect(find.textContaining('version 7'), findsOneWidget);
    expect(find.textContaining('supported 5'), findsOneWidget);
  });

  testWidgets('host lost shows restart and no running unit', (tester) async {
    final first = FakeHostLink();
    final second = FakeHostLink();
    var starts = 0;
    await pumpStatus(tester, () async => starts++ == 0 ? first : second);
    await tester.pumpAndSettle();
    expect(find.text('Host connected'), findsOneWidget);

    first.lose();
    await tester.pumpAndSettle();

    expect(find.text('Host lost'), findsOneWidget);
    expect(find.text('Host connected'), findsNothing);
    expect(find.text('Restart host'), findsOneWidget);
    expect(find.textContaining('Nothing is running'), findsOneWidget);
    expect(find.textContaining('Running'), findsNothing);

    await tester.tap(find.text('Restart host'));
    await tester.pumpAndSettle();
    expect(starts, 2);
    expect(find.text('Host connected'), findsOneWidget);
  });

  testWidgets('host lost by a protocol violation shows the reason', (
    tester,
  ) async {
    final link = FakeHostLink();
    await pumpStatus(tester, () async => link);
    await tester.pumpAndSettle();

    link.lose(
      const HostLoss(
        HostLossKind.connectionClosed,
        null,
        CloseReason(
          CloseReason.protocolViolation,
          'frame length 70000 exceeds 65536',
        ),
        '',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Host lost'), findsOneWidget);
    expect(find.textContaining(CloseReason.protocolViolation), findsOneWidget);
    expect(
      find.textContaining('frame length 70000 exceeds 65536'),
      findsOneWidget,
    );
  });
}
