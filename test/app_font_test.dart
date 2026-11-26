import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/fonts/system_font_catalog.dart';
import 'package:matter/providers/app_font_provider.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/theme/system_font.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('android falls back to the generic system family', () async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(appFontFamilyProvider), kSystemFontFamily);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(appFontProvider), isNull);
  });

  test('desktop keeps the platform default font', () async {
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

    expect(container.read(appFontFamilyProvider), kSystemFontFamily);
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

  test('the user fallback is tried before the theme fallback and preserves emoji fallback', () {
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
      ...?kEmojiFontFallback,
    ]);
  });

  test('a system family fallback is passed through and deduplicated with emoji fallback', () {
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

    expect(container.read(appFontFallbackProvider), [
      'monospace',
      ...?kEmojiFontFallback,
    ]);
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

  test(
    'chat font follows UI font by default and can override independently',
    () async {
      SharedPreferences.setMockInitialValues({});
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(appFontProvider.notifier)
          .selectSystemFamily('Noto Sans');
      expect(container.read(chatFontFamilyProvider), 'Noto Sans');

      await container
          .read(chatFontProvider.notifier)
          .selectSystemFamily('Noto Serif');
      expect(container.read(chatFontFamilyProvider), 'Noto Serif');

      await container.read(chatFontProvider.notifier).selectPlatformDefault();
      expect(container.read(chatFontFamilyProvider), isNull);

      await container.read(chatFontProvider.notifier).reset();
      expect(container.read(chatFontFamilyProvider), 'Noto Sans');
    },
  );

  test(
    'monospace font defaults to Ioskeley Mono and supports system override',
    () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(
        container.read(monospaceFontFamilyProvider),
        kBundledMonospaceFamily,
      );

      await container
          .read(monospaceFontProvider.notifier)
          .selectPlatformDefault();
      expect(
        container.read(monospaceFontFamilyProvider),
        kSystemMonospaceFamily,
      );

      await container
          .read(monospaceFontProvider.notifier)
          .selectSystemFamily('JetBrains Mono');
      expect(container.read(monospaceFontFamilyProvider), 'JetBrains Mono');

      await container.read(monospaceFontProvider.notifier).selectBundled();
      expect(
        container.read(monospaceFontFamilyProvider),
        kBundledMonospaceFamily,
      );
    },
  );

  test(
    'monospace fallback combines user fallback, chat font and emoji fallback',
    () {
      final container = ProviderContainer(
        overrides: [
          appFontProvider.overrideWith(
            () => _FixedFont(const SystemFontChoice('Sarasa Gothic SC')),
          ),
          chatFontProvider.overrideWith(() => _FixedChatFont(null)),
          fallbackFontProvider.overrideWith(
            () => _FixedFallback(const FamilyFallback('Noto Sans CJK SC')),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(monospaceFontFallbackProvider), [
        'Noto Sans CJK SC',
        'Sarasa Gothic SC',
        ...?kEmojiFontFallback,
      ]);
    },
  );

  test('font scales clamp, persist and reset cleanly', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(fontScaleSettingsProvider.notifier);
    expect(container.read(fontScaleSettingsProvider).isDefault, isTrue);

    await notifier.setUiScale(1.8);
    await notifier.setChatScale(1.25);
    await notifier.setMonoScale(0.5);

    final updated = container.read(fontScaleSettingsProvider);
    expect(updated.uiScale, kMaxUiFontScale);
    expect(updated.chatScale, 1.25);
    expect(updated.monoScale, kMinContentFontScale);

    await notifier.reset();
    expect(container.read(fontScaleSettingsProvider).isDefault, isTrue);
  });

  test(
    'user mutation during async restore is not overwritten by stale prefs',
    () async {
      SharedPreferences.setMockInitialValues({
        'app_font_kind': 'system',
        'app_font_family': 'serif',
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Mutate immediately before _restore() completes.
      await container
          .read(appFontProvider.notifier)
          .selectSystemFamily('Noto Sans');
      await Future<void>.delayed(Duration.zero);

      expect(container.read(appFontFamilyProvider), 'Noto Sans');
    },
  );

  test('desktop font catalog parsers extract, unescape and sort families', () {
    expect(
      parseFcListOutput(r'''
Noto Sans CJK SC
JetBrains\-Mono
Adwaita Sans
JetBrains\-Mono
'''),
      ['Adwaita Sans', 'JetBrains-Mono', 'Noto Sans CJK SC'],
    );

    final macCatalog = parseMacOsProfilerJson('''
{
  "SPFontsDataType": [
    {
      "_name": "SF-Mono-Regular.otf",
      "enabled": "yes",
      "typefaces": [{"family": "SF Mono"}]
    },
    {
      "_name": "Disabled.ttf",
      "enabled": "no",
      "typefaces": [{"family": "Disabled Font"}]
    },
    {
      "_name": "PingFang.ttc",
      "enabled": "yes",
      "typefaces": [{"family": "PingFang SC"}]
    }
  ]
}
''');
    expect(macCatalog.families, ['PingFang SC', 'SF Mono']);
    expect(macCatalog.monospaceFamilies, {'SF Mono'});

    expect(
      parseWindowsFontRegistryOutput('''
HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts
    Microsoft YaHei & Microsoft YaHei UI (TrueType)    REG_SZ    msyh.ttc
    Consolas (TrueType)    REG_SZ    consola.ttf
    Segoe UI (TrueType)    REG_SZ    segoeui.ttf
'''),
      ['Consolas', 'Microsoft YaHei', 'Microsoft YaHei UI', 'Segoe UI'],
    );
  });
}

class _FixedFont extends AppFont {
  _FixedFont(this.choice);

  final FontChoice? choice;

  @override
  FontChoice? build() => choice;
}

class _FixedChatFont extends ChatFont {
  _FixedChatFont(this.choice);

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
