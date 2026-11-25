import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matter/pages/chat/composer_picker_panel.dart';
import 'package:matter/pages/chat/desktop_composer_picker.dart';
import 'package:matter/pages/chat/desktop_picker_preview.dart';
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
            await tester.runAsync(
              () =>
                  (FontLoader('MaterialIcons')..addFont(
                        rootBundle.load('fonts/MaterialIcons-Regular.otf'),
                      ))
                      .load(),
            );
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
                id: 'room:!stickers:example.org:$i',
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
                allChatRoomsProvider.overrideWith(
                  (ref) async => [
                    const rust.ChatRoom(
                      id: '!stickers:example.org',
                      name: '贴纸交流',
                      lastMessage: '',
                      lastMessageTime: '',
                      lastEventId: '',
                      unreadCount: 0,
                      isMarkedUnread: false,
                      roomType: 'group',
                      isEncrypted: false,
                      isMuted: false,
                      roomState: 'joined',
                    ),
                  ],
                ),
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
          void expectIndicator(ComposerPickerTab tab) {
            final tabs = tester.getRect(
              find.byKey(const ValueKey('desktop-picker-tabs')),
            );
            final line = tester.getRect(
              find.byKey(const ValueKey('desktop-picker-indicator')),
            );
            expect(line.bottom, tabs.bottom);
            expect(
              line.center.dx,
              closeTo(
                tabs.left + tabs.width * (tab.index == 0 ? .25 : .75),
                .01,
              ),
            );
          }

          void expectConcentric(IconButton button, Rect rect) {
            final panelShape =
                tester
                        .widget<Material>(
                          find.byKey(const ValueKey('desktop-composer-popup')),
                        )
                        .shape!
                    as RoundedRectangleBorder;
            final iconShape =
                button.style!.shape!.resolve({})! as RoundedRectangleBorder;
            final outer = panelShape.borderRadius
                .resolve(TextDirection.ltr)
                .bottomLeft
                .x;
            final inner = iconShape.borderRadius
                .resolve(TextDirection.ltr)
                .bottomLeft
                .x;
            expect(rect.left - popup.left, 6);
            expect(popup.bottom - rect.bottom, 6);
            expect(rect.left + inner, popup.left + outer);
            expect(rect.bottom - inner, popup.bottom - outer);
          }

          expectIndicator(ComposerPickerTab.emoji);
          final firstEmoji = find.byKey(
            const ValueKey('desktop-emoji-category-0'),
          );
          expectConcentric(
            tester.widget<IconButton>(firstEmoji),
            tester.getRect(firstEmoji),
          );
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
          expectIndicator(ComposerPickerTab.sticker);
          final firstPack = find.byWidgetPredicate(
            (widget) => widget is IconButton && widget.tooltip == 'Pack 0',
          );
          expectConcentric(
            tester.widget<IconButton>(firstPack),
            tester.getRect(firstPack),
          );
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
          final search = find.descendant(
            of: find.byKey(const ValueKey('desktop-picker-search')),
            matching: find.byType(TextField),
          );
          expect(
            tester.getRect(search).top,
            greaterThan(
              tester
                  .getRect(find.byKey(const ValueKey('desktop-picker-tabs')))
                  .bottom,
            ),
          );
          await tester.enterText(search, 'Pack 2');
          await tester.pumpAndSettle();
          expect(find.byTooltip('Pack 0'), findsNothing);
          expect(find.byTooltip('Pack 2'), findsOneWidget);
          await tester.pump(const Duration(milliseconds: 250));
          final preview = find.byType(DesktopPickerPreview).first;
          final mouse = await tester.createGesture(
            kind: ui.PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: const Offset(10, 10));
          await mouse.moveTo(tester.getCenter(preview));
          await tester.pump(const Duration(milliseconds: 600));
          await tester.pumpAndSettle();
          expect(find.text('Sticker 0\nPack 2\n房间：贴纸交流'), findsOneWidget);
          final previewRect = tester.getRect(preview);
          final visibleCard = tester.element(find.text(':0:'));
          for (var i = 0; i < 30; i++) {
            await mouse.moveTo(
              Offset(previewRect.left + 6 + i % 20, previewRect.center.dy),
            );
            await tester.pump(const Duration(milliseconds: 16));
            expect(
              find.text('Sticker 0\nPack 2\n房间：贴纸交流'),
              findsOneWidget,
              reason: 'move $i',
            );
            expect(tester.element(find.text(':0:')), same(visibleCard));
          }

          if (const bool.fromEnvironment('RENDER_PICKER')) {
            await tester.runAsync(() async {
              final image =
                  await (boundary.currentContext!.findRenderObject()
                          as RenderRepaintBoundary)
                      .toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              File('/tmp/matter-picker-popover-$material-$dark.png')
                  .writeAsBytesSync(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }

          await mouse.moveTo(const Offset(10, 10));
          await tester.pumpAndSettle();
          await mouse.removePointer();
          await tester.enterText(search, 'no-such-pack');
          await tester.pumpAndSettle();
          expect(find.text('没有匹配的贴纸包或贴纸'), findsOneWidget);
          await tester.tap(find.byTooltip('清除搜索'));
          await tester.pumpAndSettle();
          expect(find.byTooltip('Pack 0'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
