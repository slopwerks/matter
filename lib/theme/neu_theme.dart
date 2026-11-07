import 'package:flutter/material.dart';

import 'neu_colors.dart';
import 'storage_visual_theme.dart';
import 'tokens.dart';

/// 新拟物主题的 ThemeData 构建（移植自原型 app.dart）。
///
/// 统一字阶（全 App 唯一字号来源，页面不再散落硬编码字号）：
/// headline 24 品牌/大标题；title 20/16/14 页面标题→卡片标题→小分区；
/// body 15/13/12 正文→次级说明→元信息；label 15 按钮、11 徽标/极小标签。
ThemeData buildNeuTheme(NeuColors neu, Brightness brightness) {
  TextStyle ts(double size, FontWeight weight, Color color, [double? height]) =>
      TextStyle(
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height,
      );

  final scheme =
      ColorScheme.fromSeed(
        seedColor: neu.accent,
        brightness: brightness,
        surface: neu.surface,
      ).copyWith(
        primary: neu.accent,
        onPrimary: neu.onAccent,
        surface: neu.surface,
        error: neu.error,
      );
  final text = TextTheme(
    displaySmall: ts(36, FontWeight.w700, neu.text, 1.2),
    headlineMedium: ts(24, FontWeight.w700, neu.text),
    titleLarge: ts(20, FontWeight.w700, neu.text),
    titleMedium: ts(16, FontWeight.w600, neu.text),
    titleSmall: ts(14, FontWeight.w600, neu.text),
    bodyLarge: ts(15, FontWeight.w400, neu.text, 1.45),
    bodyMedium: ts(13, FontWeight.w400, neu.textSecondary, 1.4),
    bodySmall: ts(12, FontWeight.w400, neu.textTertiary, 1.4),
    labelLarge: ts(15, FontWeight.w600, neu.text),
    labelSmall: ts(11, FontWeight.w400, neu.textTertiary, 1.2),
  );
  final theme = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamilyFallback: kEmojiFontFallback,
    scaffoldBackgroundColor: neu.base,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    colorScheme: scheme,
    textTheme: text,
    dividerColor: neu.hairline,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
        TargetPlatform.iOS: NeuPageTransitionsBuilder(),
        TargetPlatform.linux: NeuPageTransitionsBuilder(),
        TargetPlatform.macOS: NeuPageTransitionsBuilder(),
        TargetPlatform.windows: NeuPageTransitionsBuilder(),
      },
    ),
    extensions: [
      neu,
      StorageVisualTheme(
        scheme: scheme,
        previewShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NeuRadius.button),
        ),
      ),
    ],
  );
  // ThemeData 补齐字体族与 fallback 后再生成字阶，避免 Tokens 丢掉字体信息。
  final resolvedText = theme.textTheme;
  return theme.copyWith(
    extensions: [
      ...theme.extensions.values,
      AppDesignTokens(
        spacing: const AppSpacing(),
        radii: const AppRadii.neu(),
        surfaces: AppSurfaces(
          page: neu.base,
          card: neu.surface,
          overlay: neu.surfaceStrong,
          hairline: neu.hairline,
          bubbleOutgoing: neu.accent,
          bubbleIncoming: neu.card,
        ),
        typography: AppTypography(
          pageTitle: resolvedText.headlineMedium!,
          listTitle: resolvedText.titleMedium!,
          sectionTitle: resolvedText.titleSmall!,
        ),
        motion: AppMotion.neu,
      ),
    ],
  );
}

/// 统一路由过渡：轻淡入 + 微上滑（替代桌面/网页端默认的硬切）。
class NeuPageTransitionsBuilder extends PageTransitionsBuilder {
  const NeuPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, .03),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}
