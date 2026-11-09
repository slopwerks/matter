import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/storage/storage_models.dart';
import 'package:matter/features/storage/storage_settings.dart';
import 'package:matter/pages/chat/image_media.dart';
import 'package:matter/pages/chat/image_message_bubble.dart';
import 'package:matter/src/rust/frb_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/neu_test_theme.dart';
import 'support/storage_network.dart';

const _mxc = 'mxc://media.example/animated-sticker';
const _download =
    'https://matrix.example/_matrix/client/v1/media/download/media.example/animated-sticker';

// Two 1px frames (black, then white), 100ms each, looping indefinitely.
Uint8List _animatedGif() => Uint8List.fromList([
  ...ascii.encode('GIF89a'),
  1,
  0,
  1,
  0,
  0x80,
  0,
  0,
  0,
  0,
  0,
  255,
  255,
  255,
  0x21,
  0xff,
  11,
  ...ascii.encode('NETSCAPE2.0'),
  3,
  1,
  0,
  0,
  0,
  for (final pixel in [0x44, 0x4c]) ...[
    0x21,
    0xf9,
    4,
    0,
    10,
    0,
    0,
    0,
    0x2c,
    0,
    0,
    0,
    0,
    1,
    0,
    1,
    0,
    0,
    2,
    2,
    pixel,
    1,
    0,
  ],
  0x3b,
]);

class _StickerApi implements RustLibApi {
  final downloads = <({String source, int limit})>[];
  int thumbnails = 0;
  bool tooLarge = false;
  Completer<Uint8List>? pending;

  @override
  Future<String?> crateApiMatrixMxcToHttpFull({required String mxcUrl}) async =>
      _download;

  @override
  Future<String?> crateApiMatrixMxcToHttpThumbnail({
    required String mxcUrl,
    required int width,
    required int height,
  }) async {
    thumbnails++;
    return _download.replaceFirst('/download/', '/thumbnail/');
  }

  @override
  Future<Uint8List> crateApiMatrixDownloadMediaSourceBytes({
    required String mediaSourceJson,
    required int maxSizeBytes,
  }) async {
    downloads.add((source: mediaSourceJson, limit: maxSizeBytes));
    if (tooLarge) throw StateError('Media exceeds download limit');
    if (pending != null) return pending!.future;
    return _animatedGif();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _StickerApi api;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await installStorageWifi();
    api = _StickerApi();
    RustLib.initMock(api: api);
  });
  tearDown(RustLib.dispose);

  Future<void> pumpSticker(WidgetTester tester, {int? fileSize}) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: neuTestTheme(),
          home: Scaffold(
            body: ImageMessageBubble(
              imageUrl: _mxc,
              mediaSourceJson: jsonEncode(_mxc),
              imageWidth: 512,
              imageHeight: 512,
              fileSize: fileSize,
              mimeType: 'image/gif',
              isMe: false,
              heroTag: 'animated-sticker',
              isSticker: true,
              metadata: const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('unknown-size sticker automatically loads with a byte limit', (
    tester,
  ) async {
    await pumpSticker(tester);
    expect(find.text('点击下载图片'), findsNothing);
    expect(api.downloads, [(source: jsonEncode(_mxc), limit: 8 * storageMiB)]);
    expect(api.thumbnails, 0);
    final media = tester.widget<ChatMediaImage>(find.byType(ChatMediaImage));
    expect(media.cacheWidth, isNull);
    expect(media.cacheHeight, isNull);
    final codec = await ui.instantiateImageCodec(media.imageBytes!);
    expect(codec.frameCount, 2);
    codec.dispose();
    Future<void> decodeAndPump() async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }

    for (var i = 0; i < 30; i++) {
      if (tester.widget<RawImage>(find.byType(RawImage)).image != null) break;
      await decodeAndPump();
    }
    final firstFrame = tester.widget<RawImage>(find.byType(RawImage)).image;
    expect(firstFrame, isNotNull);
    final firstPixels = await tester.runAsync(() => firstFrame!.toByteData());
    Uint8List? changedPixels;
    for (var i = 0; i < 30; i++) {
      await decodeAndPump();
      final frame = tester.widget<RawImage>(find.byType(RawImage)).image;
      if (frame == null) continue;
      final pixels = await tester.runAsync(() => frame.toByteData());
      if (pixels!.getUint8(0) != firstPixels!.getUint8(0)) {
        changedPixels = pixels.buffer.asUint8List();
        break;
      }
    }
    expect(
      changedPixels,
      isNotNull,
      reason: 'The painted GIF must advance frames',
    );
  });

  testWidgets('known-size sticker uses the original without disk resizing', (
    tester,
  ) async {
    await pumpSticker(tester, fileSize: 1024);
    expect(api.thumbnails, 0);
    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.imageUrl, _download);
    expect(image.maxWidthDiskCache, isNull);
    expect(image.maxHeightDiskCache, isNull);
  });

  testWidgets('disabled automatic downloads still require a click', (
    tester,
  ) async {
    await saveStorageSettings(
      const StorageSettings(wifiDownloads: DownloadRules(enabled: false)),
    );
    await pumpSticker(tester);
    expect(find.text('点击下载图片'), findsOneWidget);
    expect(api.downloads, isEmpty);
    expect(find.byType(CachedNetworkImage), findsNothing);
    await tester.tap(find.text('点击下载图片'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('点击下载图片'), findsNothing);
    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.imageUrl, _download);
    expect(api.thumbnails, 0);
  });

  testWidgets(
    'bounded transfer does not also start an unbounded image request',
    (tester) async {
      api.pending = Completer<Uint8List>();
      await pumpSticker(tester);
      expect(api.downloads, hasLength(1));
      expect(find.byType(CachedNetworkImage), findsNothing);
      api.pending!.complete(_animatedGif());
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<ChatMediaImage>(find.byType(ChatMediaImage)).imageBytes,
        isNotNull,
      );
    },
  );

  testWidgets('oversize unknown sticker retains a manual download action', (
    tester,
  ) async {
    api.tooLarge = true;
    await pumpSticker(tester);
    expect(api.downloads.single.limit, 8 * storageMiB);
    expect(find.text('点击下载图片'), findsOneWidget);
    expect(find.byType(CachedNetworkImage), findsNothing);
  });

  testWidgets(
    'known-size sticker over the limit does not request a thumbnail',
    (tester) async {
      await pumpSticker(tester, fileSize: 9 * storageMiB);
      expect(api.thumbnails, 0);
      expect(api.downloads, isEmpty);
      expect(find.byType(CachedNetworkImage), findsNothing);
      expect(find.text('下载 9.0 MiB'), findsOneWidget);
    },
  );

  testWidgets('unknown-size sticker respects a custom automatic byte limit', (
    tester,
  ) async {
    await saveStorageSettings(
      StorageSettings(
        wifiDownloads: DownloadRules(limits: {StorageKind.image: 2048}),
      ),
    );
    await pumpSticker(tester);
    expect(api.downloads.single.limit, 2048);
  });
}
