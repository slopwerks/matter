import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/widgets/neu_surface.dart';

Future<Rect> _fillBounds(WidgetTester tester, GlobalKey key, Color fill) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await tester.runAsync(() => boundary.toImage());
  final pixels = await tester.runAsync(
    () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  var left = image!.width;
  var right = -1;
  var top = image.height;
  var bottom = -1;
  final argb = fill.toARGB32();
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final offset = (y * image.width + x) * 4;
      final actual =
          pixels!.getUint8(offset + 3) << 24 |
          pixels.getUint8(offset) << 16 |
          pixels.getUint8(offset + 1) << 8 |
          pixels.getUint8(offset + 2);
      if (actual != argb) continue;
      if (x < left) left = x;
      if (x > right) right = x;
      if (y < top) top = y;
      if (y > bottom) bottom = y;
    }
  }
  image.dispose();
  expect(right, greaterThan(left));
  return Rect.fromLTRB(
    left.toDouble(),
    top.toDouble(),
    right + 1.0,
    bottom + 1.0,
  );
}

Future<void> _pumpButton(
  WidgetTester tester,
  GlobalKey boundary, {
  VoidCallback? onPressed,
  bool reduceMotion = false,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildMaterialTheme(Brightness.light),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: child!,
    ),
    home: Scaffold(
      body: Center(
        child: RepaintBoundary(
          key: boundary,
          child: SizedBox(
            width: 160,
            height: 120,
            child: Center(
              child: NeuIconButton(
                accent: true,
                icon: Icons.add,
                tooltip: 'Add',
                onPressed: onPressed,
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'press grows the filled surface while layout and anchors stay put',
    (tester) async {
      final boundary = GlobalKey();
      var taps = 0;
      await _pumpButton(tester, boundary, onPressed: () => taps++);
      await tester.pumpAndSettle();
      final button = find.byType(IconButton);
      final rect = tester.getRect(button);
      final box = tester.renderObject<RenderBox>(button);
      final anchor = box.localToGlobal(Offset.zero);
      final fill = buildMaterialTheme(Brightness.light).colorScheme.primary;
      final rest = await _fillBounds(tester, boundary, fill);
      final gesture = await tester.startGesture(tester.getCenter(button));
      // InkWell confirms a held press after the tap recognizer's deadline.
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump(const Duration(milliseconds: 180));
      final pressed = await _fillBounds(tester, boundary, fill);
      expect(pressed.width, greaterThan(rest.width + 2));
      expect(pressed.height, greaterThan(rest.height + 2));
      expect(tester.getRect(button), rect);
      expect(box.localToGlobal(Offset.zero), anchor);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(await _fillBounds(tester, boundary, fill), rest);
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  testWidgets('a quick tap still has visible feedback and settles', (
    tester,
  ) async {
    final boundary = GlobalKey();
    await _pumpButton(tester, boundary, onPressed: () {});
    await tester.pumpAndSettle();
    final fill = buildMaterialTheme(Brightness.light).colorScheme.primary;
    final rest = await _fillBounds(tester, boundary, fill);
    await tester.tap(find.byType(IconButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(
      (await _fillBounds(tester, boundary, fill)).width,
      greaterThan(rest.width),
    );
    await tester.pumpAndSettle();
    expect(await _fillBounds(tester, boundary, fill), rest);
  });

  testWidgets('scrolling cancels the action and releases the press', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildMaterialTheme(Brightness.light),
        home: Scaffold(
          body: ListView(
            children: [
              NeuButton(onPressed: () => taps++, child: const Text('Action')),
              const SizedBox(height: 1800),
            ],
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(NeuButton)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -120));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(taps, 0);
    expect(
      tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
      greaterThan(0),
    );
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard activation and reduced motion retain the action', (
    tester,
  ) async {
    final boundary = GlobalKey();
    var taps = 0;
    await _pumpButton(
      tester,
      boundary,
      onPressed: () => taps++,
      reduceMotion: true,
    );
    await tester.pumpAndSettle();
    final fill = buildMaterialTheme(Brightness.light).colorScheme.primary;
    final rest = await _fillBounds(tester, boundary, fill);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(IconButton)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    expect(await _fillBounds(tester, boundary, fill), rest);
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(taps, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabling a held control releases it without firing', (
    tester,
  ) async {
    final boundary = GlobalKey();
    var taps = 0;
    await _pumpButton(tester, boundary, onPressed: () => taps++);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(IconButton)),
    );
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 180));
    await _pumpButton(tester, boundary);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(taps, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });
}
