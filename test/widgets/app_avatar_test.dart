import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/widgets/app_avatar.dart';

import '../helpers/neu_test_theme.dart';

void main() {
  group('AppAvatar', () {
    testWidgets('shows a single-letter initial for one-word names', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: neuTestTheme(),
            home: const Scaffold(body: AppAvatar(fallback: 'Alice')),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('shows two-letter initials for multi-word names', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: neuTestTheme(),
            home: const Scaffold(body: AppAvatar(fallback: 'Alice Smith')),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('AS'), findsOneWidget);
    });

    testWidgets('collapses whitespace when building initials', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: neuTestTheme(),
            home: const Scaffold(body: AppAvatar(fallback: 'Alice  Bob')),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('AB'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows question mark for empty fallback', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: neuTestTheme(),
            home: const Scaffold(body: AppAvatar(fallback: '')),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('?'), findsOneWidget);
    });

    testWidgets('renders at the requested size', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: neuTestTheme(),
            home: const Scaffold(body: AppAvatar(fallback: 'A', size: 64)),
          ),
        ),
      );
      await tester.pump();

      final size = tester.getSize(find.byType(AppAvatar));
      expect(size, const Size(64, 64));
    });
  });
}
