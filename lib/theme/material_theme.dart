import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import 'neu_colors.dart';
import 'storage_visual_theme.dart';
import 'tokens.dart';

const defaultMaterialSeedColor = Color(0xFF5B8DEF);

const double materialListAvatarSize = 44;
const double materialDenseListAvatarSize = 40;
const double materialListContentGap = 12;
const double materialSurfaceRadius = 28;
const materialListItemShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(materialSurfaceRadius)),
);

TextStyle? materialListTitleStyle(ThemeData theme, {bool unread = false}) =>
    theme.textTheme.titleMedium?.copyWith(
      fontSize: 16,
      fontWeight: unread ? FontWeight.w600 : FontWeight.w500,
    );

TextTheme materialConversationTextTheme(
  ThemeData theme, {
  required bool unread,
  required bool muted,
}) => theme.textTheme.copyWith(
  titleMedium: materialListTitleStyle(theme, unread: unread),
  bodyMedium: theme.textTheme.bodyMedium?.copyWith(
    color: unread
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurfaceVariant,
  ),
  labelSmall: theme.textTheme.labelSmall?.copyWith(
    color: unread && !muted
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant,
  ),
);

({Color fill, Color foreground, TextStyle? title, TextStyle? subtitle})
materialProfileCardStyle(ThemeData theme) => (
  fill: theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLow,
  foreground: theme.colorScheme.onSurfaceVariant,
  title: theme.textTheme.titleMedium?.copyWith(
    fontSize: 18,
    color: theme.colorScheme.onSurface,
  ),
  subtitle: theme.textTheme.bodyMedium,
);

TextStyle? materialSettingsSectionStyle(ThemeData theme) => theme
    .textTheme
    .titleSmall
    ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

const materialPreviewBubbleShape = RoundedSuperellipseBorder(
  borderRadius: BorderRadius.all(Radius.circular(12)),
);
const materialPreviewThumbnailShape = RoundedSuperellipseBorder(
  borderRadius: BorderRadius.all(Radius.circular(8)),
);

enum MaterialBackground {
  tonal,
  pure,
  soft;

  Color? colorFor(Brightness brightness) => switch (this) {
    tonal => null,
    pure => brightness == Brightness.dark ? Colors.black : Colors.white,
    soft =>
      brightness == Brightness.dark
          ? const Color(0xFF202124)
          : const Color(0xFFFFF8EE),
  };
}

/// Neutral, pill-shaped toolbar controls above the scrolling page.
ButtonStyle materialToolbarButtonStyle(ThemeData theme) => IconButton.styleFrom(
  backgroundColor: theme.brightness == Brightness.dark
      ? theme.colorScheme.surfaceContainerHigh
      : theme.cardTheme.color,
  foregroundColor: theme.colorScheme.onSurface,
  shape: const StadiumBorder(),
  minimumSize: const Size.square(44),
  padding: EdgeInsets.zero,
);

const composerControlShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(4)),
);

OutlinedBorder composerButtonShape(ThemeData theme) =>
    theme.extension<NeuColors>()?.isMaterial == true
    ? const StadiumBorder()
    : composerControlShape;

ShapeBorder composerThumbnailShape(ThemeData theme) =>
    theme.extension<NeuColors>()?.isMaterial == true
    ? materialPreviewThumbnailShape
    : composerControlShape;

Color? materialChoiceFill(ThemeData theme, {required bool selected}) =>
    selected ? theme.colorScheme.secondaryContainer : null;

// Shared flat composer controls: mouse targets are compact; touch stays roomy.
ButtonStyle composerIconButtonStyle(ThemeData theme, {required bool compact}) =>
    IconButton.styleFrom(
      minimumSize: Size.square(compact ? 32 : 48),
      padding: EdgeInsets.all(compact ? 6 : 12),
      tapTargetSize: compact
          ? MaterialTapTargetSize.shrinkWrap
          : MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      shape: composerButtonShape(theme),
    ).copyWith(
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
    );

ButtonStyle composerSendButtonStyle(ThemeData theme, {required bool compact}) =>
    FilledButton.styleFrom(
      minimumSize: Size(64, compact ? 32 : 48),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      tapTargetSize: compact
          ? MaterialTapTargetSize.shrinkWrap
          : MaterialTapTargetSize.padded,
      shape: composerButtonShape(theme),
    );

