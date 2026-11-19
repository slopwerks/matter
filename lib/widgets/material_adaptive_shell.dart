import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

import 'mobile_tab_view.dart';
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
  bool get extendedRail => index >= large.index;
  double get railWidth => hasRail ? (extendedRail ? 256 : 80) : 0;
  double get listWidth => extendedRail ? 360 : 320;
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
    required this.chatOpen,
    this.railShortcuts,
    this.floatingActionButton,
    this.pagesKey,
  });

  final MaterialWindowClass window;
  final int index;
  final ValueChanged<int> onNavigate;
  final List<Widget> pages;
  final ValueNotifier<double> position;
  final Widget profile;
  final bool chatOpen;
  final Widget? railShortcuts;
  final Widget? floatingActionButton;
  final Key? pagesKey;

  @override
  State<MaterialAdaptiveShell> createState() => _MaterialAdaptiveShellState();
}

class _MaterialAdaptiveShellState extends State<MaterialAdaptiveShell> {
  final _detailTabs = <int>{};

  @override
  void didUpdateWidget(MaterialAdaptiveShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pagesKey != widget.pagesKey) _detailTabs.clear();
  }

  @override
  Widget build(BuildContext context) {
    final window = widget.window;
    final index = widget.index;
    final onNavigate = widget.onNavigate;
    final position = widget.position;
    final profile = widget.profile;
    final railShortcuts = widget.railShortcuts;
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
              width: window.railWidth,
              child: ColoredBox(
                color: scheme.surfaceContainerLow,
                child: SafeArea(
                  right: false,
                  child: NavigationRail(
                    extended: window.extendedRail,
                    minWidth: 80,
                    minExtendedWidth: 256,
                    scrollable: true,
                    backgroundColor: scheme.surfaceContainerLow,
                    labelType: window.extendedRail
                        ? NavigationRailLabelType.none
                        : NavigationRailLabelType.all,
                    leading: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: window.extendedRail
                          ? SizedBox(
                              width: 224,
                              child: Row(
                                children: [
                                  profile,
                                  const SizedBox(width: 12),
                                  Text(
                                    'Matter',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge,
                                  ),
                                ],
                              ),
                            )
                          : profile,
                    ),
                    trailing: railShortcuts,
                    selectedIndex: index,
                    onDestinationSelected: onNavigate,
                    destinations: [
                      for (final destination in _destinations)
                        NavigationRailDestination(
                          icon: Icon(destination.icon),
                          selectedIcon: Icon(destination.selected),
                          label: Text(destination.label),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          PositionedDirectional(
            key: const ValueKey('material-shell-content'),
            start: window.railWidth,
            end: 0,
            top: 0,
            bottom: 0,
            child: _MaterialShellProfile(
              profile: profile,
              window: window,
              child: MobileTabView(
                key: pagesKey,
                index: index,
                position: position,
                onChanged: onNavigate,
                swipeEnabled:
                    !_detailTabs.contains(index) &&
                    (!chatOpen || window.hasSplit || index != 0),
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
    required super.child,
  });

  final Widget profile;
  final MaterialWindowClass window;

  @override
  bool updateShouldNotify(_MaterialShellProfile oldWidget) =>
      profile != oldWidget.profile || window != oldWidget.window;
}

/// Keep list and detail at stable positions in the tree when panes collapse.
/// The detail's MediaQuery describes its own viewport, as media and composer
/// decisions must never use the complete window's width.
class MaterialConversationLayout extends StatelessWidget {
  const MaterialConversationLayout({
    super.key,
    required this.window,
    required this.list,
    required this.detail,
    required this.roomId,
    this.supporting,
    required this.onCloseSupporting,
  });

  final MaterialWindowClass window;
  final Widget list;
  final Widget detail;
  final String? roomId;
  final Widget? supporting;
  final VoidCallback onCloseSupporting;

  @override
  Widget build(BuildContext context) {
    final selected = roomId != null;
    final fade =
        window.hasSplit && selected && !MediaQuery.disableAnimationsOf(context);
    final persistent = window == MaterialWindowClass.extraLarge;
    final modal = supporting != null && !persistent;
    return LayoutBuilder(
      builder: (context, constraints) {
        final listWidth = window.hasSplit
            ? window.listWidth
            : constraints.maxWidth;
        final detailStart = window.hasSplit ? listWidth + 1 : 0.0;
        final supportingWidth = persistent && supporting != null ? 361.0 : 0.0;
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
                child: ExcludeFocus(excluding: modal, child: list),
              ),
            ),
            if (window.hasSplit)
              PositionedDirectional(
                start: listWidth,
                top: 0,
                bottom: 0,
                width: 1,
                child: const VerticalDivider(width: 1),
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
                      data: MediaQuery.of(context)
                          .copyWith(size: Size(pane.maxWidth, pane.maxHeight)),
                      child: TweenAnimationBuilder<double>(
                        key: ValueKey(roomId),
                        tween: Tween(begin: fade ? .35 : 1, end: 1),
                        duration: fade
                            ? context.tokens.motion.effectsDuration
                            : Duration.zero,
                        curve: Curves.easeOut,
                        builder: (_, opacity, child) =>
                            Opacity(opacity: fade ? opacity : 1, child: child),
                        child: detail,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (supporting != null && !persistent)
              Positioned.fill(
                child: ModalBarrier(
                  color: Colors.black.withValues(alpha: .32),
                  onDismiss: onCloseSupporting,
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
                          onCloseSupporting,
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
                            child: CloseButton(onPressed: onCloseSupporting),
                          ),
                          Expanded(child: supporting!),
                        ],
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
