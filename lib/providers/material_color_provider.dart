import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/material_theme.dart';
import '../theme/system_material_colors.dart';

class MaterialColorSettings {
  const MaterialColorSettings({
    this.followSystem = true,
    this.seedColor = defaultMaterialSeedColor,
    this.lightBackground = MaterialBackground.tonal,
    this.darkBackground = MaterialBackground.tonal,
    this.colorStyle = DynamicSchemeVariant.tonalSpot,
    this.customColors = const [],
  });

  final bool followSystem;
  final Color seedColor;
  final MaterialBackground lightBackground;
  final MaterialBackground darkBackground;
  final DynamicSchemeVariant colorStyle;
  final List<Color> customColors;

  MaterialColorSettings copyWith({
    bool? followSystem,
    Color? seedColor,
    MaterialBackground? lightBackground,
    MaterialBackground? darkBackground,
    DynamicSchemeVariant? colorStyle,
    List<Color>? customColors,
  }) => MaterialColorSettings(
    followSystem: followSystem ?? this.followSystem,
    seedColor: seedColor ?? this.seedColor,
    lightBackground: lightBackground ?? this.lightBackground,
    darkBackground: darkBackground ?? this.darkBackground,
    colorStyle: colorStyle ?? this.colorStyle,
    customColors: customColors ?? this.customColors,
  );
}

class MaterialColorSettingsNotifier extends Notifier<MaterialColorSettings> {
  static const _prefsKey = 'material_color_settings';
  late Future<SharedPreferences> _prefs;
  late Future<void> _restored;

  @override
  MaterialColorSettings build() {
    _prefs = SharedPreferences.getInstance();
    _restored = _restore();
    return const MaterialColorSettings();
  }

  Future<void> _restore() async {
    final saved = (await _prefs).getString(_prefsKey);
    if (!ref.mounted || saved == null) return;
    final data = jsonDecode(saved) as Map<String, dynamic>;
    MaterialBackground background(String key) =>
        MaterialBackground.values.firstWhere(
          (value) => value.name == data[key],
          orElse: () => MaterialBackground.tonal,
        );
    DynamicSchemeVariant variant(String key) =>
        DynamicSchemeVariant.values.firstWhere(
          (value) => value.name == data[key],
          orElse: () => DynamicSchemeVariant.tonalSpot,
        );
    final rawCustom = data['customColors'] as List<dynamic>? ?? [];
    final customColors = rawCustom
        .whereType<int>()
        .map(Color.new)
        .toList(growable: false);

    state = MaterialColorSettings(
      followSystem: data['followSystem'] as bool? ?? true,
      seedColor: Color(
        data['seedColor'] as int? ?? defaultMaterialSeedColor.toARGB32(),
      ),
      lightBackground: background('lightBackground'),
      darkBackground: background('darkBackground'),
      colorStyle: variant('colorStyle'),
      customColors: customColors,
    );
  }

  Future<void> setFollowSystem(bool value) async {
    await _restored;
    if (!ref.mounted) return;
    if (value) ref.invalidate(systemMaterialColorsProvider);
    state = state.copyWith(followSystem: value);
    await _persist();
  }

  Future<void> setSeedColor(Color color) async {
    await _restored;
    if (!ref.mounted) return;
    state = state.copyWith(followSystem: false, seedColor: color);
    await _persist();
  }

  Future<void> setColorStyle(DynamicSchemeVariant style) async {
    await _restored;
    if (!ref.mounted) return;
    state = state.copyWith(colorStyle: style);
    await _persist();
  }

  Future<void> addCustomColor(Color color) async {
    await _restored;
    if (!ref.mounted) return;
    final updated = [
      color,
      ...state.customColors.where((c) => c.toARGB32() != color.toARGB32()),
    ];
    state = state.copyWith(
      followSystem: false,
      seedColor: color,
      customColors: updated,
    );
    await _persist();
  }

  Future<void> removeCustomColor(Color color) async {
    await _restored;
    if (!ref.mounted) return;
    final updated = state.customColors
        .where((c) => c.toARGB32() != color.toARGB32())
        .toList(growable: false);
    final nextSeed = state.seedColor.toARGB32() == color.toARGB32()
        ? defaultMaterialSeedColor
        : state.seedColor;
    state = state.copyWith(seedColor: nextSeed, customColors: updated);
    await _persist();
  }

  Future<void> setBackground(
    Brightness brightness,
    MaterialBackground background,
  ) async {
    await _restored;
    if (!ref.mounted) return;
    state = brightness == Brightness.light
        ? state.copyWith(lightBackground: background)
        : state.copyWith(darkBackground: background);
    await _persist();
  }

  Future<void> _persist() async {
    final data = jsonEncode({
      'followSystem': state.followSystem,
      'seedColor': state.seedColor.toARGB32(),
      'lightBackground': state.lightBackground.name,
      'darkBackground': state.darkBackground.name,
      'colorStyle': state.colorStyle.name,
      'customColors': state.customColors.map((c) => c.toARGB32()).toList(),
    });
    await (await _prefs).setString(_prefsKey, data);
  }
}

final materialColorSettingsProvider =
    NotifierProvider<MaterialColorSettingsNotifier, MaterialColorSettings>(
      MaterialColorSettingsNotifier.new,
    );

final systemMaterialColorsProvider = FutureProvider<MaterialColorSchemes?>(
  (ref) => loadSystemMaterialColors(),
);

final materialBaseColorSchemesProvider = Provider<MaterialColorSchemes>((ref) {
  final settings = ref.watch(materialColorSettingsProvider);
  final system = settings.followSystem
      ? ref.watch(systemMaterialColorsProvider).asData?.value
      : null;
  return (
    light:
        system?.light ??
        ColorScheme.fromSeed(
          seedColor: settings.seedColor,
          dynamicSchemeVariant: settings.colorStyle,
        ),
    dark:
        system?.dark ??
        ColorScheme.fromSeed(
          seedColor: settings.seedColor,
          brightness: Brightness.dark,
          dynamicSchemeVariant: settings.colorStyle,
        ),
  );
});

final materialColorSchemesProvider = Provider<MaterialColorSchemes>((ref) {
  final settings = ref.watch(materialColorSettingsProvider);
  final base = ref.watch(materialBaseColorSchemesProvider);
  return (
    light: applyMaterialBackground(base.light, settings.lightBackground),
    dark: applyMaterialBackground(base.dark, settings.darkBackground),
  );
});
