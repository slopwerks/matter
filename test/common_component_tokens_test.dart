import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/chat_list_item.dart';
import 'package:matter/theme/app_component_theme.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/theme/neu_theme.dart';
import 'package:matter/theme/tokens.dart';
import 'package:matter/widgets/floating_app_bar.dart';
import 'package:matter/widgets/grouped_rows.dart';

void main() {
  for (final material in [false, true]) {
    for (final brightness in Brightness.values) {
      final theme = material
          ? buildMaterialTheme(brightness)
          : buildNeuTheme(
              brightness == Brightness.dark ? NeuColors.dark : NeuColors.light,
              brightness,
            );
      testWidgets(
        '${material ? 'Material' : 'Neu'} $brightness component contracts retain geometry',
        (tester) async {
          late AppComponentTheme components;
          late AppDesignTokens tokens;
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: Builder(
                builder: (context) {
                  components = AppComponentTheme.of(context);
                  tokens = context.tokens;
                  return const Scaffold(
                    body: Column(
                      children: [
                        GroupedRows(
                          children: [
                            SizedBox(height: 20),
                            SizedBox(height: 20),
                          ],
                        ),
                        ChatListDivider(),
                        ChatListDivider(dense: true),
                        MaterialToolbar(
                          child: IconButton(
                            onPressed: null,
                            icon: Icon(Icons.add),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          );
          expect(components.rowRadius, material ? 28 : 18);
          expect(components.rowHorizontalPadding, material ? 12 : 8);
          expect(components.avatarSize, material ? 44 : 46);
          expect(components.denseAvatarSize, material ? 40 : 44);
          final dividers = tester
              .widgetList<Container>(
                find.descendant(
                  of: find.byType(ChatListDivider),
                  matching: find.byType(Container),
                ),
              )
              .toList();
          expect(
            (dividers.first.margin! as EdgeInsets).left,
            material ? 68 : 66,
          );
          expect(
            (dividers.last.margin! as EdgeInsets).left,
            material ? 64 : 64,
          );
          expect(
            dividers.every((box) => box.color == tokens.surfaces.hairline),
            isTrue,
          );
          final card = tester.widget<Material>(
            find.descendant(
              of: find.byType(GroupedRows),
              matching: find.byType(Material),
            ),
          );
          expect(card.color, tokens.surfaces.card);
          expect(components.toolbarStyle, material ? isNotNull : isNull);
          final button = tester.element(find.byType(IconButton));
          expect(IconButtonTheme.of(button).style, components.toolbarStyle);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  test(
    'component geometry interpolates while layout switches with the palette',
    () {
      final material = buildMaterialTheme(Brightness.light);
      final neu = buildNeuTheme(NeuColors.dark, Brightness.dark);
      for (final t in [0.0, .25, .5, 1.0]) {
        final resolved = ThemeData.lerp(
          material,
          neu,
          t,
        ).extension<AppComponentTheme>()!;
        expect(resolved.rowRadius, 28 + (18 - 28) * t);
        expect(resolved.avatarSize, 44 + 2 * t);
        expect(
          resolved.conversationLayout,
          t < .5
              ? ConversationRowLayout.trailingStatus
              : ConversationRowLayout.inlineStatus,
        );
        expect(resolved.toolbarStyle, t < .5 ? isNotNull : isNull);
      }
    },
  );
}
