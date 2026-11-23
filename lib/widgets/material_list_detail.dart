import 'package:material_ui/material_ui.dart';

import 'material_adaptive_shell.dart';
import 'conversation_routes.dart';
import 'chat_route_scope.dart';
import 'max_content_width.dart';
import 'pane_transitions.dart';

/// Secondary destinations retain one list and one route stack across resizing.
class MaterialListDetail extends StatefulWidget {
  const MaterialListDetail({
    super.key,
    required this.list,
    required this.emptyLabel,
    required this.emptyIcon,
    this.active = true,
  });

  final Widget list;
  final String emptyLabel;
  final IconData emptyIcon;
  final bool active;

  static Future<T?> push<T>(BuildContext context, Route<T> route) {
    final host = context.findAncestorStateOfType<_MaterialListDetailState>();
    if (host == null) {
      final navigator = ConversationRoutes.of(context) ?? Navigator.of(context);
      return navigator.push(route);
    }
    if (Navigator.of(context) == host._navigator.currentState) {
      return host._navigator.currentState!.push(route);
    }
    return host._navigator.currentState!.pushAndRemoveUntil(
      route,
      (previous) => previous.isFirst,
    );
  }

  @override
  State<MaterialListDetail> createState() => _MaterialListDetailState();
}

class _MaterialListDetailState extends State<MaterialListDetail> {
  final _navigator = GlobalKey<NavigatorState>();
  final _chatObserver = ChatRouteObserver();
  late final _observer = _DetailObserver(_routesChanged);
  bool _hasDetail = false;

  void _routesChanged() {
    // Navigator reports its initial route while the widget tree is building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final visible = _navigator.currentState?.canPop() ?? false;
      if (visible == _hasDetail) return;
      setState(() => _hasDetail = visible);
      MaterialDetailVisibility(visible).dispatch(context);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) {
    final window = MaterialAdaptiveShell.windowOf(context)!;
    final theme = Theme.of(context);
    final split = window.hasSplit;
    final showDetail = split || _hasDetail;
    return LayoutBuilder(
      builder: (context, constraints) {
        final listWidth = split ? window.listWidth : constraints.maxWidth;
        return Stack(
          children: [
            PositionedDirectional(
              start: 0,
              top: 0,
              bottom: 0,
              width: listWidth,
              child: ExcludeSemantics(
                excluding: !split && _hasDetail,
                child: IgnorePointer(
                  ignoring: !split && _hasDetail,
                  child: TickerMode(
                    enabled: split || !_hasDetail,
                    child: ExcludeFocus(
                      excluding: !split && _hasDetail,
                      child: MaxContentWidth(child: widget.list),
                    ),
                  ),
                ),
              ),
            ),
            if (split)
              PositionedDirectional(
                start: listWidth,
                width: 1,
                top: 0,
                bottom: 0,
                child: const VerticalDivider(width: 1),
              ),
            PositionedDirectional(
              start: split ? listWidth + 1 : 0,
              end: 0,
              top: 0,
              bottom: 0,
              child: Offstage(
                offstage: !showDetail,
                child: TickerMode(
                  enabled: showDetail,
                  child: ExcludeFocus(
                    excluding: !showDetail,
                    child: LayoutBuilder(
                      builder: (context, pane) => MediaQuery(
                        data: MediaQuery.of(context)
                            .copyWith(size: pane.biggest),
                        child: PopScope<Object?>(
                          canPop: !widget.active || !_hasDetail,
                          onPopInvokedWithResult: (didPop, result) {
                            if (didPop || !widget.active || !_hasDetail) return;
                            final navigator = _navigator.currentState!;
                            if (navigator.canPop()) navigator.maybePop(result);
                          },
                          child: Theme(
                            data: theme.copyWith(
                              pageTransitionsTheme: split
                                  ? PaneFadeTransitions.theme
                                  : PageTransitionsTheme(
                                      builders: {
                                        for (final platform
                                            in TargetPlatform.values)
                                          platform:
                                              platform == TargetPlatform.iOS
                                              ? theme
                                                    .pageTransitionsTheme
                                                    .builders[platform]!
                                              : const _DetailPageTransitionsBuilder(),
                                      },
                                    ),
                            ),
                            child: ChatRouteScope(
                              observer: _chatObserver,
                              active: widget.active,
                              ancestors: ChatRouteScope.routesOf(context),
                              child: Navigator(
                                key: _navigator,
                                observers: [_observer, _chatObserver],
                                onGenerateRoute: (_) => MaterialPageRoute<void>(
                                  builder: (context) =>
                                      !MaterialAdaptiveShell.windowOf(context)!
                                          .hasSplit
                                      ? const SizedBox.expand()
                                      : Scaffold(
                                          body: Center(
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(
                                                  widget.emptyIcon,
                                                  size: 48,
                                                ),
                                                const SizedBox(height: 16),
                                                Text(widget.emptyLabel),
                                              ],
                                            ),
                                          ),
                                        ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Keep the retained list visible throughout the detail's entrance and exit.
class _DetailPageTransitionsBuilder extends PageTransitionsBuilder {
  const _DetailPageTransitionsBuilder();

  @override
  Duration get transitionDuration => const Duration(milliseconds: 240);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 240);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final progress = animation.drive(CurveTween(curve: Curves.easeOutCubic));
    return FadeTransition(
      opacity: progress,
      child: SlideTransition(
        position: progress.drive(
          Tween(begin: const Offset(.04, 0), end: Offset.zero),
        ),
        textDirection: Directionality.of(context),
        child: child,
      ),
    );
  }
}

class _DetailObserver extends NavigatorObserver {
  _DetailObserver(this.onChanged);
  final VoidCallback onChanged;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      onChanged();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is TransitionRoute<dynamic>) {
      route.completed.then((_) => onChanged());
    } else {
      onChanged();
    }
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      onChanged();
}
