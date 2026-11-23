import 'package:material_ui/material_ui.dart';

/// List, timeline and supporting-panel actions share the conversation pane.
class ConversationRoutes extends InheritedWidget {
  const ConversationRoutes({
    super.key,
    required this.navigator,
    required super.child,
  });

  final GlobalKey<NavigatorState> navigator;

  static NavigatorState? of(BuildContext context) => context
      .getInheritedWidgetOfExactType<ConversationRoutes>()
      ?.navigator
      .currentState;

  @override
  bool updateShouldNotify(ConversationRoutes oldWidget) =>
      navigator != oldWidget.navigator;
}

class ConversationRouteObserver extends NavigatorObserver {
  ConversationRouteObserver(this.changed);

  final ValueChanged<bool> changed;

  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    // Initial route is a transparent placeholder above the live timeline.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator != null) changed(navigator!.canPop());
    });
  }
}
