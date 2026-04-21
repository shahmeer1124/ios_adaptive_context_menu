import 'package:flutter_test/flutter_test.dart';

import 'package:example/main.dart';

void main() {
  testWidgets('renders demo action trigger', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Login'), findsOneWidget);
    expect(find.text('Last selected: none'), findsOneWidget);
  });
}
