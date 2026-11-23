import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ThemeFamily {
  material('Material'),
  neu('新拟物');

  const ThemeFamily(this.label);
  final String label;
}

extension ThemeModeLabel on ThemeMode {
  String get label => switch (this) {
    ThemeMode.system => '跟随系统',
    ThemeMode.light => '浅色',
    ThemeMode.dark => '深色',
  };
}

typedef AppThemeStyle = ({ThemeFamily family, ThemeMode themeMode});

extension AppThemeStyleProperties on AppThemeStyle {
  bool get isMaterial => family == ThemeFamily.material;
  // Keep the on-disk format used by existing installations.
  String get name =>
      '${family.name}${themeMode.name[0].toUpperCase()}${themeMode.name.substring(1)}';
}

class AppThemeStyleNotifier extends Notifier<AppThemeStyle> {
  static const _prefsKey = 'app_theme_style';
  late Future<void> _ready;

  @override
  AppThemeStyle build() {
    _ready = _restore();
    return (family: ThemeFamily.neu, themeMode: ThemeMode.system);
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    if (!ref.mounted || saved == null) return;
    for (final family in ThemeFamily.values) {
      for (final mode in ThemeMode.values) {
        final style = (family: family, themeMode: mode);
        if (style.name == saved) {
          state = style;
          return;
        }
      }
    }
  }

  Future<void> update({ThemeFamily? family, ThemeMode? mode}) async {
    await _ready;
    if (!ref.mounted) return;
    final next = (
      family: family ?? state.family,
      themeMode: mode ?? state.themeMode,
    );
    if (next == state) return;
    state = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, next.name);
  }
}

final appThemeStyleProvider =
    NotifierProvider<AppThemeStyleNotifier, AppThemeStyle>(
      AppThemeStyleNotifier.new,
    );
