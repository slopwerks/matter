import 'package:material_ui/material_ui.dart';

import 'chat_route_scope.dart';
import 'pane_transitions.dart';

/// A state-selected conversation still needs a real route for Android's native
/// predictive back transition. Keep this navigator mounted across pane changes.
class SelectedChatNavigator extends StatefulWidget {
  const SelectedChatNavigator({
    super.key,
    required this.roomId,
    required this.list,
    required this.detail,
    required this.onChatPopped,
    this.active = true,
    this.canPop = true,
    this.split = false,
  });

  final String? roomId;
  final Widget list;
  final Widget detail;
  final VoidCallback onChatPopped;
  final bool active;
  final bool canPop;
  final bool split;

  @override
  State<SelectedChatNavigator> createState() => _SelectedChatNavigatorState();
}

class _SelectedChatNavigatorState extends State<SelectedChatNavigator> {
  final _navigator = GlobalKey<NavigatorState>();
  final _observer = ChatRouteObserver();

  @override
  Widget build(
    BuildContext context,
  ) => NotificationListener<NavigationNotification>(
    onNotification: (_) => true,
    child: NavigatorPopHandler<Object?>(
      enabled: widget.active && widget.roomId != null,
      onPopWithResult: (result) {
        if (widget.active && widget.roomId != null) {
          _navigator.currentState!.maybePop(result);
        }
      },
      child: ChatRouteScope(
        observer: _observer,
        active: widget.active,
        ancestors: ChatRouteScope.routesOf(context),
        child: Navigator(
          key: _navigator,
          observers: [_observer],
          pages: [
            _ChatPage(
              split: widget.split,
              isDetail: false,
              key: const ValueKey('conversation-list-route'),
              child: widget.list,
            ),
            if (widget.roomId != null || widget.split)
              _ChatPage(
                split: widget.split,
                key: ValueKey(widget.roomId ?? 'empty-chat'),
                child: PopScope<Object?>(
                  canPop: widget.active && widget.canPop,
                  onPopInvokedWithResult: (didPop, _) {
                    if (didPop && widget.roomId != null) widget.onChatPopped();
                  },
                  child: widget.detail,
                ),
              ),
          ],
          onDidRemovePage: (page) {
            // Selection is synchronized by the route's successful-pop callback.
            // Declarative removals (room switches/resizes) must not clear it.
          },
        ),
      ),
    ),
  );
}

// The split route must let the retained list paint beside the detail. Keeping
// the same Page type/key retains chat state when the window crosses 840 dp.
class _ChatPage extends MaterialPage<void> {
  const _ChatPage({
    required this.split,
    this.isDetail = true,
    required super.key,
    required super.child,
  });
  final bool split;
  final bool isDetail;

  @override
  Route<void> createRoute(BuildContext context) => _ChatRoute(this);
}

class _ChatRoute extends PageRoute<void>
    with MaterialRouteTransitionMixin<void> {
  _ChatRoute(_ChatPage page) : super(settings: page);

  @override
  bool get maintainState => true;

  @override
  Widget buildModalBarrier() =>
      page.split ? const SizedBox.shrink() : super.buildModalBarrier();

  @override
  void changedInternalState() {
    super.changedInternalState();
    if (overlayEntries.isNotEmpty &&
        animation?.status == AnimationStatus.completed) {
      overlayEntries.first.opaque = opaque;
    }
  }

  _ChatPage get page => settings as _ChatPage;

  @override
  bool get opaque => !page.split || !page.isDetail;

  @override
  Widget buildContent(BuildContext context) =>
      RepaintBoundary(child: page.child);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (page.split) {
      if (!page.isDetail) return child;
      return const PaneFadeTransitions().buildTransitions(
        this,
        context,
        animation,
        secondaryAnimation,
        child,
      );
    }
    return super.buildTransitions(
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }
}
