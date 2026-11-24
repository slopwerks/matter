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

/// Room and state key of a sticker pack imported from another room, or null
/// when [pack] belongs to [roomId] itself (or is not a room pack) and so cannot
/// be dropped from the account.
/// True when [pack] is published by [roomId] itself, i.e. the pack a switch in
/// that room can only disable locally.
bool ownsRoomPack(StickerPack pack, {required String roomId}) {
  const prefix = 'room:';
  if (!pack.id.startsWith(prefix)) return false;
  final rest = pack.id.substring(prefix.length);
  final split = rest.lastIndexOf(':');
  if (split <= 0) return false;
  return rest.substring(0, split) == roomId;
}

({String roomId, String stateKey})? importedPackScope(
  StickerPack pack, {
  required String roomId,
}) {
  const prefix = 'room:';
  if (!pack.id.startsWith(prefix)) return null;
  final rest = pack.id.substring(prefix.length);
  final split = rest.lastIndexOf(':');
  if (split <= 0) return null;
  final packRoomId = rest.substring(0, split);
  if (packRoomId == roomId) return null;
  return (roomId: packRoomId, stateKey: rest.substring(split + 1));
}
