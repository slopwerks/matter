import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:matter/pages/chat/blurhash_codec.dart';
import 'package:matter/pages/chat/image_message_runs.dart';
import 'package:matter/pages/chat/image_mosaic_layout.dart';
import 'package:matter/pages/chat/image_stack_layout.dart';
import 'package:matter/providers/image_view_history.dart';
import 'package:matter/providers/message_cache_persistence.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:shared_preferences/shared_preferences.dart';

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

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
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

  test(
    'downward stack layout anchors the front card at top-left without tilt',
    () {
      final layout = imageStackLayout(3, 520);
      expect(layout.size.width, closeTo(270.0, .000001));
      expect(layout.size.height, closeTo(196.0, .000001));
      expect(layout.layers.first.rect.left, closeTo(0.0, .000001));
      expect(layout.layers.first.rect.top, closeTo(0.0, .000001));
      expect(layout.layers.first.rect.size, const Size(270, 180));
      expect(layout.layers[1].rotation, 0);
      expect(layout.layers[2].rotation, 0);
      expect(layout.layers[1].rect.bottom, closeTo(188.0, .000001));
      expect(layout.layers[2].rect.bottom, closeTo(196.0, .000001));
      expect(layout.layers[1].rect.width, closeTo(270 * .94, .000001));
      expect(layout.layers[2].rect.width, closeTo(270 * .94 * .94, .000001));
      expect(layout.layers.map((layer) => layer.opacity), [1, .92, .92 * .92]);
    },
  );

  test(
    'the entire downward stack fits narrow widths and scales as one unit',
    () {
      for (final width in [180.0, 240.0, 320.0, 520.0]) {
        for (final count in [2, 3, 8]) {
          final layout = imageStackLayout(count, width);
          expect(layout.layers.length, math.min(count, 3));
          expect(layout.size.width, lessThanOrEqualTo(width + .000001));
          expect(layout.layers.first.rect.left, closeTo(0.0, .000001));
          expect(layout.layers.first.rect.top, closeTo(0.0, .000001));
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
}
