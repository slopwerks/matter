import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/date_separator.dart';
import 'package:matter/widgets/neu_surface.dart';

import '../helpers/neu_test_theme.dart';

void main() {
  group('DateSeparator', () {
    testWidgets('renders the date label in a centered neu pill', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: neuTestTheme(),
          home: const Scaffold(body: DateSeparator(dateLabel: '今天')),
        ),
      );

      expect(find.text('今天'), findsOneWidget);
      expect(find.byType(NeuSurface), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byType(NeuSurface),
          matching: find.byType(Center),
        ),
        findsOneWidget,
      );
    });

    testWidgets('applies vertical padding around the pill', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: neuTestTheme(),
          home: const Scaffold(body: DateSeparator(dateLabel: '昨天')),
        ),
      );

      final padding = tester.widget<Padding>(
        find.ancestor(of: find.byType(Center), matching: find.byType(Padding)),
      );
      expect(padding.padding, const EdgeInsets.symmetric(vertical: 14));
    });
  });
}
