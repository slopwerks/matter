import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';

/// Swells the whole control, including its fill, while its own recognizer owns
/// the press. Layout and popup anchors stay at rest. The controller also hears
/// keyboard activation, disabled states and presses cancelled by scrolling.
class MaterialPress extends StatefulWidget {
  const MaterialPress({super.key, required this.builder, this.maxGrowth = 6});

  final Widget Function(WidgetStatesController states) builder;
  final double maxGrowth;

  static const feedbackStyle = ButtonStyle(
    splashFactory: NoSplash.splashFactory,
    overlayColor: WidgetStateProperty<Color?>.fromMap({
      WidgetState.pressed: Colors.transparent,
    }),
  );

  @override
  State<MaterialPress> createState() => _MaterialPressState();
}

class _MaterialPressState extends State<MaterialPress>
    with SingleTickerProviderStateMixin {
  static final _spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 500,
    ratio: .78,
  );
  final _states = WidgetStatesController();
  late final _lift = AnimationController.unbounded(vsync: this);
  bool _releasePending = false;
  bool _pressed = false;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _states.addListener(_updatePress);
    _lift.addListener(_settle);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) _reset();
  }

  void _reset() {
    _releasePending = false;
    _lift.stop();
    _lift.value = 0;
  }

  void _springTo(double target) {
    _lift.animateWith(
      SpringSimulation(
        _spring,
        _lift.value,
        target,
        _lift.velocity,
        snapToEnd: true,
      ),
    );
  }

  void _updatePress() {
    final pressed = _states.value.contains(WidgetState.pressed);
    if (_reduceMotion || _states.value.contains(WidgetState.disabled)) {
      _pressed = false;
      _reset();
      return;
    }
    if (pressed == _pressed) return;
    _pressed = pressed;
    if (pressed) {
      _releasePending = false;
      _springTo(1);
    } else if (_lift.isAnimating || _lift.value != 0) {
      // A quick tap still rises far enough to be seen before it springs home.
      _releasePending = true;
      _settle();
    }
  }

  void _settle() {
    if (!_releasePending || _lift.value < .8) return;
    _releasePending = false;
    _springTo(0);
  }

  @override
  void dispose() {
    _states.removeListener(_updatePress);
    _states.dispose();
    _lift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _PressPaint(
    lift: _lift,
    maxGrowth: widget.maxGrowth,
    child: widget.builder(_states),
  );
}

class _PressPaint extends SingleChildRenderObjectWidget {
  const _PressPaint({
    required this.lift,
    required this.maxGrowth,
    required super.child,
  });

  final Animation<double> lift;
  final double maxGrowth;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPressPaint(lift, maxGrowth);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderPressPaint renderObject,
  ) {
    renderObject.maxGrowth = maxGrowth;
  }
}

class _RenderPressPaint extends RenderProxyBox {
  _RenderPressPaint(this.lift, this._maxGrowth);

  final Animation<double> lift;
  double _maxGrowth;

  set maxGrowth(double value) {
    if (_maxGrowth == value) return;
    _maxGrowth = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    lift.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    lift.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty || lift.value == 0) {
      layer = null;
      super.paint(context, offset);
      return;
    }
    final scale = 1 + math.min(.12, _maxGrowth / size.longestSide) * lift.value;
    final transform = Matrix4.diagonal3Values(scale, scale, 1)
      ..setTranslationRaw(
        size.width * (1 - scale) / 2,
        size.height * (1 - scale) / 2,
        0,
      );
    layer = context.pushTransform(
      needsCompositing,
      offset,
      transform,
      super.paint,
      oldLayer: layer is TransformLayer ? layer as TransformLayer : null,
    );
  }
}
