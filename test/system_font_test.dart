import 'package:flutter_test/flutter_test.dart';
import 'package:matter/theme/image_editor_theme.dart';
import 'package:matter/theme/system_font.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('android text styles use the generic system family', () {
    final applied = applySystemFont(ThemeData(), kSystemFontFamily);

    expect(applied.textTheme.bodyMedium?.fontFamily, 'sans-serif');
    expect(applied.textTheme.headlineLarge?.fontFamily, 'sans-serif');
    expect(applied.primaryTextTheme.bodyMedium?.fontFamily, 'sans-serif');
  });

  test('a null family keeps the theme font', () {
    final applied = applySystemFont(ThemeData(), null);

    expect(applied.textTheme.bodyMedium?.fontFamily, isNot(kSystemFontFamily));
  });

  test('a picked font replaces the system family everywhere', () {
    final applied = applySystemFont(ThemeData(), 'MatterCustomFont');

    expect(applied.textTheme.bodyMedium?.fontFamily, 'MatterCustomFont');
    expect(applied.textTheme.headlineLarge?.fontFamily, 'MatterCustomFont');
    expect(applied.primaryTextTheme.bodyMedium?.fontFamily, 'MatterCustomFont');
  });

  test('the image editor keeps the app font', () {
    final app = applySystemFont(ThemeData(), 'MatterCustomFont');

    final editor = buildMaterialImageEditorTheme(app);

    expect(editor.textTheme.bodyMedium?.fontFamily, 'MatterCustomFont');
    expect(editor.primaryTextTheme.bodyMedium?.fontFamily, 'MatterCustomFont');
  });
}
