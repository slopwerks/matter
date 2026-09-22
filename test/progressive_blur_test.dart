import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/widgets/glass.dart';
import 'package:matter/widgets/progressive_blur.dart';

import 'helpers/neu_test_theme.dart';

void main() {
  testWidgets('edge shader asset loads and accepts its uniform layout', (
    tester,
  ) async {
    final program = await tester.runAsync(
      () => ui.FragmentProgram.fromAsset('shaders/progressive_blur.frag'),
    );
    final shader = program!.fragmentShader();
    for (var i = 2; i <= 10; i++) {
      shader.setFloat(i, 0);
    }
    shader.dispose();
  });

  testWidgets('zero blur and fully inactive regions bypass filtering', (
    tester,
  ) async {
    for (final values in [(0.0, 0.0), (20.0, 1.0)]) {
      await tester.pumpWidget(
        MaterialApp(
          home: ProgressiveBlur(
            sigma: values.$1,
            bottom: true,
            inactiveFraction: values.$2,
            fallback: const Text('fallback'),
          ),
        ),
      );
      expect(find.text('fallback'), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('top and bottom overlays tolerate small sizes and resizing', (
    tester,
  ) async {
    for (final height in [24.0, 160.0, 64.0]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: neuTestTheme(),
          home: Align(
            child: SizedBox(
              width: 240,
              height: height,
              child: const Stack(
                fit: StackFit.expand,
                children: [
                  TopFadeBlur(useShader: true),
                  BottomFadeBlur(useShader: true),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        for (final element
            in find
                .byWidgetPredicate(
                  (widget) => widget is FutureBuilder<ui.FragmentProgram>,
                )
                .evaluate()) {
          await (element.widget as FutureBuilder<ui.FragmentProgram>).future;
        }
      });
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Impeller blurs inside translated bounds and preserves the reading area',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 600);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey();
      for (final scenario in [
        (false, 1.0),
        (true, 1.0),
        (false, 3.0),
        (true, 3.0),
      ]) {
        final (bottom, dpr) = scenario;
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = const Size(800, 600) * dpr;
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(
              key: key,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: Colors.black),
                  const Positioned(
                    left: 200,
                    top: 0,
                    bottom: 0,
                    width: 100,
                    child: ColoredBox(color: Colors.white),
                  ),
                  const Positioned(
                    left: 340,
                    top: 0,
                    bottom: 0,
                    width: 1,
                    child: ColoredBox(color: Colors.white),
                  ),
                  Positioned(
                    left: 100,
                    top: 100,
                    width: 300,
                    height: 300,
                    child: ClipRect(
                      child: ProgressiveBlur(
                        sigma: 20,
                        bottom: bottom,
                        inactiveFraction: 0.25,
                        fallback: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        // Asset IO must finish outside the test's fake clock.
        await tester.runAsync(
          () => ui.FragmentProgram.fromAsset('shaders/progressive_blur.frag'),
        );
        await tester.runAsync(() async {
          for (final element
              in find
                  .byWidgetPredicate(
                    (widget) => widget is FutureBuilder<ui.FragmentProgram>,
                  )
                  .evaluate()) {
            await (element.widget as FutureBuilder<ui.FragmentProgram>).future;
          }
        });
        await tester.pumpAndSettle();
        final filter = tester.layers
            .whereType<BackdropFilterLayer>()
            .single
            .filter;
        tester.renderObject(find.byType(ProgressiveBlur)).markNeedsPaint();
        await tester.pump();
        expect(
          tester.layers.whereType<BackdropFilterLayer>().single.filter,
          same(filter),
          reason: 'background repaints must reuse unchanged filter parameters',
        );
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = (await tester.runAsync(
          () => boundary.toImage(pixelRatio: dpr),
        ))!;
        final bytes = (await tester.runAsync(() => image.toByteData()))!;
        int red(int x, int y) => bytes.getUint8(
          ((y * dpr).round() * image.width + (x * dpr).round()) * 4,
        );
        expect(
          red(195, bottom ? 140 : 360),
          0,
          reason: 'inactive reading area stays sharp',
        );
        expect(
          red(195, bottom ? 390 : 110),
          inExclusiveRange(0, 255),
          reason: 'active edge blurs',
        );
        expect(
          red(340, bottom ? 140 : 360),
          255,
          reason: 'inactive region preserves even one-pixel details',
        );
        expect(
          red(341, bottom ? 140 : 360),
          0,
          reason: 'inactive region must not be downsampled',
        );
        expect(red(195, 410), 0, reason: 'blur stays inside its clip');
        image.dispose();
        expect(tester.takeException(), isNull);
      }
    },
    skip: !ui.ImageFilter.isShaderFilterSupported,
  );
  testWidgets('Impeller smooths fine stripes without a sampling lattice', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 300);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    for (final period in [4.0, 5.0, 10.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: key,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Colors.black),
                for (var x = 0.0; x < 400; x += period)
                  Positioned(
                    left: x,
                    top: 0,
                    bottom: 0,
                    width: period == 10 ? 2 : 1,
                    child: const ColoredBox(color: Colors.white),
                  ),
                const ClipRect(
                  child: ProgressiveBlur(
                    sigma: 20,
                    bottom: true,
                    inactiveFraction: 0,
                    fallback: SizedBox.expand(),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        for (final element
            in find
                .byWidgetPredicate(
                  (widget) => widget is FutureBuilder<ui.FragmentProgram>,
                )
                .evaluate()) {
          await (element.widget as FutureBuilder<ui.FragmentProgram>).future;
        }
      });
      await tester.pumpAndSettle();
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = (await tester.runAsync(() => boundary.toImage()))!;
      final bytes = (await tester.runAsync(() => image.toByteData()))!;
      for (final y in [230, 265, 299]) {
        final values = [
          for (var x = 100; x < 300; x++)
            bytes.getUint8((y * image.width + x) * 4),
        ]..sort();
        expect(
          values.last - values.first,
          lessThanOrEqualTo(12),
          reason:
              'blur at y=$y must average stripes, without a sharp ghost or sampling lattice',
        );
        expect(
          values[values.length ~/ 2],
          inInclusiveRange(period == 4 ? 55 : 40, period == 4 ? 73 : 65),
          reason:
              '20 percent white coverage should retain its average luminance',
        );
      }
      image.dispose();
    }
  }, skip: !ui.ImageFilter.isShaderFilterSupported);
}
