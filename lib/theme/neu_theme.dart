import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'neu_colors.dart';

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

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamilyFallback: kEmojiFontFallback,
    scaffoldBackgroundColor: neu.base,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    colorScheme:
        ColorScheme.fromSeed(
          seedColor: neu.accent,
          brightness: brightness,
          surface: neu.surface,
        ).copyWith(
          primary: neu.accent,
          onPrimary: neu.onAccent,
          surface: neu.surface,
          error: neu.error,
        ),
    textTheme: TextTheme(
      headlineMedium: ts(24, FontWeight.w700, neu.text),
      titleLarge: ts(20, FontWeight.w700, neu.text),
      titleMedium: ts(16, FontWeight.w600, neu.text),
      titleSmall: ts(14, FontWeight.w600, neu.text),
      bodyLarge: ts(15, FontWeight.w400, neu.text, 1.45),
      bodyMedium: ts(13, FontWeight.w400, neu.textSecondary, 1.4),
      bodySmall: ts(12, FontWeight.w400, neu.textTertiary, 1.4),
      labelLarge: ts(15, FontWeight.w600, neu.text),
      labelSmall: ts(11, FontWeight.w400, neu.textTertiary, 1.2),
    ),
    dividerColor: neu.hairline,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: NeuPageTransitionsBuilder(),
        TargetPlatform.iOS: NeuPageTransitionsBuilder(),
        TargetPlatform.linux: NeuPageTransitionsBuilder(),
        TargetPlatform.macOS: NeuPageTransitionsBuilder(),
        TargetPlatform.windows: NeuPageTransitionsBuilder(),
      },
    ),
    extensions: [neu],
  );
}

/// 经典深色配色映射为 [NeuColors]：阴影透明、无凸起高光，neu 组件
/// 在此 palette 下呈现为近似原有扁平深色的观感。
NeuColors classicNeuColors() {
  return NeuColors(
    base: AppColors.background,
    surface: AppColors.surface,
    surfaceStrong: AppColors.surfaceElevated,
    card: AppColors.surfaceVariant,
    shadowLight: Colors.transparent,
    shadowDark: Colors.transparent,
    text: AppColors.onBackground,
    textSecondary: AppColors.onSurface,
    textTertiary: AppColors.onSurfaceVariant,
    accent: AppColors.primary,
    accentPressed: Color.lerp(AppColors.primary, Colors.black, .15)!,
    onAccent: Colors.white,
    accentSoft: Color.lerp(AppColors.primary, AppColors.background, .8)!,
    success: AppColors.success,
    warning: AppColors.warning,
    error: AppColors.error,
    glassFill: AppColors.glassBackground,
    glassBorder: AppColors.glassBorder,
    hairline: AppColors.surfaceVariant,
    highlightAlpha: 0,
  );
}

/// 经典主题（现有深色）注册 [NeuColors] 扩展，供迁移后的页面取色。
ThemeData buildClassicTheme() {
  return AppTheme.darkTheme.copyWith(extensions: [classicNeuColors()]);
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
