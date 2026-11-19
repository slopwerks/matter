import 'dart:convert';
import 'dart:typed_data';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/settings/material_color_settings_page.dart';
import 'package:matter/pages/settings/material_scheme_preview.dart';
import 'package:matter/providers/material_color_provider.dart';
import 'package:matter/providers/theme_provider.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/theme/system_material_colors.dart';
import 'package:shared_preferences/shared_preferences.dart';

void _mockSystem({List<int>? palette, Color? accent, bool fail = false}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(DynamicColorPlugin.channel, (call) async {
        if (fail) throw PlatformException(code: 'unavailable');
        return switch (call.method) {
          'getCorePalette' =>
            palette == null ? null : Int64List.fromList(palette),
          'getAccentColor' => accent?.toARGB32(),
          _ => throw UnsupportedError(call.method),
        };
      });
}

class _ColorApp extends ConsumerWidget {
  const _ColorApp({required this.brightness, this.textScale = 1});

  final Brightness brightness;
  final double textScale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(materialColorSchemesProvider);
    return MaterialApp(
      theme: buildMaterialTheme(Brightness.light, colorScheme: colors.light),
      darkTheme: buildMaterialTheme(Brightness.dark, colorScheme: colors.dark),
      themeMode: brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: const MaterialColorSettingsPage(),
    );
  }
}

Future<void> _tapChip(WidgetTester tester, String label) async {
  final tooltipFinder = find.byTooltip(label);
  final target = tooltipFinder.evaluate().isNotEmpty
      ? tooltipFinder
      : find.text(label);
  final scrollable = find.byType(Scrollable).first;
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(target, 200, scrollable: scrollable);
  await Scrollable.ensureVisible(tester.element(target.first), alignment: .5);
  await tester.pumpAndSettle();
  await tester.tap(target.first);
  await tester.pumpAndSettle();
}

