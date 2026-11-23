import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';

/// Shared expansion progress for Material search and space headers.
class MaterialHeaderTransition extends StatelessWidget {
  const MaterialHeaderTransition({
    super.key,
    required this.collapsed,
    required this.builder,
    this.enabled = true,
    this.child,
    this.onEnd,
  });

  final bool collapsed;
  final bool enabled;
  final ValueWidgetBuilder<double> builder;
  final Widget? child;
  final VoidCallback? onEnd;

  static bool shouldCollapse(
    ScrollMetrics metrics,
    bool collapsed,
    double extent,
  ) => collapsed
      ? metrics.extentBefore > 0
      : metrics.extentBefore >= extent &&
            metrics.maxScrollExtent - metrics.minScrollExtent > extent;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(end: enabled && collapsed ? 0 : 1),
    duration: enabled && !MediaQuery.disableAnimationsOf(context)
        ? context.tokens.motion.layoutDuration
        : Duration.zero,
    curve: Curves.easeInOutCubic,
    onEnd: onEnd,
    builder: builder,
    child: child,
  );
}

class HeaderScrollListener extends StatelessWidget {
  const HeaderScrollListener({
    super.key,
    required this.onScroll,
    required this.child,
  });
  final ValueChanged<ScrollMetrics> onScroll;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollMetricsNotification>(
        onNotification: (n) {
          if (n.depth == 0 && n.metrics.axis == Axis.vertical) {
            onScroll(n.metrics);
          }
          return false;
        },
        child: NotificationListener<ScrollUpdateNotification>(
          onNotification: (n) {
            if (n.depth == 0 && n.metrics.axis == Axis.vertical) {
              onScroll(n.metrics);
            }
            return false;
          },
          child: child,
        ),
      );
}
