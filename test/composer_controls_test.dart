import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/composer/composer_actions_bar.dart';
import 'package:matter/pages/chat/composer/composer_quote_banner.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/theme/neu_theme.dart';

void main() {
  for (final material in [false, true]) {
    for (final brightness in Brightness.values) {
      final label = '${material ? 'Material' : 'Neu'} $brightness';
      final theme = material
          ? buildMaterialTheme(brightness)
          : buildNeuTheme(
              brightness == Brightness.dark ? NeuColors.dark : NeuColors.light,
              brightness,
            );

      testWidgets('$label banners preserve cancel and in-flight behavior', (
        tester,
      ) async {
        var cancelled = 0;
        await tester.pumpWidget(
          _app(
            theme,
            ComposerQuoteBanner.reply(
              senderName: 'Alice',
              content: 'A long quoted message that stays on one line',
              onCancel: () => cancelled++,
            ),
          ),
        );
        expect(find.text('Alice'), findsOneWidget);
        expect(tester.widget<Text>(find.text('Alice')).maxLines, 1);
        await tester.tap(find.byIcon(Icons.close_rounded));
        expect(cancelled, 1);

        await tester.pumpWidget(
          _app(
            theme,
            ComposerQuoteBanner.editing(
              content: 'Original message',
              sendInFlight: true,
              onCancel: () => cancelled++,
            ),
          ),
        );
        expect(find.text('编辑中'), findsOneWidget);
        expect(find.byIcon(Icons.close_rounded), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(cancelled, 1);
        expect(tester.takeException(), isNull);
      });

      for (final expanded in [false, true]) {
        testWidgets(
          '$label controls (expanded=$expanded) retain callbacks and busy guards',
          (tester) async {
            var sends = 0;
            var emojis = 0;
            var attachments = 0;
            var menus = 0;
            BuildContext? anchor;
            Widget controls({
              bool busy = false,
              bool hasText = false,
              bool hasImages = false,
            }) => ComposerActionsBar(
              expanded: expanded,
              compact: expanded,
              showMore: expanded,
              inlineImages: expanded,
              emojiIcon: Icons.sentiment_satisfied_alt_rounded,
              emojiSelected: false,
              attachmentSelected: false,
              sendBusy: busy,
              hasText: hasText,
              hasImages: hasImages,
              editor: const SizedBox(height: 44),
              onToggleEmoji: () => emojis++,
              onToggleAttachment: () => attachments++,
              onShowTools: (context) {
                menus++;
                anchor = context;
              },
              onSend: () => sends++,
            );
            Widget app(Widget child) =>
                _app(theme, child, width: expanded ? 800 : 320);
            await tester.pumpWidget(app(controls()));
            if (expanded) {
              expect(
                tester
                    .widget<FilledButton>(find.byType(FilledButton))
                    .onPressed,
                isNull,
              );
            } else {
              expect(find.byKey(const ValueKey('voice_only')), findsOneWidget);
            }
            await tester.tap(
              find.byIcon(Icons.sentiment_satisfied_alt_rounded),
            );
            await tester.tap(
              find.byIcon(expanded ? Icons.image_outlined : Icons.add_rounded),
            );
            expect(emojis, 1);
            expect(attachments, 1);
            await tester.longPress(
              find.byIcon(expanded ? Icons.image_outlined : Icons.add_rounded),
            );
            expect(menus, 1);
            expect(anchor!.findRenderObject(), isA<RenderBox>());
            if (expanded) {
              await tester.tap(find.byIcon(Icons.more_horiz_rounded));
              expect(menus, 2);
            }

            // Image-only drafts can send, even with no text.
            await tester.pumpWidget(app(controls(hasImages: true)));
            await tester.pumpAndSettle();
            expect(find.byKey(const ValueKey('send_only')), findsOneWidget);
            await tester.tap(find.byIcon(Icons.send_rounded));
            expect(sends, 1);

            await tester.pumpWidget(app(controls(busy: true, hasText: true)));
            await tester.pump();
            final menuCount = menus;
            await tester.tap(
              find.byIcon(Icons.sentiment_satisfied_alt_rounded),
            );
            await tester.tap(
              find.byIcon(expanded ? Icons.image_outlined : Icons.add_rounded),
            );
            await tester.longPress(
              find.byIcon(expanded ? Icons.image_outlined : Icons.add_rounded),
            );
            expect(emojis, 1);
            expect(attachments, 1);
            expect(menus, menuCount);
            expect(sends, 1);
            expect(find.byType(CircularProgressIndicator), findsOneWidget);
            expect(tester.takeException(), isNull);
            // Continuous progress indicators do not settle.
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
}

Widget _app(ThemeData theme, Widget child, {double width = 320}) => MaterialApp(
  theme: theme,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: const TextScaler.linear(1.5)),
    child: child!,
  ),
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: SizedBox(width: width, child: child),
    ),
  ),
);
