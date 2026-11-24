import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/sticker_catalog.dart';

StickerPack _pack(String id) => StickerPack(
  id: id,
  title: 'Pack',
  accent: '✦',
  source: 'room',
  stickers: const [],
);

void main() {
  test('a pack from another room is removable', () {
    final scope = importedPackScope(
      _pack('room:!src:example.org:shared'),
      roomId: '!here:example.org',
    );
    expect(scope, isNotNull);
    expect(scope!.roomId, '!src:example.org');
    expect(scope.stateKey, 'shared');
  });

  test('the pack of the open room stays put', () {
    expect(
      importedPackScope(
        _pack('room:!here:example.org:default'),
        roomId: '!here:example.org',
      ),
      isNull,
    );
  });

  test('non room packs are not removable this way', () {
    expect(
      importedPackScope(_pack('user:@bob:example.org:mine'), roomId: '!a:b'),
      isNull,
    );
  });

  test('only the open room owns its pack', () {
    expect(
      ownsRoomPack(
        _pack('room:!here:example.org:default'),
        roomId: '!here:example.org',
      ),
      isTrue,
    );
    expect(
      ownsRoomPack(
        _pack('room:!src:example.org:shared'),
        roomId: '!here:example.org',
      ),
      isFalse,
    );
    expect(
      ownsRoomPack(_pack('user:abc'), roomId: '!here:example.org'),
      isFalse,
    );
  });
}
