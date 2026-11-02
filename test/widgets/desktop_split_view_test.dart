import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/desktop_split_view.dart';

import '../helpers/neu_test_theme.dart';

void main() {
  for (final material in [false, true]) {
    for (final dark in [false, true]) {
      testWidgets('split panes keep chat width ($material, $dark)', (
        tester,
      ) async {
        addTearDown(() => tester.binding.setSurfaceSize(null));
        for (final width in [883.0, 947.0, 1123.0, 1800.0]) {
          await tester.binding.setSurfaceSize(Size(width, 720));
          await tester.pumpWidget(
            MaterialApp(
              theme: neuTestTheme(material: material, dark: dark),
              home: const Scaffold(
                body: DesktopSplitView(
                  roomList: SizedBox.expand(),
                  chat: SizedBox.expand(key: ValueKey('chat')),
                  details: SizedBox.expand(key: ValueKey('details')),
                ),
              ),
            ),
          );
          expect(
            tester.getSize(find.byKey(const ValueKey('chat'))).width,
            greaterThanOrEqualTo(360),
          );
          expect(
            find.byKey(const ValueKey('details')),
            width >= 929 ? findsOneWidget : findsNothing,
          );
          final chatContext = tester.element(
            find.byKey(const ValueKey('chat')),
          );
          expect(
            MediaQuery.sizeOf(chatContext).width,
            tester.getSize(find.byKey(const ValueKey('chat'))).width,
          );
          expect(tester.takeException(), isNull);
        }
      });
    }
  }

  testWidgets('dragging divider clamps width and keeps the chat mounted', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1300, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopSplitView(
            roomList: const SizedBox.expand(),
            chat: TextField(controller: controller),
            details: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'keep this draft');
    final state = tester.state(find.byType(TextField));
    final divider = find.byKey(const ValueKey('desktop-list-divider'));
    await tester.drag(divider, const Offset(600, 0));
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const ValueKey('desktop-room-list'))).width,
      480,
    );
    await tester.drag(divider, const Offset(-800, 0));
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const ValueKey('desktop-room-list'))).width,
      260,
    );
    expect(tester.state(find.byType(TextField)), same(state));
    expect(controller.text, 'keep this draft');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 350));
  });
}
