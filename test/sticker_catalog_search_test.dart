import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/sticker_catalog.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;

void main() {
  final packs = stickerPacksFromRemote([
    const rust.StickerPack(
      id: 'room:!cats:example.org:animals',
      title: 'Cats',
      source: 'room',
      stickers: [
        rust.Sticker(
          id: 'wave',
          shortcode: 'cat_wave',
          body: '挥手',
          imageUrl: 'mxc://example.org/wave',
        ),
        rust.Sticker(
          id: 'sleep',
          shortcode: 'cat_sleep',
          body: 'Sleepy cat',
          imageUrl: 'mxc://example.org/sleep',
        ),
      ],
    ),
  ]);
  test('Matrix image-map shortcode survives conversion and is searchable', () {
    expect(packs.first.stickers.first.shortcode, 'cat_wave');
    expect(
      searchStickerPacks(packs, ':CAT_WAVE:').single.stickers.single.body,
      '挥手',
    );
    expect(
      searchStickerPacks(packs, '挥手').single.stickers.single.shortcode,
      'cat_wave',
    );
    expect(
      searchStickerPacks(packs, 'sleepy').single.stickers.single.shortcode,
      'cat_sleep',
    );
  });
  test(
    'pack title and scoped ID select whole packs; unknown queries are empty',
    () {
      expect(searchStickerPacks(packs, 'CATS').single.stickers.length, 2);
      expect(
        searchStickerPacks(packs, '!cats:example.org').single.stickers.length,
        2,
      );
      expect(searchStickerPacks(packs, 'unknown'), isEmpty);
      expect(searchStickerPacks(packs, '  '), same(packs));
    },
  );
}