/// 页面标题字号。`buildFloatingAppBar` 和自绘标题行统一取它,不再各抄一个数字。
const double materialPageTitleSize = 24;

/// 页面标题字重。M3 的 `titleLarge` 是 22/w400,拿来当页面标题太轻。
const FontWeight materialPageTitleWeight = FontWeight.w600;

/// [buildMaterialTheme] 的 page/card 两级配色。
///
/// 层次靠填充的明度差,不靠描边和阴影:深色下只向亮走——比所在面更暗的一层
/// 读起来是"洞",不是"层"。浅色下页面压灰、卡片近白,纯白贴灰会显得扎眼。
///
/// 配色预设会把 `surface` 拉离 M3 的容器阶梯(纯黑/纯白),此时容器角色不再与
/// 页面相连,退回按明度抬一档,保证卡片始终比页面"近"。
({Color page, Color card}) _surfacesOf(ColorScheme scheme) {
  final dark = scheme.brightness == Brightness.dark;
  // 浅色下的页面必须压一档,不能取 `surface`:M3 在浅色下把 `surface` 和
  // `surfaceBright` 都放在 tone 98,两者几乎同色,卡片和页面就分不出来。
  final page = dark ? scheme.surface : scheme.surfaceContainer;
  final card = dark ? scheme.surfaceContainer : scheme.surfaceBright;
  final blended = Color.alphaBlend(
    Colors.white.withValues(alpha: dark ? .06 : .5),
    page,
  );
  final cardStepsAway =
      (card.computeLuminance() - page.computeLuminance()).abs() > .01;
  final resolvedCard = cardStepsAway ? card : blended;
  final pageLuminance = page.computeLuminance();
  final cardLuminance = resolvedCard.computeLuminance();
  double contrast(Color color) {
    final luminance = color.computeLuminance();
    return luminance < cardLuminance
        ? (cardLuminance + .05) / (luminance + .05)
        : (luminance + .05) / (cardLuminance + .05);
  }

  // pure/soft 浅色预设的阶跃略低于 1.11；只在不足时微调页面，
  // 保留卡片与强调色，按最小的 8-bit 混色步长拉开层级。
  if (contrast(page) < 1.11) {
    final away = cardLuminance > pageLuminance ? Colors.black : Colors.white;
    for (var step = 1; step <= 255; step++) {
      final adjusted = Color.lerp(page, away, step / 255)!;
      if (contrast(adjusted) >= 1.11) {
        return (page: adjusted, card: resolvedCard);
      }
    }
  }
  return (page: page, card: resolvedCard);
}

/// Background presets change neutral surfaces while preserving accent roles.
ColorScheme applyMaterialBackground(
  ColorScheme scheme,
  MaterialBackground background,
) {
  if (background == MaterialBackground.tonal) return scheme;
  final dark = scheme.brightness == Brightness.dark;
  final neutral = ColorScheme.fromSeed(
    seedColor: background == MaterialBackground.pure
        ? Colors.grey
        : dark
        ? const Color(0xFF738095)
        : const Color(0xFFB99A68),
    brightness: scheme.brightness,
    dynamicSchemeVariant: background == MaterialBackground.pure
        ? DynamicSchemeVariant.monochrome
        : DynamicSchemeVariant.tonalSpot,
  );
  Color surface(Color color) => dark && background == MaterialBackground.soft
      ? Color.alphaBlend(Colors.white.withValues(alpha: .06), color)
      : color;
  return scheme.copyWith(
    surface: background.colorFor(scheme.brightness),
    onSurface: neutral.onSurface,
    onSurfaceVariant: neutral.onSurfaceVariant,
    surfaceDim: surface(neutral.surfaceDim),
    surfaceBright: surface(neutral.surfaceBright),
    surfaceContainerLowest: surface(neutral.surfaceContainerLowest),
    surfaceContainerLow: surface(neutral.surfaceContainerLow),
    surfaceContainer: surface(neutral.surfaceContainer),
    surfaceContainerHigh: surface(neutral.surfaceContainerHigh),
    surfaceContainerHighest: surface(neutral.surfaceContainerHighest),
    outline: neutral.outline,
    outlineVariant: neutral.outlineVariant,
    inverseSurface: neutral.inverseSurface,
    onInverseSurface: neutral.onInverseSurface,
  );
}

