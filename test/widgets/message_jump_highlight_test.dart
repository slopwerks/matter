import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/message_jump_highlight.dart';

import '../helpers/neu_test_theme.dart';

Future<Color> _sample(WidgetTester tester, GlobalKey key, int x) async {
  return (await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final offset = (8 * image.width + x) * 4;
    final color = Color.fromARGB(
      bytes!.getUint8(offset + 3),
      bytes.getUint8(offset),
      bytes.getUint8(offset + 1),
      bytes.getUint8(offset + 2),
    );
    image.dispose();
    return color;
  }))!;
}

void main() {
  for (final material in [false, true]) {
    for (final dark in [false, true]) {
      testWidgets(
        'target brightens without dimming text, fades and repeats (material=$material dark=$dark)',
        (tester) async {
          final target = ValueNotifier<String?>(null);
          addTearDown(target.dispose);
          final boundary = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: neuTestTheme(material: material, dark: dark),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: RepaintBoundary(
                    key: boundary,
                    child: SizedBox(
                      width: 80,
                      height: 40,
                      child: MessageJumpHighlight(
                        messageId: 'one',
                        target: target,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ColoredBox(
                              color: dark
                                  ? const Color(0xFF283240)
                                  : const Color(0xFFDDE8FA),
                            ),
                            const Positioned(
                              left: 40,
                              top: 0,
                              width: 12,
                              height: 40,
                              child: ColoredBox(color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          final baseline = await _sample(tester, boundary, 8);
          target.value = 'other';
          await tester.pump();
          expect(await _sample(tester, boundary, 8), baseline);
          target.value = 'one';
          await tester.pump();
          final lit = await _sample(tester, boundary, 8);
          expect(lit.r, greaterThanOrEqualTo(baseline.r));
          expect(lit.g, greaterThanOrEqualTo(baseline.g));
          expect(lit.b, greaterThanOrEqualTo(baseline.b));
          expect(
            lit.computeLuminance(),
            greaterThan(baseline.computeLuminance()),
          );
          expect(await _sample(tester, boundary, 44), Colors.white);
          await tester.pumpAndSettle();
          expect(await _sample(tester, boundary, 8), baseline);
          target.value = null;
          target.value = 'one';
          await tester.pump();
          expect(await _sample(tester, boundary, 8), lit);
          await tester.pumpAndSettle();
        },
      );
    }
  }
}
