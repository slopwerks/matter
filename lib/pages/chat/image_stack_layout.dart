import 'dart:math' as math;
import 'dart:ui';

class ImageStackLayer {
  final Rect rect;
  final Rect paintBounds;
  final double rotation;
  final double opacity;

  const ImageStackLayer({
    required this.rect,
    required this.paintBounds,
    required this.rotation,
    required this.opacity,
  });
}

class ImageStackLayout {
  final Size size;
  final double scale;
  final List<ImageStackLayer> layers;

  const ImageStackLayout(this.size, this.scale, this.layers);
}

/// WeChat-style downward stacked card geometry: the front card stays flush at
/// the top edge while up to two backing layers step straight downward behind it.
ImageStackLayout imageStackLayout(
  int count,
  double maxWidth, {
  double aspectRatio = 1.5,
}) {
  const baseWidth = 270.0;
  const peekStep = 8.0;
  final clampedAspect = aspectRatio.clamp(.5, 2.0).toDouble();
  final baseHeight = (baseWidth / clampedAspect)
      .clamp(baseWidth * .5, 240.0)
      .toDouble();
  final layerCount = math.min(count, 3);
  final rawHeight = baseHeight + peekStep * math.max(0, layerCount - 1);
  final scale = math.min(1.0, maxWidth / baseWidth);
  final layers = <ImageStackLayer>[];
  for (var depth = 0; depth < layerCount; depth++) {
    final layerScale = math.pow(.94, depth).toDouble();
    final cardWidth = baseWidth * layerScale;
    final cardHeight = baseHeight * layerScale;
    final cardBottom = baseHeight + peekStep * depth;
    final cardLeft = (baseWidth - cardWidth) / 2;
    final cardTop = math.max(0.0, cardBottom - cardHeight);
    final rect = Rect.fromLTWH(
      cardLeft * scale,
      cardTop * scale,
      cardWidth * scale,
      (cardBottom - cardTop) * scale,
    );
    layers.add(
      ImageStackLayer(
        rect: rect,
        paintBounds: rect,
        rotation: 0,
        opacity: math.pow(.92, depth).toDouble(),
      ),
    );
  }
  return ImageStackLayout(
    Size(baseWidth * scale, rawHeight * scale),
    scale,
    layers,
  );
}
