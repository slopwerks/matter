import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Rasterize the entire page, including its backdrop filters, for a short
/// transition. Unsupported platform/texture views continue painting live.
class PageSnapshot extends StatelessWidget {
  const PageSnapshot({
    super.key,
    required this.controller,
    required this.child,
  });

  final SnapshotController controller;
  final Widget child;

  static BuildContext? paintOriginOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_SnapshotOrigin>();
    return scope?.notifier?.allowSnapshotting == true ? scope!.origin : null;
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return RepaintBoundary(child: child);
    return SnapshotWidget(
      controller: controller,
      mode: SnapshotMode.permissive,
      autoresize: true,
      child: Builder(
        builder: (context) => _SnapshotOrigin(
          controller: controller,
          origin: context,
          child: RepaintBoundary(child: child),
        ),
      ),
    );
  }
}

// SnapshotWidget paints into a page-local image. Shader coordinates must use
// that origin, not the animated page's position in the window.
class _SnapshotOrigin extends InheritedNotifier<SnapshotController> {
  const _SnapshotOrigin({
    required SnapshotController controller,
    required this.origin,
    required super.child,
  }) : super(notifier: controller);

  final BuildContext origin;
}

class RouteSnapshot extends StatefulWidget {
  const RouteSnapshot({
    super.key,
    required this.animation,
    required this.secondaryAnimation,
    required this.enabled,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final bool enabled;
  final Widget child;

  @override
  State<RouteSnapshot> createState() => _RouteSnapshotState();
}

class _RouteSnapshotState extends State<RouteSnapshot> {
  final _controller = SnapshotController();

  void _update([AnimationStatus? status]) {
    _controller.allowSnapshotting =
        !kIsWeb &&
        widget.enabled &&
        (widget.animation.status.isAnimating ||
            widget.secondaryAnimation.status.isAnimating);
  }

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_update);
    widget.secondaryAnimation.addStatusListener(_update);
    _update();
  }

  @override
  void didUpdateWidget(RouteSnapshot oldWidget) {
    super.didUpdateWidget(oldWidget);
    oldWidget.animation.removeStatusListener(_update);
    oldWidget.secondaryAnimation.removeStatusListener(_update);
    widget.animation.addStatusListener(_update);
    widget.secondaryAnimation.addStatusListener(_update);
    _update();
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_update);
    widget.secondaryAnimation.removeStatusListener(_update);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      PageSnapshot(controller: _controller, child: widget.child);
}
