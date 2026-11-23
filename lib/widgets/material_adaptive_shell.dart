import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/tokens.dart';
import 'mobile_tab_view.dart';
import 'conversation_routes.dart';
import 'pane_transitions.dart';
import 'compact_capsule_transition.dart';
import 'material_tab_navigation_bar.dart';

/// Window classes belong to the app window, not the remaining chat pane.
enum MaterialWindowClass {
  compact,
  medium,
  expanded,
  large,
  extraLarge;

  static MaterialWindowClass fromWidth(double width) => switch (width) {
    < 600 => compact,
    < 840 => medium,
    < 1200 => expanded,
    < 1600 => large,
    _ => extraLarge,
  };

  bool get hasRail => this != compact;
  bool get hasSplit => index >= expanded.index;
  double get railWidth => switch (this) {
    compact => 0,
    medium || expanded => 80,
    large || extraLarge => 256,
  };
  double get listWidth => index >= large.index ? 360 : 320;
}

const _destinations = [
  (label: '聊天', icon: Icons.chat_bubble_outline, selected: Icons.chat_bubble),
  (label: '空间', icon: Icons.workspaces_outline, selected: Icons.workspaces),
  (label: '通讯录', icon: Icons.people_outline, selected: Icons.people),
  (label: '设置', icon: Icons.settings_outlined, selected: Icons.settings),
];

/// Secondary destinations notify the shell when their route stack is open.
class MaterialDetailVisibility extends Notification {
  const MaterialDetailVisibility(this.visible);
  final bool visible;
}

/// Both navigation forms drive one retained page tree at every window width.
class MaterialAdaptiveShell extends StatefulWidget {
  static Widget? profileOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_MaterialShellProfile>()
      ?.profile;

  static bool expandedRailOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_MaterialShellProfile>()
          ?.expandedRail ??
      false;

  static MaterialWindowClass? windowOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_MaterialShellProfile>()
      ?.window;

  const MaterialAdaptiveShell({
    super.key,
    required this.window,
    required this.index,
    required this.onNavigate,
    required this.pages,
    required this.position,
    required this.profile,
    required this.railAccount,
    required this.railActions,
    required this.railSpaces,
    required this.unreadCount,
    required this.chatOpen,
    this.floatingActionButton,
    this.pagesKey,
  });

  final MaterialWindowClass window;
  final int index;
  final ValueChanged<int> onNavigate;
  final List<Widget> pages;
  final ValueNotifier<double> position;
  final Widget profile;
  final Widget railAccount;
  final Widget Function(bool extended) railActions;
  final Widget railSpaces;
  final int unreadCount;
  final bool chatOpen;
  final Widget? floatingActionButton;
  final Key? pagesKey;

  @override
  State<MaterialAdaptiveShell> createState() => _MaterialAdaptiveShellState();
}

mixin _RememberWidth<T extends StatefulWidget> on State<T> {
  String get _widthKey;
  double? _preferredWidth;

  @override
  void initState() {
    super.initState();
    _restoreWidth();
  }

  Future<void> _restoreWidth() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getDouble(_widthKey);
    if (mounted && _preferredWidth == null && saved != null && saved.isFinite) {
      setState(() => _preferredWidth = saved);
    }
  }

  Future<void> _saveWidth() async {
    final width = _preferredWidth;
    final prefs = await SharedPreferences.getInstance();
    if (width == null) {
      await prefs.remove(_widthKey);
    } else {
      await prefs.setDouble(_widthKey, width);
    }
  }
}

