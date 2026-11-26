import 'package:material_ui/material_ui.dart';

import 'tokens.dart';

/// Generic Android family: the platform resolves it through
/// /system/etc/fonts.xml, so the device font (including vendor theme fonts)
/// is used instead of whatever Flutter would otherwise pick.
const String kSystemFontFamily = 'sans-serif';

/// Generic platform monospace family.
const String kSystemMonospaceFamily = 'monospace';

/// Built-in monospace font bundled in pubspec.yaml (OFL-1.1).
const String kBundledMonospaceFamily = 'Ioskeley Mono';

/// Applies [family] and/or [fallback] to the theme's text styles and design
/// tokens. A null [family] and null [fallback] keeps the theme's own fonts.
///
/// [fallback] is tried before the platform fallback, which is how a serif pick
/// keeps Chinese serif: the named Android families ship Latin glyphs only.
ThemeData applySystemFont(
  ThemeData theme,
  String? family, {
  List<String>? fallback,
}) {
  if (family == null && fallback == null) return theme;
  final nextTextTheme = theme.textTheme.apply(
    fontFamily: family,
    fontFamilyFallback: fallback,
  );
  final nextPrimaryTextTheme = theme.primaryTextTheme.apply(
    fontFamily: family,
    fontFamilyFallback: fallback,
  );
  final existingTokens = theme.extension<AppDesignTokens>();
  if (existingTokens == null) {
    return theme.copyWith(
      textTheme: nextTextTheme,
      primaryTextTheme: nextPrimaryTextTheme,
    );
  }
  final currentTypography = existingTokens.typography;
  final nextTokens = existingTokens.copyWith(
    typography: currentTypography.copyWith(
      pageTitle: currentTypography.pageTitle.apply(
        fontFamily: family,
        fontFamilyFallback: fallback,
      ),
      listTitle: currentTypography.listTitle.apply(
        fontFamily: family,
        fontFamilyFallback: fallback,
      ),
      sectionTitle: currentTypography.sectionTitle.apply(
        fontFamily: family,
        fontFamilyFallback: fallback,
      ),
    ),
  );
  return theme.copyWith(
    textTheme: nextTextTheme,
    primaryTextTheme: nextPrimaryTextTheme,
    extensions: [
      for (final ext in theme.extensions.values)
        ext is AppDesignTokens ? nextTokens : ext,
    ],
  );
}
