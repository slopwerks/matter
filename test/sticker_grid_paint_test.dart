import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/composer_picker_panel.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/theme/material_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('scrolling stickers keeps the picker header clear', (
    tester,
  ) async {
    final theme = buildMaterialTheme(Brightness.dark);
    SharedPreferences.setMockInitialValues({});
    final boundary = GlobalKey();
    final pack = rust.StickerPack(
      id: 'pack',
      title: 'Pack',
      source: 'room',
      stickers: [
        for (var i = 0; i < 60; i++)
          rust.Sticker(
            id: '$i',
            shortcode: '$i',
            body: '$i',
            imageUrl: 'mxc://example.org/$i',
          ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          stickerPacksProvider('room').overrideWith((_) async => [pack]),
        ],
        child: MaterialApp(
          theme: theme,
          home: Material(
            child: Center(
              child: RepaintBoundary(
                key: boundary,
                child: SizedBox(
                  width: 400,
                  height: 316,
                  child: ComposerPickerPanel(
                    roomId: 'room',
                    maxHeight: 316,
                    tab: ComposerPickerTab.sticker,
                    onTabChanged: (_) {},
                    onEmojiSelected: (_) {},
                    onStickerSelected: (_, _) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final grid = tester.widget<CustomScrollView>(find.byType(CustomScrollView));
    // Scrolling the grid must not repaint the empty band beside the tabs.
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final headerY = render
        .globalToLocal(tester.getCenter(find.text('Emoji')))
        .dy
        .round();
    Future<List<int>> headerPixels() async {
      final image = await render.toImage();
      try {
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        return [
          for (var x = 250; x < 360; x++)
            bytes.getUint32(4 * (headerY * image.width + x)),
        ];
      } finally {
        image.dispose();
      }
    }

    final before = await tester.runAsync(headerPixels);
    grid.controller!.jumpTo(160);
    await tester.pump();
    expect(await tester.runAsync(headerPixels), before);
  });
}
