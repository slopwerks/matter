import 'package:material_ui/material_ui.dart';

/// Generic Android family: the platform resolves it through
/// /system/etc/fonts.xml, so the device font (including vendor theme fonts)
/// is used instead of whatever Flutter would otherwise pick.
const String kSystemFontFamily = 'sans-serif';

/// Applies [family] to every text style. A null family keeps the theme's own
/// font, which is what every platform except Android already wants.
///
/// [fallback] is tried before the platform fallback, which is how a serif pick
/// keeps Chinese serif: the named Android families ship Latin glyphs only.
ThemeData applySystemFont(
  ThemeData theme,
  String? family, {
  List<String>? fallback,
}) {
  if (family == null) return theme;
  return theme.copyWith(
    textTheme: theme.textTheme.apply(
      fontFamily: family,
      fontFamilyFallback: fallback,
    ),
    primaryTextTheme: theme.primaryTextTheme.apply(
      fontFamily: family,
      fontFamilyFallback: fallback,
    ),
  );
}
