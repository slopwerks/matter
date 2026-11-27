import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:material_ui/material_ui.dart';

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
    this.superellipseEnabled = true,
    this.depthProgress,
    this.accentProgress,
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
  final bool superellipseEnabled;
  final double? depthProgress;
  final double? accentProgress;

  double get _accentProgress => accentProgress ?? (accent ? 1 : 0);

  Color get _baseColor => color ?? (accent ? colors.accent : colors.surface);

  double get _depthProgress =>
      depthProgress ??
      switch (depth) {
        NeuDepth.raised => 1,
        NeuDepth.flat => 0,
        NeuDepth.pressed => -1,
      };

  NeuDecoration _lerp(NeuDecoration other, double progress) => NeuDecoration(
    colors: colors.lerp(other.colors, progress),
    depth: progress < .5 ? depth : other.depth,
    depthProgress: lerpDouble(_depthProgress, other._depthProgress, progress),
    radius: lerpDouble(radius, other.radius, progress)!,
    color: Color.lerp(_baseColor, other._baseColor, progress),
    accent: progress < .5 ? accent : other.accent,
    accentProgress: lerpDouble(
      _accentProgress,
      other._accentProgress,
      progress,
    ),
    intensity: lerpDouble(intensity, other.intensity, progress)!,
    borderColor: Color.lerp(borderColor, other.borderColor, progress),
    superellipseEnabled: progress < .5
        ? superellipseEnabled
        : other.superellipseEnabled,
  );

  @override
  Decoration? lerpFrom(Decoration? a, double t) =>
      a is NeuDecoration ? a._lerp(this, t) : super.lerpFrom(a, t);

  @override
  Decoration? lerpTo(Decoration? b, double t) =>
      b is NeuDecoration ? _lerp(b, t) : super.lerpTo(b, t);

  // Let repaint boundaries (including lazy-list rows) raster-cache the blur
  // operations instead of rasterizing both shadows on every scrolling frame.
  @override
  bool get isComplex => !colors.isMaterial && _depthProgress != 0;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _NeuPainter(this, onChanged);

  @override
  bool operator ==(Object other) =>
      other is NeuDecoration &&
      other.colors == colors &&
      other.depth == depth &&
      other.depthProgress == depthProgress &&
      other.accentProgress == accentProgress &&
      other.radius == radius &&
      other.color == color &&
      other.accent == accent &&
      other.intensity == intensity &&
      other.borderColor == borderColor &&
      other.superellipseEnabled == superellipseEnabled;

  @override
  int get hashCode => Object.hash(
    colors,
    depth,
    depthProgress,
    accentProgress,
    radius,
    color,
    accent,
    intensity,
    borderColor,
    superellipseEnabled,
  );
}

class _NeuPainter extends BoxPainter {
  _NeuPainter(this.decoration, super.onChanged);

  final NeuDecoration decoration;
  Size? _size;
  late RSuperellipse _shape;
  late RSuperellipse _darkOuterShadow;
  late RSuperellipse _lightOuterShadow;
  RRect? _roundedShape;
  RRect? _darkOuterRoundedShadow;
  RRect? _lightOuterRoundedShadow;
  late Path _darkShadow;
  late Path _lightShadow;
  late Paint _fillPaint;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size!;
    final rect = Offset.zero & size;
    if (rect.isEmpty) return;

