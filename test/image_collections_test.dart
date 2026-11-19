import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:matter/pages/chat/blurhash_codec.dart';
import 'package:matter/pages/chat/image_message_bubble.dart';
import 'package:matter/pages/chat/image_message_collection.dart';
import 'package:matter/pages/chat/image_message_runs.dart';
import 'package:matter/pages/chat/image_mosaic_layout.dart';
import 'package:matter/pages/chat/image_stack_layout.dart';
import 'package:matter/pages/chat/message_group.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/image_view_history.dart';
import 'package:matter/providers/message_cache_persistence.dart';
import 'package:matter/providers/mutable_state.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/neu_test_theme.dart';
import 'support/storage_network.dart';

rust.ChatMessage picture(
  String id, {
  int time = 1000,
  String sender = 'alice',
  String? root,
  bool spoiler = false,
  String? caption,
  String? captionFormattedBody,
  String? sharedCaption,
  List<rust.Reaction> reactions = const [],
  rust.MessageType type = rust.MessageType.image,
}) => rust.ChatMessage(
  id: id,
  senderId: sender,
  senderName: sender,
  content: '$id.png',
  timestamp: '$time',
  isMe: false,
  msgType: type,
  imageUrl: 'mxc://example.org/$id',
  fileSize: 2 * 1024 * 1024,
  imageWidth: 1200,
  imageHeight: 800,
  caption: caption,
  captionFormattedBody: captionFormattedBody,
  sharedCaption: sharedCaption,
  imageMetadata: root == null && !spoiler
      ? null
      : rust.ImageMessageMetadata(albumRoot: root, spoiler: spoiler),
  mentionedUserIds: const [],
  mentionsRoom: false,
  isEdited: false,
  editHistory: const [],
  reactions: reactions,
  readers: const [],
  totalMembers: 2,
);

