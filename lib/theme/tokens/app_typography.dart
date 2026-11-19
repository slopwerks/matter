import 'package:flutter/material.dart';

/// 语义字阶槽位。字号字重由各皮肤的主题构建器决定，页面只按语义取槽，
/// 不再各自 copyWith 数字。
///
/// 三个槽位是跨皮肤契约（见 docs/ui-conventions.md）：
/// - [pageTitle] 页面标题（Material 24/w600，Neu 24/w700）；
/// - [listTitle] 列表行标题（未读时组件自行加粗）；
/// - [sectionTitle] 设置页分区标题。
class AppTypography {
  const AppTypography({
    required this.pageTitle,
    required this.listTitle,
    required this.sectionTitle,
  });

  final TextStyle pageTitle;
  final TextStyle listTitle;
  final TextStyle sectionTitle;

  static AppTypography lerp(AppTypography a, AppTypography b, double t) =>
      AppTypography(
        pageTitle: TextStyle.lerp(a.pageTitle, b.pageTitle, t)!,
        listTitle: TextStyle.lerp(a.listTitle, b.listTitle, t)!,
        sectionTitle: TextStyle.lerp(a.sectionTitle, b.sectionTitle, t)!,
      );
}
