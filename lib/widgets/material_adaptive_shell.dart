import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  double get railWidth => hasRail ? 80 : 0;
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
    if (width == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_widthKey, width);
  }
}

class _MaterialAdaptiveShellState extends State<MaterialAdaptiveShell>
    with _RememberWidth<MaterialAdaptiveShell> {
  final _detailTabs = <int>{};
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
    final railWidth = window.hasRail
        ? (_preferredWidth ?? window.railWidth).clamp(64.0, maxWidth)
        : 0.0;
    void resize(double delta) {
      final current = (_preferredWidth ?? railWidth).clamp(64.0, maxWidth);
      setState(() => _preferredWidth = (current + delta).clamp(64.0, maxWidth));
    }

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
              child: ColoredBox(
                color: scheme.surfaceContainerLow,
                child: SafeArea(
                  right: false,
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: profile,
                        ),
                        _RailDestinations(
                          index: index,
                          position: position,
                          onNavigate: onNavigate,
                        ),
                      ],
                    ),
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
                  onHorizontalDragUpdate: (event) => resize(
                    Directionality.of(context) == TextDirection.rtl
                        ? -event.delta.dx
                        : event.delta.dx,
                  ),
                  onHorizontalDragEnd: (_) => _saveWidth(),
                  onDoubleTap: () {
                    setState(() => _preferredWidth = window.railWidth);
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
    required this.index,
    required this.position,
    required this.onNavigate,
  });

  final int index;
  final ValueNotifier<double> position;
  final ValueChanged<int> onNavigate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = Theme.of(context).textTheme.labelMedium!;
    final pitch =
        48 +
        MediaQuery.textScalerOf(context).scale(label.fontSize!) *
            (label.height ?? 1.4);
    final reduced = MediaQuery.disableAnimationsOf(context);
    return Stack(
      children: [
        ValueListenableBuilder<double>(
          valueListenable: position,
          builder: (_, page, child) => Positioned(
            top: 4 + (reduced ? index.toDouble() : page) * pitch,
            left: 12,
            right: 12,
            height: 32,
            child: child!,
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
            children: [
              for (final (i, destination) in _destinations.indexed)
                Semantics(
                  button: true,
                  selected: index == i,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => onNavigate(i),
                    child: SizedBox(
                      height: pitch,
                      width: double.infinity,
                      child: Column(
                        children: [
                          const SizedBox(height: 4),
                          SizedBox(
                            height: 32,
                            child: Center(
                              child: Icon(
                                index == i
                                    ? destination.selected
                                    : destination.icon,
                                color: index == i
                                    ? scheme.onSecondaryContainer
                                    : scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            destination.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: label.copyWith(
                              color: index == i
                                  ? scheme.onSurface
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
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
class MaterialConversationLayout extends StatefulWidget {
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
  State<MaterialConversationLayout> createState() =>
      _MaterialConversationLayoutState();
}

class _MaterialConversationLayoutState extends State<MaterialConversationLayout>
    with _RememberWidth<MaterialConversationLayout> {
  @override
  String get _widthKey => 'material_conversation_list_width';

  @override
  Widget build(BuildContext context) {
    final window = widget.window;
    final supporting = widget.supporting;
    final selected = widget.roomId != null;
    final persistent = window == MaterialWindowClass.extraLarge;
    final modal = supporting != null && !persistent;
    return LayoutBuilder(
      builder: (context, constraints) {
        final supportingWidth = persistent && supporting != null ? 361.0 : 0.0;
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
                      data: MediaQuery.of(context)
                          .copyWith(size: Size(pane.maxWidth, pane.maxHeight)),
                      child: widget.detail,
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
    );
  }
}