    final c = decoration.colors;
    if (c.isMaterial) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          offset & size,
          Radius.circular(decoration.radius),
        ),
        Paint()..color = decoration._baseColor,
      );
      if (decoration.borderColor case final borderColor?) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            (offset & size).deflate(.6),
            Radius.circular(decoration.radius),
          ),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = borderColor,
        );
      }
      return;
    }
    final strength = decoration._depthProgress.abs();
    final d = 3.8 * decoration.intensity * strength;
    final sigma = d * 1.15;
    if (_size != size) {
      _size = size;
      _prepare(size, rect, c, d, sigma);
    }
    canvas.save();
    canvas.translate(offset.dx, offset.dy);

    switch (decoration._depthProgress) {
      case > 0:
        _drawShape(
          canvas,
          _darkOuterShadow,
          _darkOuterRoundedShadow,
          _shadowPaint(c.shadowDark.withValues(alpha: .72 * strength), sigma),
        );
        _drawShape(
          canvas,
          _lightOuterShadow,
          _lightOuterRoundedShadow,
          _shadowPaint(
            c.shadowLight.withValues(alpha: c.highlightAlpha * strength),
            sigma * .65,
          ),
        );
        _drawShape(canvas, _shape, _roundedShape, _fillPaint);
      case 0:
        _drawShape(canvas, _shape, _roundedShape, _fillPaint);
      default:
        _drawShape(canvas, _shape, _roundedShape, _fillPaint);
        canvas.save();
        if (_roundedShape case final roundedShape?) {
          canvas.clipRRect(roundedShape);
        } else {
          canvas.clipRSuperellipse(_shape);
        }
        _shadow(
          canvas,
          _darkShadow,
          Color.lerp(
            c.shadowDark,
            neuShift(decoration._baseColor, -.12),
            decoration._accentProgress,
          )!.withValues(alpha: .48 * strength),
          sigma,
        );
        _shadow(
          canvas,
          _lightShadow,
          Color.lerp(
            c.shadowLight,
            neuShift(decoration._baseColor, .10),
            decoration._accentProgress,
          )!.withValues(alpha: c.highlightAlpha * strength),
          sigma * .9,
        );
        canvas.restore();
    }

    if (decoration.borderColor != null) {
      _drawShape(
        canvas,
        _shape,
        _roundedShape,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = decoration.borderColor!,
      );
    }
    canvas.restore();
  }

  void _prepare(Size size, Rect rect, NeuColors c, double d, double sigma) {
    final radius = decoration.radius.clamp(
      0.0,
      math.min(size.width, size.height) / 2,
    );
    // Preserve the primitive: converting it to a Path prevents Impeller
    // from using its specialized superellipse blur shader for the shadows.
    _shape = RSuperellipse.fromRectAndRadius(rect, Radius.circular(radius));
    _roundedShape = decoration.superellipseEnabled
        ? null
        : RRect.fromRectAndRadius(rect, Radius.circular(radius));

    final base = decoration._baseColor;

    switch (decoration._depthProgress) {
      case > 0:
        _darkOuterShadow = _shape.shift(Offset(d, d));
        _lightOuterShadow = _shape.shift(Offset(-d, -d));
        _darkOuterRoundedShadow = _roundedShape?.shift(Offset(d, d));
        _lightOuterRoundedShadow = _roundedShape?.shift(Offset(-d, -d));
        _fillPaint = _fill(rect, base, convex: true);
      case 0:
        _fillPaint = _fill(rect, base, convex: false);
      default:
        final path = _roundedShape == null
            ? (Path()..addRSuperellipse(_shape))
            : (Path()..addRRect(_roundedShape!));
        _fillPaint = _fill(
          rect,
          neuShift(
            base,
            -0.012 *
                decoration._depthProgress.abs() *
                (1 - decoration._accentProgress),
          ),
          convex: false,
        );
        _darkShadow = _innerShadow(rect, path, Offset(d * .8, d * .8), sigma);
        _lightShadow = _innerShadow(
          rect,
          path,
          Offset(-d * .8, -d * .8),
          sigma * .9,
        );
    }
  }

  void _drawShape(
    Canvas canvas,
    RSuperellipse superellipse,
    RRect? roundedRect,
    Paint paint,
  ) {
    if (roundedRect != null) {
      canvas.drawRRect(roundedRect, paint);
    } else {
      canvas.drawRSuperellipse(superellipse, paint);
    }
  }

  Paint _fill(Rect rect, Color base, {required bool convex}) {
    final Gradient? gradient;
    final accent = decoration._accentProgress;
    final depth = convex ? decoration._depthProgress : 0.0;
    if (accent > 0 || convex) {
      gradient = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          neuShift(base, lerpDouble(.055 * depth, .08, accent)!),
          neuShift(base, lerpDouble(-.05 * depth, -.06, accent)!),
        ],
      );
    } else {
      gradient = null;
    }
    return Paint()
      ..color = base
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
