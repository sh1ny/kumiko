import 'package:desktop/main.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_host.dart';

void main() {
  testWidgets('app starts and connects to the scripted host', (tester) async {
    await tester.pumpWidget(
      KumikoApp(
        connector: () async => FakeHostLink(),
        hostPath: '/app/host/bin/kumiko_host',
        onExit: () {},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Personal'), findsOneWidget);
    expect(find.text('Host connected'), findsOneWidget);
  });
}