class _Images implements RustLibApi {
  final resolved = <String>[];
  @override
  Future<String?> crateApiMatrixMxcToHttpThumbnail({
    required String mxcUrl,
    required int width,
    required int height,
  }) async {
    resolved.add(mxcUrl);
    return 'https://example.org/image.png';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await installStorageWifi();
  });

  test(
    'independent images fold only across adjacent five-minute intervals',
    () {
      final runs = chatImageRuns([
        picture('one'),
        picture('two', time: 301000),
        picture('three', time: 601001),
        picture('text', time: 601002, type: rust.MessageType.text),
        picture('four', time: 601003),
        picture('other', time: 601004, sender: 'bob'),
        picture('five', time: 601005),
      ]);
      expect(
        runs.map((run) => run.messages.map((message) => message.id).toList()),
        [
          ['one', 'two'],
          ['three'],
          ['text'],
          ['four'],
          ['other'],
          ['five'],
        ],
      );
      expect(runs.every((run) => !run.album), isTrue);
    },
  );

  test('independent image stacks stop when their descriptions change', () {
    final runs = chatImageRuns([
      picture('empty'),
      picture('blank', caption: '  \n '),
      picture('first', caption: 'First description'),
      picture('same-first', caption: ' First description '),
      picture('second', caption: 'Second description'),
      picture('same-second', caption: 'Second description'),
      picture('no-caption'),
      picture('empty-caption', caption: ''),
    ]);
    expect(
      runs.map((run) => run.messages.map((message) => message.id).toList()),
      [
        ['empty', 'blank'],
        ['first', 'same-first'],
        ['second', 'same-second'],
        ['no-caption', 'empty-caption'],
      ],
    );
    expect(runs.every((run) => !run.album), isTrue);
  });

  test(
    'different caption links remain independent even with the same plain text',
    () {
      final runs = chatImageRuns([
        picture(
          'first-link',
          caption: 'Details',
          captionFormattedBody: '<a href="https://example.org/one">Details</a>',
        ),
        picture(
          'second-link',
          caption: 'Details',
          captionFormattedBody: '<a href="https://example.org/two">Details</a>',
        ),
      ]);
      expect(runs.map((run) => run.messages.length), [1, 1]);
    },
  );

  test('standard descriptions take precedence over older shared descriptions when folding', () {
    final runs = chatImageRuns([
      picture(
        'first',
        caption: 'First description',
        sharedCaption: 'Old description',
      ),
      picture(
        'second',
        caption: 'Second description',
        sharedCaption: 'Old description',
      ),
    ]);
    expect(runs.map((run) => run.messages.length), [1, 1]);
  });

  test('albums remain one unit across intervening messages and midnight', () {
    final runs = chatImageRuns([
      picture('root', time: 86399000, caption: 'Root description'),
      picture('between', sender: 'bob'),
      picture(
        'child',
        time: 86401000,
        root: 'root',
        caption: 'Child description',
      ),
      picture('after', time: 86402000),
    ]);
    expect(runs.first.album, isTrue);
    expect(runs.first.messages.map((message) => message.id), ['root', 'child']);
    expect(runs.skip(1).map((run) => run.messages.single.id), [
      'between',
      'after',
    ]);
  });

  test('an album interruption does not merge independent images around it', () {
    final runs = chatImageRuns([
      picture('root'),
      picture('one', sender: 'bob'),
      picture('child', root: 'root'),
      picture('two', sender: 'bob'),
    ]);
    expect(runs.map((run) => run.messages.length), [2, 1, 1]);
  });

  test('legacy shared captions identify albums and their final image ends each batch', () {
    final runs = chatImageRuns([
      picture('one', sharedCaption: 'Holiday'),
      picture('two', sharedCaption: 'Holiday', caption: 'Holiday'),
      picture('three', sharedCaption: 'Holiday'),
      picture('four', sharedCaption: 'Holiday', caption: 'Holiday'),
      picture('five'),
      picture('six'),
    ]);
    expect(
      runs.map((run) => run.messages.map((message) => message.id).toList()),
      [
        ['one', 'two'],
        ['three', 'four'],
        ['five', 'six'],
      ],
    );
    expect(runs.map((run) => run.album), [true, true, false]);
  });

  test('legacy captions do not connect across text, senders or long gaps', () {
    final runs = chatImageRuns([
      picture('one', sharedCaption: 'Holiday'),
      picture('text', type: rust.MessageType.text),
      picture('two', sharedCaption: 'Holiday', caption: 'Holiday'),
      picture('three', sharedCaption: 'Holiday', sender: 'bob'),
      picture('four', sharedCaption: 'Holiday', time: 301001),
    ]);
    expect(runs.every((run) => !run.album), isTrue);
  });

  test('alternating photo layout matches the HTML default geometry', () {
    final layout = imageStackLayout(3, 520);
    // Reference values from the playground's geometry() at its default 3:2 ratio.
    expect(layout.size.width, closeTo(321.17741336174504, .000001));
    expect(layout.size.height, closeTo(217.6370237665914, .000001));
    expect(layout.layers.first.rect.left, closeTo(33.69371829386361, .000001));
    expect(layout.layers.first.rect.top, closeTo(37.6370237665914, .000001));
    expect(layout.layers.first.rect.size, const Size(270, 180));
    expect(layout.layers[1].rotation * 180 / math.pi, closeTo(5, .000001));
    expect(layout.layers[2].rotation * 180 / math.pi, closeTo(-10, .000001));
    expect(layout.layers[1].rect.width, closeTo(264.6, .000001));
    expect(layout.layers[2].rect.width, closeTo(259.308, .000001));
    expect(layout.layers.map((layer) => layer.opacity), [1, .97, .9409]);
  });

  test(
    'the entire rotated stack fits narrow widths and scales as one unit',
    () {
      for (final width in [180.0, 240.0, 320.0, 520.0]) {
        for (final count in [2, 3, 8]) {
          final layout = imageStackLayout(count, width);
          expect(layout.layers.length, math.min(count, 3));
          expect(layout.size.width, lessThanOrEqualTo(width + .000001));
          for (final layer in layout.layers) {
            expect(layer.paintBounds.left, greaterThanOrEqualTo(-.000001));
            expect(layer.paintBounds.top, greaterThanOrEqualTo(-.000001));
            expect(
              layer.paintBounds.right,
              lessThanOrEqualTo(layout.size.width + .000001),
            );
            expect(
              layer.paintBounds.bottom,
              lessThanOrEqualTo(layout.size.height + .000001),
            );
          }
          expect(
            layout.layers.first.rect.width / 270,
            closeTo(layout.scale, .000001),
          );
          expect(
            layout.layers.first.rect.width / layout.layers.first.rect.height,
            closeTo(1.5, .000001),
          );
        }
      }
    },
  );

  test('mosaic tiles cover the message width without overlap or out-of-bounds geometry', () {
    for (final width in [200.0, 340.0, 520.0]) {
      for (var count = 1; count <= 18; count++) {
        final layout = imageMosaicLayout([
          for (var i = 0; i < count; i++) [.3, 2.8, 1.0, .8][i % 4],
        ], width);
        expect(layout.tiles, hasLength(count));
        expect(
          layout.tiles
              .map((tile) => tile.right)
              .reduce((a, b) => a > b ? a : b),
          closeTo(width, .001),
        );
        final bounds = Rect.fromLTWH(0, 0, width, layout.height);
        for (var i = 0; i < count; i++) {
          final tile = layout.tiles[i];
          expect(tile.width, greaterThan(0));
          expect(tile.height, greaterThan(0));
          expect(bounds.contains(tile.topLeft), isTrue);
          expect(tile.right, lessThanOrEqualTo(width + .001));
          expect(tile.bottom, lessThanOrEqualTo(layout.height + .001));
          for (var j = i + 1; j < count; j++) {
            expect(tile.overlaps(layout.tiles[j]), isFalse);
          }
        }
      }
    }
  });

  test('BlurHash accepts published hashes and rejects malformed or oversized input', () {
    final published = img.decodePng(
      decodeBlurhash('LEHV6nWB2yk8pyo0adR*.7kCMdnj')!,
    );
    expect(published!.width, 32);
    expect(published.height, 32);
    final black = img.decodePng(decodeBlurhash('000000')!)!;
    expect(black.getPixel(10, 10).r, 0);
    expect(black.getPixel(10, 10).a, 255);
    for (final hash in ['', 'invalid', '00000!', '0' * 1000, '~00000']) {
      expect(decodeBlurhash(hash), isNull);
    }
  });

  test('image metadata survives caching and remains backward-compatible', () {
    final original = picture('child', root: 'root', spoiler: true);
    final restored = chatMessageFromMap(
      jsonDecode(jsonEncode(chatMessageToMap(original)))
          as Map<String, dynamic>,
    );
    expect(restored.imageMetadata, original.imageMetadata);
    final old = chatMessageToMap(original)..remove('imageMetadata');
    expect(chatMessageFromMap(old).imageMetadata, isNull);
  });

  test('view history merges a late persisted snapshot and isolates accounts and rooms', () async {
    SharedPreferences.setMockInitialValues({
      'chat_image_views:${jsonEncode(['alice', 'room'])}': ['older'],
    });
    final container = ProviderContainer();
    const scope = (account: 'alice', room: 'room');
    await container
        .read(imageViewHistoryProvider(scope).notifier)
        .viewed('new');
    expect(container.read(imageViewHistoryProvider(scope)), ['older', 'new']);
    expect(
      container.read(imageViewHistoryProvider((account: 'bob', room: 'room'))),
      isEmpty,
    );
    expect(
      container.read(
        imageViewHistoryProvider((account: 'alice', room: 'other')),
      ),
      isEmpty,
    );
    container.dispose();
    final restored = ProviderContainer();
    restored.read(imageViewHistoryProvider(scope));
    await Future<void>.delayed(Duration.zero);
    expect(restored.read(imageViewHistoryProvider(scope)), ['older', 'new']);
    restored.dispose();
  });

  for (final width in [320.0, 800.0]) {
    testWidgets(
      'stack expands into independent rows with every anchor (width=$width)',
      (tester) async {
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final messages = [
          for (var index = 0; index < 5; index++) picture('$index'),
        ];
        final anchors = {
          for (final message in messages) message.id: GlobalKey(),
        };
        await tester.pumpWidget(
          MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: ImageMessageCollection(
                  messages: messages,
                  selected: messages.last,
                  album: false,
                  isMe: false,
                  borderRadius: BorderRadius.circular(18),
                  shadows: const [],
                  anchors: anchors,
                  metadata: const Positioned(
                    right: 7,
                    bottom: 6,
                    child: Text('12:00'),
                  ),
                  captionBuilder: (_) => null,
                  collapsedBuilder: (content) => content,
                  expandedBuilder: (collapseButton) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      collapseButton,
                      for (final message in messages)
                        SizedBox(
                          key: anchors[message.id],
                          width: 100,
                          height: 100,
                          child: Center(child: Text(message.id)),
                        ),
                    ],
                  ),
                  tileBuilder: (message, size, radius) => SizedBox(
                    key: ValueKey('test-tile:${message.id}'),
                    width: size.width,
                    height: size.height,
                    child: ColoredBox(
                      color: Colors.blue,
                      child: Center(child: Text(message.id)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.byKey(const ValueKey('image-stack')), findsOneWidget);
        expect(find.text('0'), findsNothing);
        expect(find.text('4'), findsOneWidget);
        final front = tester.getRect(find.byKey(const ValueKey('test-tile:4')));
        final frontCenter = tester.getCenter(
          find.byKey(const ValueKey('test-tile:4')),
        );
        final middleCenter = tester.getCenter(
          find.byKey(const ValueKey('test-tile:3')),
        );
        final backCenter = tester.getCenter(
          find.byKey(const ValueKey('test-tile:2')),
        );
        expect(middleCenter.dx, greaterThan(frontCenter.dx));
        expect(backCenter.dx, lessThan(frontCenter.dx));
        expect(middleCenter.dy, lessThan(frontCenter.dy));
        expect(backCenter.dy, lessThan(middleCenter.dy));
        expect(
          tester.getRect(find.text('12:00')).bottom,
          lessThanOrEqualTo(front.bottom),
        );
        expect(
          anchors.values.every((key) => key.currentContext != null),
          isTrue,
        );
        final count = find.byKey(const ValueKey('image-stack-count'));
        expect(tester.widget<Text>(count).data, '5');
        expect(front.contains(tester.getRect(count).center), isTrue);
        await tester.tap(find.byTooltip('展开全部5张图片'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('image-mosaic')), findsNothing);
        expect(find.byKey(const ValueKey('image-stack')), findsNothing);
        expect(tester.widget<Text>(count).data, '5');
        expect(find.text('收起 ·'), findsOneWidget);
        for (final message in messages) {
          expect(find.text(message.id), findsOneWidget);
        }
        for (var index = 1; index < messages.length; index++) {
          final previous = tester.getRect(
            find.byKey(anchors[messages[index - 1].id]!),
          );
          final current = tester.getRect(
            find.byKey(anchors[messages[index].id]!),
          );
          expect(previous.bottom, lessThanOrEqualTo(current.top));
        }
        await tester.tap(find.byTooltip('收起图片，共5张'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('image-stack')), findsOneWidget);
        expect(tester.widget<Text>(count).data, '5');
        expect(find.text('收起 ·'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final kind in ['album', 'legacy', 'independent']) {
    testWidgets(
      'image descriptions preserve album and independent presentation ($kind)',
      (tester) async {
        final api = _Images();
        RustLib.initMock(api: api);
        addTearDown(RustLib.dispose);
        final messages = kind == 'legacy'
            ? [
                picture('one', sharedCaption: 'Holiday'),
                picture('two', sharedCaption: 'Holiday'),
                picture('three', sharedCaption: 'Holiday', caption: 'Holiday'),
              ]
            : kind == 'album'
            ? [
                picture('one'),
                picture('two', root: 'one'),
                picture('three', root: 'one', caption: 'Holiday'),
              ]
            : [
                picture('one', caption: 'First description'),
                picture('two', caption: 'Second description'),
                picture('three', caption: 'Third description'),
              ];
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              activeUserIdProvider.overrideWith(() => MutableState('alice')),
            ],
            child: MaterialApp(
              theme: neuTestTheme(),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: MessageGroupWidget(
                    group: MessageGroup(
                      senderId: 'alice',
                      senderName: 'Alice',
                      isMe: false,
                      messages: messages,
                    ),
                    roomId: 'room',
                    membersById: const {},
                    messageIndex: {
                      for (final message in messages) message.id: message,
                    },
                    messageAnchorKeys: {
                      for (final message in messages) message.id: GlobalKey(),
                    },
                    showAvatar: false,
                  ),
                ),
              ),
            ),
          ),
        );
        expect(
          find.byKey(const ValueKey('image-mosaic')),
          kind == 'independent' ? findsNothing : findsOneWidget,
        );
        expect(find.byKey(const ValueKey('image-stack')), findsNothing);
        expect(find.byKey(const ValueKey('image-stack-count')), findsNothing);
        expect(
          find.byKey(const ValueKey('image-caption')),
          findsNWidgets(kind == 'independent' ? 3 : 1),
        );
        for (final message in messages) {
          expect(
            find.byKey(ValueKey('image-bubble:${message.id}')),
            findsOneWidget,
          );
          if (kind == 'independent') {
            final bubble = tester.widget<ImageMessageBubble>(
              find.byKey(ValueKey('image-bubble:${message.id}')),
            );
            expect(bubble.caption, message.caption);
            expect(bubble.displaySize, isNull);
          }
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'expanding a stack restores ordinary independent image messages',
    (tester) async {
      final api = _Images();
      RustLib.initMock(api: api);
      addTearDown(RustLib.dispose);
      final messages = [
        picture('one', time: 1000, caption: 'Shared description'),
        picture(
          'two',
          time: 2000,
          caption: 'Shared description',
          reactions: [
            const rust.Reaction(key: '👍', senders: ['bob']),
          ],
        ),
        picture('three', time: 3000, caption: 'Shared description'),
      ];
      final anchors = {for (final message in messages) message.id: GlobalKey()};
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeUserIdProvider.overrideWith(() => MutableState('alice')),
          ],
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: MessageGroupWidget(
                  group: MessageGroup(
                    senderId: 'alice',
                    senderName: 'Alice',
                    isMe: false,
                    messages: messages,
                  ),
                  roomId: 'room',
                  messageIndex: {
                    for (final message in messages) message.id: message,
                  },
                  messageAnchorKeys: anchors,
                  showAvatar: false,
                ),
              ),
            ),
          ),
        ),
      );
      final foldedImage = tester.widget<ImageMessageBubble>(
        find.byKey(const ValueKey('image-bubble:three')),
      );
      expect(foldedImage.borderRadius!.bottomLeft, Radius.zero);
      expect(foldedImage.borderRadius!.bottomRight, Radius.zero);
      final photoRect = tester.getRect(
        find.byKey(const ValueKey('image-bubble:three')),
      );
      final captionRect = tester.getRect(
        find.byKey(const ValueKey('image-caption')),
      );
      final cardRect = tester.getRect(
        find.byKey(const ValueKey('image-stack-card:three')),
      );
      expect(captionRect.top, closeTo(photoRect.bottom, .001));
      expect(captionRect.left, closeTo(photoRect.left, .001));
      expect(captionRect.right, closeTo(photoRect.right, .001));
      expect(cardRect.top, closeTo(photoRect.top, .001));
      expect(cardRect.bottom, closeTo(captionRect.bottom, .001));
      await tester.tap(find.byTooltip('展开全部3张图片'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('image-mosaic')), findsNothing);
      expect(find.byKey(const ValueKey('image-stack')), findsNothing);
      expect(find.byKey(const ValueKey('image-caption')), findsNWidgets(3));
      expect(find.byKey(const ValueKey('two:👍')), findsOneWidget);
      for (final message in messages) {
        final bubble = tester.widget<ImageMessageBubble>(
          find.byKey(ValueKey('image-bubble:${message.id}')),
        );
        expect(bubble.displaySize, isNull);
        expect(bubble.caption, message.caption);
        expect(
          find.byKey(ValueKey('message-metadata:${message.id}')),
          findsOneWidget,
        );
        expect(anchors[message.id]!.currentContext, isNotNull);
      }
      final first = tester.getRect(
        find.byKey(const ValueKey('image-bubble:one')),
      );
      final second = tester.getRect(
        find.byKey(const ValueKey('image-bubble:two')),
      );
      final third = tester.getRect(
        find.byKey(const ValueKey('image-bubble:three')),
      );
      expect(first.bottom, lessThanOrEqualTo(second.top));
      expect(second.bottom, lessThanOrEqualTo(third.top));
      await tester.tap(find.byTooltip('收起图片，共3张'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('image-stack')), findsOneWidget);
      expect(find.byKey(const ValueKey('image-caption')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a spoiler is not fetched until it is explicitly revealed', (
    tester,
  ) async {
    final api = _Images();
    RustLib.initMock(api: api);
    addTearDown(RustLib.dispose);
    final message = picture('hidden', spoiler: true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeUserIdProvider.overrideWith(() => MutableState('alice')),
        ],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: Scaffold(
            body: ImageMessageBubble(
              message: message,
              roomId: 'room',
              imageUrl: message.imageUrl,
              imageWidth: 1200,
              imageHeight: 800,
              isMe: false,
              heroTag: 'hidden',
              metadata: const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('spoiler-image-cover')), findsOneWidget);
    expect(api.resolved, isEmpty);
    await tester.tap(find.byKey(const ValueKey('spoiler-image-cover')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('spoiler-image-cover')), findsNothing);
    expect(api.resolved, ['mxc://example.org/hidden']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'message grouping uses the latest viewed image as the stack front',
    (tester) async {
      final api = _Images();
      RustLib.initMock(api: api);
      addTearDown(RustLib.dispose);
      final messages = [picture('one'), picture('two'), picture('three')];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeUserIdProvider.overrideWith(() => MutableState('alice')),
          ],
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: MessageGroupWidget(
                group: MessageGroup(
                  senderId: 'alice',
                  senderName: 'Alice',
                  isMe: false,
                  messages: messages,
                ),
                roomId: 'room',
                messageIndex: {
                  for (final message in messages) message.id: message,
                },
                showAvatar: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        tester
            .widget<ImageMessageCollection>(find.byType(ImageMessageCollection))
            .selected
            .id,
        'three',
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MessageGroupWidget)),
      );
      await tester.runAsync(
        () => container
            .read(
              imageViewHistoryProvider((account: 'alice', room: 'room'))
                  .notifier,
            )
            .viewed('one'),
      );
      await tester.pump();
      expect(
        tester
            .widget<ImageMessageCollection>(find.byType(ImageMessageCollection))
            .selected
            .id,
        'one',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
