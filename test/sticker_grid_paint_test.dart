import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matter/app.dart';
import 'package:matter/pages/chat/composer_picker_panel.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/neu_test_theme.dart';
import 'support/temp_path_provider.dart';

final _stickerPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _StickerCacheManager implements BaseCacheManager, ImageCacheManager {
  _StickerCacheManager(this.dir);
  final Directory dir;

  @override
  Stream<FileResponse> getImageFile(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
    int? maxHeight,
    int? maxWidth,
  }) => Stream.fromFuture(() async {
    final fs = IOFileSystem(dir.path);
    final file = await fs.createFile('s.png');
    await file.writeAsBytes(_stickerPng);
    return FileInfo(
      file,
      FileSource.Cache,
      DateTime.now().add(const Duration(days: 1)),
      url,
    );
  }());

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) =>
      getImageFile(url, key: key, headers: headers, withProgress: withProgress);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WideStickerFakeApi implements RustLibApi {
  final sync = StreamController<rust.SyncEvent>.broadcast();

  @override
  Future<List<rust.AccountInfo>> crateApiMatrixListAccounts() async => [];
  @override
  Future<bool> crateApiMatrixIsRoomEncrypted({required String roomId}) async =>
      false;
  @override
  Future<String> crateApiMatrixSubscribeTypingForRoom({
    required String roomId,
    String? accountUserId,
  }) async => 't1';
  @override
  Future<void> crateApiMatrixUnsubscribeTyping({
    required String roomId,
    required String subscriptionId,
    String? accountUserId,
  }) async {}
  @override
  Future<String> crateApiMatrixSubscribeRoomForReceipts({
    required String roomId,
    String? accountUserId,
  }) async => 'r1';
  @override
  Future<void> crateApiMatrixUnsubscribeRoomForReceipts({
    required String roomId,
    required String subscriptionId,
    String? accountUserId,
  }) async {}
  @override
  Future<bool> crateApiMatrixMarkRoomAsRead({
    required String accountUserId,
    required String roomId,
    required bool explicit,
  }) async => true;
  @override
  Future<List<String>> crateApiMatrixGetPinnedEventIds({
    required String accountUserId,
    required String roomId,
  }) async => const [];
  @override
  Future<List<rust.ChatMessage>> crateApiMatrixGetPinnedMessages({
    required String roomId,
  }) async => const [];
  @override
  Stream<rust.SyncEvent> crateApiMatrixWatchSyncEvents() => sync.stream;
  @override
  Stream<rust.TypingNotification> crateApiMatrixWatchTypingNotifications() =>
      const Stream.empty();
  @override
  Future<void> crateApiMatrixSendTypingNotice({
    required String roomId,
    required bool typing,
    String? accountUserId,
  }) async {}
  @override
  Future<String?> crateApiMatrixMxcToHttpFull({required String mxcUrl}) async =>
      'https://example.org/${Uri.encodeComponent(mxcUrl)}';
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected: ${invocation.memberName}');
}

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

  testWidgets(
    'wide desktop sticker panel uses responsive grid, avoids image rebuild flashes, and closes on desktop focus',
    (tester) async {
      final tempDir = Directory.systemTemp.createTempSync('sticker_wide_');
      installTempPathProvider(tempDir);
      final prevCache = CachedNetworkImageProvider.defaultCacheManager;
      CachedNetworkImageProvider.defaultCacheManager = _StickerCacheManager(
        tempDir,
      );
      addTearDown(() {
        CachedNetworkImageProvider.defaultCacheManager = prevCache;
        PaintingBinding.instance.imageCache.clear();
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      SharedPreferences.setMockInitialValues({});
      final api = _WideStickerFakeApi();
      RustLib.initMock(api: api);
      addTearDown(() async {
        await api.sync.close();
        RustLib.dispose();
      });

      const room = rust.ChatRoom(
        id: '!r:e',
        name: 'Room',
        lastMessage: 'hi',
        lastMessageTime: '1',
        lastEventId: r'$1',
        unreadCount: 0,
        isMarkedUnread: false,
        roomType: 'dm',
        isEncrypted: false,
        isMuted: false,
        roomState: 'joined',
      );
      final pack = rust.StickerPack(
        id: 'pack1',
        title: 'Pack 1',
        source: 'room',
        stickers: [
          for (var i = 0; i < 20; i++)
            rust.Sticker(
              id: 's$i',
              shortcode: 's$i',
              body: 's$i',
              imageUrl: 'mxc://example.org/s$i',
            ),
        ],
      );

      for (final material in [false, true]) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1200, 800);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);

        final container = ProviderContainer(
          overrides: [
            allChatRoomsProvider.overrideWith((ref) async => [room]),
            spacesProvider.overrideWith((ref) async => const []),
            ungroupedRoomsProvider.overrideWith((ref) async => [room]),
            contactsProvider.overrideWith((ref) async => const []),
            ignoredUserIdsProvider.overrideWith((ref) async => <String>{}),
            roomMembersProvider('!r:e').overrideWith((ref) async => const []),
            stickerPacksProvider('!r:e').overrideWith((ref) async => [pack]),
          ],
        );
        addTearDown(container.dispose);
        container.read(sessionReadyProvider.notifier).value = true;
        container.read(activeUserIdProvider.notifier).value = '@me:e';

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: neuTestTheme(material: material)
                  .copyWith(platform: TargetPlatform.linux),
              home: const MatterApp(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Room'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('表情与贴纸'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('贴纸'));
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }

        // Wide pane must lay out more than 5 columns so stickers stay compact.
        final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
        final delegate =
            grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
        expect(delegate.crossAxisCount, greaterThan(5));

        final counts = <String, int>{};
        final prev = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (Element e, bool builtOnce) {
          final name = e.widget.runtimeType.toString();
          counts[name] = (counts[name] ?? 0) + 1;
          prev?.call(e, builtOnce);
        };
        container.invalidate(allChatRoomsProvider);
        await tester.pump();
        final scroll = tester.widget<CustomScrollView>(
          find.byType(CustomScrollView).last,
        );
        scroll.controller?.jumpTo(24);
        await tester.pump();
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        debugOnRebuildDirtyWidget = prev;

        expect(counts['FadeWidget'], isNull, reason: 'material=$material');
        expect(counts['Image'], isNull, reason: 'material=$material');
        expect(
          find.byType(CircularProgressIndicator),
          findsNothing,
          reason: 'material=$material',
        );

        // Focusing the text field on desktop closes the picker cleanly instead of
        // holding _keepPickerDuringKeyboardOpen open forever with keyboard=0.
        await tester.tap(find.byType(TextField).last);
        await tester.pumpAndSettle();
        expect(find.byType(ComposerPickerPanel), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    },
  );
}
