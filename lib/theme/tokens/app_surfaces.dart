import 'package:flutter/material.dart';

/// 表面层级：层次靠填充的明度差，不靠描边和阴影。
/// 深色下只向亮走——比所在面更暗的一层读起来是"洞"，不是"层"；
/// 浅色下页面压灰、卡片近白。
class AppSurfaces {
  const AppSurfaces({
    required this.page,
    required this.card,
    required this.overlay,
    required this.hairline,
    required this.bubbleOutgoing,
    required this.bubbleIncoming,
  });

  /// scaffold 页面底色。
  final Color page;

  /// 基础卡片填充。新拟物的密集内容卡片仍由 NeuColors.card 单独提供。
  final Color card;

  /// 顶栏玻璃基底；不替代菜单、底部抽屉等组件的专用 ThemeData 配色。
  final Color overlay;

  /// 列表分隔线。
  final Color hairline;

  /// 出站气泡的实色/渐变基色，与主题的 accent 保持一致。
  final Color bubbleOutgoing;

  /// 入站气泡的密集内容表面，不等同于 Neu 的基础 card 槽位。
  final Color bubbleIncoming;

  static AppSurfaces lerp(AppSurfaces a, AppSurfaces b, double t) =>
      AppSurfaces(
        page: Color.lerp(a.page, b.page, t)!,
        card: Color.lerp(a.card, b.card, t)!,
        overlay: Color.lerp(a.overlay, b.overlay, t)!,
        hairline: Color.lerp(a.hairline, b.hairline, t)!,
        bubbleOutgoing: Color.lerp(a.bubbleOutgoing, b.bubbleOutgoing, t)!,
        bubbleIncoming: Color.lerp(a.bubbleIncoming, b.bubbleIncoming, t)!,
      );
}
