import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/date_separator.dart';

import '../helpers/neu_test_theme.dart';

void main() {
  group('DateSeparator', () {
    testWidgets('renders the supplied date label', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: neuTestTheme(),
          home: const Scaffold(body: DateSeparator(dateLabel: '今天')),
        ),
      );

      expect(find.text('今天'), findsOneWidget);
    });
  });
}
