import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主题风格：经典深色（既有配色）或新拟物明/暗/跟随系统。
enum AppThemeStyle { classic, neuLight, neuDark, neuSystem }

class AppThemeStyleNotifier extends Notifier<AppThemeStyle> {
  static const _prefsKey = 'app_theme_style';

  @override
  AppThemeStyle build() {
    _restore();
    return AppThemeStyle.neuSystem;
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    for (final style in AppThemeStyle.values) {
      if (style.name == saved && style != state) {
        state = style;
        return;
      }
    }
  }

  Future<void> setStyle(AppThemeStyle style) async {
    if (style == state) return;
    state = style;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, style.name);
  }
}

final appThemeStyleProvider =
    NotifierProvider<AppThemeStyleNotifier, AppThemeStyle>(
      AppThemeStyleNotifier.new,
    );
