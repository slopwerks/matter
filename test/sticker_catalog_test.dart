import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/sticker_catalog.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;

void main() {
  group('StickerItem', () {
    test('aspect ratio uses width over height when available', () {
      const item = StickerItem(
        id: 's1',
        label: 'sticker',
        body: 'sticker',
        width: 200,
        height: 100,
      );
      expect(item.aspectRatio, 2.0);
    });

    test('aspect ratio defaults to 1.0 when dimensions are missing', () {
      const item = StickerItem(id: 's1', label: 'sticker', body: 'sticker');
      expect(item.aspectRatio, 1.0);
    });

    test('aspect ratio defaults to 1.0 for zero dimensions', () {
      const item = StickerItem(
        id: 's1',
        label: 'sticker',
        body: 'sticker',
        width: 0,
        height: 100,
      );
      expect(item.aspectRatio, 1.0);
    });
  });

  group('stickerPacksFromRemote', () {
    test('maps remote packs with prefixed sticker ids', () {
      final remote = [
        rust.StickerPack(
          id: 'pack-1',
          roomId: '!here:e',
          stateKey: '',
          collected: true,
          title: 'Pack One',
          source: 'room',
          stickers: [
            rust.Sticker(
              id: 'st-1',
              shortcode: 'wave',
              body: 'wave',
              imageUrl: 'mxc://example.org/wave',
              width: 128,
              height: 128,
            ),
          ],
        ),
      ];

      final packs = stickerPacksFromRemote(remote);
      expect(packs.length, 1);
      expect(packs.single.title, 'Pack One');
      expect(packs.single.accent, '房');
      expect(packs.single.stickers.single.id, 'pack-1:st-1');
      expect(packs.single.stickers.single.aspectRatio, 1.0);
    });

    test('uses user accent for user packs', () {
      final remote = [
        rust.StickerPack(
          id: 'pack-2',
          roomId: '',
          stateKey: '',
          collected: false,
          title: 'My Pack',
          source: 'user',
          stickers: const [],
        ),
      ];

      final packs = stickerPacksFromRemote(remote);
      expect(packs.single.accent, '我');
    });

    test('falls back to default accent for unknown sources', () {
      final remote = [
        rust.StickerPack(
          id: 'pack-3',
          roomId: '',
          stateKey: '',
          collected: false,
          title: 'Other Pack',
          source: 'unknown',
          stickers: const [],
        ),
      ];

      final packs = stickerPacksFromRemote(remote);
      expect(packs.single.accent, '✦');
    });
  });
}
