import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/neu_colors.dart';

/// 新拟物起伏模式。
enum NeuDepth {
  /// 凸起:双向投影 + 对角渐变。
  raised,

  /// 平:仅填充,无起伏。
  flat,

  /// 凹陷:内阴影井(输入框、压下态、开关轨道)。
  pressed,
}

/// 基于超椭圆([RoundedSuperellipseBorder])的新拟物绘制。
/// 光源固定在左上:凸起时左上高光、右下暗部;凹陷时内侧反过来。
class NeuDecoration extends Decoration {
  const NeuDecoration({
    required this.colors,
    this.depth = NeuDepth.raised,
    this.radius = 18,
    this.color,
    this.accent = false,
    this.intensity = 1,
    this.borderColor,
  });

  final NeuColors colors;
  final NeuDepth depth;
  final double radius;

  /// 覆盖默认填充色。
  final Color? color;

  /// 使用主色渐变填充(主要按钮、选中态)。
  final bool accent;

  /// 阴影强度系数(小控件用 0.6~0.8)。
  final double intensity;

  /// 额外描边(如选中描主色)。
  final Color? borderColor;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _NeuPainter(this, onChanged);

  @override
  bool operator ==(Object other) =>
      other is NeuDecoration &&
      other.colors == colors &&
      other.depth == depth &&
      other.radius == radius &&
      other.color == color &&
      other.accent == accent &&
      other.intensity == intensity &&
      other.borderColor == borderColor;

  @override
  int get hashCode =>
      Object.hash(colors, depth, radius, color, accent, intensity, borderColor);
}

class _NeuPainter extends BoxPainter {
  _NeuPainter(this.decoration, super.onChanged);

  final NeuDecoration decoration;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size!;
    final rect = offset & size;
    if (rect.isEmpty) return;

    final c = decoration.colors;
    final radius = decoration.radius.clamp(
      0.0,
      math.min(size.width, size.height) / 2,
    );
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(radius),
    );
    final path = shape.getOuterPath(rect);

    final d = 3.8 * decoration.intensity; // 阴影偏移
    final sigma = d * 1.15; // 阴影模糊:收敛半径,阴影更实、层次更清晰
    final base = decoration.color ?? c.surface;

    switch (decoration.depth) {
      case NeuDepth.raised:
        _outerShadow(canvas, path, Offset(d, d), c.shadowDark, sigma, 0.72);
        // 受光边:高光阴影压得比暗部更锐,读作一条"光",不读作"线"。
        // 不透明度按主题收敛(深色下满强度就是辉光)。
        _outerShadow(
          canvas,
          path,
          Offset(-d, -d),
          c.shadowLight,
          sigma * 0.65,
          c.highlightAlpha,
        );
        _fill(canvas, path, rect, base, convex: true, c: c);
      case NeuDepth.flat:
        _fill(canvas, path, rect, base, convex: false, c: c);
      case NeuDepth.pressed:
        _fill(canvas, path, rect, neuShift(base, -0.012), convex: false, c: c);
        _innerShadow(
          canvas,
          rect,
          path,
          Offset(d * .8, d * .8),
          c.shadowDark.withValues(alpha: .48),
          sigma,
        );
        _innerShadow(
          canvas,
          rect,
          path,
          Offset(-d * .8, -d * .8),
          c.shadowLight.withValues(alpha: c.highlightAlpha),
          sigma * .9,
        );
    }

    if (decoration.borderColor != null) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = decoration.borderColor!,
      );
    }
  }

  void _fill(
    Canvas canvas,
    Path path,
    Rect rect,
    Color base, {
    required bool convex,
    required NeuColors c,
  }) {
    final Gradient? gradient;
    if (decoration.accent) {
      gradient = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [neuShift(c.accent, .08), neuShift(c.accent, -.06)],
      );
    } else if (convex) {
      gradient = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [neuShift(base, .055), neuShift(base, -.05)],
      );
    } else {
      gradient = null;
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = decoration.accent ? c.accent : base
        ..shader = gradient?.createShader(rect),
    );
  }

  void _outerShadow(
    Canvas canvas,
    Path path,
    Offset shift,
    Color color,
    double sigma,
    double opacity,
  ) {
    canvas.drawPath(
      path.shift(shift),
      Paint()
        ..color = color.withValues(alpha: opacity)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma),
    );
  }

  /// 内阴影:绘制"大矩形减本体"的反形并模糊,裁切到本体内部,
  /// 只在内边缘留下渐隐的暗部/高光。
  void _innerShadow(
    Canvas canvas,
    Rect rect,
    Path path,
    Offset shift,
    Color color,
    double sigma,
  ) {
    final inverse = Path.combine(
      PathOperation.difference,
      Path()..addRect(rect.inflate(sigma * 2 + 8)),
      path,
    );
    canvas.save();
    canvas.clipPath(path);
    canvas.drawPath(
      inverse.shift(shift),
      Paint()
        ..color = color
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma),
    );
    canvas.restore();
  }
}
