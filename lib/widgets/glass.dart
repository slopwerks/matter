import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'progressive_blur.dart';

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
    this.backdropGroupKey,
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

  /// Shares the captured backdrop with other non-overlapping glass panels.
  final BackdropKey? backdropGroupKey;
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
        backdropGroupKey: backdropGroupKey,
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

/// 顶部渐变模糊层:滚入屏幕上缘的内容先被底色盖住、再随渐变柔和消失,
/// 避免在视口边缘被硬裁切。用于聊天列表头部与聊天室浮动顶栏的后方。
class TopFadeBlur extends StatelessWidget {
  const TopFadeBlur({
    super.key,
    this.blur = 20,
    this.useShader = false,
    this.backdropGroupKey,
  });

  /// 连续半径模糊;不支持 Shader 滤镜的后端沿用条带实现。
  final bool useShader;

  /// 模糊半径。配合 [GlassPanel] 的 16~22 区间取值。
  final double blur;
  final BackdropKey? backdropGroupKey;

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    return _ProgressiveEdgeBlur(
      edge: _Edge.top,
      blur: blur,
      useShader: useShader,
      backdropGroupKey: backdropGroupKey,
      // 覆盖率按平方曲线渐出:靠近内容侧几乎透明,
      // 配合模糊条带实现"从无到有"的柔和过渡。
      colors: [
        colors.base.withValues(alpha: .96),
        colors.base.withValues(alpha: .54),
        colors.base.withValues(alpha: .24),
        colors.base.withValues(alpha: .06),
        colors.base.withValues(alpha: 0),
      ],
      stops: const [0, .25, .5, .75, 1],
    );
  }
}

/// 底部渐变模糊层:输入面板等底部浮层后方使用,滚入下缘的内容
/// 先模糊、再随渐变消失。
class BottomFadeBlur extends StatelessWidget {
  const BottomFadeBlur({
    super.key,
    this.blur = 12,
    this.fadeStart = 32,
    this.useShader = false,
    this.backdropGroupKey,
  });

  /// 模糊半径。底部浮层比顶部条带矮,取值偏小。
  final double blur;

  /// 从上缘算起不施加模糊的距离(逻辑像素),让出内容阅读区。
  final double fadeStart;

  /// 连续半径模糊;不支持 Shader 滤镜的后端沿用条带实现。
  final bool useShader;
  final BackdropKey? backdropGroupKey;

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final fadeStop = height <= fadeStart ? 1.0 : fadeStart / height;
        return _ProgressiveEdgeBlur(
          edge: _Edge.bottom,
          blur: blur,
          inactiveFraction: fadeStop,
          useShader: useShader,
          backdropGroupKey: backdropGroupKey,
          colors: [
            Colors.transparent,
            Colors.transparent,
            colors.base.withValues(alpha: .31),
            colors.base.withValues(alpha: .88),
          ],
          stops: [0, fadeStop, (fadeStop + 1) / 2, 1],
        );
      },
    );
  }
}

enum _Edge { top, bottom }

/// 渐进式边缘模糊:降采样渐变半径 shader (不支持时使用条带)叠加底色渐变,
/// 越靠近边缘模糊越强,靠近内容侧衰减为零,静止时内容不被模糊。
///
/// 不用 ShaderMask + BackdropFilter 的组合:该组合在 Android (Impeller)
/// 上模糊层完全不生效(flutter/flutter#164079),条带叠加则各端一致。
///
/// TODO(neu): 发行目标只有 Android arm64,Impeller 默认开启且清单未关闭,
/// 所有调用点默认选择 [useShader] 的降采样渐变半径 shader 路径;16 层条带
/// 用于 shader 加载期间及 web/CanvasKit 等非 Impeller 后端的降级。
/// 等非 Impeller 后端有了明确的边缘渐隐方案(或确认不再支持这些
/// 平台)后再删,届时 `useShader`、`_strips`、`_strip` 与 `dart:math` 的
/// `pow` 依赖可一并移除。
class _ProgressiveEdgeBlur extends StatelessWidget {
  const _ProgressiveEdgeBlur({
    required this.edge,
    required this.blur,
    required this.colors,
    required this.stops,
    this.inactiveFraction = 0,
    this.useShader = false,
    this.backdropGroupKey,
  });

  static const _strips = 16;

  final _Edge edge;

  /// 边缘侧的峰值模糊半径。配合 [GlassPanel] 的 16~22 区间取值。
  final double blur;

  /// 底色渐变,从上缘到下缘。
  final List<Color> colors;
  final List<double> stops;

  /// 从内容侧算起不施加模糊的比例。
  final double inactiveFraction;
  final bool useShader;
  final BackdropKey? backdropGroupKey;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final activeHeight = constraints.maxHeight * (1 - inactiveFraction);
            final stripHeight = activeHeight / _strips;
            return Stack(
              fit: StackFit.expand,
              children: [
                if (useShader)
                  ProgressiveBlur(
                    sigma: blur,
                    bottom: edge == _Edge.bottom,
                    inactiveFraction: inactiveFraction,
                    backdropGroupKey: backdropGroupKey,
                    fallback: Stack(
                      fit: StackFit.expand,
                      children: [
                        for (var i = 0; i < _strips; i++)
                          _strip(i, stripHeight),
                      ],
                    ),
                  )
                else
                  for (var i = 0; i < _strips; i++) _strip(i, stripHeight),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: colors,
                      stops: stops,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _strip(int i, double stripHeight) {
    // 模糊半径按立方曲线从边缘侧的峰值衰减到内容侧的零:
    // 起步足够平缓,16 层使相邻层的半径差缩到感知阈值以下。
    final sigma = blur * pow(1 - i / (_strips - 1), 3);
    if (sigma < .5) return const SizedBox.shrink();
    final offset = i * stripHeight;
    return Positioned(
      top: edge == _Edge.top ? offset : null,
      bottom: edge == _Edge.bottom ? offset : null,
      left: 0,
      right: 0,
      // 1px 重叠,避免条带接缝处漏出未模糊的内容。
      height: stripHeight + 1,
      // ClipRect 必须直接包住 BackdropFilter:否则在 Android (Impeller)
      // 上模糊输出会渗出条带边界,把条带下方的内容也糊掉。
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}
