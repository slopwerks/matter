import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/fonts/system_font_catalog.dart';
import 'package:matter/providers/app_font_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('android falls back to the generic system family', () async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(appFontFamilyProvider), 'sans-serif');
    await Future<void>.delayed(Duration.zero);
    expect(container.read(appFontProvider), isNull);
  });

  test('desktop keeps the bundled font', () async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(appFontFamilyProvider), isNull);
  });

  test('a system family overrides the default', () async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(appFontProvider.notifier).selectSystemFamily('serif');

    expect(container.read(appFontFamilyProvider), 'serif');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('app_font_kind'), 'system');
    expect(prefs.getString('app_font_family'), 'serif');
  });

  test('resetting the choice goes back to the system font', () async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(appFontProvider.notifier).selectSystemFamily('serif');
    await container.read(appFontProvider.notifier).reset();

    expect(container.read(appFontFamilyProvider), 'sans-serif');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('app_font_kind'), isNull);
  });

  test('named families are read in order without duplicates', () async {
    final dir = await Directory.systemTemp.createTemp('fonts');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/fonts.xml');
    await file.writeAsString('''
<familyset version="23">
  <family name="sans-serif">
    <font weight="400">MiSansVF.ttf</font>
  </family>
  <family>
    <font weight="400">Fallback.ttf</font>
  </family>
  <family name="serif">
    <font weight="400">NotoSerif.ttf</font>
  </family>
  <family name="sans-serif">
    <font weight="700">MiSansBold.ttf</font>
  </family>
</familyset>
''');

    expect(await loadSystemFontFamilies(path: file.path), [
      'sans-serif',
      'serif',
    ]);
  });

  test('a missing font config yields no families', () async {
    expect(
      await loadSystemFontFamilies(path: '/nonexistent/fonts.xml'),
      isEmpty,
    );
  });

  test('the user fallback is tried before the theme fallback', () {
    final container = ProviderContainer(
      overrides: [
        appFontProvider.overrideWith(
          () =>
              _FixedFont(const SystemFontChoice('serif', [kCjkFallbackFamily])),
        ),
        fallbackFontProvider.overrideWith(
          () => _FixedFallback(
            const FileFallback(path: '/tmp/a.ttf', name: 'a.ttf'),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(appFontFallbackProvider), [
      kFallbackFontFamily,
      kCjkFallbackFamily,
    ]);
  });

  test('a system family fallback is passed through by name', () {
    final container = ProviderContainer(
      overrides: [
        appFontProvider.overrideWith(
          () => _FixedFont(const SystemFontChoice('cursive')),
        ),
        fallbackFontProvider.overrideWith(
          () => _FixedFallback(const FamilyFallback('monospace')),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(appFontFallbackProvider), ['monospace']);
  });

  test('no fallback is requested when nothing is picked', () {
    final container = ProviderContainer(
      overrides: [
        appFontProvider.overrideWith(() => _FixedFont(null)),
        fallbackFontProvider.overrideWith(() => _FixedFallback(null)),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(appFontFallbackProvider), isNull);
  });
}

class _FixedFont extends AppFont {
  _FixedFont(this.choice);

  final FontChoice? choice;

  @override
  FontChoice? build() => choice;
}

class _FixedFallback extends FallbackFont {
  _FixedFallback(this.choice);

  final FallbackChoice? choice;

  @override
  FallbackChoice? build() => choice;
}
