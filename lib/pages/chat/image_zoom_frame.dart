import 'package:flutter/material.dart';

/// Image gestures adapted from the original viewer in commit 98469ca.
class ZoomableImageFrame extends StatefulWidget {
  final Widget child;
  final bool active;
  final ValueChanged<bool> onZoomChanged;

  const ZoomableImageFrame({
    super.key,
    required this.child,
    required this.active,
    required this.onZoomChanged,
  });

  @override
  State<ZoomableImageFrame> createState() => _ZoomableImageFrameState();
}

class _ZoomableImageFrameState extends State<ZoomableImageFrame>
    with SingleTickerProviderStateMixin {
  static const _zoomLevels = [2.0, 4.0];
  final _transform = TransformationController();
  late final _zoomController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  late Animation<Matrix4> _zoomAnimation = ConstantTween(Matrix4.identity())
      .animate(_zoomController);
  Offset? _doubleTapPosition;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _zoomController.addListener(() {
      _transform.value = _zoomAnimation.value;
    });
    _transform.addListener(_handleTransform);
  }

  @override
  void didUpdateWidget(covariant ZoomableImageFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) {
      _zoomController.stop();
      _transform.value = Matrix4.identity();
    }
  }

  void _handleTransform() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed == _zoomed) return;
    setState(() => _zoomed = zoomed);
    widget.onZoomChanged(zoomed);
  }

  @override
  void dispose() {
    _zoomController.dispose();
    _transform.dispose();
    super.dispose();
  }

  void _doubleTap() {
    final tapped = _doubleTapPosition;
    final current = _transform.value.getMaxScaleOnAxis();
    final double targetScale;
    if (current < _zoomLevels.first - .1) {
      targetScale = _zoomLevels.first;
    } else if (current < _zoomLevels.last - .1) {
      targetScale = _zoomLevels.last;
    } else {
      targetScale = 1;
    }
    final Matrix4 target;
    if (targetScale == 1 || tapped == null) {
      target = Matrix4.identity();
    } else {
      final scenePoint = _transform.toScene(tapped);
      target = Matrix4.identity()
        ..translateByDouble(tapped.dx, tapped.dy, 0, 1)
        ..scaleByDouble(targetScale, targetScale, targetScale, 1)
        ..translateByDouble(-scenePoint.dx, -scenePoint.dy, 0, 1);
    }
    _zoomAnimation = Matrix4Tween(begin: _transform.value, end: target).animate(
      CurvedAnimation(parent: _zoomController, curve: Curves.easeOutCubic),
    );
    _zoomController.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onDoubleTapDown: (details) => _doubleTapPosition = details.localPosition,
    onDoubleTap: _doubleTap,
    child: InteractiveViewer(
      transformationController: _transform,
      minScale: 1,
      maxScale: _zoomLevels.last,
      clipBehavior: Clip.none,
      panEnabled: _zoomed,
      onInteractionStart: (_) => _zoomController.stop(),
      child: widget.child,
    ),
  );
}

class DismissibleImageGallery extends StatefulWidget {
  final Widget child;
  final bool enabled;
  final VoidCallback onClose;

  const DismissibleImageGallery({
    super.key,
    required this.child,
    required this.enabled,
    required this.onClose,
  });

  @override
  State<DismissibleImageGallery> createState() =>
      _DismissibleImageGalleryState();
}

class _DismissibleImageGalleryState extends State<DismissibleImageGallery>
    with SingleTickerProviderStateMixin {
  double _dragY = 0;
  late final _settleController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  Animation<double>? _settleAnimation;

  @override
  void initState() {
    super.initState();
    _settleController.addListener(() {
      final animation = _settleAnimation;
      if (animation != null) setState(() => _dragY = animation.value);
    });
  }

  @override
  void dispose() {
    _settleController.dispose();
    super.dispose();
  }

  void _settle() {
    _settleAnimation = Tween<double>(begin: _dragY, end: 0).animate(
      CurvedAnimation(parent: _settleController, curve: Curves.easeOutCubic),
    );
    _settleController.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final progress = (_dragY.abs() / (MediaQuery.sizeOf(context).height * .45))
        .clamp(0.0, 1.0);
    return GestureDetector(
      onVerticalDragStart: widget.enabled
          ? (_) => _settleController.stop()
          : null,
      onVerticalDragUpdate: widget.enabled
          ? (details) => setState(() => _dragY += details.delta.dy)
          : null,
      onVerticalDragEnd: widget.enabled
          ? (details) {
              if (_dragY.abs() > 140 ||
                  (details.primaryVelocity ?? 0).abs() > 800) {
                widget.onClose();
              } else {
                _settle();
              }
            }
          : null,
      onVerticalDragCancel: widget.enabled ? _settle : null,
      child: Transform.translate(
        offset: Offset(0, _dragY),
        child: Transform.scale(scale: 1 - progress * .15, child: widget.child),
      ),
    );
  }
}
