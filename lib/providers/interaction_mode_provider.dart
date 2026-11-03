import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum InteractionMode { auto, touch, keyboardMouse }

extension InteractionModeLabel on InteractionMode {
  String get label => switch (this) {
    InteractionMode.auto => '自动',
    InteractionMode.touch => '触屏',
    InteractionMode.keyboardMouse => '键鼠',
  };

  bool usesKeyboardMouse(TargetPlatform platform) => switch (this) {
    InteractionMode.touch => false,
    InteractionMode.keyboardMouse => true,
    InteractionMode.auto => switch (platform) {
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => true,
      _ => false,
    },
  };
}

class InteractionModeNotifier extends Notifier<InteractionMode> {
  static const preferenceKey = 'interaction_mode';
  bool _edited = false;
  late Future<SharedPreferences> _preferences;

  @override
  InteractionMode build() {
    _preferences = SharedPreferences.getInstance();
    _restore();
    return InteractionMode.auto;
  }

  Future<void> _restore() async {
    final preferences = await _preferences;
    if (!ref.mounted || _edited) return;
    state =
        InteractionMode.values.asNameMap()[preferences.getString(
          preferenceKey,
        )] ??
        InteractionMode.auto;
  }

  Future<void> setMode(InteractionMode mode) async {
    _edited = true;
    state = mode;
    final preferences = await _preferences;
    await preferences.setString(preferenceKey, mode.name);
  }
}

final interactionModeProvider =
    NotifierProvider<InteractionModeNotifier, InteractionMode>(
      InteractionModeNotifier.new,
    );
