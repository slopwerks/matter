import 'package:flutter/material.dart';

/// 动效参数。字段为 null 表示该皮肤没有这种动效，组件按"无动效"处理，
/// 不再查 `context.isMaterial` 分支：
///
/// - [pressSpring] 按压弹性放大。仅 Material 有（`MaterialPress`）；
///   新拟物按压走自身的即时处理，无弹性。
/// - [routeForward] / [routeReverse] 自绘路由过渡曲线。仅 Neu 需要
/// （Material 用框架的 FadeForwards 过渡，无单一曲线值）。
class AppMotion {
  const AppMotion({this.pressSpring, this.routeForward, this.routeReverse});

  /// Material 按压反馈弹簧，数值与 `MaterialPress` 一致。
  static final AppMotion material = AppMotion(
    pressSpring: SpringDescription.withDampingRatio(
      mass: 1,
      stiffness: 500,
      ratio: .78,
    ),
  );

  /// Neu 路由过渡：轻淡入 + 微上滑（进 easeOutCubic / 出 easeInCubic）。
  static const AppMotion neu = AppMotion(
    routeForward: Curves.easeOutCubic,
    routeReverse: Curves.easeInCubic,
  );

  final SpringDescription? pressSpring;
  final Curve? routeForward;
  final Curve? routeReverse;
}
