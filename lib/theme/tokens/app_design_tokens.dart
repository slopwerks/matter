import 'package:flutter/material.dart';

import 'app_motion.dart';
import 'app_radii.dart';
import 'app_spacing.dart';
import 'app_surfaces.dart';
import 'app_typography.dart';

/// 语义化 Design Tokens：两套皮肤（M3 / 新拟物）各自的间距、圆角、表面、
/// 字阶与动效在这里一次配齐。业务组件通过 `context.tokens` 读取，
/// 不再写 `context.isMaterial ? A : B` 的取值分支。
///
/// 值由 `material_theme.dart` 与 `neu_theme.dart` 生成并挂到
/// `ThemeData.extensions`。主题切换时数字与颜色逐字段插值；
/// 动效参数（弹簧、曲线）无法插值，按 t < .5 整组切换。
class AppDesignTokens extends ThemeExtension<AppDesignTokens> {
  const AppDesignTokens({
    required this.spacing,
    required this.radii,
    required this.surfaces,
    required this.typography,
    required this.motion,
  });

  final AppSpacing spacing;
  final AppRadii radii;
  final AppSurfaces surfaces;
  final AppTypography typography;
  final AppMotion motion;

  /// 两套主题构建器都会挂载；独立 Widget 测试也需使用它们。
  static AppDesignTokens of(BuildContext context) {
    final tokens = Theme.of(context).extension<AppDesignTokens>();
    if (tokens == null) {
      throw FlutterError(
        'AppDesignTokens is missing from ThemeData.extensions. '
        'Use buildMaterialTheme or buildNeuTheme to provide it.',
      );
    }
    return tokens;
  }

  @override
  AppDesignTokens copyWith({
    AppSpacing? spacing,
    AppRadii? radii,
    AppSurfaces? surfaces,
    AppTypography? typography,
    AppMotion? motion,
  }) => AppDesignTokens(
    spacing: spacing ?? this.spacing,
    radii: radii ?? this.radii,
    surfaces: surfaces ?? this.surfaces,
    typography: typography ?? this.typography,
    motion: motion ?? this.motion,
  );

  @override
  AppDesignTokens lerp(covariant AppDesignTokens? other, double t) =>
      other == null
      ? this
      : AppDesignTokens(
          spacing: AppSpacing.lerp(spacing, other.spacing, t),
          radii: AppRadii.lerp(radii, other.radii, t),
          surfaces: AppSurfaces.lerp(surfaces, other.surfaces, t),
          typography: AppTypography.lerp(typography, other.typography, t),
          motion: t < .5 ? motion : other.motion,
        );
}

extension AppDesignTokensX on BuildContext {
  /// 当前皮肤的设计令牌。
  AppDesignTokens get tokens => AppDesignTokens.of(this);
}
