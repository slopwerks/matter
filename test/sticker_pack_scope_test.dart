import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/sticker_catalog.dart';

StickerPack _pack(String roomId, String stateKey, {String source = 'room'}) =>
    StickerPack(
      id: 'opaque',
      roomId: roomId,
      stateKey: stateKey,
      collected: true,
      title: 'Pack',
      accent: '✦',
      source: source,
      stickers: const [],
    );

void main() {
  test('a pack from another room is removable', () {
    final scope = importedPackScope(
      _pack('!src:example.org', 'shared:cats'),
      roomId: '!here:example.org',
    );
    expect(scope, isNotNull);
    expect(scope!.roomId, '!src:example.org');
    expect(scope.stateKey, 'shared:cats');
    for (final key in ['', 'default', ' ']) {
      expect(
        importedPackScope(
          _pack('!src:example.org', key),
          roomId: '!here:example.org',
        )?.stateKey,
        key,
      );
    }
  });

  test('the pack of the open room stays put', () {
    expect(
      importedPackScope(
        _pack('!here:example.org', ''),
        roomId: '!here:example.org',
      ),
      isNull,
    );
  });

  test('non room packs are not removable this way', () {
    expect(
      importedPackScope(_pack('', 'mine', source: 'user'), roomId: '!a:b'),
      isNull,
    );
  });

  test('only the open room owns its pack', () {
    expect(
      ownsRoomPack(
        _pack('!here:example.org', 'default'),
        roomId: '!here:example.org',
      ),
      isTrue,
    );
    expect(
      ownsRoomPack(
        _pack('!src:example.org', 'shared'),
        roomId: '!here:example.org',
      ),
      isFalse,
    );
    expect(
      ownsRoomPack(
        _pack('', 'abc', source: 'user'),
        roomId: '!here:example.org',
      ),
      isFalse,
    );
  });
}
