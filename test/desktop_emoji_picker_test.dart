import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matter/pages/chat/desktop_emoji_picker.dart';
import 'package:matter/pages/chat/emoji_data.dart';
import 'package:matter/theme/material_theme.dart';

void main() {
  testWidgets(
    'category footer follows scrolling and navigates distant sections',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildMaterialTheme(Brightness.dark),
          home: Scaffold(
            body: SizedBox(
              width: 380,
              height: 460,
              child: DesktopEmojiPicker(onSelected: (_) {}),
            ),
          ),
        ),
      );
      final scroll = tester
          .widget<CustomScrollView>(
            find.byKey(const ValueKey('desktop-emoji-scroll')),
          )
          .controller!;
      IconButton category(int i) => tester.widget<IconButton>(
        find.byKey(ValueKey('desktop-emoji-category-$i')),
      );
      expect(category(0).isSelected, isTrue);
      await tester.drag(
        find.byKey(const ValueKey('desktop-emoji-scroll')),
        const Offset(0, -320),
      );
      await tester.pumpAndSettle();
      expect(category(1).isSelected, isTrue);
      final last = kEmojiCategories.length - 1;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(category(last).isSelected, isTrue);
      await tester.ensureVisible(
        find.byKey(const ValueKey('desktop-emoji-category-0')),
      );
      await tester.tap(find.byKey(const ValueKey('desktop-emoji-category-0')));
      await tester.pumpAndSettle();
      expect(scroll.offset, 0);
      expect(category(0).isSelected, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
