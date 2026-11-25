import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../src/rust/api/matrix.dart' show StickerPackKey;

typedef DisabledStickerPackScope = ({String account, String roomId});

class DisabledStickerPacks extends AsyncNotifier<Set<StickerPackKey>> {
  DisabledStickerPacks(this.scope);
  final DisabledStickerPackScope scope;
  String get _key =>
      'chat_disabled_sticker_packs_v2:${jsonEncode([scope.account, scope.roomId])}';

  @override
  Future<Set<StickerPackKey>> build() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_key);
    if (saved != null) {
      return {
        for (final value in saved)
          if (jsonDecode(value) case [String room, String key])
            StickerPackKey(roomId: room, stateKey: key),
      };
    }
    final previous =
        prefs.getStringList('chat_disabled_sticker_packs:${scope.account}') ??
        [];
    return {
      for (final value in previous)
        if (value.startsWith('['))
          if (jsonDecode(value) case [String room, String key]
              when room == scope.roomId)
            StickerPackKey(roomId: room, stateKey: key),
    };
  }

  Future<void> setEnabled(StickerPackKey key, bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    final next = {...state.requireValue};
    if (enabled ? !next.remove(key) : !next.add(key)) return;
    state = AsyncData(next);
    await prefs.setStringList(_key, [
      for (final item in next) jsonEncode([item.roomId, item.stateKey]),
    ]);
  }
}

final disabledStickerPacksProvider =
    AsyncNotifierProvider.family<
      DisabledStickerPacks,
      Set<StickerPackKey>,
      DisabledStickerPackScope
    >(DisabledStickerPacks.new);
