import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/providers/chat_visual_settings_provider.dart';
import 'package:matter/widgets/glass.dart';

import '../helpers/neu_test_theme.dart';

void main() {
  for (final reduced in [true, false]) {
    for (final bottom in [false, true]) {
      testWidgets(
        '${reduced ? 6 : 16}-strip ${bottom ? 'bottom' : 'top'} blur fades out before the content edge',
        (tester) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: neuTestTheme(),
              home: ChatVisualSettingsScope(
                settings: ChatVisualSettings(
                  progressiveBlurReducedFallbackEnabled: reduced,
                  progressiveBlurSigmaCapEnabled: false,
                ),
                child: Scaffold(
                  body: SizedBox(
                    width: 200,
                    height: 120,
                    child: bottom
                        ? const BottomFadeBlur(blur: 20, fadeStart: 30)
                        : const TopFadeBlur(blur: 20),
                  ),
                ),
              ),
            ),
          );
          final strips = tester.widgetList<Positioned>(find.byType(Positioned));
          final activeHeight = bottom ? 90.0 : 120.0;
          expect(strips, isNotEmpty);
          for (final strip in strips) {
            final offset = bottom ? strip.bottom! : strip.top!;
            expect(offset, lessThan(activeHeight * 5 / 6));
            expect(offset + strip.height!, lessThanOrEqualTo(activeHeight + 1));
          }
        },
      );
    }
  }
}
