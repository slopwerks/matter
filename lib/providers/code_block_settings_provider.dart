import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

@immutable
class CodeBlockSettings {
  final String darkTheme;
  final String lightTheme;
  final double opacity;
  final bool showLineNumbers;

  const CodeBlockSettings({
    this.darkTheme = 'atom-one-dark',
    this.lightTheme = 'atom-one-light',
    this.opacity = 1.0,
    this.showLineNumbers = false,
  });

  CodeBlockSettings copyWith({
    String? darkTheme,
    String? lightTheme,
    double? opacity,
    bool? showLineNumbers,
  }) {
    return CodeBlockSettings(
      darkTheme: darkTheme ?? this.darkTheme,
      lightTheme: lightTheme ?? this.lightTheme,
      opacity: (opacity ?? this.opacity).clamp(0.1, 1.0),
      showLineNumbers: showLineNumbers ?? this.showLineNumbers,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CodeBlockSettings &&
        other.darkTheme == darkTheme &&
        other.lightTheme == lightTheme &&
        other.opacity == opacity &&
        other.showLineNumbers == showLineNumbers;
  }

  @override
  int get hashCode =>
      Object.hash(darkTheme, lightTheme, opacity, showLineNumbers);
}

class CodeBlockSettingsNotifier extends Notifier<CodeBlockSettings> {
  static const _keyDarkTheme = 'code_block_dark_theme';
  static const _keyLightTheme = 'code_block_light_theme';
  static const _keyOpacity = 'code_block_opacity';
  static const _keyLineNumbers = 'code_block_line_numbers';

  @override
  CodeBlockSettings build() {
    _restore();
    return const CodeBlockSettings();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final darkTheme = prefs.getString(_keyDarkTheme) ?? 'atom-one-dark';
    final lightTheme = prefs.getString(_keyLightTheme) ?? 'atom-one-light';
    final opacity = prefs.getDouble(_keyOpacity) ?? 1.0;
    final showLineNumbers = prefs.getBool(_keyLineNumbers) ?? false;

    state = CodeBlockSettings(
      darkTheme: darkTheme,
      lightTheme: lightTheme,
      opacity: opacity.clamp(0.1, 1.0),
      showLineNumbers: showLineNumbers,
    );
  }

  Future<void> setDarkTheme(String theme) async {
    state = state.copyWith(darkTheme: theme);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDarkTheme, theme);
  }

  Future<void> setLightTheme(String theme) async {
    state = state.copyWith(lightTheme: theme);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLightTheme, theme);
  }

  Future<void> setOpacity(double opacity) async {
    final clamped = opacity.clamp(0.1, 1.0);
    state = state.copyWith(opacity: clamped);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyOpacity, clamped);
  }

  Future<void> setShowLineNumbers(bool show) async {
    state = state.copyWith(showLineNumbers: show);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyLineNumbers, show);
  }
}

final codeBlockSettingsProvider =
    NotifierProvider<CodeBlockSettingsNotifier, CodeBlockSettings>(
      CodeBlockSettingsNotifier.new,
    );
