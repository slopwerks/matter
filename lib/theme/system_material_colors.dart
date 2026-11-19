import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart' as material_ui;

typedef MaterialColorSchemes = ({ColorScheme light, ColorScheme dark});

/// Android supplies a full palette; desktop platforms supply an accent color.
Future<MaterialColorSchemes?> loadSystemMaterialColors() async {
  try {
    final palette = await DynamicColorPlugin.getCorePalette();
    if (palette != null) {
      return (
        light: _toFlutterScheme(palette.toColorScheme()),
        dark: _toFlutterScheme(
          palette.toColorScheme(brightness: Brightness.dark),
        ),
      );
    }
  } on PlatformException {
    // A desktop accent may still be available if the palette request fails.
  }
  try {
    final accent = await DynamicColorPlugin.getAccentColor();
    if (accent != null) {
      return (
        light: ColorScheme.fromSeed(seedColor: accent),
        dark: ColorScheme.fromSeed(
          seedColor: accent,
          brightness: Brightness.dark,
        ),
      );
    }
  } on PlatformException {
    // Unsupported or unavailable system colors use the selected seed instead.
  }
  return null;
}

// dynamic_color 2 uses material_ui's separate ColorScheme type. Copy every
// modern role into the SDK scheme used by the application's Flutter widgets.
ColorScheme _toFlutterScheme(material_ui.ColorScheme source) => ColorScheme(
  brightness: source.brightness,
  primary: source.primary,
  onPrimary: source.onPrimary,
  primaryContainer: source.primaryContainer,
  onPrimaryContainer: source.onPrimaryContainer,
  primaryFixed: source.primaryFixed,
  primaryFixedDim: source.primaryFixedDim,
  onPrimaryFixed: source.onPrimaryFixed,
  onPrimaryFixedVariant: source.onPrimaryFixedVariant,
  secondary: source.secondary,
  onSecondary: source.onSecondary,
  secondaryContainer: source.secondaryContainer,
  onSecondaryContainer: source.onSecondaryContainer,
  secondaryFixed: source.secondaryFixed,
  secondaryFixedDim: source.secondaryFixedDim,
  onSecondaryFixed: source.onSecondaryFixed,
  onSecondaryFixedVariant: source.onSecondaryFixedVariant,
  tertiary: source.tertiary,
  onTertiary: source.onTertiary,
  tertiaryContainer: source.tertiaryContainer,
  onTertiaryContainer: source.onTertiaryContainer,
  tertiaryFixed: source.tertiaryFixed,
  tertiaryFixedDim: source.tertiaryFixedDim,
  onTertiaryFixed: source.onTertiaryFixed,
  onTertiaryFixedVariant: source.onTertiaryFixedVariant,
  error: source.error,
  onError: source.onError,
  errorContainer: source.errorContainer,
  onErrorContainer: source.onErrorContainer,
  surface: source.surface,
  onSurface: source.onSurface,
  onSurfaceVariant: source.onSurfaceVariant,
  surfaceDim: source.surfaceDim,
  surfaceBright: source.surfaceBright,
  surfaceContainerLowest: source.surfaceContainerLowest,
  surfaceContainerLow: source.surfaceContainerLow,
  surfaceContainer: source.surfaceContainer,
  surfaceContainerHigh: source.surfaceContainerHigh,
  surfaceContainerHighest: source.surfaceContainerHighest,
  outline: source.outline,
  outlineVariant: source.outlineVariant,
  shadow: source.shadow,
  scrim: source.scrim,
  inverseSurface: source.inverseSurface,
  onInverseSurface: source.onInverseSurface,
  inversePrimary: source.inversePrimary,
  surfaceTint: source.surfaceTint,
);
