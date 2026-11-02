import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ComposerEnterShortcut { enter, shiftEnter, altEnter }

enum ComposerEnterAction { send, newline }

@immutable
class ComposerKeyboardSettings {
  final ComposerEnterAction enter;
  final ComposerEnterAction shiftEnter;
  final ComposerEnterAction altEnter;

  const ComposerKeyboardSettings({
    this.enter = ComposerEnterAction.send,
    this.shiftEnter = ComposerEnterAction.newline,
    this.altEnter = ComposerEnterAction.send,
  });

  ComposerEnterAction actionFor(ComposerEnterShortcut shortcut) =>
      switch (shortcut) {
        ComposerEnterShortcut.enter => enter,
        ComposerEnterShortcut.shiftEnter => shiftEnter,
        ComposerEnterShortcut.altEnter => altEnter,
      };

  ComposerKeyboardSettings withAction(
    ComposerEnterShortcut shortcut,
    ComposerEnterAction action,
  ) => ComposerKeyboardSettings(
    enter: shortcut == ComposerEnterShortcut.enter ? action : enter,
    shiftEnter: shortcut == ComposerEnterShortcut.shiftEnter
        ? action
        : shiftEnter,
    altEnter: shortcut == ComposerEnterShortcut.altEnter ? action : altEnter,
  );
}

class ComposerKeyboardSettingsNotifier
    extends Notifier<ComposerKeyboardSettings> {
  final _edited = <ComposerEnterShortcut>{};
  late Future<SharedPreferences> _preferences;

  @override
  ComposerKeyboardSettings build() {
    _preferences = SharedPreferences.getInstance();
    _restore();
    return const ComposerKeyboardSettings();
  }

  String _key(ComposerEnterShortcut shortcut) =>
      'composer_keyboard_${shortcut.name}';

  Future<void> _restore() async {
    final prefs = await _preferences;
    if (!ref.mounted) return;
    var restored = state;
    for (final shortcut in ComposerEnterShortcut.values) {
      if (_edited.contains(shortcut)) continue;
      final saved = prefs.getString(_key(shortcut));
      final action = ComposerEnterAction.values.asNameMap()[saved];
      if (action != null) restored = restored.withAction(shortcut, action);
    }
    state = restored;
  }

  Future<void> setAction(
    ComposerEnterShortcut shortcut,
    ComposerEnterAction action,
  ) async {
    _edited.add(shortcut);
    state = state.withAction(shortcut, action);
    final prefs = await _preferences;
    await prefs.setString(_key(shortcut), action.name);
  }
}

final composerKeyboardSettingsProvider =
    NotifierProvider<
      ComposerKeyboardSettingsNotifier,
      ComposerKeyboardSettings
    >(ComposerKeyboardSettingsNotifier.new);
