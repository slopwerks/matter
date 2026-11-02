import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/unread_messages_banner.dart';

import 'helpers/neu_test_theme.dart';

void main() {
  for (final material in [false, true]) {
    for (final dark in [false, true]) {
      testWidgets(
        'unread entry exposes jump and dismiss (material=$material dark=$dark)',
        (tester) async {
          var jumps = 0;
          var dismisses = 0;
          await tester.binding.setSurfaceSize(const Size(320, 640));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(
            MaterialApp(
              theme: neuTestTheme(material: material, dark: dark),
              home: Scaffold(
                body: UnreadMessagesBanner(
                  count: 1234,
                  hasReadMarker: true,
                  loading: false,
                  onPressed: () => jumps++,
                  onDismiss: () => dismisses++,
                ),
              ),
            ),
          );
          expect(find.text('1234 条未读 · 跳到最早未读'), findsOneWidget);
          await tester.tap(find.byType(TextButton));
          await tester.tap(find.byTooltip('关闭未读提示'));
          expect(jumps, 1);
          expect(dismisses, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('locating prevents duplicate requests and can be dismissed', (
    tester,
  ) async {
    var jumps = 0;
    var dismissed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: neuTestTheme(),
        home: Scaffold(
          body: UnreadMessagesBanner(
            count: 99,
            hasReadMarker: true,
            loading: true,
            onPressed: () => jumps++,
            onDismiss: () => dismissed = true,
          ),
        ),
      ),
    );
    expect(
      tester.widget<TextButton>(find.byType(TextButton)).onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('关闭未读提示'));
    expect(jumps, 0);
    expect(dismissed, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
