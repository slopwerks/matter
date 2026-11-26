import 'package:material_ui/material_ui.dart';

/// Keeps the app's palette and typography while using the editor's default
/// component styles: these pages build their own [ThemeData], which would
/// otherwise reset the font chosen in the settings.
ThemeData materialEditorThemeFrom(
  ThemeData theme, {
  ColorScheme? colorScheme,
  Color? scaffoldBackgroundColor,
}) => ThemeData(
  useMaterial3: true,
  brightness: theme.brightness,
  scaffoldBackgroundColor:
      scaffoldBackgroundColor ?? theme.scaffoldBackgroundColor,
  colorScheme: colorScheme ?? theme.colorScheme,
  textTheme: theme.textTheme,
  primaryTextTheme: theme.primaryTextTheme,
);

ThemeData buildMaterialImageEditorTheme(ThemeData theme) =>
    materialEditorThemeFrom(theme);
