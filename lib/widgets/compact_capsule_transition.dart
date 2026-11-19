import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';

import '../theme/material_theme.dart';
import '../theme/neu_colors.dart';
import '../theme/tokens.dart';

/// The shell swaps the dock and editor synchronously. Capture the outgoing
/// surface before that rebuild, then paint the live destination from its bounds.
class CompactCapsuleTransition extends StatefulWidget {
  const CompactCapsuleTransition({
    super.key,
    required this.enabled,
    required this.chatOpen,
    required this.accountKey,
    required this.child,
  });

  final bool enabled;
  final bool chatOpen;
  final Key? accountKey;
  final Widget child;

  static Widget surface(
    BuildContext context, {
    required bool composer,
    required Widget child,
  }) {
    final motion = context
        .dependOnInheritedWidgetOfExactType<_CapsuleScope>()
        ?.motion;
    return _CapsuleSurface(
      key: composer ? motion?._editorKey : motion?._dockKey,
      motion: motion,
      composer: composer,
      child: child,
    );
  }

  @override
  State<CompactCapsuleTransition> createState() => _CapsuleMotion();
}

class _CapsuleMotion extends State<CompactCapsuleTransition>
    with TickerProviderStateMixin {
  // Each endpoint owns a distinct key so switching never reparents the editor.
  final _dockKey = GlobalKey();
  final _editorKey = GlobalKey();
  late final _space = AnimationController.unbounded(vsync: this, value: 1);
  late final _fade = AnimationController(vsync: this, value: 1);
  late final _ticks = Listenable.merge([_space, _fade]);
  Rect? _origin;
  bool _reduce = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduce = MediaQuery.disableAnimationsOf(context);
    if (_reduce) _finish();
  }

  void _finish() {
    _origin = null;
    _space.value = 1;
    _fade.value = 1;
  }

  @override
  void didUpdateWidget(CompactCapsuleTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled ||
        !oldWidget.enabled ||
        widget.accountKey != oldWidget.accountKey ||
        _reduce) {
      if (_origin != null) _finish();
      return;
    }
    if (oldWidget.chatOpen == widget.chatOpen) return;
    final previous = oldWidget.chatOpen ? _editorKey : _dockKey;
    final box = previous.currentContext?.findRenderObject() as _RenderCapsule?;
    final motion = context.tokens.motion;
    final spring = motion.pressSpring;
    if (box == null || !box.hasSize || box.size.isEmpty || spring == null) {
      _finish();
      return;
    }
    _origin = box.paintedBounds;
    _space.animateWith(SpringSimulation(spring, 0, 1, 0, snapToEnd: true));
    _fade.duration = motion.effectsDuration;
    _fade.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) =>
      _CapsuleScope(motion: this, child: widget.child);

  @override
  void dispose() {
    _space.dispose();
    _fade.dispose();
    super.dispose();
  }
}

class _CapsuleScope extends InheritedWidget {
  const _CapsuleScope({required this.motion, required super.child});
  final _CapsuleMotion motion;
  @override
  bool updateShouldNotify(_CapsuleScope oldWidget) =>
      motion != oldWidget.motion;
}

class _CapsuleSurface extends SingleChildRenderObjectWidget {
  const _CapsuleSurface({
    super.key,
    required this.motion,
    required this.composer,
    required super.child,
  });
  final _CapsuleMotion? motion;
  final bool composer;

  @override
  _RenderCapsule createRenderObject(BuildContext context) {
    final box = _RenderCapsule();
    _configure(context, box);
    return box;
  }

  @override
  void updateRenderObject(BuildContext context, _RenderCapsule renderObject) =>
      _configure(context, renderObject);

  void _configure(BuildContext context, _RenderCapsule box) {
    box.motion = motion;
    box.sourceColor = composer
        ? context.neu.glassFill
        : Theme.of(context).colorScheme.surfaceContainerHigh;
    box.sourceRadius = composer ? 31 : materialComposerRadius.topLeft.x;
    box.targetRadius = composer ? materialComposerRadius.topLeft.x : 31;
    box.markNeedsPaint();
  }
}

class _RenderCapsule extends RenderProxyBox {
  late Color sourceColor;
  late double sourceRadius, targetRadius;
  _CapsuleMotion? _motion;
  set motion(_CapsuleMotion? value) {
    if (value == _motion) return;
    if (attached) _motion?._ticks.removeListener(markNeedsPaint);
    _motion = value;
    if (attached) _motion?._ticks.addListener(markNeedsPaint);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _motion?._ticks.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _motion?._ticks.removeListener(markNeedsPaint);
    super.detach();
  }

  Rect get paintedBounds {
    final target = localToGlobal(Offset.zero) & size;
    final motion = _motion;
    return motion?._origin == null
        ? target
        : Rect.lerp(motion!._origin, target, motion._space.value)!;
  }

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    final motion = _motion;
    if (motion == null ||
        motion._origin == null ||
        (!motion._space.isAnimating && !motion._fade.isAnimating) ||
        size.isEmpty) {
      super.paint(context, offset);
      return;
    }
    final bounds = paintedBounds;
    final delta = globalToLocal(bounds.topLeft);
    final fade = Curves.easeOut.transform(motion._fade.value);
    final radius =
        sourceRadius + (targetRadius - sourceRadius) * motion._space.value;
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(
        (offset + delta) & bounds.size,
        Radius.circular(radius),
      ),
      Paint()
        ..color = sourceColor.withValues(alpha: sourceColor.a * (1 - fade)),
    );
    final transform = Matrix4.translationValues(delta.dx, delta.dy, 0)
      ..scaleByDouble(
        bounds.width / size.width,
        bounds.height / size.height,
        1,
        1,
      );
    context.pushTransform(
      true,
      offset,
      transform,
      (ctx, pos) => ctx.pushOpacity(pos, (255 * fade).round(), super.paint),
    );
  }
}
