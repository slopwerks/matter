import 'package:flutter/material.dart';

const defaultMaterialSeedColor = Color(0xFF5B5BD6);

/// The prototype's brand palette; personal and system palettes keep M3's
/// generated roles instead of being recolored with the brand's surface tones.
ColorScheme materialColorScheme({
  Brightness brightness = Brightness.light,
  Color seedColor = defaultMaterialSeedColor,
  DynamicSchemeVariant dynamicSchemeVariant = DynamicSchemeVariant.tonalSpot,
}) {
  final generated = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
    dynamicSchemeVariant: dynamicSchemeVariant,
  );
  if (seedColor != defaultMaterialSeedColor ||
      dynamicSchemeVariant != DynamicSchemeVariant.tonalSpot) {
    return generated;
  }
  if (brightness == Brightness.dark) {
    return generated.copyWith(
      primary: const Color(0xFFC9C3FF),
      onPrimary: const Color(0xFF2B2660),
      primaryContainer: const Color(0xFF423C86),
      onPrimaryContainer: const Color(0xFFE4E0FF),
      surface: const Color(0xFF121116),
      surfaceContainerLowest: const Color(0xFF0E0D12),
      surfaceContainerLow: const Color(0xFF1A191F),
      surfaceContainer: const Color(0xFF211F29),
      surfaceContainerHigh: const Color(0xFF2B2833),
      surfaceContainerHighest: const Color(0xFF38343F),
      surfaceBright: const Color(0xFF38343F),
      surfaceDim: const Color(0xFF121116),
      onSurface: const Color(0xFFE8E1EF),
      onSurfaceVariant: const Color(0xFFCAC4D0),
    );
  }
  return generated.copyWith(
    primary: defaultMaterialSeedColor,
    onPrimary: Colors.white,
    primaryContainer: const Color(0xFFE4E0FF),
    onPrimaryContainer: const Color(0xFF17134B),
    surface: const Color(0xFFFBF8FF),
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: const Color(0xFFF3EFFA),
    surfaceContainer: const Color(0xFFECE7F5),
    surfaceContainerHigh: const Color(0xFFE5E0ED),
    surfaceContainerHighest: const Color(0xFFDCD6E6),
    surfaceBright: const Color(0xFFFBF8FF),
    surfaceDim: const Color(0xFFDCD6E6),
    onSurface: const Color(0xFF1B1B21),
    onSurfaceVariant: const Color(0xFF49454F),
  );
}
