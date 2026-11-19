import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/timeline/timeline_bubble_frame.dart';
import 'package:matter/providers/chat_visual_settings_provider.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/theme/neu_theme.dart';
import 'package:matter/theme/tokens.dart';

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
      testWidgets('$label preserves all joined corner positions', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Builder(
              builder: (context) {
                for (final isMe in [false, true]) {
                  for (final first in [false, true]) {
                    for (final last in [false, true]) {
                      expect(
                        timelineBubbleBorderRadius(
                          context,
                          isMe: isMe,
                          isFirst: first,
                          isLast: last,
                        ),
                        _originalRadius(isMe, first, last),
                      );
                    }
                  }
                }
                return const SizedBox();
              },
            ),
          ),
        );
      });

      for (final isMe in [false, true]) {
        testWidgets(
          '$label isMe=$isMe frame pixels and rect match the original',
          (tester) async {
            final boundary = GlobalKey();
            const bubbleKey = ValueKey('bubble');
            late BuildContext host;
            Future<void> pump(bool extracted) async {
              await tester.pumpWidget(
                MaterialApp(
                  theme: theme,
                  home: Scaffold(
                    body: Builder(
                      builder: (context) {
                        host = context;
                        final colors = context.neu;
                        const content = SizedBox(
                          width: 300,
                          height: 44,
                          child: Text('Timeline bubble'),
                        );
                        return Align(
                          alignment: Alignment.topLeft,
                          child: RepaintBoundary(
                            key: boundary,
                            child: SizedBox(
                              width: 320,
                              height: 120,
                              child: ColoredBox(
                                color: theme.scaffoldBackgroundColor,
                                child: Align(
                                  alignment: isMe
                                      ? Alignment.topRight
                                      : Alignment.topLeft,
                                  child: extracted
                                      ? TimelineBubbleFrame(
                                          bubbleKey: bubbleKey,
                                          isMe: isMe,
                                          isFirst: true,
                                          isLast: true,
                                          child: content,
                                        )
                                      : Container(
                                          key: bubbleKey,
                                          constraints: const BoxConstraints(
                                            maxWidth: 320 * .68,
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 14,
                                            vertical: 10,
                                          ),
                                          decoration: _originalDecoration(
                                            context,
                                            colors,
                                            isMe,
                                            _originalRadius(isMe, true, true),
                                          ),
                                          child: content,
                                        ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
            }

            // The actual MediaQuery width must match the legacy 68% constraint.
            tester.view.physicalSize = const Size(320, 640);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            await pump(false);
            final oldRect = tester.getRect(find.byKey(bubbleKey));
            Future<List<int>> pixels() async {
              final render =
                  boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await render.toImage(pixelRatio: 1);
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              );
              image.dispose();
              return bytes!.buffer.asUint8List();
            }

            final original = await tester.runAsync(pixels);
            await pump(true);
            expect(tester.getRect(find.byKey(bubbleKey)), oldRect);
            expect(await tester.runAsync(pixels), orderedEquals(original!));
            expect(TimelineBubbleFrame.maxWidth(host), closeTo(217.6, .001));
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets('custom semantic radii drive frame geometry', (tester) async {
    final base = buildMaterialTheme(Brightness.light);
    final tokens = base.extension<AppDesignTokens>()!;
    final theme = base.copyWith(
      extensions: [
        ...base.extensions.values.where((value) => value is! AppDesignTokens),
        tokens.copyWith(radii: const AppRadii(bubble: 30, tag: 9)),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Builder(
          builder: (context) {
            expect(
              timelineBubbleBorderRadius(
                context,
                isMe: true,
                isFirst: true,
                isLast: true,
              ),
              const BorderRadius.only(
                topLeft: Radius.circular(30),
                topRight: Radius.circular(30),
                bottomLeft: Radius.circular(30),
                bottomRight: Radius.circular(9),
              ),
            );
            return const SizedBox();
          },
        ),
      ),
    );
  });

  testWidgets('wide text frames retain their 520dp cap', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildMaterialTheme(Brightness.light),
        home: Builder(
          builder: (context) {
            expect(TimelineBubbleFrame.maxWidth(context), 520);
            return const SizedBox();
          },
        ),
      ),
    );
  });
}

BorderRadius _originalRadius(bool isMe, bool first, bool last) => isMe
    ? BorderRadius.only(
        topLeft: const Radius.circular(18),
        topRight: Radius.circular(first ? 18 : 6),
        bottomLeft: const Radius.circular(18),
        bottomRight: Radius.circular(last ? 10 : 6),
      )
    : BorderRadius.only(
        topLeft: Radius.circular(first ? 18 : 6),
        topRight: const Radius.circular(18),
        bottomLeft: Radius.circular(last ? 10 : 6),
        bottomRight: const Radius.circular(18),
      );

// Before-extraction paint recipe: intentionally independent of Tokens.
ShapeDecoration _originalDecoration(
  BuildContext context,
  NeuColors colors,
  bool isMe,
  BorderRadius radius,
) {
  final settings = ChatVisualSettingsScope.of(context);
  const offset = 3.8 * .7;
  return ShapeDecoration(
    color: context.isMaterial ? (isMe ? colors.accent : colors.card) : null,
    shape: settings.superellipseBorderEnabled
        ? RoundedSuperellipseBorder(borderRadius: radius)
        : RoundedRectangleBorder(borderRadius: radius),
    gradient: settings.bubbleGradientEnabled
        ? LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isMe
                ? [neuShift(colors.accent, .08), neuShift(colors.accent, -.06)]
                : [neuShift(colors.card, .055), neuShift(colors.card, -.05)],
          )
        : null,
    shadows: settings.bubbleShadowsEnabled
        ? [
            BoxShadow(
              color: colors.shadowDark.withValues(alpha: .72),
              blurRadius:
                  offset *
                  (settings.shadowBlurOptimizationEnabled ? 1.45 : 2.3),
              offset: const Offset(offset, offset),
            ),
            BoxShadow(
              color: colors.shadowLight.withValues(
                alpha: colors.highlightAlpha,
              ),
              blurRadius:
                  offset * (settings.shadowBlurOptimizationEnabled ? 1 : 1.5),
              offset: const Offset(-offset, -offset),
            ),
          ]
        : const [],
  );
}
