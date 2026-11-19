import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/widgets/app_avatar.dart';

import '../helpers/neu_test_theme.dart';

void main() {
  testWidgets('avatar initials and size follow the supplied fallback', (
    tester,
  ) async {
    for (final (fallback, initials, size) in [
      ('Alice', 'A', 32.0),
      ('Alice Smith', 'AS', 48.0),
      ('Alice  Bob', 'AB', 64.0),
      ('', '?', 32.0),
    ]) {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: AppAvatar(fallback: fallback, size: size),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text(initials), findsOneWidget, reason: fallback);
      expect(tester.getSize(find.byType(AppAvatar)), Size(size, size));
      expect(tester.takeException(), isNull);
    }
  });
}
