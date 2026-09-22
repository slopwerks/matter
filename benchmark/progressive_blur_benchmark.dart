import 'dart:ui' as ui;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/widgets/progressive_blur.dart';

// flutter test --enable-impeller benchmark/progressive_blur_benchmark.dart
// Includes GPU readback; useful for comparing implementations on the same
// host, not as a substitute for device raster-frame timings.
void main() {
  testWidgets('scrolling edge blur render/readback benchmark', (tester) async {
    // Tests otherwise use Ahem boxes. Supply a font for visual inspection.
    const fontPath = String.fromEnvironment('BLUR_FONT_PATH');
    if (fontPath.isNotEmpty) {
      await tester.runAsync(() async {
        final loader = FontLoader('BlurBenchmark')
          ..addFont(File(fontPath).readAsBytes().then(ByteData.sublistView));
        await loader.load();
      });
    }
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1236, 2700);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final key = GlobalKey();
    final scroll = ValueNotifier<double>(0);
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: key,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Color(0xff202020)),
              ValueListenableBuilder<double>(
                valueListenable: scroll,
                builder: (context, value, child) => Transform.translate(
                  offset: Offset(0, -value),
                  child: child,
                ),
                child: Text(
                  List.generate(
                    35,
                    (i) => i.isEven
                        ? 'Performance test 0123456789'
                        : '聊天消息与细线 — frosted glass',
                  ).join('\n'),
                  style: const TextStyle(
                    fontSize: 28,
                    color: Colors.white,
                    fontFamily: fontPath == '' ? null : 'BlurBenchmark',
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
              if (!const bool.fromEnvironment('BLUR_BENCHMARK_DISABLED'))
                const Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: 160,
                  child: ClipRect(
                    child: ProgressiveBlur(
                      sigma: 20,
                      bottom: false,
                      inactiveFraction: 0,
                      fallback: SizedBox.expand(),
                    ),
                  ),
                ),
              if (!const bool.fromEnvironment('BLUR_BENCHMARK_DISABLED'))
                const Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 160,
                  child: ClipRect(
                    child: ProgressiveBlur(
                      sigma: 12,
                      bottom: true,
                      inactiveFraction: 0.2,
                      fallback: SizedBox.expand(),
                    ),
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
    final samples = <double>[];
    for (var frame = 0; frame < 25; frame++) {
      scroll.value = frame * 1.25;
      await tester.pump();
      await tester.runAsync(() async {
        final watch = Stopwatch()..start();
        final image = await boundary.toImage(pixelRatio: 3);
        await image.toByteData();
        watch.stop();
        const capturePath = String.fromEnvironment('BLUR_CAPTURE');
        if (frame == 24 && capturePath.isNotEmpty) {
          final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
          await File(capturePath).writeAsBytes(png.buffer.asUint8List());
        }
        image.dispose();
        if (frame >= 5) samples.add(watch.elapsedMicroseconds / 1000);
      });
    }
    samples.sort();
    // ignore: avoid_print
    print(
      'Blur render + readback: median=${samples[10].toStringAsFixed(2)}ms '
      'p90=${samples[18].toStringAsFixed(2)}ms',
    );
    expect(tester.takeException(), isNull);
  }, skip: !ui.ImageFilter.isShaderFilterSupported);
}
