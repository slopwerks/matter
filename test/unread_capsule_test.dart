import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matter/pages/chat/latest_message_control.dart';
import 'package:matter/theme/material_theme.dart';

void main() {
  testWidgets(
    'LatestMessageControl clips ink to the capsule height while keeping a 48dp hit target',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildMaterialTheme(
            Brightness.dark,
          ).copyWith(platform: TargetPlatform.android),
          home: Scaffold(
            body: Center(
              child: LatestMessageControl(
                visible: true,
                showSentNotice: false,
                onPressed: () => taps++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final control = find.byType(LatestMessageControl);
      final ink = find.descendant(of: control, matching: find.byType(Ink));
      final inkWell = find.descendant(
        of: control,
        matching: find.byType(InkWell),
      );
      final controlRect = tester.getRect(control);
      final inkRect = tester.getRect(ink);
      final inkWellRect = tester.getRect(inkWell);

      expect(controlRect.height, greaterThanOrEqualTo(48));
      expect(inkWellRect, equals(inkRect));
      expect(inkRect.height, lessThan(48));

      // Tapping the outer 48dp padded band still triggers the capsule.
      await tester.tapAt(Offset(controlRect.center.dx, controlRect.top + 2));
      await tester.pump();
      expect(taps, 1);
    },
  );
}