/// Material 3 palette。现有页面的颜色角色映射到 ColorScheme,两套外观共用
/// 同一批有状态组件和业务逻辑。
///
/// 排版、形状、表面、状态色在这里一次配齐。页面里单独写的 `shape`、
/// `titleTextStyle`、`contentPadding` 都该收进本文件:一致的观感来自这里
/// 只有一处说了算,不来自单个组件调得多好看。
ThemeData buildMaterialTheme(
  Brightness brightness, {
  Color seedColor = defaultMaterialSeedColor,
  ColorScheme? colorScheme,
}) {
  final scheme =
      colorScheme ??
      ColorScheme.fromSeed(seedColor: seedColor, brightness: brightness);
  final dark = brightness == Brightness.dark;
  final surfaces = _surfacesOf(scheme);
  final text = _buildTextTheme(scheme);
  final overlaySurface = scheme.surfaceContainer.withValues(alpha: .88);
  // 分隔线取正文色的 14%,不用 outlineVariant:后者在深色页上比对浅色页重一倍,
  // 还会带种子的色偏。
  final hairline = scheme.onSurface.withValues(alpha: .14);
  // 列表行标题:tokens 与 listTileTheme 共用同一份,不各抄一次。
  final listTitle = text.bodyLarge?.copyWith(
    fontSize: 16,
    fontWeight: FontWeight.w500,
  );
  final tokens = AppDesignTokens(
    spacing: const AppSpacing(),
    radii: const AppRadii.material(),
    surfaces: AppSurfaces(
      page: surfaces.page,
      card: surfaces.card,
      overlay: overlaySurface,
      hairline: hairline,
      bubbleOutgoing: scheme.primary,
      bubbleIncoming: surfaces.card,
    ),
    typography: AppTypography(
      pageTitle: text.headlineSmall!,
      listTitle: listTitle!,
      sectionTitle: text.titleSmall!.copyWith(color: scheme.onSurfaceVariant),
    ),
    motion: AppMotion.material,
  );
  const surfaceShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(materialSurfaceRadius)),
  );
  const buttonShape = StadiumBorder();
  const overlayShape = RoundedSuperellipseBorder(
    borderRadius: BorderRadius.all(Radius.circular(NeuRadius.content)),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    textTheme: text,
    fontFamilyFallback: kEmojiFontFallback,
    scaffoldBackgroundColor: surfaces.page,
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        for (final platform in TargetPlatform.values)
          platform: platform == TargetPlatform.iOS
              ? const CupertinoPageTransitionsBuilder()
              : FadeForwardsPageTransitionsBuilder(
                  backgroundColor: surfaces.page,
                ),
      },
    ),

    // ── 分层 ──────────────────────────────────────────────────────────
    // 卡片用填充和圆角立起来,elevation 保持 0。阴影只在真正浮起的层
    // (底部导航、弹层、对话框)出现:列表里每张卡都带阴影只是白烧栅格时间。
    cardTheme: CardThemeData(
      color: surfaces.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: surfaceShape,
      clipBehavior: Clip.antiAlias,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: overlaySurface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.headlineSmall,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: overlaySurface,
      // 不在这里改 indicatorColor:底部 dock 的指示器由
      // `MaterialTabNavigationBar` 自绘,它读的是 `secondaryContainer` 的
      // 中性盘。改成半透明主色会把指示器抽成一层几乎看不见的膜。
      // 选中项的颜色走 indicator 之外:图标和文字取 primary。
      elevation: 0,
      height: 68,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => text.labelMedium?.copyWith(
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.onSurfaceVariant,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 24,
          color: states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.onSurfaceVariant,
        ),
      ),
    ),
    dividerTheme: DividerThemeData(color: hairline, thickness: 1, space: 1),

    // ── 列表 ──────────────────────────────────────────────────────────
    // 行高 56 起、标题 16、次要 14:比 M3 默认的 48+16 松一档,分组卡片里
    // 行与行之间才会呼吸。
    listTileTheme: ListTileThemeData(
      minTileHeight: 56,
      contentPadding: const EdgeInsets.symmetric(horizontal: NeuSpacing.lg),
      // 16 (contentPadding) + 24 (minLeadingWidth) + 8 = 48,与
      // `NeuSpacing.rowTitleInset` 对齐。用 12 会落在 52,行间分隔线从 48
      // 起,线就穿过文字左缘前的 4 dp。
      horizontalTitleGap: NeuSpacing.sm,
      minLeadingWidth: 24,
      iconColor: scheme.onSurfaceVariant,
      textColor: scheme.onSurface,
      titleTextStyle: listTitle,
      subtitleTextStyle: text.bodyMedium?.copyWith(fontSize: 14),
      // The group owns its outline; ink inside a run reaches the row edges.
      shape: const RoundedRectangleBorder(),
    ),

    // ── 控件 ──────────────────────────────────────────────────────────
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(NeuRadius.content),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(NeuRadius.content),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(NeuRadius.content),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(NeuRadius.content),
        borderSide: BorderSide(color: scheme.error, width: 1.5),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(NeuRadius.content),
        borderSide: BorderSide(color: scheme.error, width: 2),
      ),
      prefixIconColor: scheme.onSurfaceVariant,
      suffixIconColor: scheme.onSurfaceVariant,
    ),
    searchBarTheme: SearchBarThemeData(
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(surfaces.card),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      shape: const WidgetStatePropertyAll(buttonShape),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 16),
      ),
      constraints: const BoxConstraints(minHeight: 56),
      textStyle: WidgetStatePropertyAll(text.bodyLarge),
      hintStyle: WidgetStatePropertyAll(
        text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: scheme.surfaceContainer,
      selectedColor: scheme.primary,
      secondarySelectedColor: scheme.primary,
      labelStyle: text.labelLarge?.copyWith(
        fontSize: 14,
        color: scheme.onSurface,
      ),
      secondaryLabelStyle: text.labelLarge?.copyWith(
        fontSize: 14,
        color: scheme.onPrimary,
      ),
      side: BorderSide.none,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(NeuRadius.nav)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      showCheckmark: false,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: const WidgetStatePropertyAll(buttonShape),
        side: const WidgetStatePropertyAll(BorderSide.none),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: buttonShape,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        shape: buttonShape,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: buttonShape,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: buttonShape),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: 2,
      focusElevation: 2,
      hoverElevation: 2,
      highlightElevation: 4,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.onPrimary
            : scheme.outline,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : scheme.surfaceContainerHighest,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.surfaceContainerHighest,
      circularTrackColor: Colors.transparent,
    ),
    tabBarTheme: TabBarThemeData(
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: Colors.transparent,
      labelStyle: text.titleSmall,
      unselectedLabelStyle: text.titleSmall,
      labelColor: scheme.onSurface,
      unselectedLabelColor: scheme.onSurfaceVariant,
    ),

    // ── 浮层 ──────────────────────────────────────────────────────────
    dialogTheme: DialogThemeData(
      backgroundColor: surfaces.card,
      surfaceTintColor: Colors.transparent,
      elevation: 3,
      shape: surfaceShape,
      titleTextStyle: text.headlineSmall,
      contentTextStyle: text.bodyMedium?.copyWith(fontSize: 15),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: scheme.surfaceContainerLow,
      elevation: 1,
      showDragHandle: true,
      dragHandleColor: scheme.onSurfaceVariant.withValues(alpha: .4),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(NeuRadius.nav),
        ),
      ),
    ),
    badgeTheme: BadgeThemeData(
      backgroundColor: scheme.error,
      textColor: scheme.onError,
      textStyle: text.labelSmall?.copyWith(fontWeight: FontWeight.w700),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: surfaces.page,
      elevation: 0,
      indicatorColor: scheme.secondaryContainer,
      selectedIconTheme: IconThemeData(size: 24, color: scheme.primary),
      unselectedIconTheme: IconThemeData(
        size: 24,
        color: scheme.onSurfaceVariant,
      ),
      selectedLabelTextStyle: text.labelMedium?.copyWith(
        fontWeight: FontWeight.w600,
        color: scheme.primary,
      ),
      unselectedLabelTextStyle: text.labelMedium?.copyWith(
        fontWeight: FontWeight.w500,
        color: scheme.onSurfaceVariant,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: surfaces.card,
      surfaceTintColor: Colors.transparent,
      elevation: 3,
      shape: overlayShape,
      textStyle: text.bodyLarge,
    ),
    snackBarTheme: SnackBarThemeData(
      // 抬到 0.94:半透明 snackbar 贴在卡片上会透出底下的内容。
      backgroundColor: Color.alphaBlend(
        scheme.surfaceContainerHighest.withValues(alpha: .94),
        surfaces.page,
      ),
      contentTextStyle: text.bodyMedium?.copyWith(
        fontSize: 15,
        color: scheme.onSurface,
      ),
      actionTextColor: scheme.primary,
      behavior: SnackBarBehavior.floating,
      elevation: 2,
      shape: overlayShape,
      insetPadding: const EdgeInsets.fromLTRB(
        NeuSpacing.lg,
        0,
        NeuSpacing.lg,
        NeuSpacing.lg,
      ),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      textStyle: text.bodySmall?.copyWith(color: scheme.onInverseSurface),
      decoration: BoxDecoration(
        color: scheme.inverseSurface,
        borderRadius: const BorderRadius.all(Radius.circular(NeuRadius.tag)),
      ),
    ),

    extensions: [
      StorageVisualTheme(
        scheme: scheme,
        previewShape: materialPreviewThumbnailShape,
      ),
      NeuColors(
        isMaterial: true,
        base: surfaces.page,
        surface: surfaces.card,
        // 弹层、底栏这类"再往上浮一层"的面。
        surfaceStrong: scheme.surfaceContainerHigh,
        // 密集内容卡片(会话行、入站气泡)的填充。
        card: surfaces.card,
        shadowLight: Colors.transparent,
        shadowDark: Colors.transparent,
        text: scheme.onSurface,
        textSecondary: scheme.onSurfaceVariant,
        textTertiary: scheme.onSurfaceVariant.withValues(alpha: .75),
        accent: scheme.primary,
        accentPressed: scheme.primary,
        onAccent: scheme.onPrimary,
        accentSoft: scheme.primaryContainer,
        success: dark ? const Color(0xFF8AD6A1) : const Color(0xFF206A39),
        warning: dark ? const Color(0xFFEEC16C) : const Color(0xFF805600),
        error: scheme.error,
        glassFill: overlaySurface,
        glassBorder: Colors.transparent,
        hairline: hairline,
        highlightAlpha: 0,
      ),
      tokens,
    ],
  );
}

