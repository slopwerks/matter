import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/theme/neu_theme.dart';
import 'package:matter/theme/tokens.dart';

/// WCAG 相对亮度对比度。
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + .05) / (lo + .05);
}

void main() {
  for (final brightness in Brightness.values) {
    for (final background in MaterialBackground.values) {
      test('Material tokens ($brightness, ${background.name})', () {
        final scheme = applyMaterialBackground(
          ColorScheme.fromSeed(
            seedColor: defaultMaterialSeedColor,
            brightness: brightness,
          ),
          background,
        );
        final theme = buildMaterialTheme(brightness, colorScheme: scheme);
        final tokens = theme.extension<AppDesignTokens>();
        expect(tokens, isNotNull, reason: 'theme 必须挂载 AppDesignTokens');
        final t = tokens!;

        // 表面层级:页面就是 scaffold 底色;卡片必须离页面 ≥ 1.11:1,
        // 否则就是浅色表面色调坍塌(卡片看不见)。
        expect(t.surfaces.page, theme.scaffoldBackgroundColor);
        expect(t.surfaces.card, theme.cardTheme.color);
        expect(t.surfaces.hairline, theme.dividerTheme.color);
        expect(t.surfaces.overlay, theme.appBarTheme.backgroundColor);
        expect(t.surfaces.bubbleOutgoing, scheme.primary);
        expect(t.surfaces.bubbleIncoming, theme.extension<NeuColors>()!.card);
        final ratio = _contrast(t.surfaces.page, t.surfaces.card);
        expect(
          ratio >= 1.11,
          isTrue,
          reason:
              'card 与 page 对比度 $ratio < 1.11 '
              '(${background.name} $brightness),卡片会贴进页面里',
        );

        // 圆角:分组卡片 28,气泡两套皮肤同值 18。
        expect(t.radii.surface, 28);
        expect(t.radii.bubble, 18);

        // 字阶槽位齐全。
        expect(t.typography.pageTitle.fontSize, 24);
        expect(t.typography.pageTitle.fontWeight, FontWeight.w600);
        expect(t.typography.listTitle.fontSize, 16);
        expect(t.typography.sectionTitle.fontWeight, isNotNull);
        expect(t.typography.pageTitle, theme.appBarTheme.titleTextStyle);
        expect(t.typography.listTitle, theme.listTileTheme.titleTextStyle);
        expect(
          _contrast(theme.textTheme.bodyLarge!.color!, t.surfaces.card),
          greaterThanOrEqualTo(4.5),
        );

        // 动效:Material 有按压弹簧,无自绘路由曲线。
        expect(t.motion.pressSpring, isNotNull);
        expect(t.motion.routeForward, isNull);
      });
    }
  }

  for (final brightness in Brightness.values) {
    test('Neu tokens ($brightness)', () {
      final neu = brightness == Brightness.dark
          ? NeuColors.dark
          : NeuColors.light;
      final theme = buildNeuTheme(neu, brightness);
      final tokens = theme.extension<AppDesignTokens>();
      expect(tokens, isNotNull, reason: 'theme 必须挂载 AppDesignTokens');
      final t = tokens!;

      expect(t.surfaces.page, neu.base);
      expect(t.surfaces.card, neu.surface);
      expect(t.surfaces.overlay, neu.surfaceStrong);
      expect(t.surfaces.hairline, neu.hairline);
      expect(t.surfaces.bubbleOutgoing, neu.accent);
      expect(t.surfaces.bubbleIncoming, neu.card);

      expect(t.radii.surface, NeuRadius.surface);
      expect(t.radii.bubble, NeuRadius.content);

      expect(t.typography.pageTitle.fontSize, 24);
      expect(t.typography.pageTitle.fontWeight, FontWeight.w700);
      expect(t.typography.listTitle.fontSize, 16);
      expect(t.typography.sectionTitle.fontSize, 14);
      expect(t.typography.pageTitle, theme.textTheme.headlineMedium);
      expect(t.typography.listTitle, theme.textTheme.titleMedium);
      expect(t.typography.sectionTitle, theme.textTheme.titleSmall);
      expect(
        _contrast(theme.textTheme.bodyLarge!.color!, t.surfaces.card),
        greaterThanOrEqualTo(4.5),
      );

      expect(t.motion.pressSpring, isNull);
      expect(t.motion.routeForward, Curves.easeOutCubic);
      expect(t.motion.routeReverse, Curves.easeInCubic);
    });
  }

  test('间距与圆角保留现有主题契约', () {
    const spacing = AppSpacing();
    expect(
      [spacing.xs, spacing.sm, spacing.md, spacing.lg, spacing.xl],
      [4, 8, 12, 16, 24],
    );
    expect(spacing.navClearance, NeuSpacing.navClearance);
    expect(spacing.dockClearance, NeuSpacing.floatingDockClearance);
    expect(spacing.rowTitleInset, NeuSpacing.rowTitleInset);
    expect(const AppRadii.material().surface, materialSurfaceRadius);
    expect(const AppRadii.material().thumbnail, 8);
    expect(const AppRadii.neu().thumbnail, NeuRadius.button);
  });

  test('copyWith 保留未覆盖槽位且不修改原实例', () {
    final original = buildMaterialTheme(Brightness.light)
        .extension<AppDesignTokens>()!;
    final other = buildNeuTheme(
      NeuColors.dark,
      Brightness.dark,
    ).extension<AppDesignTokens>()!;
    final copy = original.copyWith();
    expect(copy.spacing, same(original.spacing));
    expect(copy.radii, same(original.radii));
    expect(copy.surfaces, same(original.surfaces));
    expect(copy.typography, same(original.typography));
    expect(copy.motion, same(original.motion));
    expect(
      original.copyWith(spacing: other.spacing).spacing,
      same(other.spacing),
    );
    expect(original.copyWith(radii: other.radii).radii, same(other.radii));
    expect(
      original.copyWith(surfaces: other.surfaces).surfaces,
      same(other.surfaces),
    );
    expect(
      original.copyWith(typography: other.typography).typography,
      same(other.typography),
    );
    expect(original.copyWith(motion: other.motion).motion, same(other.motion));
    expect(original.motion, same(AppMotion.material));
    expect(original.lerp(null, .5), same(original));
  });

  test('ThemeData.lerp 逐字段插值并在中点切换离散动效', () {
    final startTheme = buildMaterialTheme(Brightness.light);
    final endTheme = buildNeuTheme(NeuColors.dark, Brightness.dark);
    final start = startTheme.extension<AppDesignTokens>()!.copyWith(
      spacing: const AppSpacing(
        xs: 0,
        sm: 0,
        md: 0,
        lg: 0,
        xl: 0,
        navClearance: 0,
        dockClearance: 0,
        rowTitleInset: 0,
      ),
      radii: const AppRadii(
        tag: 0,
        bubble: 0,
        surface: 0,
        nav: 0,
        thumbnail: 0,
      ),
    );
    final end = endTheme.extension<AppDesignTokens>()!;
    final theme = startTheme.copyWith(extensions: [start]);
    for (final t in [0.0, .25, .5, 1.0]) {
      final result = ThemeData.lerp(
        theme,
        endTheme,
        t,
      ).extension<AppDesignTokens>()!;
      expect(
        [
          result.spacing.xs,
          result.spacing.sm,
          result.spacing.md,
          result.spacing.lg,
          result.spacing.xl,
          result.spacing.navClearance,
          result.spacing.dockClearance,
          result.spacing.rowTitleInset,
        ],
        [
          end.spacing.xs,
          end.spacing.sm,
          end.spacing.md,
          end.spacing.lg,
          end.spacing.xl,
          end.spacing.navClearance,
          end.spacing.dockClearance,
          end.spacing.rowTitleInset,
        ].map((value) => value * t).toList(),
      );
      expect(
        [
          result.radii.tag,
          result.radii.bubble,
          result.radii.surface,
          result.radii.nav,
          result.radii.thumbnail,
        ],
        [
          end.radii.tag,
          end.radii.bubble,
          end.radii.surface,
          end.radii.nav,
          end.radii.thumbnail,
        ].map((value) => value * t).toList(),
      );
      expect(
        result.surfaces.page,
        Color.lerp(start.surfaces.page, end.surfaces.page, t),
      );
      expect(
        result.surfaces.card,
        Color.lerp(start.surfaces.card, end.surfaces.card, t),
      );
      expect(
        result.surfaces.overlay,
        Color.lerp(start.surfaces.overlay, end.surfaces.overlay, t),
      );
      expect(
        result.surfaces.hairline,
        Color.lerp(start.surfaces.hairline, end.surfaces.hairline, t),
      );
      expect(
        result.surfaces.bubbleOutgoing,
        Color.lerp(
          start.surfaces.bubbleOutgoing,
          end.surfaces.bubbleOutgoing,
          t,
        ),
      );
      expect(
        result.surfaces.bubbleIncoming,
        Color.lerp(
          start.surfaces.bubbleIncoming,
          end.surfaces.bubbleIncoming,
          t,
        ),
      );
      expect(
        result.typography.pageTitle,
        TextStyle.lerp(start.typography.pageTitle, end.typography.pageTitle, t),
      );
      expect(
        result.typography.listTitle,
        TextStyle.lerp(start.typography.listTitle, end.typography.listTitle, t),
      );
      expect(
        result.typography.sectionTitle,
        TextStyle.lerp(
          start.typography.sectionTitle,
          end.typography.sectionTitle,
          t,
        ),
      );
      expect(result.motion, same(t < .5 ? start.motion : end.motion));
    }
  });

  testWidgets('缺失 Tokens 时报告挂载要求而不回退到另一套皮肤', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            context.tokens;
            return const SizedBox();
          },
        ),
      ),
    );
    final error = tester.takeException();
    expect(error, isA<FlutterError>());
    expect(error.toString(), contains('AppDesignTokens is missing'));
    expect(error.toString(), contains('buildMaterialTheme or buildNeuTheme'));
  });

  testWidgets('context.tokens 读取当前皮肤的令牌', (tester) async {
    late AppDesignTokens material;
    late AppDesignTokens neu;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildMaterialTheme(Brightness.light),
        builder: (context, _) {
          material = context.tokens;
          return const SizedBox();
        },
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildNeuTheme(NeuColors.light, Brightness.light),
        builder: (context, _) {
          neu = context.tokens;
          return const SizedBox();
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(material.radii.surface, 28);
    expect(material.motion.pressSpring, isNotNull);
    expect(neu.radii.surface, NeuRadius.surface);
    expect(neu.motion.pressSpring, isNull);
  });
}