class _MaterialAdaptiveShellState extends State<MaterialAdaptiveShell>
    with _RememberWidth<MaterialAdaptiveShell> {
  final _detailTabs = <int>{};
  bool _draggingRail = false;
  @override
  String get _widthKey => 'material_navigation_rail_width';

  @override
  void didUpdateWidget(MaterialAdaptiveShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pagesKey != widget.pagesKey) _detailTabs.clear();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) =>
        _buildShell(context, constraints.maxWidth),
  );

  Widget _buildShell(BuildContext context, double available) {
    final window = widget.window;
    final maxWidth =
        (available - 360 - (window.hasSplit ? window.listWidth + 1 : 0)).clamp(
          64.0,
          256.0,
        );
    final target =
        (_preferredWidth ?? (window.hasRail ? window.railWidth : 80.0)).clamp(
          64.0,
          maxWidth,
        );
    final duration = MediaQuery.disableAnimationsOf(context) || _draggingRail
        ? Duration.zero
        : context.tokens.motion.layoutDuration;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: target),
      duration: duration,
      curve: Curves.easeInOutCubicEmphasized,
      builder: (context, width, _) => _buildPanes(
        context,
        railWidth: window.hasRail
            ? (_draggingRail || duration == Duration.zero
                  ? target
                  : width.clamp(64.0, available))
            : 0,
        maxWidth: maxWidth,
        expanded: target >= 192,
        duration: duration,
      ),
    );
  }

  Widget _buildPanes(
    BuildContext context, {
    required double railWidth,
    required double maxWidth,
    required bool expanded,
    required Duration duration,
  }) {
    final window = widget.window;
    final index = widget.index;
    final onNavigate = widget.onNavigate;
    final position = widget.position;
    final profile = widget.profile;
    final pagesKey = widget.pagesKey;
    final chatOpen = widget.chatOpen;
    final scheme = Theme.of(context).colorScheme;
    final hideBottomBar =
        (chatOpen && index == 0) || _detailTabs.contains(index);
    final scaffold = Scaffold(
      extendBody: true,
      floatingActionButton: _detailTabs.contains(index)
          ? null
          : widget.floatingActionButton,
      body: Stack(
        children: [
          if (window.hasRail)
            PositionedDirectional(
              key: const ValueKey('material-navigation-rail'),
              start: 0,
              top: 0,
              bottom: 0,
              width: railWidth,
              child: Material(
                color: scheme.surfaceContainerLow,
                child: SafeArea(
                  right: false,
                  child: Column(
                    children: [
                      Expanded(
                        child: ClipRect(
                          child: AnimatedSwitcher(
                            duration: duration,
                            switchInCurve: Curves.easeOut,
                            switchOutCurve: Curves.easeIn,
                            child: OverflowBox(
                              key: ValueKey(expanded),
                              alignment: AlignmentDirectional.centerStart,
                              minWidth: expanded
                                  ? railWidth.clamp(192.0, 256.0)
                                  : railWidth.clamp(64.0, 191.0),
                              maxWidth: expanded
                                  ? railWidth.clamp(192.0, 256.0)
                                  : railWidth.clamp(64.0, 191.0),
                              child: Column(
                                children: [
                                  Expanded(
                                    child: ListView(
                                      primary: false,
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
                                      children: [
                                        if (expanded) widget.railAccount,
                                        widget.railActions(expanded),
                                        _RailDestinations(
                                          index: index,
                                          position: position,
                                          onNavigate: onNavigate,
                                          extended: expanded,
                                          unreadCount: widget.unreadCount,
                                        ),
                                        if (expanded) widget.railSpaces,
                                      ],
                                    ),
                                  ),
                                  if (!expanded) profile,
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (maxWidth >= 192)
                        IconButton(
                          tooltip: expanded ? '收起侧栏' : '展开侧栏',
                          icon: AnimatedRotation(
                            turns: expanded ? .5 : 0,
                            duration: duration,
                            child: const Icon(Icons.chevron_right),
                          ),
                          onPressed: () {
                            setState(
                              () => _preferredWidth = expanded ? 80 : 256,
                            );
                            _saveWidth();
                          },
                        ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            ),
          PositionedDirectional(
            key: const ValueKey('material-shell-content'),
            start: railWidth,
            end: 0,
            top: 0,
            bottom: 0,
            child: _MaterialShellProfile(
              profile: profile,
              window: window,
              expandedRail: expanded,
              child: MobileTabView(
                key: pagesKey,
                stationary: window.hasRail,
                index: index,
                position: position,
                onChanged: onNavigate,
                swipeEnabled:
                    !window.hasRail &&
                    !_detailTabs.contains(index) &&
                    (!chatOpen || index != 0),
                children: [
                  for (var tab = 0; tab < widget.pages.length; tab++)
                    NotificationListener<MaterialDetailVisibility>(
                      onNotification: (notification) {
                        setState(() {
                          if (notification.visible) {
                            _detailTabs.add(tab);
                          } else {
                            _detailTabs.remove(tab);
                          }
                        });
                        return true;
                      },
                      child: widget.pages[tab],
                    ),
                ],
              ),
            ),
          ),
          if (window.hasRail)
            PositionedDirectional(
              start: railWidth - 4,
              top: 0,
              bottom: 0,
              width: 8,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: GestureDetector(
                  key: const ValueKey('material-rail-divider'),
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: (_) => setState(() {
                    _preferredWidth = railWidth;
                    _draggingRail = true;
                  }),
                  onHorizontalDragUpdate: (event) {
                    final delta =
                        Directionality.of(context) == TextDirection.rtl
                        ? -event.delta.dx
                        : event.delta.dx;
                    setState(
                      () => _preferredWidth = (_preferredWidth! + delta).clamp(
                        64.0,
                        maxWidth,
                      ),
                    );
                  },
                  onHorizontalDragEnd: (_) {
                    setState(() => _draggingRail = false);
                    _saveWidth();
                  },
                  onHorizontalDragCancel: () =>
                      setState(() => _draggingRail = false),
                  onDoubleTap: () {
                    setState(() => _preferredWidth = null);
                    _saveWidth();
                  },
                  child: const VerticalDivider(width: 1, thickness: 1),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: window.hasRail || hideBottomBar
          ? null
          : _MaterialDock(
              index: index,
              position: position,
              onNavigate: onNavigate,
            ),
    );
    return CompactCapsuleTransition(
      enabled: !window.hasRail && index == 0 && !_detailTabs.contains(0),
      chatOpen: chatOpen,
      accountKey: pagesKey,
      child: scaffold,
    );
  }
}

class _RailDestinations extends StatelessWidget {
  const _RailDestinations({
    required this.extended,
    required this.unreadCount,
    required this.index,
    required this.position,
    required this.onNavigate,
  });

  final bool extended;
  final int unreadCount;
  final int index;
  final ValueNotifier<double> position;
  final ValueChanged<int> onNavigate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final spacing = context.tokens.spacing;
    final height = extended ? 56.0 : kMinInteractiveDimension;
    final gap = spacing.xs;
    final reduced = MediaQuery.disableAnimationsOf(context);
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: extended ? spacing.md : spacing.sm,
      ),
      child: Align(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: extended ? double.infinity : 56,
          ),
          child: Stack(
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(end: index.toDouble()),
                duration: reduced
                    ? Duration.zero
                    : context.tokens.motion.layoutDuration,
                curve: Curves.easeInOutCubic,
                builder: (_, tail, child) => ValueListenableBuilder<double>(
                  valueListenable: position,
                  child: child,
                  builder: (_, page, indicator) {
                    final head = reduced ? index.toDouble() : page;
                    final lag = reduced
                        ? 0.0
                        : ((tail - head) * (height + gap)).clamp(
                            -gap * 3,
                            gap * 3,
                          );
                    return Positioned(
                      top: head * (height + gap) + (lag < 0 ? lag : 0),
                      left: 0,
                      right: 0,
                      height: height + lag.abs(),
                      child: indicator!,
                    );
                  },
                ),
                child: DecoratedBox(
                  key: const ValueKey('rail-indicator'),
                  decoration: ShapeDecoration(
                    color: scheme.secondaryContainer,
                    shape: const StadiumBorder(),
                  ),
                ),
              ),
              Material(
                type: MaterialType.transparency,
                child: Column(
                  spacing: gap,
                  children: [
                    for (final (i, destination) in _destinations.indexed)
                      Builder(
                        builder: (_) {
                          final selected = index == i;
                          final color = selected
                              ? scheme.onSecondaryContainer
                              : scheme.onSurfaceVariant;
                          final icon = Icon(
                            selected ? destination.selected : destination.icon,
                            color: color,
                          );
                          final unread = i == 0 && unreadCount > 0;
                          Widget button(BuildContext context) => Semantics(
                            button: true,
                            selected: selected,
                            label: extended ? null : destination.label,
                            child: InkWell(
                              customBorder: const StadiumBorder(),
                              hoverColor: selected ? Colors.transparent : null,
                              onFocusChange: extended
                                  ? null
                                  : (focused) {
                                      if (focused &&
                                          FocusManager.instance.highlightMode ==
                                              FocusHighlightMode.traditional) {
                                        context
                                            .findAncestorStateOfType<
                                              TooltipState
                                            >()
                                            ?.ensureTooltipVisible();
                                      } else if (!focused) {
                                        Tooltip.dismissAllToolTips();
                                      }
                                    },
                              onTap: () => onNavigate(i),
                              child: SizedBox(
                                width: double.infinity,
                                height: height,
                                child: extended
                                    ? Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 18,
                                        ),
                                        child: Row(
                                          spacing: spacing.md,
                                          children: [
                                            icon,
                                            Expanded(
                                              child: Text(
                                                destination.label,
                                                style: theme
                                                    .textTheme
                                                    .labelLarge
                                                    ?.copyWith(color: color),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            if (unread)
                                              Badge.count(count: unreadCount),
                                          ],
                                        ),
                                      )
                                    : Center(
                                        child: Badge.count(
                                          count: unreadCount,
                                          isLabelVisible: unread,
                                          child: icon,
                                        ),
                                      ),
                              ),
                            ),
                          );
                          return extended
                              ? button(context)
                              : Tooltip(
                                  message: destination.label,
                                  excludeFromSemantics: true,
                                  child: Builder(builder: button),
                                );
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MaterialDock extends StatefulWidget {
  const _MaterialDock({
    required this.index,
    required this.position,
    required this.onNavigate,
  });

  final int index;
  final ValueNotifier<double> position;
  final ValueChanged<int> onNavigate;

  @override
  State<_MaterialDock> createState() => _MaterialDockState();
}

class _MaterialDockState extends State<_MaterialDock> {
  final _lift = ValueNotifier(0.0);

  @override
  void dispose() {
    _lift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
    child: CompactCapsuleTransition.surface(
      context,
      composer: false,
      child: DockSurface(
        radius: 31,
        lift: _lift,
        child: MaterialTabNavigationBar(
          key: const ValueKey('material-dock'),
          position: widget.position,
          lift: _lift,
          selectedIndex: widget.index,
          onDestinationSelected: widget.onNavigate,
          destinations: [
            for (final destination in _destinations)
              NavigationDestination(
                icon: Icon(destination.icon),
                selectedIcon: Icon(destination.selected),
                label: destination.label,
                tooltip: destination.label,
              ),
          ],
        ),
      ),
    ),
  );
}

class _MaterialShellProfile extends InheritedWidget {
  const _MaterialShellProfile({
    required this.profile,
    required this.window,
    required this.expandedRail,
    required super.child,
  });

  final Widget profile;
  final MaterialWindowClass window;

  final bool expandedRail;

  @override
  bool updateShouldNotify(_MaterialShellProfile oldWidget) =>
      profile != oldWidget.profile ||
      window != oldWidget.window ||
      expandedRail != oldWidget.expandedRail;
}

/// Keep list and detail at stable positions in the tree when panes collapse.
/// The detail's MediaQuery describes its own viewport, as media and composer
/// decisions must never use the complete window's width.
class MaterialConversationLayout extends StatefulWidget {
  const MaterialConversationLayout({
    super.key,
    required this.window,
    required this.list,
    required this.detail,
    required this.roomId,
    required this.navigator,
    required this.routesOpen,
    required this.active,
    required this.onRoutesChanged,
    this.supporting,
    required this.onCloseSupporting,
  });

  final MaterialWindowClass window;
  final Widget list;
  final Widget detail;
  final String? roomId;
  final GlobalKey<NavigatorState> navigator;
  final bool routesOpen;
  final bool active;
  final ValueChanged<bool> onRoutesChanged;
  final Widget? supporting;
  final VoidCallback onCloseSupporting;

  @override
  State<MaterialConversationLayout> createState() =>
      _MaterialConversationLayoutState();
}

class _MaterialConversationLayoutState extends State<MaterialConversationLayout>
    with _RememberWidth<MaterialConversationLayout> {
  late final _observer = ConversationRouteObserver((open) {
    if (mounted && open != widget.routesOpen) {
      widget.onRoutesChanged(open);
      MaterialDetailVisibility(open).dispatch(context);
    }
  });

  @override
  String get _widthKey => 'material_conversation_list_width';

  @override
  Widget build(BuildContext context) {
    final window = widget.window;
    final supporting = widget.supporting;
    final selected = widget.roomId != null || widget.routesOpen;
    final persistent = window == MaterialWindowClass.extraLarge;
    final modal = supporting != null && !persistent;
    return ConversationRoutes(
      navigator: widget.navigator,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final supportingWidth = persistent && supporting != null
              ? 361.0
              : 0.0;
          final maxWidth = (constraints.maxWidth - supportingWidth - 361).clamp(
            260.0,
            480.0,
          );
          final listWidth = window.hasSplit
              ? (_preferredWidth ?? 320.0).clamp(260.0, maxWidth)
              : constraints.maxWidth;
          final detailStart = window.hasSplit ? listWidth + 1 : 0.0;
          return Stack(
            children: [
              PositionedDirectional(
                key: const ValueKey('material-conversation-list'),
                start: 0,
                top: 0,
                bottom: 0,
                width: listWidth,
                child: Offstage(
                  offstage: selected && !window.hasSplit,
                  child: ExcludeFocus(excluding: modal, child: widget.list),
                ),
              ),
              PositionedDirectional(
                key: const ValueKey('material-conversation-detail'),
                start: detailStart,
                end: supportingWidth,
                top: 0,
                bottom: 0,
                child: Offstage(
                  offstage: !window.hasSplit && !selected,
                  child: ExcludeFocus(
                    excluding: modal,
                    child: LayoutBuilder(
                      builder: (context, pane) => MediaQuery(
                        data: MediaQuery.of(
                          context,
                        ).copyWith(size: Size(pane.maxWidth, pane.maxHeight)),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Offstage(
                              offstage: widget.routesOpen,
                              child: TweenAnimationBuilder<double>(
                                key: ValueKey(widget.roomId),
                                tween: Tween(begin: 0, end: 1),
                                duration: context.tokens.motion.effectsDuration,
                                curve: Curves.easeOut,
                                child: PrimaryCapsuleEditor(
                                  child: widget.detail,
                                ),
                                builder: (context, opacity, child) => Opacity(
                                  opacity:
                                      window.hasSplit &&
                                          widget.roomId != null &&
                                          !MediaQuery.disableAnimationsOf(
                                            context,
                                          )
                                      ? opacity
                                      : 1,
                                  child: child,
                                ),
                              ),
                            ),
                            Offstage(
                              offstage: !widget.routesOpen,
                              child: PopScope<Object?>(
                                canPop: !widget.active || !widget.routesOpen,
                                onPopInvokedWithResult: (didPop, result) {
                                  if (!didPop &&
                                      widget.active &&
                                      widget.routesOpen) {
                                    widget.navigator.currentState?.maybePop(
                                      result,
                                    );
                                  }
                                },
                                child: Theme(
                                  data: window.hasSplit
                                      ? Theme.of(context).copyWith(
                                          pageTransitionsTheme:
                                              PaneFadeTransitions.theme,
                                        )
                                      : Theme.of(context),
                                  child: Navigator(
                                    key: widget.navigator,
                                    observers: [_observer],
                                    onGenerateRoute: (_) =>
                                        MaterialPageRoute<void>(
                                          builder: (_) =>
                                              const SizedBox.shrink(),
                                        ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (window.hasSplit)
                PositionedDirectional(
                  start: listWidth - 3.5,
                  top: 0,
                  bottom: 0,
                  width: 8,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeColumn,
                    child: GestureDetector(
                      key: const ValueKey('conversation-list-divider'),
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragUpdate: (event) {
                        final delta =
                            Directionality.of(context) == TextDirection.rtl
                            ? -event.delta.dx
                            : event.delta.dx;
                        setState(
                          () => _preferredWidth =
                              ((_preferredWidth ?? listWidth).clamp(
                                        260.0,
                                        maxWidth,
                                      ) +
                                      delta)
                                  .clamp(260.0, maxWidth),
                        );
                      },
                      onHorizontalDragEnd: (_) => _saveWidth(),
                      onDoubleTap: () {
                        setState(() => _preferredWidth = 320);
                        _saveWidth();
                      },
                      child: const VerticalDivider(width: 1, thickness: 1),
                    ),
                  ),
                ),
              if (supporting != null && !persistent)
                Positioned.fill(
                  child: ModalBarrier(
                    color: Colors.black.withValues(alpha: .32),
                    onDismiss: widget.onCloseSupporting,
                    semanticsLabel: '关闭房间详情',
                  ),
                ),
              if (supporting != null)
                PositionedDirectional(
                  end: 0,
                  top: window.hasSplit ? 0 : constraints.maxHeight * .12,
                  bottom: 0,
                  width: window.hasSplit ? 360 : constraints.maxWidth,
                  child: CallbackShortcuts(
                    bindings: {
                      if (!persistent)
                        const SingleActivator(LogicalKeyboardKey.escape):
                            widget.onCloseSupporting,
                    },
                    child: FocusScope(
                      autofocus: !persistent,
                      child: Material(
                        elevation: persistent ? 0 : 3,
                        clipBehavior: Clip.antiAlias,
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(window.hasSplit ? 0 : 28),
                        ),
                        child: Column(
                          children: [
                            Align(
                              alignment: AlignmentDirectional.centerEnd,
                              child: CloseButton(
                                onPressed: widget.onCloseSupporting,
                              ),
                            ),
                            Expanded(child: supporting),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
