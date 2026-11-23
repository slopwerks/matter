import 'package:flutter/material.dart';

/// Secondary routes in split panes fade in place, keeping the list anchored.
class PaneFadeTransitions extends PageTransitionsBuilder {
  const PaneFadeTransitions();

  static final theme = PageTransitionsTheme(
    builders: {
      for (final platform in TargetPlatform.values)
        platform: const PaneFadeTransitions(),
    },
  );

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return FadeTransition(
      opacity: animation.drive(CurveTween(curve: Curves.easeOut)),
      child: child,
    );
  }
}
