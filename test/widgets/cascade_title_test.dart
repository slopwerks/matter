import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/widgets/cascade_title.dart';

void main() {
  group('CascadeTitle', () {
    testWidgets('cross-fades to new text', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CascadeTitle(text: 'Home', style: TextStyle(fontSize: 20)),
          ),
        ),
      );
      expect(find.text('Home'), findsOneWidget);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CascadeTitle(
              text: 'Settings',
              style: TextStyle(fontSize: 20),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);

      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(CascadeTitle),
          matching: find.text('Home'),
        ),
        findsNothing,
      );
      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('does not animate when text is unchanged', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CascadeTitle(text: 'Home', style: TextStyle(fontSize: 20)),
          ),
        ),
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CascadeTitle(text: 'Home', style: TextStyle(fontSize: 20)),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Home'), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  });
}
