import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef DisabledStickerPackScope = ({String account});

/// Sticker packs the user switched off, kept per account in local storage.
///
/// A room pack normally shows up in the room that publishes it and Matrix has
/// no account-data slot for "enabled in its own room only", so the switch is a
/// purely local preference.
class DisabledStickerPacks extends Notifier<Set<String>> {
  DisabledStickerPacks(this.scope);
  final DisabledStickerPackScope scope;
  late Future<void> _restoring;
  String get _key => 'chat_disabled_sticker_packs:${scope.account}';

  @override
  Set<String> build() {
    _restoring = _restore();
    unawaited(_restoring);
    return const {};
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList(_key) ?? const <String>[];
      if (!ref.mounted || saved.isEmpty) return;
      state = {...state, ...saved};
    } catch (error) {
      debugPrint('restore disabled sticker packs failed: $error');
    }
  }

  Future<void> setEnabled(String packId, bool enabled) async {
    final next = {...state};
    if (enabled) {
      next.remove(packId);
    } else {
      next.add(packId);
    }
    if (next.length == state.length && next.containsAll(state)) return;
    state = next;
    try {
      await _restoring;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_key, next.toList()..sort());
    } catch (error) {
      debugPrint('persist disabled sticker packs failed: $error');
    }
  }
}

final disabledStickerPacksProvider =
    NotifierProvider.family<
      DisabledStickerPacks,
      Set<String>,
      DisabledStickerPackScope
    >(DisabledStickerPacks.new);
