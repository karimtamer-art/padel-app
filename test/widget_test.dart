import 'package:flutter_test/flutter_test.dart';
import 'package:padel_clay/main.dart';

void main() {
  testWidgets('app smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const PadelApp());
    expect(find.byType(PadelApp), findsOneWidget);
  });
}
