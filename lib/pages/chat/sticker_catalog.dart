import '../../src/rust/api/matrix.dart' as rust;

class StickerPack {
  final String id;
  final String roomId;
  final String stateKey;
  final bool collected;
  final String title;
  final String accent;
  final String source;
  final String? avatarUrl;
  final List<StickerItem> stickers;

  const StickerPack({
    required this.id,
    required this.roomId,
    required this.stateKey,
    required this.collected,
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
  final String? imageUrl;
  final String? thumbnailUrl;
  final String? mimeType;
  final int? width;
  final int? height;

  const StickerItem({
    required this.id,
    required this.label,
    required this.body,
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
      roomId: pack.roomId,
      stateKey: pack.stateKey,
      collected: pack.collected,
      title: pack.title,
      accent: accent,
      source: pack.source,
      avatarUrl: pack.avatarUrl,
      stickers: pack.stickers.map((sticker) {
        return StickerItem(
          id: '${pack.id}:${sticker.id}',
          label: sticker.body,
          body: sticker.body,
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

bool ownsRoomPack(StickerPack pack, {required String roomId}) =>
    pack.source == 'room' && pack.roomId == roomId;

({String roomId, String stateKey})? importedPackScope(
  StickerPack pack, {
  required String roomId,
}) {
  if (!pack.collected || pack.source != 'room' || pack.roomId == roomId) {
    return null;
  }
  return (roomId: pack.roomId, stateKey: pack.stateKey);
}
