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

  // Let repaint boundaries (including lazy-list rows) raster-cache the blur
  // operations instead of rasterizing both shadows on every scrolling frame.
  @override
  bool get isComplex => depth != NeuDepth.flat;

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
  Size? _size;
  static const double _borderWidth = 1.2;

  late RSuperellipse _shape;
  late RSuperellipse _fillShape;
  late RSuperellipse _darkOuterShadow;
  late RSuperellipse _lightOuterShadow;
  late Path _darkShadow;
  late Path _lightShadow;
  late Paint _fillPaint;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size!;
    final rect = Offset.zero & size;
    if (rect.isEmpty) return;

    final c = decoration.colors;
    final d = 3.8 * decoration.intensity;
    final sigma = d * 1.15;
    if (_size != size) {
      _size = size;
      _prepare(size, rect, c, d, sigma);
    }
    canvas.save();
    canvas.translate(offset.dx, offset.dy);

    switch (decoration.depth) {
      case NeuDepth.raised:
        canvas.drawRSuperellipse(
          _darkOuterShadow,
          _shadowPaint(c.shadowDark.withValues(alpha: .72), sigma),
        );
        canvas.drawRSuperellipse(
          _lightOuterShadow,
          _shadowPaint(
            c.shadowLight.withValues(alpha: c.highlightAlpha),
            sigma * .65,
          ),
        );
        _paintBody(canvas);
      case NeuDepth.flat:
        _paintBody(canvas);
      case NeuDepth.pressed:
        _paintBody(canvas);
        canvas.save();
        canvas.clipRSuperellipse(_fillShape);
        _shadow(
          canvas,
          _darkShadow,
          c.shadowDark.withValues(alpha: .48),
          sigma,
        );
        _shadow(
          canvas,
          _lightShadow,
          c.shadowLight.withValues(alpha: c.highlightAlpha),
          sigma * .9,
        );
        canvas.restore();
    }

    canvas.restore();
  }

  void _paintBody(Canvas canvas) {
    final borderColor = decoration.borderColor;
    if (borderColor != null) {
      // Impeller does not anti-alias RSuperellipse strokes on some platforms
      // (e.g. desktop GLES without MSAA), but fills are smooth everywhere —
      // paint the border as a full-size fill covered by the deflated body.
      canvas.drawRSuperellipse(_shape, Paint()..color = borderColor);
    }
    canvas.drawRSuperellipse(_fillShape, _fillPaint);
  }

  void _prepare(Size size, Rect rect, NeuColors c, double d, double sigma) {
    final radius = decoration.radius.clamp(
      0.0,
      math.min(size.width, size.height) / 2,
    );
    // Preserve the primitive: converting it to a Path prevents Impeller
    // from using its specialized superellipse blur shader for the shadows.
    _shape = RSuperellipse.fromRectAndRadius(rect, Radius.circular(radius));
    _fillShape = decoration.borderColor != null
        ? RSuperellipse.fromRectAndRadius(
            rect.deflate(_borderWidth),
            Radius.circular(radius),
          )
        : _shape;

    final base = decoration.color ?? c.surface;

    switch (decoration.depth) {
      case NeuDepth.raised:
        _darkOuterShadow = _shape.shift(Offset(d, d));
        _lightOuterShadow = _shape.shift(Offset(-d, -d));
        _fillPaint = _fill(rect, base, convex: true, c: c);
      case NeuDepth.flat:
        _fillPaint = _fill(rect, base, convex: false, c: c);
      case NeuDepth.pressed:
        final path = Path()..addRSuperellipse(_shape);
        _fillPaint = _fill(rect, neuShift(base, -0.012), convex: false, c: c);
        _darkShadow = _innerShadow(rect, path, Offset(d * .8, d * .8), sigma);
        _lightShadow = _innerShadow(
          rect,
          path,
          Offset(-d * .8, -d * .8),
          sigma * .9,
        );
    }
  }

  Paint _fill(
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
    return Paint()
      ..color = decoration.accent ? c.accent : base
      ..shader = gradient?.createShader(rect);
  }

  void _shadow(Canvas canvas, Path path, Color color, double sigma) {
    canvas.drawPath(path, _shadowPaint(color, sigma));
  }

  Paint _shadowPaint(Color color, double sigma) => Paint()
    ..color = color
    ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma);

  /// 内阴影:绘制"大矩形减本体"的反形并模糊,裁切到本体内部,
  /// 只在内边缘留下渐隐的暗部/高光。
  Path _innerShadow(Rect rect, Path path, Offset shift, double sigma) {
    final inverse = Path.combine(
      PathOperation.difference,
      Path()..addRect(rect.inflate(sigma * 2 + 8)),
      path,
    );
    return inverse.shift(shift);
  }
}