double _contrast(Color first, Color second) {
  final luminances = [first.computeLuminance(), second.computeLuminance()]
    ..sort();
  return (luminances.last + .05) / (luminances.first + .05);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _mockSystem();
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DynamicColorPlugin.channel, null);
  });

  test(
    'an early edit preserves restored background and brightness preferences',
    () async {
      SharedPreferences.setMockInitialValues({
        'app_theme_style': 'materialDark',
        'material_color_settings': jsonEncode({
          'followSystem': true,
          'seedColor': Colors.green.toARGB32(),
          'lightBackground': 'soft',
          'darkBackground': 'pure',
        }),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(appThemeStyleProvider);
      await container
          .read(materialColorSettingsProvider.notifier)
          .setSeedColor(Colors.purple);
      final settings = container.read(materialColorSettingsProvider);
      expect(settings.followSystem, isFalse);
      expect(settings.lightBackground, MaterialBackground.soft);
      expect(settings.darkBackground, MaterialBackground.pure);
      expect(container.read(appThemeStyleProvider), AppThemeStyle.materialDark);
      final saved = jsonDecode(
        (await SharedPreferences.getInstance()).getString(
          'material_color_settings',
        )!,
      ) as Map<String, dynamic>;
      expect(saved['seedColor'], Colors.purple.toARGB32());
      expect(saved['darkBackground'], 'pure');
      expect(saved['lightBackground'], 'soft');
    },
  );

  test(
    'rapid edits persist both backgrounds and the last selected seed',
    () async {
      final container = ProviderContainer();
      final notifier = container.read(materialColorSettingsProvider.notifier);
      await Future.wait([
        notifier.setSeedColor(Colors.teal),
        notifier.setBackground(Brightness.dark, MaterialBackground.pure),
        notifier.setBackground(Brightness.light, MaterialBackground.soft),
        notifier.setSeedColor(Colors.orange),
      ]);
      container.dispose();
      final restored = ProviderContainer();
      addTearDown(restored.dispose);
      // This setter waits for restoration and keeps the other saved fields.
      await restored
          .read(materialColorSettingsProvider.notifier)
          .setFollowSystem(true);
      final settings = restored.read(materialColorSettingsProvider);
      expect(settings.followSystem, isTrue);
      expect(settings.seedColor.toARGB32(), Colors.orange.toARGB32());
      expect(settings.darkBackground, MaterialBackground.pure);
      expect(settings.lightBackground, MaterialBackground.soft);
    },
  );

  test('unavailable system colors fall back to the selected seed', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container
        .read(materialColorSettingsProvider.notifier)
        .setSeedColor(Colors.pink);
    await container
        .read(materialColorSettingsProvider.notifier)
        .setFollowSystem(true);
    await container.read(systemMaterialColorsProvider.future);
    final colors = container.read(materialColorSchemesProvider);
    expect(
      colors.light.primary,
      ColorScheme.fromSeed(seedColor: Colors.pink).primary,
    );
    expect(
      colors.dark.primary,
      ColorScheme.fromSeed(
        seedColor: Colors.pink,
        brightness: Brightness.dark,
      ).primary,
    );
  });

  test(
    'desktop accent produces complete Flutter light and dark schemes',
    () async {
      _mockSystem(accent: Colors.green);
      final colors = (await loadSystemMaterialColors())!;
      expect(colors.light, ColorScheme.fromSeed(seedColor: Colors.green));
      expect(
        colors.dark,
        ColorScheme.fromSeed(
          seedColor: Colors.green,
          brightness: Brightness.dark,
        ),
      );
      expect(
        buildMaterialTheme(
          Brightness.dark,
          colorScheme: colors.dark,
        ).extension<NeuColors>()!.accent,
        colors.dark.primary,
      );
    },
  );

  test(
    'Android roles retain the supplied tonal palette through SDK conversion',
    () async {
      const tones = [0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 95, 99, 100];
      final palette = [
        for (var p = 0; p < 5; p++)
          for (final tone in tones)
            Color.fromARGB(
              255,
              tone * 255 ~/ 100,
              (tone * 255 ~/ 100 + p * 3).clamp(0, 255),
              tone * 255 ~/ 100,
            ).toARGB32(),
      ];
      _mockSystem(palette: palette, accent: Colors.red);
      final colors = (await loadSystemMaterialColors())!;
      expect(colors.light.primary, Color(palette[4]));
      expect(colors.light.secondary, Color(palette[13 + 4]));
      expect(colors.light.tertiary, Color(palette[26 + 4]));
      expect(colors.light.surface, Color(palette[39 + 11]));
      expect(colors.dark.primary, Color(palette[8]));
      expect(colors.dark.onSurface, Color(palette[39 + 9]));
      expect(colors.light.surfaceContainerHighest.a, 1);
      expect(
        buildMaterialTheme(
          Brightness.light,
          colorScheme: colors.light,
        ).colorScheme,
        colors.light,
      );
    },
  );

  test('platform errors leave a usable seed palette', () async {
    _mockSystem(fail: true);
    expect(await loadSystemMaterialColors(), isNull);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(systemMaterialColorsProvider.future);
    expect(
      container.read(materialColorSchemesProvider).light.primary,
      buildMaterialTheme(Brightness.light).colorScheme.primary,
    );
  });

  test(
    'system refresh applies new colors while manual colors stay selected',
    () async {
      _mockSystem(accent: Colors.green);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(systemMaterialColorsProvider.future);
      expect(
        container.read(materialColorSchemesProvider).light.primary,
        ColorScheme.fromSeed(seedColor: Colors.green).primary,
      );
      _mockSystem(accent: Colors.purple);
      container.invalidate(systemMaterialColorsProvider);
      await container.read(systemMaterialColorsProvider.future);
      expect(
        container.read(materialColorSchemesProvider).light.primary,
        ColorScheme.fromSeed(seedColor: Colors.purple).primary,
      );
      await container
          .read(materialColorSettingsProvider.notifier)
          .setSeedColor(Colors.orange);
      expect(
        container.read(materialColorSchemesProvider).light.primary,
        ColorScheme.fromSeed(seedColor: Colors.orange).primary,
      );
      _mockSystem(accent: Colors.teal);
      await container
          .read(materialColorSettingsProvider.notifier)
          .setFollowSystem(true);
      await container.read(systemMaterialColorsProvider.future);
      expect(
        container.read(materialColorSchemesProvider).light.primary,
        ColorScheme.fromSeed(seedColor: Colors.teal).primary,
      );
    },
  );

  for (final brightness in Brightness.values) {
    for (final background in MaterialBackground.values) {
      test(
        '$brightness $background preserves accents and readable surface layers',
        () {
          final base = ColorScheme.fromSeed(
            seedColor: Colors.teal,
            brightness: brightness,
          );
          final scheme = applyMaterialBackground(base, background);
          expect(scheme.primary, base.primary);
          expect(scheme.primaryContainer, base.primaryContainer);
          expect(scheme.secondary, base.secondary);
          expect(scheme.tertiary, base.tertiary);
          if (background != MaterialBackground.tonal) {
            expect(scheme.surface, background.colorFor(brightness));
            expect(scheme.surfaceContainerLow, isNot(scheme.surface));
          }
          expect(
            _contrast(scheme.onSurface, scheme.surface),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            _contrast(scheme.onSurfaceVariant, scheme.surfaceContainerHighest),
            greaterThanOrEqualTo(4.5),
          );
          if (brightness == Brightness.dark) {
            expect(
              scheme.surfaceContainerLow.computeLuminance(),
              greaterThan(scheme.surface.computeLuminance()),
            );
            if (background == MaterialBackground.soft) {
              expect(
                _contrast(scheme.surface, Colors.black),
                greaterThan(1.25),
              );
            }
          }
          if (brightness == Brightness.light &&
              background == MaterialBackground.soft) {
            expect(
              scheme.surfaceContainerLow.r,
              greaterThan(scheme.surfaceContainerLow.b),
            );
          }
        },
      );
    }

    testWidgets(
      '$brightness color choices update the app and both backgrounds',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final container = ProviderContainer();
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: _ColorApp(brightness: brightness),
          ),
        );
        await tester.pumpAndSettle();
        await _tapChip(tester, '紫色');
        expect(
          container.read(materialColorSettingsProvider).followSystem,
          isFalse,
        );
        final page = tester.element(find.byType(MaterialColorSettingsPage));
        expect(
          Theme.of(page).colorScheme.primary,
          ColorScheme.fromSeed(
            seedColor: const Color(0xFF8B5CF6),
            brightness: brightness,
          ).primary,
        );
        await _tapChip(tester, '纯黑');
        await _tapChip(tester, '淡米白');
        final colors = container.read(materialColorSchemesProvider);
        expect(colors.dark.surface, Colors.black);
        expect(colors.light.surface, const Color(0xFFFFF8EE));
        expect(
          Theme.of(page).colorScheme.surface,
          brightness == Brightness.dark
              ? Colors.black
              : const Color(0xFFFFF8EE),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'system swatch restores the system palette after a manual choice',
    (tester) async {
      _mockSystem(accent: Colors.green);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const _ColorApp(brightness: Brightness.light),
        ),
      );
      await tester.pumpAndSettle();
      await _tapChip(tester, '紫色');
      await _tapChip(tester, '跟随系统配色');
      expect(
        container.read(materialColorSettingsProvider).followSystem,
        isTrue,
      );
      expect(
        container.read(materialColorSchemesProvider).light.primary,
        ColorScheme.fromSeed(seedColor: Colors.green).primary,
      );
      final style = tester.widget<ListTile>(
        find.widgetWithText(ListTile, '色彩风格'),
      );
      expect(style.onTap, isNull);
      expect(find.text('由系统配色决定'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('style picker updates both live previews and the app palette', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _ColorApp(brightness: Brightness.light),
      ),
    );
    await tester.pumpAndSettle();
    await _tapChip(tester, '紫色');
    await _tapChip(tester, '色彩风格');
    await tester.tap(find.text('生动'));
    await tester.pumpAndSettle();
    expect(
      container.read(materialColorSettingsProvider).colorStyle,
      DynamicSchemeVariant.vibrant,
    );
    final previews = tester
        .widgetList<MaterialSchemePreview>(find.byType(MaterialSchemePreview))
        .toList();
    const brightnesses = [Brightness.light, Brightness.dark];
    for (var i = 0; i < brightnesses.length; i++) {
      expect(
        previews[i].scheme,
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF8B5CF6),
          brightness: brightnesses[i],
          dynamicSchemeVariant: DynamicSchemeVariant.vibrant,
        ),
      );
    }
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'custom colors validate input, select, and delete without losing the page',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const _ColorApp(brightness: Brightness.dark),
        ),
      );
      await tester.pumpAndSettle();
      await _tapChip(tester, '添加自定义颜色');
      await tester.enterText(find.byType(TextField), '#xyz');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('请输入有效的 6 位颜色代码'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '#123456');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        container.read(materialColorSettingsProvider).seedColor,
        const Color(0xFF123456),
      );
      await tester.longPress(find.byTooltip('#123456 (长按删除)'));
      await tester.pumpAndSettle();
      expect(
        container.read(materialColorSettingsProvider).customColors,
        isEmpty,
      );
      expect(
        container.read(materialColorSettingsProvider).seedColor,
        defaultMaterialSeedColor,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('background thumbnails retain the original tonal palette', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container
        .read(materialColorSettingsProvider.notifier)
        .setBackground(Brightness.light, MaterialBackground.pure);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _ColorApp(brightness: Brightness.light),
      ),
    );
    await tester.pumpAndSettle();
    await _tapChip(tester, '纯白');
    final thumbnail = tester.widget<MaterialSchemeThumbnail>(
      find.descendant(
        of: find.widgetWithText(ListTile, '随主题色').first,
        matching: find.byType(MaterialSchemeThumbnail),
      ),
    );
    expect(
      thumbnail.scheme,
      ColorScheme.fromSeed(seedColor: defaultMaterialSeedColor),
    );
    expect(
      container.read(materialColorSchemesProvider).light.surface,
      Colors.white,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'palette page clears the actual toolbar and supports enlarged text',
    (tester) async {
      tester.view.padding = const FakeViewPadding(top: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 24);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        const ProviderScope(
          child: _ColorApp(brightness: Brightness.dark, textScale: 2),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('配色预览')).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(find.byType(AppBar)).dy + 16),
      );
      await _tapChip(tester, '极深灰');
      await _tapChip(tester, '纯白');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
