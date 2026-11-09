import 'dart:ui' show lerpDouble;

import '../neu_colors.dart';

/// 圆角档位（语义命名，两套皮肤各自给值）：
///
/// - [tag] 角标、极小控件底、消息组内收尾角；
/// - [bubble] 消息气泡外框（两套皮肤同值，见 `neuBubbleShape`）；
/// - [surface] 卡片、面板、对话框；
/// - [nav] 导航、底部大浮层；
/// - [thumbnail] 媒体缩略图预览。
///
/// Material 的按钮胶囊（StadiumBorder）是形状不是数字，不属于这里；
/// 需要数字圆角的场合才取 token。
class AppRadii {
  const AppRadii({
    this.tag = NeuRadius.tag,
    this.bubble = NeuRadius.content,
    this.surface = NeuRadius.surface,
    this.nav = NeuRadius.nav,
    this.thumbnail = NeuRadius.button,
  });

  /// 新拟物皮肤：卡片 22，独立媒体预览圆角 14。
  /// Composer 缩略图仍使用自己的形状契约，不消费此槽位。
  const AppRadii.neu()
    : this(surface: NeuRadius.surface, thumbnail: NeuRadius.button);

  /// Material 皮肤：分组卡片与对话框用 28（`materialSurfaceRadius`），
  /// 缩略图取 Material 预览小圆角 8。
  const AppRadii.material() : this(surface: 28, thumbnail: 8);

  final double tag;
  final double bubble;
  final double surface;
  final double nav;
  final double thumbnail;

  static AppRadii lerp(AppRadii a, AppRadii b, double t) => AppRadii(
    tag: lerpDouble(a.tag, b.tag, t)!,
    bubble: lerpDouble(a.bubble, b.bubble, t)!,
    surface: lerpDouble(a.surface, b.surface, t)!,
    nav: lerpDouble(a.nav, b.nav, t)!,
    thumbnail: lerpDouble(a.thumbnail, b.thumbnail, t)!,
  );
}
