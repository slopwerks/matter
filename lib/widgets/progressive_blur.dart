import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'page_snapshot.dart';

/// Downsampled variable-radius Gaussian blur for the app's vertical edge fades.
/// The caller supplies a clip and the fallback for non-Impeller backends.
class ProgressiveBlur extends StatelessWidget {
  const ProgressiveBlur({
    super.key,
    required this.sigma,
    required this.bottom,
    required this.inactiveFraction,
    this.backdropGroupKey,
    required this.fallback,
  });

  final double sigma;
  final bool bottom;
  final double inactiveFraction;
  final BackdropKey? backdropGroupKey;
  final Widget fallback;

  static final _program = _loadProgram();
  static ui.FragmentProgram? _loadedProgram;

  static Future<ui.FragmentProgram> _loadProgram() async {
    try {
      return _loadedProgram = await ui.FragmentProgram.fromAsset(
        'shaders/progressive_blur.frag',
      );
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'progressive blur',
          context: ErrorDescription('loading the edge blur shader'),
        ),
      );
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (sigma <= 0 || inactiveFraction >= 1) {
      return const SizedBox.expand();
    }
    if (!ui.ImageFilter.isShaderFilterSupported) return fallback;
    return FutureBuilder<ui.FragmentProgram>(
      future: _loadedProgram == null
          ? _program
          : SynchronousFuture(_loadedProgram!),
      builder: (context, snapshot) {
        final program = snapshot.data;
        if (program == null) return fallback;
        return ClipRect(
          clipper: _ActiveBlurClip(bottom, inactiveFraction),
          child: _BlurFilter(
            program: program,
            sigma: sigma,
            bottom: bottom,
            inactiveFraction: inactiveFraction,
            backdropGroupKey: backdropGroupKey,
            devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
            snapshotOrigin: PageSnapshot.paintOriginOf(context),
          ),
        );
      },
    );
  }
}

// Exclude the reading area from the entire downsampling/filtering pipeline.
class _ActiveBlurClip extends CustomClipper<Rect> {
  const _ActiveBlurClip(this.bottom, this.inactiveFraction);

  final bool bottom;
  final double inactiveFraction;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(
    0,
    bottom ? size.height * inactiveFraction : 0,
    size.width,
    size.height * (1 - inactiveFraction),
  );

  @override
  bool shouldReclip(_ActiveBlurClip oldClipper) =>
      bottom != oldClipper.bottom ||
      inactiveFraction != oldClipper.inactiveFraction;
}

class _BlurFilter extends LeafRenderObjectWidget {
  const _BlurFilter({
    required this.program,
    required this.sigma,
    required this.bottom,
    required this.inactiveFraction,
    required this.backdropGroupKey,
    required this.devicePixelRatio,
    required this.snapshotOrigin,
  });

  final ui.FragmentProgram program;
  final double sigma;
  final bool bottom;
  final double inactiveFraction;
  final BackdropKey? backdropGroupKey;
  final double devicePixelRatio;
  final BuildContext? snapshotOrigin;

  @override
  _RenderBlurFilter createRenderObject(BuildContext context) =>
      _RenderBlurFilter(this);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderBlurFilter renderObject,
  ) {
    if (renderObject.settings.sigma == sigma &&
        renderObject.settings.bottom == bottom &&
        renderObject.settings.inactiveFraction == inactiveFraction &&
        renderObject.settings.backdropGroupKey == backdropGroupKey &&
        renderObject.settings.devicePixelRatio == devicePixelRatio &&
        renderObject.settings.snapshotOrigin == snapshotOrigin) {
      return;
    }
    renderObject.settings = this;
    renderObject.markNeedsPaint();
  }
}

class _RenderBlurFilter extends RenderBox {
  _RenderBlurFilter(this.settings)
    : _downsample = settings.program.fragmentShader(),
      _horizontal = settings.program.fragmentShader(),
      _vertical = settings.program.fragmentShader();

  _BlurFilter settings;
  final ui.FragmentShader _downsample;
  final ui.FragmentShader _horizontal;
  final ui.FragmentShader _vertical;
  static final _halfSize = ui.ImageFilter.matrix(
    Matrix4.diagonal3Values(0.5, 0.5, 1).storage,
    filterQuality: ui.FilterQuality.low,
  );
  static final _fullSize = ui.ImageFilter.matrix(
    Matrix4.diagonal3Values(4, 4, 1).storage,
    filterQuality: ui.FilterQuality.low,
  );
  ui.ImageFilter? _filter;
  (Rect, double, double, bool, double)? _filterInputs;

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performResize() {
    size = computeDryLayout(constraints);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) return;
    // Resolve during paint so keyboard/layout movement cannot leave stale
    // shader coordinates from a previous frame. Backdrop textures use physical
    // screen coordinates, unlike the local logical bounds of this render box.
    final dpr = settings.devicePixelRatio;
    final transform = getTransformTo(
      settings.snapshotOrigin?.findRenderObject(),
    );
    final bounds = MatrixUtils.transformRect(transform, Offset.zero & size);
    final inputs = (
      bounds,
      dpr,
      settings.sigma,
      settings.bottom,
      settings.inactiveFraction,
    );
    if (_filterInputs != inputs) {
      _filter = _createFilter(bounds, dpr);
      _filterInputs = inputs;
    }
    final backdropLayer =
        (layer as BackdropFilterLayer?) ?? BackdropFilterLayer();
    backdropLayer
      ..filter = _filter
      ..blendMode = ui.BlendMode.srcOver
      ..backdropKey = settings.backdropGroupKey;
    layer = backdropLayer;
    context.pushLayer(backdropLayer, (context, offset) {
      context.canvas.drawRect(
        offset & size,
        Paint()..color = const Color(0x00000000),
      );
    }, offset);
  }

  ui.ImageFilter _createFilter(Rect bounds, double dpr) {
    const scale = 0.25;
    for (final shader in [_downsample, _horizontal, _vertical]) {
      final passScale = shader == _downsample ? 0.5 : scale;
      shader
        ..setFloat(2, bounds.left * dpr * passScale)
        ..setFloat(3, bounds.top * dpr * passScale)
        ..setFloat(4, bounds.width * dpr * passScale)
        ..setFloat(5, bounds.height * dpr * passScale)
        ..setFloat(6, shader == _horizontal ? 1 : 0)
        ..setFloat(7, shader == _vertical ? 1 : 0)
        ..setFloat(8, shader == _downsample ? 0 : settings.sigma * dpr * scale)
        ..setFloat(9, settings.bottom ? 1 : 0)
        ..setFloat(10, settings.inactiveFraction);
    }
    // Two separate 2x reductions preserve fine detail. One 4x bilinear
    // reduction can miss entire 1px lines. The intermediate shader forces the
    // first reduction to materialize instead of collapsing both matrices.
    var filter = ui.ImageFilter.compose(
      outer: ui.ImageFilter.shader(_downsample),
      inner: _halfSize,
    );
    filter = ui.ImageFilter.compose(outer: _halfSize, inner: filter);
    filter = ui.ImageFilter.compose(
      outer: ui.ImageFilter.shader(_horizontal),
      inner: filter,
    );
    filter = ui.ImageFilter.compose(
      outer: ui.ImageFilter.shader(_vertical),
      inner: filter,
    );
    filter = ui.ImageFilter.compose(outer: _fullSize, inner: filter);
    return filter;
  }

  @override
  void dispose() {
    layer = null;
    _filter = null;
    _downsample.dispose();
    _horizontal.dispose();
    _vertical.dispose();
    super.dispose();
  }
}
