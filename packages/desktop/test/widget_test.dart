import 'package:desktop/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app starts', (tester) async {
    await tester.pumpWidget(const KumikoApp());
    expect(find.text('Kumiko'), findsOneWidget);
  });
}
