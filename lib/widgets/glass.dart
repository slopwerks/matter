import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/neu_colors.dart';

/// 磨砂玻璃点缀面板。
///
/// 用法纪律:玻璃只用于"浮在滚动内容之上"的层(顶栏、悬浮搜索、
/// 对话气泡浮层、弹层卡片),大面积静态面板一律用 [NeuSurface],
/// 否则新拟物的立体感会被玻璃感盖掉,且可读性下降。
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    this.radius = NeuRadius.surface,
    this.padding,
    this.blur = 18,
    this.opacity = 1,
    this.width,
    this.height,
    required this.child,
  });

  final double radius;
  final EdgeInsetsGeometry? padding;

  /// 模糊半径。消息列表上方的浮层 16~22 之间较稳。
  final double blur;

  /// 填充不透明度系数(1 = tokens 默认值,调大可提升可读性)。
  final double opacity;
  final double? width;
  final double? height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(radius),
      side: BorderSide(color: colors.glassBorder, width: 1),
    );
    return ClipPath.shape(
      shape: shape,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          width: width,
          height: height,
          padding: padding,
          decoration: ShapeDecoration(
            shape: shape,
            color: colors.glassFill.withValues(
              alpha: (colors.glassFill.a * opacity).clamp(0, 1),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
