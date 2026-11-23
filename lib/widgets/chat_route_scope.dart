import 'package:flutter/material.dart';

final chatRouteObserver = ChatRouteObserver();

class ChatRouteObserver extends RouteObserver<ModalRoute<dynamic>> {
  final _coveringRoutes = <ModalRoute<dynamic>, Route<dynamic>>{};

  bool isCoveredByPopup(ModalRoute<dynamic>? route) =>
      route != null && _coveringRoutes[route] is PopupRoute<dynamic>;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute case final ModalRoute<dynamic> previousModalRoute) {
      _coveringRoutes[previousModalRoute] = route;
    }
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _forgetRoute(route);
    super.didPop(route, previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _forgetRoute(route);
    super.didRemove(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) {
      final coveringRoute = _coveringRoutes.remove(oldRoute);
      if (newRoute case final ModalRoute<dynamic> newModalRoute) {
        if (coveringRoute != null) {
          _coveringRoutes[newModalRoute] = coveringRoute;
        }
      }
      for (final entry in _coveringRoutes.entries.toList()) {
        if (identical(entry.value, oldRoute)) {
          if (newRoute == null) {
            _coveringRoutes.remove(entry.key);
          } else {
            _coveringRoutes[entry.key] = newRoute;
          }
        }
      }
    }
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }

  void _forgetRoute(Route<dynamic> route) {
    _coveringRoutes.remove(route);
    _coveringRoutes.removeWhere((_, covering) => identical(covering, route));
  }
}

/// The observer belongs to this Navigator; active belongs to its retained tab.
class ChatRouteScope extends InheritedWidget {
  const ChatRouteScope({
    super.key,
    required this.observer,
    required this.active,
    required this.ancestors,
    required super.child,
  });

  final ChatRouteObserver observer;
  final bool active;
  final List<({ChatRouteObserver observer, ModalRoute<dynamic> route})>
  ancestors;

  static List<({ChatRouteObserver observer, ModalRoute<dynamic> route})>
  routesOf(BuildContext context) {
    final scope = of(context);
    final route = ModalRoute.of(context);
    return [
      ...?scope?.ancestors,
      if (route != null)
        (observer: scope?.observer ?? chatRouteObserver, route: route),
    ];
  }

  static ChatRouteScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatRouteScope>();

  @override
  bool updateShouldNotify(ChatRouteScope oldWidget) =>
      observer != oldWidget.observer ||
      active != oldWidget.active ||
      ancestors != oldWidget.ancestors;
}
