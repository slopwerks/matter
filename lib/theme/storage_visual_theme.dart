import 'package:flutter/material.dart';

import '../features/storage/storage_appearance.dart';

/// Shared chart and media-preview roles. Both app skins supply their scheme
/// and preview shape; storage widgets never choose a fixed light/dark palette.
class StorageVisualTheme extends ThemeExtension<StorageVisualTheme> {
  final ColorScheme scheme;
  final ShapeBorder previewShape;
  const StorageVisualTheme({required this.scheme, required this.previewShape});

  static StorageVisualTheme of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<StorageVisualTheme>() ??
        StorageVisualTheme(
          scheme: theme.colorScheme,
          previewShape: theme.cardTheme.shape ?? const RoundedRectangleBorder(),
        );
  }

  List<Color> get heroColors => [
    scheme.primaryContainer,
    scheme.tertiaryContainer,
  ];
  Color get heroInk => scheme.onPrimaryContainer;
  Color get chartTrack => scheme.surfaceContainerHighest;
  Color color(int index, StoragePalette palette) {
    final seed = HSLColor.fromColor(scheme.primary);
    final saturation = switch (palette) {
      StoragePalette.theme => .62,
      StoragePalette.soft => .38,
      StoragePalette.vivid => .85,
    };
    final lightness = scheme.brightness == Brightness.dark ? .70 : .40;
    return HSLColor.fromAHSL(
      1,
      (seed.hue + index * 137.508) % 360,
      saturation,
      lightness,
    ).toColor();
  }

  Color tint(int index, StoragePalette palette) => Color.alphaBlend(
    color(index, palette).withValues(alpha: .12),
    scheme.surface,
  );
  TextStyle? secondaryLabel(ThemeData theme) =>
      theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
  TextStyle? heroNumber(ThemeData theme) =>
      theme.textTheme.displaySmall?.copyWith(color: heroInk);
  TextStyle? heroMetric(ThemeData theme) =>
      theme.textTheme.titleLarge?.copyWith(color: heroInk);
  TextStyle? heroLabel(ThemeData theme) =>
      theme.textTheme.labelLarge?.copyWith(color: heroInk);
  TextStyle? categoryTitle(
    ThemeData theme,
    int index,
    StoragePalette palette,
  ) => theme.textTheme.titleSmall?.copyWith(color: color(index, palette));
  @override
  StorageVisualTheme copyWith({
    ColorScheme? scheme,
    ShapeBorder? previewShape,
  }) => StorageVisualTheme(
    scheme: scheme ?? this.scheme,
    previewShape: previewShape ?? this.previewShape,
  );
  @override
  StorageVisualTheme lerp(covariant StorageVisualTheme? other, double t) =>
      other == null
      ? this
      : StorageVisualTheme(
          scheme: ColorScheme.lerp(scheme, other.scheme, t),
          previewShape: ShapeBorder.lerp(previewShape, other.previewShape, t)!,
        );
}
