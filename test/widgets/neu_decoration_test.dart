import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/providers/chat_visual_settings_provider.dart';
import 'package:matter/widgets/neu_decoration.dart';
import 'package:matter/widgets/neu_surface.dart';
import 'package:matter/widgets/neu_field.dart';
import 'package:matter/widgets/neu_chip_tray.dart';
import 'package:matter/widgets/avatar.dart';

import '../helpers/neu_test_theme.dart';

class _RecordingCanvas implements Canvas {
  final paths = <Path>[];
  final superellipses = <ui.RSuperellipse>[];
  final roundedRects = <RRect>[];
  final roundedClips = <RRect>[];

  @override
  void drawPath(Path path, Paint paint) => paths.add(path);

  @override
  void drawRSuperellipse(ui.RSuperellipse shape, Paint paint) =>
      superellipses.add(shape);

  @override
  void drawRRect(RRect shape, Paint paint) => roundedRects.add(shape);

  @override
  void clipRRect(RRect shape, {bool doAntiAlias = true}) =>
      roundedClips.add(shape);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<List<int>> _pixels(BoxPainter painter, Size size, Offset offset) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), offset, ImageConfiguration(size: size));
  final picture = recorder.endRecording();
  final image = await picture.toImage(240, 160);
  final data = await image.toByteData();
  final bytes = data!.buffer.asUint8List().toList();
  image.dispose();
  picture.dispose();
  return bytes;
}

void main() {
  test(
    'raised surfaces use native superellipses for both shadows and fill',
    () {
      final painter = const NeuDecoration(
        colors: NeuColors.light,
      ).createBoxPainter();
      final canvas = _RecordingCanvas();
      painter.paint(
        canvas,
        Offset.zero,
        const ImageConfiguration(size: Size(120, 60)),
      );
      expect(canvas.paths, isEmpty);
      expect(canvas.superellipses, hasLength(3));
      expect(
        canvas.superellipses.last.outerRect,
        const Rect.fromLTWH(0, 0, 120, 60),
      );
      painter.dispose();
    },
  );

  test('shadow decorations advertise raster-cache complexity', () {
    for (final depth in NeuDepth.values) {
      expect(
        NeuDecoration(colors: NeuColors.light, depth: depth).isComplex,
        depth != NeuDepth.flat,
      );
    }
  });

  for (final depth in NeuDepth.values) {
    test(
      '$depth uses rounded fill, shadows, clip and border when disabled',
      () {
        final decoration = NeuDecoration(
          colors: NeuColors.light,
          depth: depth,
          borderColor: NeuColors.light.accent,
          superellipseEnabled: false,
        );
        final painter = decoration.createBoxPainter();
        final first = _RecordingCanvas();
        final second = _RecordingCanvas();
        const configuration = ImageConfiguration(size: Size(120, 60));
        painter.paint(first, Offset.zero, configuration);
        painter.paint(second, const Offset(20, 30), configuration);
        expect(first.superellipses, isEmpty);
        expect(first.roundedRects, hasLength(depth == NeuDepth.raised ? 4 : 2));
        expect(
          first.roundedClips,
          hasLength(depth == NeuDepth.pressed ? 1 : 0),
        );
        expect(
          first.roundedRects.last,
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(0, 0, 120, 60),
            const Radius.circular(18),
          ),
        );
        for (var i = 0; i < first.roundedRects.length; i++) {
          expect(
            identical(first.roundedRects[i], second.roundedRects[i]),
            isTrue,
          );
        }
        painter.dispose();
      },
    );
  }

  testWidgets(
    'shared neu widgets repaint when the superellipse setting changes',
    (tester) async {
      for (final enabled in [true, false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: neuTestTheme(),
            home: ChatVisualSettingsScope(
              settings: ChatVisualSettings(superellipseBorderEnabled: enabled),
              child: Scaffold(
                body: Column(
                  children: [
                    const NeuSurface(child: Text('surface')),
                    NeuButton(onPressed: () {}, child: const Text('button')),
                    NeuIconButton(onPressed: () {}, icon: Icons.add),
                    const NeuTextField(),
                    const NeuChipTray(children: [Text('tray')]),
                    const NeuAvatar(seed: 'test', label: 'Test'),
                    const NeuBadge(count: 2),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final decorations = tester
            .widgetList<DecoratedBox>(find.byType(DecoratedBox))
            .map((widget) => widget.decoration)
            .whereType<NeuDecoration>()
            .toList();
        expect(decorations, hasLength(7));
        for (final decoration in decorations) {
          expect(decoration.superellipseEnabled, enabled);
        }
      }
    },
  );

  for (final depth in NeuDepth.values) {
    test('$depth reuses geometry when only paint offset changes', () {
      final painter = NeuDecoration(
        colors: NeuColors.light,
        depth: depth,
      ).createBoxPainter();
      final first = _RecordingCanvas();
      final second = _RecordingCanvas();
      const configuration = ImageConfiguration(size: Size(120, 60));
      painter.paint(first, Offset.zero, configuration);
      painter.paint(second, const Offset(20, 30), configuration);
      expect(first.superellipses, isNotEmpty);
      expect(second.paths.length, first.paths.length);
      for (var i = 0; i < first.paths.length; i++) {
        expect(identical(first.paths[i], second.paths[i]), isTrue);
      }
      expect(second.superellipses.length, first.superellipses.length);
      for (var i = 0; i < first.superellipses.length; i++) {
        expect(
          identical(first.superellipses[i], second.superellipses[i]),
          isTrue,
        );
      }
      painter.dispose();
    });

    testWidgets('$depth cached paint stays correct after moving and resizing', (
      tester,
    ) async {
      await tester.runAsync(() async {
        for (final colors in [NeuColors.light, NeuColors.dark]) {
          final decoration = NeuDecoration(
            colors: colors,
            depth: depth,
            accent: true,
            borderColor: colors.accent,
          );
          final cached = decoration.createBoxPainter();
          await _pixels(cached, const Size(120, 60), const Offset(12, 12));
          for (final size in [const Size(120, 60), const Size(180, 90)]) {
            final fresh = decoration.createBoxPainter();
            expect(
              await _pixels(cached, size, const Offset(25, 30)),
              await _pixels(fresh, size, const Offset(25, 30)),
            );
            fresh.dispose();
          }
          cached.dispose();
        }
      });
    });
  }
}
