import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matter/pages/chat/composer_picker_panel.dart';
import 'package:matter/pages/chat/desktop_composer_picker.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/neu_test_theme.dart';

class _Api implements RustLibApi {
  @override
  Future<String?> crateApiMatrixMxcToHttpFull({required String mxcUrl}) async =>
      null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RustLib.initMock(api: _Api());
  });
  tearDown(RustLib.dispose);
  for (final material in [false, true]) {
    for (final dark in [false, true]) {
      testWidgets(
        'popup bounds and pack footer (material=$material dark=$dark)',
        (tester) async {
          if (const bool.fromEnvironment('RENDER_PICKER')) {
            debugDisableShadows = false;
            addTearDown(() => debugDisableShadows = true);
            final fonts = {
              'Roboto': '/home/ollie/fvm/versions/stable/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
              'PickerCJK':
                  '/usr/share/fonts/pingFang/pingFangTC/PingFangTC-Regular.otf',
              'Twemoji Mozilla Fallback':
                  'assets/fonts/Twemoji.Mozilla.fallback.ttf',
            };
            for (final entry in fonts.entries) {
              final loader = FontLoader(entry.key)
                ..addFont(
                  Future.value(
                    ByteData.sublistView(File(entry.value).readAsBytesSync()),
                  ),
                );
              await tester.runAsync(loader.load);
            }
          }
          final controller = MenuController();
          final boundary = GlobalKey();
          var tab = ComposerPickerTab.emoji;
          final packs = [
            for (var i = 0; i < 6; i++)
              rust.StickerPack(
                id: '$i',
                title: 'Pack $i',
                source: 'room',
                stickers: [
                  for (var j = 0; j < 40; j++)
                    rust.Sticker(
                      id: '$i-$j',
                      shortcode: '$j',
                      body: 'Sticker $j',
                      imageUrl: 'mxc://example.org/unavailable',
                      thumbnailUrl: null,
                      mimeType: null,
                      width: 128,
                      height: 128,
                    ),
                ],
              ),
          ];
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                stickerPacksProvider('room').overrideWith((ref) async => packs),
              ],
              child: RepaintBoundary(
                key: boundary,
                child: MaterialApp(
                  theme: neuTestTheme(material: material, dark: dark).copyWith(
                    textTheme: neuTestTheme(material: material, dark: dark)
                        .textTheme
                        .apply(
                          fontFamilyFallback: [
                            'PickerCJK',
                            'Twemoji Mozilla Fallback',
                          ],
                        ),
                  ),
                  home: Scaffold(
                    body: Align(
                      alignment: Alignment.bottomRight,
                      child: StatefulBuilder(
                        builder: (context, setState) => DesktopComposerPicker(
                          controller: controller,
                          roomId: 'room',
                          tab: tab,
                          onTabChanged: (value) => setState(() => tab = value),
                          onEmojiSelected: (_) {},
                          onStickerSelected: (_, _) {},
                          onOpenChanged: (_) {},
                          child: TextButton(
                            onPressed: controller.open,
                            child: const Text('Open'),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          controller.open();
          await tester.pumpAndSettle();
          final popup = tester.getRect(
            find.byKey(const ValueKey('desktop-composer-popup')),
          );
          expect(popup.right, lessThanOrEqualTo(800));
          expect(popup.bottom, lessThanOrEqualTo(600));
          expect(popup.top, greaterThanOrEqualTo(0));
          if (const bool.fromEnvironment('RENDER_PICKER')) {
            await tester.runAsync(() async {
              final image =
                  await (boundary.currentContext!.findRenderObject()
                          as RenderRepaintBoundary)
                      .toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              File('/tmp/matter-desktop-picker-$material-$dark.png')
                  .writeAsBytesSync(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
          await tester.tap(
            find.byKey(const ValueKey('desktop-picker-tab-sticker')),
          );
          await tester.pump();
          for (var i = 0; i < 10; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 30));
          }
          final footer = find.byType(ListView);
          final scroll = tester
              .widget<CustomScrollView>(find.byType(CustomScrollView).last)
              .controller!;
          expect(tester.getRect(footer).top, greaterThan(popup.center.dy));
          await tester.tap(find.byTooltip('Pack 2'));
          await tester.pumpAndSettle();
          expect(scroll.offset, greaterThan(0));
          final packOffset = scroll.offset;
          await tester.tap(
            find.byKey(const ValueKey('desktop-picker-tab-emoji')),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('desktop-picker-tab-sticker')),
          );
          await tester.pumpAndSettle();
          expect(scroll.offset, packOffset);
          Semantics selectedPack() => tester.widget<Semantics>(
            find
                .descendant(
                  of: find.byTooltip('Pack 2'),
                  matching: find.byWidgetPredicate(
                    (widget) =>
                        widget is Semantics &&
                        widget.properties.selected != null,
                  ),
                )
                .first,
          );
          expect(selectedPack().properties.selected, isTrue);
          scroll.jumpTo(0);
          await tester.pumpAndSettle();
          expect(selectedPack().properties.selected, isFalse);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
