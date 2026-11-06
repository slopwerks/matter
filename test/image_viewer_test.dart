import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/image_viewer.dart';
import 'package:matter/pages/chat/image_message_bubble.dart';
import 'package:matter/providers/connection_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/providers/message_cache_persistence.dart';
import 'package:matter/pages/chat/message_group.dart';
import 'package:matter/pages/chat/message_input.dart'
    show editingDraftProvider, editingSendInFlightProvider;
import 'package:matter/providers/mutable_state.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'helpers/neu_test_theme.dart';
import 'support/storage_network.dart';
import 'support/temp_path_provider.dart';

class _DownloadPaths extends TempPathProvider {
  _DownloadPaths(super.root);

  @override
  Future<String?> getDownloadsPath() async => root.path;
}

Future<Directory> _installDownloads(WidgetTester tester) async {
  final directory = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('matter-image-download-'),
  ))!;
  final previous = PathProviderPlatform.instance;
  PathProviderPlatform.instance = _DownloadPaths(directory);
  addTearDown(() async {
    PathProviderPlatform.instance = previous;
    await directory.delete(recursive: true);
  });
  return directory;
}

Future<void> _downloadImage(WidgetTester tester) async {
  await tester.tap(find.byTooltip('下载').hitTestable());
  // File I/O needs real event-loop turns, while the download spinner keeps
  // scheduling frames until saving finishes.
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (find.text('图片已保存').evaluate().isNotEmpty) break;
  }
  expect(find.text('图片已保存'), findsWidgets);
}

final pixel = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
  ),
);

class ImageApi implements RustLibApi {
  final thumbnails = <String>[];
  final originals = <String>[];
  final downloads = <String>[];
  bool failDownloads = false;
  final forwards = <String>[];
  final albumCaptions = <String, String?>{};
  final captionRequests = <String>[];

  @override
  Future<String?> crateApiMatrixGetImageAlbumCaption({
    required String accountUserId,
    required String roomId,
    required String rootEventId,
  }) async {
    captionRequests.add(rootEventId);
    return albumCaptions[rootEventId];
  }

  Completer<String?>? originalPending;
  Completer<String?>? thumbnailPending;

  @override
  Future<Uint8List?> crateApiMatrixDownloadMediaBytes({
    required String mxcUrl,
  }) async {
    downloads.add(mxcUrl);
    return pixel;
  }

  @override
  Future<Uint8List> crateApiMatrixDownloadMediaSourceBytes({
    required String mediaSourceJson,
    int? maxSizeBytes,
  }) async {
    downloads.add(mediaSourceJson);
    if (failDownloads) throw StateError('Connection reset');
    return pixel;
  }

  @override
  Future<String> crateApiMatrixForwardMessage({
    required String sourceRoomId,
    required String targetRoomId,
    required String eventId,
    required rust.FormattedMessageInput text,
  }) async {
    forwards.add(eventId);
    return 'forwarded';
  }

  @override
  Future<String?> crateApiMatrixMxcToHttpThumbnail({
    required String mxcUrl,
    required int width,
    required int height,
  }) async {
    thumbnails.add(mxcUrl);
    return thumbnailPending?.future ??
        Future.value('https://example.org/thumbnail/${mxcUrl.split('/').last}');
  }

  @override
  Future<String?> crateApiMatrixMxcToHttp({required String mxcUrl}) async {
    thumbnails.add(mxcUrl);
    return 'https://example.org/thumbnail/${mxcUrl.split('/').last}';
  }

