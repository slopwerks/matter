import 'package:material_ui/material_ui.dart';

/// Keep the app's palette while using the editor's default component styles.
ThemeData buildMaterialImageEditorTheme(ThemeData theme) => ThemeData(
  useMaterial3: true,
  brightness: theme.brightness,
  scaffoldBackgroundColor: theme.scaffoldBackgroundColor,
  colorScheme: theme.colorScheme,
);
