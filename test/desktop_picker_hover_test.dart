import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matter/pages/chat/desktop_picker_preview.dart';
import 'package:matter/theme/material_theme.dart';

void main() {
  testWidgets(
    'scroll hides previews and stationary pointer cannot rearm after cooldown',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      var identity = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildMaterialTheme(Brightness.dark),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return DesktopPickerHoverScope(
                  identity: identity,
                  child: SizedBox(
                    width: 300,
                    height: 300,
                    child: ListView.builder(
                      controller: scroll,
                      itemExtent: 60,
                      itemCount: 30,
                      itemBuilder: (_, index) => DesktopPickerPreview(
                        name: 'Preview $index',
                        details: 'Metadata $index',
                        preview: const Text('😀'),
                        child: Text('Item $index'),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(700, 500));
      await mouse.moveTo(const Offset(100, 90));
      await tester.pump(const Duration(milliseconds: 499));
      expect(find.text('Preview 1'), findsNothing);
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('Preview 1'), findsOneWidget);

      tester.binding.handlePointerEvent(
        const PointerScrollEvent(
          position: Offset(100, 90),
          scrollDelta: Offset(0, 60),
        ),
      );
      await tester.pump();
      expect(find.textContaining('Preview '), findsNothing);
      scroll.jumpTo(180);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(find.textContaining('Preview '), findsNothing);

      await mouse.moveTo(const Offset(101, 90));
      await tester.pump(const Duration(milliseconds: 400));
      await mouse.moveTo(const Offset(111, 90));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('Preview '), findsNothing);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('Preview '), findsOneWidget);

      final animation = scroll.animateTo(
        600,
        duration: const Duration(seconds: 1),
        curve: Curves.linear,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await mouse.moveTo(const Offset(115, 90));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.textContaining('Preview '), findsNothing);
      await tester.pumpAndSettle();
      await animation;
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.textContaining('Preview '), findsNothing);
      await mouse.moveTo(const Offset(116, 90));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('Preview '), findsOneWidget);

      update(() => identity++);
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Preview '), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      expect(find.textContaining('Preview '), findsNothing);
      await mouse.moveTo(const Offset(112, 90));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('Preview '), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(find.textContaining('Preview '), findsNothing);
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    },
  );
}
