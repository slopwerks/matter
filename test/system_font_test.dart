import 'package:flutter_test/flutter_test.dart';
import 'package:matter/theme/image_editor_theme.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/theme/neu_theme.dart';
import 'package:matter/theme/system_font.dart';
import 'package:matter/theme/tokens/app_design_tokens.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('android text styles use the generic system family', () {
    final applied = applySystemFont(ThemeData(), kSystemFontFamily);

    expect(applied.textTheme.bodyMedium?.fontFamily, 'sans-serif');
    expect(applied.textTheme.headlineLarge?.fontFamily, 'sans-serif');
    expect(applied.primaryTextTheme.bodyMedium?.fontFamily, 'sans-serif');
  });

  test('a null family and null fallback keeps the theme font', () {
    final applied = applySystemFont(ThemeData(), null);

    expect(applied.textTheme.bodyMedium?.fontFamily, isNot(kSystemFontFamily));
  });

  test('a null family still applies fallback fonts when provided', () {
    final base = buildNeuTheme(NeuColors.light, Brightness.light);
    final applied = applySystemFont(
      base,
      null,
      fallback: const ['MatterFallbackFont', 'MatterSecondaryFallback'],
    );

    expect(applied.textTheme.bodyMedium?.fontFamilyFallback, [
      'MatterFallbackFont',
      'MatterSecondaryFallback',
    ]);
    final tokens = applied.extension<AppDesignTokens>()!;
    expect(tokens.typography.listTitle.fontFamilyFallback, [
      'MatterFallbackFont',
      'MatterSecondaryFallback',
    ]);
  });

  test('a picked font replaces the system family everywhere', () {
    final applied = applySystemFont(ThemeData(), 'MatterCustomFont');

    expect(applied.textTheme.bodyMedium?.fontFamily, 'MatterCustomFont');
    expect(applied.textTheme.headlineLarge?.fontFamily, 'MatterCustomFont');
    expect(applied.primaryTextTheme.bodyMedium?.fontFamily, 'MatterCustomFont');
  });

  test('neu theme applies font family, fallback and typography slots', () {
    final neu = buildNeuTheme(
      NeuColors.light,
      Brightness.light,
      fontFamily: 'MatterCustomFont',
      fontFamilyFallback: const ['MatterFallbackFont'],
      chatFontFamily: 'MatterChatFont',
      chatFontScale: 1.2,
      monospaceFontFamily: kBundledMonospaceFamily,
      monospaceFontFallback: const ['MatterCustomFont'],
      monoFontScale: 1.1,
    );

    expect(neu.textTheme.bodyMedium?.fontFamily, 'MatterCustomFont');
    expect(neu.textTheme.bodyMedium?.fontFamilyFallback, [
      'MatterFallbackFont',
    ]);
    final typo = neu.extension<AppDesignTokens>()!.typography;
    expect(typo.pageTitle.fontFamily, 'MatterCustomFont');
    expect(typo.listTitle.fontFamily, 'MatterCustomFont');
    expect(typo.sectionTitle.fontFamily, 'MatterCustomFont');
    expect(typo.chatBody.fontFamily, 'MatterChatFont');
    expect(typo.chatBody.fontSize, closeTo(15 * 1.2, 0.01));
    expect(typo.monospace.fontFamily, kBundledMonospaceFamily);
    expect(typo.monospace.fontFamilyFallback, ['MatterCustomFont']);
    expect(typo.monoScale, 1.1);
  });

  test('the image editor keeps the app font', () {
    final app = applySystemFont(ThemeData(), 'MatterCustomFont');

    final editor = buildMaterialImageEditorTheme(app);

    expect(editor.textTheme.bodyMedium?.fontFamily, 'MatterCustomFont');
    expect(editor.primaryTextTheme.bodyMedium?.fontFamily, 'MatterCustomFont');
  });
}