  @override
  Future<String?> crateApiMatrixMxcToHttpFull({required String mxcUrl}) async {
    originals.add(mxcUrl);
    return originalPending?.future ??
        Future.value('https://example.org/original/${mxcUrl.split('/').last}');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

rust.ChatMessage imageMessage(
  String id, {
  int? size = 2 * 1024 * 1024,
  String? filename,
  String? mimeType,
  String? caption,
  String? sharedCaption,
  rust.ImageMessageMetadata? metadata,
  bool encrypted = false,
}) => rust.ChatMessage(
  id: id,
  senderId: '@alice:example.org',
  senderName: 'Alice',
  content: filename ?? '$id.png',
  caption: caption,
  sharedCaption: sharedCaption,
  imageMetadata: metadata,
  timestamp: id == 'older' ? '100' : '200',
  isMe: false,
  msgType: rust.MessageType.image,
  imageUrl: encrypted ? null : 'mxc://example.org/$id',
  mediaSourceJson: encrypted
      ? '{"url":"mxc://example.org/$id","key":{}}'
      : null,
  mimeType: mimeType,
  imageWidth: 1600,
  imageHeight: 1200,
  fileSize: size,
  filename: filename,
  mentionedUserIds: const [],
  mentionsRoom: false,
  isEdited: false,
  editHistory: const [],
  reactions: const [],
  readers: const [],
  totalMembers: 2,
);

Future<void> pumpImages(
  WidgetTester tester,
  List<rust.ChatMessage> messages, {
  ValueChanged<String>? onJump,
  VoidCallback? onReply,
  ImageHistoryLoader? loadOlder,
  String account = 'image-tester',
  bool dark = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeUserIdProvider.overrideWith(() => MutableState(account)),
        chatRoomsProvider.overrideWith(
          (_) async => [
            const rust.ChatRoom(
              id: '!target:example.org',
              name: '目标会话',
              lastMessage: '',
              lastMessageTime: '0',
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
      child: MaterialApp(
        theme: neuTestTheme(dark: dark),
        home: Scaffold(
          body: MessageGroupWidget(
            group: MessageGroup(
              senderId: messages.last.senderId,
              senderName: 'Alice',
              isMe: false,
              messages: [messages.last],
            ),
            roomId: '!room:example.org',
            messageIndex: {for (final message in messages) message.id: message},
            showAvatar: false,
            onMessageJumpRequested: onJump,
            onReplyRequested: onReply,
            loadOlderImages: loadOlder,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> openImage(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(ValueKey('msg-image:image-preview:$id')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  final toolbar = find.byKey(const ValueKey('image-viewer-toolbar'));
  final appBar = tester.widget<AppBar>(
    find.descendant(of: toolbar, matching: find.byType(AppBar)),
  );
  final background = appBar.backgroundColor!;
  final foreground = appBar.foregroundColor!;
  expect(background.a, 1);
  final backgroundLuminance = background.computeLuminance();
  final foregroundLuminance = foreground.computeLuminance();
  final lighter = backgroundLuminance > foregroundLuminance
      ? backgroundLuminance
      : foregroundLuminance;
  final darker = backgroundLuminance < foregroundLuminance
      ? backgroundLuminance
      : foregroundLuminance;
  expect((lighter + .05) / (darker + .05), greaterThanOrEqualTo(4.5));
  final toolbarRect = tester.getRect(toolbar);
  expect(toolbarRect.top, 0);
  expect(
    toolbarRect.height,
    kToolbarHeight + MediaQuery.paddingOf(tester.element(toolbar)).top,
  );
  final imageViewport = tester.getRect(
    find.descendant(
      of: find.byKey(ValueKey(id)),
      matching: find.byType(InteractiveViewer),
    ),
  );
  expect(imageViewport.top, greaterThanOrEqualTo(toolbarRect.bottom));
}

Future<void> chooseImageAction(
  WidgetTester tester,
  String id,
  String action,
) async {
  expect(find.byKey(ValueKey(id)), findsOneWidget);
  final toolbar = find.byKey(const ValueKey('image-viewer-toolbar'));
  final menuState = tester.state(
    find.descendant(
      of: toolbar,
      matching: find.byWidgetPredicate((widget) => widget is PopupMenuButton),
    ),
  );
  await tester.tap(
    find.descendant(of: toolbar, matching: find.byTooltip('更多操作')),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  expect(menuState.mounted, isTrue);
  await tester.tap(find.text(action));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

void main() {
  late ImageApi api;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await installStorageWifi();
    api = ImageApi();
    RustLib.initMock(api: api);
  });
  tearDown(RustLib.dispose);

  testWidgets('encrypted bubble retries after sync reconnects', (tester) async {
    api.failDownloads = true;
    await pumpImages(tester, [imageMessage('offline', encrypted: true)]);
    expect(api.downloads, hasLength(1));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ImageMessageBubble)),
    );
    container.read(connectionProvider.notifier).value =
        AppConnectionState.disconnected;
    await tester.pump();
    api.failDownloads = false;
    container.read(connectionProvider.notifier).value =
        AppConnectionState.connected;
    await tester.pump();
    await tester.pump();

    expect(api.downloads, hasLength(2));
    expect(find.byType(Image), findsOneWidget);
    container.read(connectionProvider.notifier).value =
        AppConnectionState.disconnected;
    await tester.pump();
    container.read(connectionProvider.notifier).value =
        AppConnectionState.connected;
    await tester.pump();
    expect(api.downloads, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('encrypted viewer retries after sync reconnects', (tester) async {
    api.failDownloads = true;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatImageViewer(
            initialSource: ImageViewerSource.fromMessage(
              imageMessage('offline', encrypted: true),
            ),
            animation: const AlwaysStoppedAnimation(1),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('重新加载图片'), findsOneWidget);
    final failedRequests = api.downloads.length;
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ChatImageViewer)),
    );
    container.read(connectionProvider.notifier).value =
        AppConnectionState.disconnected;
    await tester.pump();
    api.failDownloads = false;
    container.read(connectionProvider.notifier).value =
        AppConnectionState.connected;
    await tester.pump();
    await tester.pump();

    expect(api.downloads.length, greaterThan(failedRequests));
    expect(find.text('重新加载图片'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('image metadata survives the message disk cache round trip', () {
    final message = imageMessage(
      'metadata',
      size: 123456,
      filename: 'animation',
      mimeType: 'image/gif',
    );
    final restored = chatMessageFromMap(chatMessageToMap(message));
    expect(restored.fileSize, 123456);
    expect(restored.mimeType, 'image/gif');
    expect(restored.filename, 'animation');
  });

  test(
    'shared image caption survives caching and changes snapshot equality',
    () {
      final message = imageMessage('shared', sharedCaption: '整组的描述');
      final restored = chatMessageFromMap(chatMessageToMap(message));
      expect(restored.sharedCaption, '整组的描述');
      expect(restored.caption, isNull);
      expect(chatMessageContentEquals(message, restored), isTrue);
      expect(
        chatMessageContentEquals(message, imageMessage('shared')),
        isFalse,
      );
      expect(ImageViewerSource.fromMessage(restored).description, '整组的描述');
    },
  );

  for (final encrypted in [false, true]) {
    testWidgets(
      'gallery shows the shared caption on every image (encrypted=$encrypted)',
      (tester) async {
        await pumpImages(tester, [
          imageMessage('one', sharedCaption: '共同描述', encrypted: encrypted),
          imageMessage(
            'two',
            caption: '最后一张的描述',
            sharedCaption: '共同描述',
            encrypted: encrypted,
          ),
        ]);
        await openImage(tester, 'two');
        final caption = find.byKey(const ValueKey('image-viewer-caption'));
        expect(
          find.descendant(of: caption, matching: find.text('最后一张的描述')),
          findsOneWidget,
        );
        final bounds = tester.getRect(caption);
        await tester.drag(find.byType(PageView), const Offset(650, 0));
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.descendant(of: caption, matching: find.text('共同描述')),
          findsOneWidget,
        );
        final gesture = await tester.startGesture(const Offset(400, 200));
        await gesture.moveBy(const Offset(0, 20));
        await tester.pump();
        await gesture.moveBy(const Offset(0, 40));
        await tester.pump();
        expect(tester.getRect(caption).bottom, bounds.bottom);
        await gesture.cancel();
        await tester.pump(const Duration(milliseconds: 250));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'an album caption is shared without repeating it in every image event',
    (tester) async {
      await pumpImages(tester, [
        imageMessage('older'),
        imageMessage(
          'two',
          caption: '整组描述',
          metadata: const rust.ImageMessageMetadata(
            albumRoot: 'older',
            spoiler: false,
          ),
        ),
      ]);
      await openImage(tester, 'two');
      await tester.drag(find.byType(PageView), const Offset(650, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('image-viewer-caption')),
          matching: find.text('整组描述'),
        ),
        findsOneWidget,
      );
      expect(api.captionRequests, isEmpty);
    },
  );

  testWidgets('a partial album loads its caption through the root relation', (
    tester,
  ) async {
    const root = '\$root:example.org';
    const child = '\$child:example.org';
    api.albumCaptions[root] = '尚未加载到聊天列表里的描述';
    await pumpImages(tester, [
      imageMessage(
        child,
        metadata: const rust.ImageMessageMetadata(
          albumRoot: root,
          spoiler: false,
        ),
      ),
    ]);
    await openImage(tester, child);
    await tester.pump();
    expect(find.text('尚未加载到聊天列表里的描述'), findsOneWidget);
    expect(api.captionRequests, [root]);
  });

  testWidgets(
    'paging to a spoiler keeps encrypted media unfetched until reveal',
    (tester) async {
      final hidden = imageMessage(
        'older',
        encrypted: true,
        metadata: const rust.ImageMessageMetadata(spoiler: true),
      );
      await pumpImages(tester, [hidden, imageMessage('two')]);
      await openImage(tester, 'two');
      expect(api.downloads, isEmpty);
      await tester.drag(find.byType(PageView), const Offset(650, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final pages = tester.widget<PageView>(find.byType(PageView)).controller!;
      for (
        var frame = 0;
        frame < 30 && pages.position.isScrollingNotifier.value;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(pages.position.isScrollingNotifier.value, isFalse);
      final cover = find.byKey(const ValueKey('spoiler-image-cover'));
      expect(cover, findsOneWidget);
      expect(api.downloads, isEmpty);
      await tester.tap(cover);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(api.downloads, [hidden.mediaSourceJson]);
      expect(
        find.byKey(const ValueKey('spoiler-image-cover')).hitTestable(),
        findsNothing,
      );
    },
  );

  testWidgets(
    'original preference survives remount, eviction and is isolated by account',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'mxc_http_cache_v1_image-tester': jsonEncode({
          'mxc://example.org/persisted|original':
              'https://example.org/original/persisted',
          for (var i = 0; i < 501; i++)
            'mxc://example.org/cache-$i|96x96':
                'https://example.org/thumbnail/$i',
        }),
      });
      await pumpImages(tester, [imageMessage('persisted', size: 512 * 1024)]);
      expect(api.thumbnails, isEmpty);
      expect(api.originals, isEmpty);
      expect(
        tester
            .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
            .imageUrl,
        'https://example.org/original/persisted',
      );
      expect(
        tester
            .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
            .maxWidthDiskCache,
        isNull,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        jsonDecode(
          prefs.getString('mxc_http_cache_v1_image-tester')!,
        )['mxc://example.org/persisted|original'],
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox());
      await pumpImages(tester, [imageMessage('persisted', size: 512 * 1024)]);
      expect(api.thumbnails, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await pumpImages(tester, [
        imageMessage('persisted', size: 512 * 1024),
      ], account: 'other-account');
      // This account must resolve its own original, without reusing the first
      // account's persisted URL. The image is below the new Wi-Fi limit.
      expect(api.originals, ['mxc://example.org/persisted']);
      expect(api.thumbnails, isEmpty);
    },
  );

  testWidgets('late thumbnail resolution cannot erase an original preference', (
    tester,
  ) async {
    api.thumbnailPending = Completer<String?>();
    late WidgetRef mediaRef;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              mediaRef = ref;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    final thumbnail = resolveMxcUrl(
      mediaRef,
      'mxc://example.org/race',
      width: 100,
      height: 100,
    );
    await tester.pump();
    await resolveMxcUrlFull(mediaRef, 'mxc://example.org/race');
    api.thumbnailPending!.complete('https://example.org/thumbnail/race');
    await thumbnail;
    expect(
      cachedOriginalMxcUrl(mediaRef, 'mxc://example.org/race'),
      'https://example.org/original/race',
    );
  });

  testWidgets('download and forwarding use the image selected after a swipe', (
    tester,
  ) async {
    final downloads = await _installDownloads(tester);
    await pumpImages(tester, [imageMessage('older'), imageMessage('latest')]);
    await openImage(tester, 'latest');
    await tester.drag(find.byType(PageView), const Offset(650, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(
      tester.widget<PageView>(find.byType(PageView)).controller!.page,
      closeTo(0, .01),
    );
    final scrolling = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(PageView),
        matching: find.byType(Scrollable),
      ),
    );
    for (
      var frame = 0;
      frame < 40 && scrolling.position.isScrollingNotifier.value;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump();
    expect(scrolling.position.isScrollingNotifier.value, isFalse);
    await _downloadImage(tester);
    expect(api.downloads, ['mxc://example.org/older']);
    expect(
      await tester.runAsync(
        () => File('${downloads.path}/older.png').readAsBytes(),
      ),
      pixel,
    );
    await chooseImageAction(tester, 'older', '转发');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(
      find.byKey(const ValueKey('forward-room-!target:example.org')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(api.forwards, ['older']);
  });

  testWidgets(
    'encrypted image downloads decrypted bytes through its MediaSource',
    (tester) async {
      final downloads = await _installDownloads(tester);
      await pumpImages(tester, [imageMessage('encrypted', encrypted: true)]);
      await openImage(tester, 'encrypted');
      expect(api.downloads, ['{"url":"mxc://example.org/encrypted","key":{}}']);
      api.downloads.clear();
      await _downloadImage(tester);
      // The preview already has the decrypted original, so saving reuses it.
      expect(api.downloads, isEmpty);
      expect(
        await tester.runAsync(
          () => File('${downloads.path}/encrypted.png').readAsBytes(),
        ),
        pixel,
      );
    },
  );

  testWidgets(
    'loading older images preserves the current page and selects the preceding image',
    (tester) async {
      String? jumped;
      await pumpImages(
        tester,
        [imageMessage('latest')],
        onJump: (id) => jumped = id,
        loadOlder: () async => (
          messages: [imageMessage('older'), imageMessage('latest')],
          hasMore: false,
        ),
      );
      await openImage(tester, 'latest');
      await tester.tap(find.byTooltip('加载更早图片'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await chooseImageAction(tester, 'older', '转到消息');
      await tester.pump();
      expect(
        find.byWidgetPredicate((widget) => widget is PopupMenuItem),
        findsNothing,
      );
      expect(find.byType(ChatImageViewer), findsNothing);
      expect(jumped, 'older');
    },
  );

  testWidgets('reply quotes the selected gallery image and opens the input', (
    tester,
  ) async {
    final older = imageMessage('older', encrypted: true);
    final latest = imageMessage('latest');
    var replyRequests = 0;
    await pumpImages(tester, [older, latest], onReply: () => replyRequests++);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MessageGroupWidget)),
    );
    const key = (roomId: '!room:example.org', userId: 'image-tester');
    const otherKey = (roomId: '!room:example.org', userId: 'another-account');
    container.read(editingMessageProvider(key).notifier).value = latest;
    container.read(editingDraftProvider(key).notifier).value = (
      editingId: latest.id,
      text: 'unfinished edit',
    );
    container.read(replyingToProvider(otherKey).notifier).value = latest;
    await openImage(tester, 'latest');
    await tester.drag(find.byType(PageView), const Offset(650, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await chooseImageAction(tester, 'older', '回复');
    expect(find.byType(ChatImageViewer), findsNothing);
    expect(container.read(replyingToProvider(key)), same(older));
    expect(container.read(editingMessageProvider(key)), isNull);
    expect(container.read(editingDraftProvider(key)), isNull);
    expect(container.read(replyingToProvider(otherKey)), same(latest));
    expect(replyRequests, 1);
  });

  testWidgets('image reply preserves an edit being sent', (tester) async {
    final image = imageMessage('latest');
    var replyRequests = 0;
    await pumpImages(tester, [image], onReply: () => replyRequests++);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MessageGroupWidget)),
    );
    const key = (roomId: '!room:example.org', userId: 'image-tester');
    container.read(editingMessageProvider(key).notifier).value = image;
    container.read(editingSendInFlightProvider(key).notifier).value = image.id;
    await openImage(tester, 'latest');
    await chooseImageAction(tester, 'latest', '回复');
    expect(container.read(replyingToProvider(key)), isNull);
    expect(container.read(editingMessageProvider(key)), same(image));
    expect(container.read(editingSendInFlightProvider(key)), image.id);
    expect(replyRequests, 0);
    expect(find.text('编辑正在发送，请稍候'), findsOneWidget);
  });

  testWidgets('unsent local images do not offer reply', (tester) async {
    const id = 'local_outgoing_pending:photo';
    await pumpImages(tester, [imageMessage(id)], onJump: (_) {});
    await tester.tap(find.byType(ImageMessageBubble));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('回复'), findsNothing);
    expect(find.text('转到消息'), findsOneWidget);
  });

  testWidgets('open menu keeps its target while history changes the page', (
    tester,
  ) async {
    final history =
        Completer<({List<rust.ChatMessage> messages, bool hasMore})>();
    String? jumped;
    await pumpImages(
      tester,
      [imageMessage('latest')],
      onJump: (id) => jumped = id,
      loadOlder: () => history.future,
    );
    await openImage(tester, 'latest');
    await tester.tap(find.byTooltip('加载更早图片'));
    await tester.pump();
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    history.complete((
      messages: [
        imageMessage('older', size: 512 * 1024),
        imageMessage('latest'),
      ],
      hasMore: false,
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '上一张',
            ),
          )
          .onPressed,
      isNull,
    );
    expect(find.byTooltip('查看原图'), findsNothing);
    await tester.tap(find.text('转到消息'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(jumped, 'latest');
    expect(find.byType(ChatImageViewer), findsNothing);
  });

  testWidgets('toolbar and paging controls stay fixed while dragging images', (
    tester,
  ) async {
    await pumpImages(tester, [imageMessage('older'), imageMessage('latest')]);
    await openImage(tester, 'latest');
    final toolbar = find.byKey(const ValueKey('image-viewer-toolbar'));
    final nextButton = find.byTooltip('下一张');
    final image = find.descendant(
      of: find.byKey(const ValueKey('latest')),
      matching: find.byType(InteractiveViewer),
    );
    final toolbarRect = tester.getRect(toolbar);
    final nextButtonRect = tester.getRect(nextButton);
    final imageRect = tester.getRect(image);
    final vertical = await tester.startGesture(imageRect.center);
    await vertical.moveBy(const Offset(0, 20));
    await tester.pump(const Duration(milliseconds: 16));
    await vertical.moveBy(const Offset(0, 40));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.getRect(image), isNot(imageRect));
    expect(tester.getRect(nextButton), nextButtonRect);
    expect(tester.getRect(toolbar), toolbarRect);
    await vertical.cancel();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    final horizontal = await tester.startGesture(imageRect.center);
    await horizontal.moveBy(const Offset(20, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await horizontal.moveBy(const Offset(80, 0));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.getRect(image).left, greaterThan(imageRect.left));
    expect(tester.getRect(nextButton), nextButtonRect);
    expect(tester.getRect(toolbar), toolbarRect);
    await horizontal.cancel();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets(
    'drag dismisses at 1x and zooming keeps drag and paging in the image',
    (tester) async {
      await pumpImages(tester, [imageMessage('older'), imageMessage('latest')]);
      await openImage(tester, 'latest');
      final viewer = find.byType(InteractiveViewer).hitTestable();
      final position = tester.getCenter(viewer);
      await tester.tapAt(position);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(position);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.widget<PageView>(find.byType(PageView)).physics,
        isA<NeverScrollableScrollPhysics>(),
      );
      await tester.drag(viewer, const Offset(0, 200));
      await tester.pump();
      expect(find.byType(ChatImageViewer), findsOneWidget);
      tester.widget<InteractiveViewer>(viewer).transformationController!.value =
          Matrix4.identity();
      await tester.pump();
      await tester.drag(viewer, const Offset(0, 200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(ChatImageViewer), findsNothing);
    },
  );

  testWidgets(
    'an original resolving during a swipe cannot change the selected image',
    (tester) async {
      api.originalPending = Completer<String?>();
      await pumpImages(tester, [
        imageMessage('older', size: 16 * 1024 * 1024),
        imageMessage('latest', size: 16 * 1024 * 1024),
      ]);
      await openImage(tester, 'latest');
      await tester.tap(find.text('原图').hitTestable());
      await tester.pump();
      await tester.drag(find.byType(PageView), const Offset(650, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      api.originalPending!.complete('https://example.org/original/latest');
      await tester.pump();
      expect(find.byTooltip('查看原图'), findsOneWidget);
      expect(find.byTooltip('正在加载原图'), findsNothing);
      expect(
        tester
            .widget<CachedNetworkImage>(
              find.descendant(
                of: find.byKey(const ValueKey('older')),
                matching: find.byType(CachedNetworkImage),
              ),
            )
            .imageUrl,
        'https://example.org/thumbnail/older',
      );
    },
  );

  testWidgets(
    'original resolution failure leaves a retry that can load the image',
    (tester) async {
      api.originalPending = Completer<String?>();
      await pumpImages(tester, [imageMessage('retry', size: 16 * 1024 * 1024)]);
      await openImage(tester, 'retry');
      await tester.tap(find.text('原图'));
      await tester.pump();
      api.originalPending!.complete(null);
      await tester.pump();
      expect(find.text('重试'), findsOneWidget);
      api.originalPending = null;
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is CachedNetworkImage &&
              widget.imageUrl == 'https://example.org/original/retry',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('double tap cycles 2x, 4x and original scale', (tester) async {
    await pumpImages(tester, [imageMessage('zoom')]);
    await openImage(tester, 'zoom');
    final viewer = find.byType(InteractiveViewer);
    final position = tester.getCenter(viewer);
    for (final scale in [2.0, 4.0, 1.0]) {
      await tester.tapAt(position);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(position);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final widget = tester.widget<InteractiveViewer>(viewer);
      expect(widget.transformationController, isNotNull);
      expect(widget.transformationController!.value.getMaxScaleOnAxis(), scale);
      await tester.pump(const Duration(milliseconds: 350));
    }
  });

  testWidgets('viewed original is reused after closing and reopening', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.view.padding = const FakeViewPadding(top: 24);
    addTearDown(tester.view.resetPadding);
    // Above the Wi-Fi original limit, so the explicit quality switch is visible.
    await pumpImages(tester, [
      imageMessage('remember', size: 16 * 1024 * 1024),
    ], dark: false);
    await openImage(tester, 'remember');
    final qualityWidth = tester
        .getSize(find.widgetWithText(TextButton, '原图'))
        .width;
    await tester.tap(find.text('原图'));
    await tester.pump();
    final full = find.byWidgetPredicate(
      (widget) =>
          widget is CachedNetworkImage &&
          widget.imageUrl.contains('/original/'),
    );
    expect(full, findsOneWidget);
    final image = tester.widget<CachedNetworkImage>(full);
    image.imageBuilder!(tester.element(full), MemoryImage(pixel));
    await tester.pump();
    await tester.pump();
    expect(find.text('高清'), findsOneWidget);
    expect(
      tester.getSize(find.widgetWithText(TextButton, '高清')).width,
      qualityWidth,
    );
    expect(qualityWidth, lessThanOrEqualTo(56));
    expect(find.text('转发'), findsNothing);
    expect(find.text('转到消息'), findsNothing);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    await openImage(tester, 'remember');
    expect(full, findsWidgets);
    expect(find.text('原图'), findsNothing);
    expect(api.originals, ['mxc://example.org/remember']);
  });

  testWidgets('a slow automatic original leaves its thumbnail usable', (
    tester,
  ) async {
    api.originalPending = Completer<String?>();
    await pumpImages(tester, [imageMessage('slow', size: 512 * 1024)]);
    await tester.pump(const Duration(milliseconds: 16));
    expect(api.originals, ['mxc://example.org/slow']);
    expect(api.thumbnails, ['mxc://example.org/slow']);
    expect(
      find.byKey(const ValueKey('msg-image:image-preview:slow')),
      findsOneWidget,
    );
    api.originalPending!.complete('https://example.org/original/slow');
    await tester.pump();
    expect(
      tester
          .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
          .imageUrl,
      'https://example.org/original/slow',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'over-limit images fetch a thumbnail without fetching the original',
    (tester) async {
      await pumpImages(tester, [imageMessage('large', size: 16 * 1024 * 1024)]);
      expect(api.originals, isEmpty);
      expect(api.thumbnails, ['mxc://example.org/large']);
      expect(
        find.byKey(const ValueKey('msg-image:image-preview:large')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('small image loads original despite large pixel dimensions', (
    tester,
  ) async {
    await pumpImages(tester, [imageMessage('small', size: 512 * 1024)]);
    expect(api.originals, ['mxc://example.org/small']);
    expect(api.thumbnails, isEmpty);
    await openImage(tester, 'small');
    expect(find.byType(TextButton), findsNothing);
    expect(find.byTooltip('下载'), findsOneWidget);
  });

  testWidgets('GIF loads original within the configured network limit', (
    tester,
  ) async {
    await pumpImages(tester, [
      imageMessage('gif', size: 4 * 1024 * 1024, filename: 'animation.GIF'),
    ]);
    expect(api.originals, ['mxc://example.org/gif']);
    expect(api.thumbnails, isEmpty);
    await openImage(tester, 'gif');
    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets('swiping selects another image and jump targets that message', (
    tester,
  ) async {
    String? jumped;
    await pumpImages(tester, [
      imageMessage('older'),
      imageMessage('latest'),
    ], onJump: (id) => jumped = id);
    await openImage(tester, 'latest');
    expect(find.byType(PageView), findsOneWidget);
    await tester.drag(find.byType(PageView), const Offset(650, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(
      tester.widget<PageView>(find.byType(PageView)).controller!.page,
      closeTo(0, .01),
    );
    final scrolling = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(PageView),
        matching: find.byType(Scrollable),
      ),
    );
    for (
      var frame = 0;
      frame < 40 && scrolling.position.isScrollingNotifier.value;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump();
    expect(scrolling.position.isScrollingNotifier.value, isFalse);
    await chooseImageAction(tester, 'older', '转到消息');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(jumped, 'older');
    expect(find.byType(InteractiveViewer), findsNothing);
  });
}
