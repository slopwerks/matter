import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/widgets/page_snapshot.dart';
import 'package:matter/widgets/progressive_blur.dart';

void main() {
  testWidgets('route snapshots stop repainting only during transitions', (
    tester,
  ) async {
    final primary = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 300),
    );
    final secondary = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 300),
    );
    final updates = ValueNotifier<int>(0);
    addTearDown(primary.dispose);
    addTearDown(secondary.dispose);
    addTearDown(updates.dispose);
    var paints = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RouteSnapshot(
          animation: primary,
          secondaryAnimation: secondary,
          enabled: true,
          child: ValueListenableBuilder<int>(
            valueListenable: updates,
            builder: (context, value, child) =>
                CustomPaint(painter: _CountingPainter(() => paints++, value)),
          ),
        ),
      ),
    );
    for (final animation in [primary, secondary]) {
      animation.forward();
      await tester.pump();
      final capturedPaints = paints;
      for (var i = 0; i < 3; i++) {
        updates.value++;
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(paints, capturedPaints, reason: 'reuse the captured page');
      await tester.pumpAndSettle();
      expect(
        paints,
        greaterThan(capturedPaints),
        reason: 'show live updates after settling',
      );
      animation.reverse();
      await tester.pump();
      final reversePaints = paints;
      updates.value++;
      await tester.pump(const Duration(milliseconds: 50));
      expect(paints, reversePaints);
      await tester.pumpAndSettle();
      expect(paints, greaterThan(reversePaints));
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('snapshot keeps translated backdrop blur aligned', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 500);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final controller = SnapshotController();
    addTearDown(controller.dispose);
    final key = GlobalKey();
    final position = ValueNotifier<Offset>(Offset.zero);
    addTearDown(position.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: key,
          child: Stack(
            children: [
              ValueListenableBuilder<Offset>(
                valueListenable: position,
                builder: (context, offset, child) => Positioned(
                  left: offset.dx,
                  top: offset.dy,
                  width: 400,
                  height: 300,
                  child: child!,
                ),
                child: PageSnapshot(
                  controller: controller,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const ColoredBox(color: Colors.black),
                      const Positioned(
                        left: 100,
                        top: 0,
                        bottom: 0,
                        width: 100,
                        child: ColoredBox(color: Colors.white),
                      ),
                      const ClipRect(
                        child: ProgressiveBlur(
                          sigma: 20,
                          bottom: true,
                          inactiveFraction: 0.25,
                          fallback: SizedBox.expand(),
                        ),
                      ),
                    ],
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
    Future<int> sample() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = (await image.toByteData())!;
      final x = 95 + position.value.dx.toInt();
      final y = 280 + position.value.dy.toInt();
      final value = bytes.getUint8((y * image.width + x) * 4);
      image.dispose();
      return value;
    }

    final live = (await tester.runAsync(sample))!;
    expect(live, inExclusiveRange(0, 255));
    controller.allowSnapshotting = true;
    position.value = const Offset(80, 40);
    await tester.pump();
    final captured = (await tester.runAsync(sample))!;
    expect(
      captured,
      closeTo(live, 3),
      reason: 'snapshot uses page-local shader coordinates',
    );
    controller.allowSnapshotting = false;
    position.value = Offset.zero;
    await tester.pump();
    expect((await tester.runAsync(sample))!, closeTo(live, 3));
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !ui.ImageFilter.isShaderFilterSupported);
}

class _CountingPainter extends CustomPainter {
  const _CountingPainter(this.onPaint, this.value);
  final VoidCallback onPaint;
  final int value;

  @override
  void paint(Canvas canvas, Size size) {
    onPaint();
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.blue);
  }

  @override
  bool shouldRepaint(_CountingPainter oldDelegate) =>
      value != oldDelegate.value;
}