/// 字阶,对标 FlClash 的 `AppTextStyle`:字号档位和字重一起给,而不是让
/// `titleLarge` 停在 w400。
///
/// 数字一律等宽——消息数、时长、速度靠 `tabularFigures` 才不会随刷新抖动。
/// 中文行高比 M3 收紧 (1.35~1.5),默认的 1.5 在列表里显得松散。
TextTheme _buildTextTheme(ColorScheme scheme) {
  TextStyle slot(
    double size,
    FontWeight weight, {
    double height = 1.35,
    Color? color,
    bool tabular = false,
  }) => TextStyle(
    fontSize: size,
    fontWeight: weight,
    height: height,
    letterSpacing: 0,
    color: color ?? scheme.onSurface,
    fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
  );

  return TextTheme(
    // 大数字:仪表盘、统计里的主值。
    displaySmall: slot(36, FontWeight.w700, height: 1.2, tabular: true),
    // 页面大标题(自绘标题行、SliverAppBar.large)。
    headlineMedium: slot(materialPageTitleSize, materialPageTitleWeight),
    // 顶栏标题、对话框标题。
    headlineSmall: slot(
      materialPageTitleSize,
      materialPageTitleWeight,
      height: 1.25,
    ),
    titleLarge: slot(22, FontWeight.w700),
    // 卡片标题、分区标题。
    titleMedium: slot(17, FontWeight.w600, height: 1.4),
    titleSmall: slot(15, FontWeight.w600, height: 1.4),
    // 正文 16 / 次要 14 / 注释 12。
    bodyLarge: slot(16, FontWeight.w400, height: 1.5, color: scheme.onSurface),
    bodyMedium: slot(
      14,
      FontWeight.w400,
      height: 1.45,
      color: scheme.onSurfaceVariant,
    ),
    bodySmall: slot(
      12,
      FontWeight.w400,
      height: 1.35,
      color: scheme.onSurfaceVariant,
    ),
    labelLarge: slot(15, FontWeight.w600, height: 1.4),
    labelMedium: slot(
      12,
      FontWeight.w500,
      height: 1.3,
      color: scheme.onSurfaceVariant,
    ),
    labelSmall: slot(
      11,
      FontWeight.w500,
      height: 1.2,
      color: scheme.onSurfaceVariant,
    ),
  );
}
