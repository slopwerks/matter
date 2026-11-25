import '../../src/rust/api/matrix.dart' as rust;

class StickerPack {
  final String id;
  final String title;
  final String accent;
  final String source;
  final String? avatarUrl;
  final List<StickerItem> stickers;

  const StickerPack({
    required this.id,
    required this.title,
    required this.accent,
    required this.source,
    this.avatarUrl,
    required this.stickers,
  });
}

class StickerItem {
  final String id;
  final String label;
  final String body;
  final String? shortcode;
  final String? imageUrl;
  final String? thumbnailUrl;
  final String? mimeType;
  final int? width;
  final int? height;

  const StickerItem({
    required this.id,
    required this.label,
    required this.body,
    this.shortcode,
    this.imageUrl,
    this.thumbnailUrl,
    this.mimeType,
    this.width,
    this.height,
  });

  double get aspectRatio {
    final w = width;
    final h = height;
    if (w != null && h != null && w > 0 && h > 0) {
      return w / h;
    }
    return 1.0;
  }
}

List<StickerPack> stickerPacksFromRemote(List<rust.StickerPack> packs) {
  return packs.map((pack) {
    final accent = switch (pack.source) {
      'room' => '房',
      'user' => '我',
      _ => '✦',
    };
    return StickerPack(
      id: pack.id,
      title: pack.title,
      accent: accent,
      source: pack.source,
      avatarUrl: pack.avatarUrl,
      stickers: pack.stickers.map((sticker) {
        return StickerItem(
          id: '${pack.id}:${sticker.id}',
          label: sticker.body,
          body: sticker.body,
          shortcode: sticker.shortcode,
          imageUrl: sticker.imageUrl,
          thumbnailUrl: sticker.thumbnailUrl,
          mimeType: sticker.mimeType,
          width: sticker.width,
          height: sticker.height,
        );
      }).toList(),
    );
  }).toList();
}

/// Search the metadata carried by Matrix image packs, including image-map keys.
List<StickerPack> searchStickerPacks(List<StickerPack> packs, String query) {
  final text = query.trim().toLowerCase();
  if (text.isEmpty) return packs;
  final shortcode =
      text.startsWith(':') && text.endsWith(':') && text.length > 2
      ? text.substring(1, text.length - 1)
      : text;
  final matches = <StickerPack>[];
  for (final pack in packs) {
    if (pack.title.toLowerCase().contains(text) ||
        pack.id.toLowerCase().contains(text)) {
      matches.add(pack);
      continue;
    }
    final stickers = pack.stickers
        .where(
          (sticker) =>
              (sticker.shortcode?.toLowerCase().contains(shortcode) ?? false) ||
              sticker.body.toLowerCase().contains(text),
        )
        .toList();
    if (stickers.isNotEmpty) {
      matches.add(
        StickerPack(
          id: pack.id,
          title: pack.title,
          accent: pack.accent,
          source: pack.source,
          avatarUrl: pack.avatarUrl,
          stickers: stickers,
        ),
      );
    }
  }
  return matches;
}
