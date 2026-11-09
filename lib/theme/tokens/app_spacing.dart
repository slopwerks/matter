import 'dart:ui' show lerpDouble;

import '../neu_colors.dart';

/// 间距档位：页面节奏统一从这里取，不再散落魔数。
///
/// 两套皮肤共用同一节奏，数值与 [NeuSpacing] 一致（以它为单一数值来源）：
/// 标题行(20,12,16,8) → 搜索框(上 4) → 筛选条(上 12) → 列表(上 8)。
class AppSpacing {
  const AppSpacing({
    this.xs = NeuSpacing.xs,
    this.sm = NeuSpacing.sm,
    this.md = NeuSpacing.md,
    this.lg = NeuSpacing.lg,
    this.xl = NeuSpacing.xl,
    this.navClearance = NeuSpacing.navClearance,
    this.dockClearance = NeuSpacing.floatingDockClearance,
    this.rowTitleInset = NeuSpacing.rowTitleInset,
  });

  /// 基础步进：4 / 8 / 12 / 16 / 24。
  final double xs;
  final double sm;
  final double md;
  final double lg;
  final double xl;

  /// 窄屏列表底部为玻璃导航预留的高度。
  final double navClearance;

  /// Material 悬浮 dock 占掉的垂直高度（滚动内容底部要留这么多，
  /// 系统底部安全区另加）。
  final double dockClearance;

  /// 分组卡片里行标题的起始缩进；行间分隔线也从这里起。
  final double rowTitleInset;

  static AppSpacing lerp(AppSpacing a, AppSpacing b, double t) => AppSpacing(
    xs: lerpDouble(a.xs, b.xs, t)!,
    sm: lerpDouble(a.sm, b.sm, t)!,
    md: lerpDouble(a.md, b.md, t)!,
    lg: lerpDouble(a.lg, b.lg, t)!,
    xl: lerpDouble(a.xl, b.xl, t)!,
    navClearance: lerpDouble(a.navClearance, b.navClearance, t)!,
    dockClearance: lerpDouble(a.dockClearance, b.dockClearance, t)!,
    rowTitleInset: lerpDouble(a.rowTitleInset, b.rowTitleInset, t)!,
  );
}
