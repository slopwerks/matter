import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/blurhash_codec.dart';
import 'package:matter/pages/chat/image_media.dart';
import 'package:matter/pages/chat/image_placeholders.dart';
import 'package:matter/pages/chat/image_message_bubble.dart';
import 'package:matter/features/cache/media_decode_recovery.dart';
import 'package:matter/providers/authenticated_media_cache.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/connection_provider.dart';
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/neu_test_theme.dart';
import 'support/temp_path_provider.dart';
import 'support/storage_network.dart';

class _LogApi implements RustLibApi {
  final messages = <String>[];
  @override
  void crateApiMatrixLogAppMessage({
    required String level,
    required String tag,
    required String message,
  }) => messages.add(message);
  @override
  Future<String?> crateApiMatrixMxcToHttpFull({required String mxcUrl}) async =>
      null;
  @override
  Future<String?> crateApiMatrixMxcToHttpThumbnail({
    required String mxcUrl,
    required int width,
    required int height,
  }) async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Cache implements BaseCacheManager {
  final FileInfo good;
  final FileInfo bad;
  final removed = <String>[];
  final requests = <String>[];
  final original = Completer<void>();
  bool corrupt = false;
  bool alwaysCorrupt = false;
  bool offline = false;
  Completer<void>? evictionGate;
  _Cache(this.good, this.bad);
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    requests.add(url);
    if (url.endsWith('/original')) await original.future;
    if (offline) throw const SocketException('Connection reset');
    yield corrupt || alwaysCorrupt ? bad : good;
  }

  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) async => corrupt || alwaysCorrupt ? bad : good;
  @override
  Future<void> removeFile(String key) async {
    removed.add(key);
    await evictionGate?.future;
    corrupt = false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory dir;
  late _Cache cache;
  late _LogApi api;
  late BaseCacheManager previous;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('matter-image-test');
    installTempPathProvider(dir);
    final fs = IOFileSystem('images');
    final good = await fs.createFile('good.png');
    await good.writeAsBytes(decodeBlurhash('000000')!);
    final bad = await fs.createFile('bad.png');
    await bad.writeAsBytes([1, 2, 3]);
    cache = _Cache(
      FileInfo(good, FileSource.Cache, DateTime(2100), 'good'),
      FileInfo(bad, FileSource.Cache, DateTime(2100), 'bad'),
    );
    previous = CachedNetworkImageProvider.defaultCacheManager;
    CachedNetworkImageProvider.defaultCacheManager = cache;
    api = _LogApi();
    RustLib.initMock(api: api);
  });
  tearDown(() {
    CachedNetworkImageProvider.defaultCacheManager = previous;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    RustLib.dispose();
    dir.deleteSync(recursive: true);
  });
  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  Future<void> show(WidgetTester tester, {String? url, Uint8List? bytes}) =>
      tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: SizedBox(
                width: 100,
                height: 100,
                child: ChatMediaImage(
                  imageUrl: url,
                  imageBytes: bytes,
                  blurhash: '000000',
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('decode failure keeps BlurHash beneath failure indicator', (
    tester,
  ) async {
    await show(tester, bytes: Uint8List.fromList([1, 2, 3]));
    await flush(tester);
    expect(find.byType(BlurhashPlaceholder), findsOneWidget);
    expect(find.byIcon(Icons.broken_image_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('failed URL resolution leaves BlurHash in the message bubble', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await installStorageWifi();
    const message = rust.ChatMessage(
      id: 'failed-resolution',
      senderId: '@alice:example',
      senderName: 'Alice',
      content: 'photo',
      mentionedUserIds: [],
      mentionsRoom: false,
      timestamp: '100',
      isMe: false,
      msgType: rust.MessageType.image,
      imageUrl: 'mxc://example/missing',
      fileSize: 1024,
      imageMetadata: rust.ImageMessageMetadata(
        blurhash: '000000',
        spoiler: false,
      ),
      isEdited: false,
      editHistory: [],
      reactions: [],
      readers: [],
      totalMembers: 2,
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: neuTestTheme(),
          home: Scaffold(
            body: ImageMessageBubble(
              imageUrl: message.imageUrl,
              fileSize: 1024,
              message: message,
              isMe: false,
              heroTag: 'failed-resolution',
              metadata: const SizedBox(),
            ),
          ),
        ),
      ),
    );
    await flush(tester);
    expect(find.byIcon(Icons.broken_image_rounded), findsOneWidget);
    expect(find.byType(BlurhashPlaceholder), findsOneWidget);
    expect(cache.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets('successful thumbnail survives pending and failed original', (
    tester,
  ) async {
    await show(tester, url: 'https://images.example/thumbnail');
    await flush(tester);
    final thumbnail = tester
        .widgetList<RawImage>(find.byType(RawImage))
        .where((x) => x.image != null)
        .first
        .image!
        .clone();
    addTearDown(thumbnail.dispose);
    // Retain decoded pixels even when the global image cache is reclaimed.
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await show(tester, url: 'https://images.example/original');
    await flush(tester);
    expect(
      tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((x) => x.image?.isCloneOf(thumbnail) == true),
      isTrue,
    );
    cache.offline = true;
    cache.original.complete();
    await flush(tester);
    expect(
      tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((x) => x.image?.isCloneOf(thumbnail) == true),
      isTrue,
    );
    expect(cache.removed, isEmpty);
    expect(cache.requests, [
      'https://images.example/thumbnail',
      'https://images.example/original',
    ]);
    expect(tester.takeException(), isNull);
  });
  testWidgets('bad disk image is removed and downloaded once', (tester) async {
    cache.corrupt = true;
    await show(tester, url: 'https://images.example/corrupt');
    await flush(tester);
    expect(cache.requests, hasLength(2));
    expect(cache.removed, ['https://images.example/corrupt']);
    expect(find.byIcon(Icons.broken_image_rounded), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'successful original replaces preview only after its first frame',
    (tester) async {
      await show(tester, url: 'https://images.example/thumbnail');
      await flush(tester);
      final thumbnail = tester
          .widgetList<RawImage>(find.byType(RawImage))
          .firstWhere((x) => x.image != null)
          .image!
          .clone();
      addTearDown(thumbnail.dispose);
      await show(tester, url: 'https://images.example/original');
      await flush(tester);
      expect(
        tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((x) => x.image?.isCloneOf(thumbnail) == true),
        isTrue,
      );
      cache.original.complete();
      await flush(tester);
      final frames = tester
          .widgetList<RawImage>(find.byType(RawImage))
          .where((x) => x.image != null);
      expect(frames, isNotEmpty);
      expect(frames.any((x) => x.image!.isCloneOf(thumbnail)), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'recovery removes only account source and exact resize variant',
    () async {
      const url =
          'https://matrix.example/_matrix/client/v1/media/download/server/id';
      final alice = authenticatedMediaCacheKey(
        url: url,
        userId: '@alice:example',
        homeserver: 'https://matrix.example',
      );
      final bob = authenticatedMediaCacheKey(
        url: url,
        userId: '@bob:example',
        homeserver: 'https://matrix.example',
      );
      expect(alice, isNot(bob));
      await recoverMediaDecodeCache(
        manager: cache,
        url: url,
        cacheKey: alice,
        width: 240,
        height: 180,
      );
      expect(cache.removed, ['resized_w240_h180_$alice', alice]);
      expect(cache.removed, isNot(contains(bob)));
    },
  );

  testWidgets('finishing eviction cannot retry a replaced source', (
    tester,
  ) async {
    cache.corrupt = true;
    cache.evictionGate = Completer<void>();
    await show(tester, url: 'https://images.example/old');
    await flush(tester);
    expect(cache.removed, hasLength(1));
    cache.corrupt = false;
    await show(tester, url: 'https://images.example/new');
    await flush(tester);
    cache.evictionGate!.complete();
    await flush(tester);
    expect(cache.requests, [
      'https://images.example/old',
      'https://images.example/new',
    ]);
    expect(tester.takeException(), isNull);
  });
  testWidgets('persistently invalid data stops after one recovery attempt', (
    tester,
  ) async {
    cache.alwaysCorrupt = true;
    await show(tester, url: 'https://images.example/invalid');
    await flush(tester);
    expect(cache.requests, hasLength(2));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ChatMediaImage)),
    );
    container.read(connectionProvider.notifier).value =
        AppConnectionState.disconnected;
    await tester.pump();
    container.read(connectionProvider.notifier).value =
        AppConnectionState.connected;
    await flush(tester);
    expect(cache.requests, hasLength(2));
    expect(cache.removed, hasLength(1));
    expect(find.byType(BlurhashPlaceholder), findsOneWidget);
    expect(find.byIcon(Icons.broken_image_rounded), findsOneWidget);
    await flush(tester);
    expect(cache.requests, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching account drops the previous decoded preview', (
    tester,
  ) async {
    await show(tester, url: 'https://images.example/thumbnail');
    await flush(tester);
    final thumbnail = tester
        .widgetList<RawImage>(find.byType(RawImage))
        .firstWhere((x) => x.image != null)
        .image!
        .clone();
    addTearDown(thumbnail.dispose);
    await show(tester, url: 'https://images.example/original');
    await flush(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ChatMediaImage)),
    );
    container.read(activeUserIdProvider.notifier).value = '@bob:example';
    await tester.pump();
    expect(
      tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((x) => x.image?.isCloneOf(thumbnail) == true),
      isFalse,
    );
    cache.original.complete();
    await flush(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('finishing eviction after disposal does not schedule a retry', (
    tester,
  ) async {
    cache.corrupt = true;
    cache.evictionGate = Completer<void>();
    await show(tester, url: 'https://images.example/disposed');
    await flush(tester);
    expect(cache.removed, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    cache.evictionGate!.complete();
    await flush(tester);
    expect(cache.requests, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
