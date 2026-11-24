import 'package:material_ui/material_ui.dart';

import '../theme/app_component_theme.dart';

/// Shared M3 top app bar; its opaque surface and controls come from the theme.
PreferredSizeWidget buildFloatingAppBar({
  required Widget title,
  Widget? leading,
  List<Widget>? actions,
  PreferredSizeWidget? bottom,
  double toolbarHeight = kToolbarHeight,
  double? titleSpacing,
  bool automaticallyImplyLeading = true,
}) => _FloatingAppBar(
  title: title,
  leading: leading,
  actions: actions,
  bottom: bottom,
  toolbarHeight: toolbarHeight,
  titleSpacing: titleSpacing,
  automaticallyImplyLeading: automaticallyImplyLeading,
);

class _FloatingAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _FloatingAppBar({
    required this.title,
    this.leading,
    this.actions,
    this.bottom,
    required this.toolbarHeight,
    this.titleSpacing,
    required this.automaticallyImplyLeading,
  });

  final Widget title;
  final Widget? leading;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;
  final double toolbarHeight;
  final double? titleSpacing;
  final bool automaticallyImplyLeading;

  @override
  Size get preferredSize =>
      Size.fromHeight(toolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) {
    Widget? resolvedLeading = leading;
    var implyLeading = automaticallyImplyLeading;
    if (resolvedLeading == null && automaticallyImplyLeading) {
      final route = ModalRoute.of(context);
      final hasDrawer = Scaffold.maybeOf(context)?.hasDrawer ?? false;
      if (!hasDrawer && (route?.impliesAppBarDismissal ?? false)) {
        resolvedLeading = route is PageRoute && route.fullscreenDialog
            ? const CloseButton()
            : const BackButton();
        implyLeading = false;
      }
    }
    return AppBar(
      title: title,
      leading: resolvedLeading == null
          ? null
          : Center(child: MaterialToolbar(child: resolvedLeading)),
      actions: actions == null
          ? null
          : [
              MaterialToolbar(
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 6,
                    children: actions!,
                  ),
                ),
              ),
            ],
      bottom: bottom,
      toolbarHeight: toolbarHeight,
      titleSpacing: titleSpacing,
      automaticallyImplyLeading: implyLeading,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    );
  }
}

/// A neutral filled control sits above the fading header. Keep this local to
/// toolbars so composer actions and inline list buttons retain their own skin.
class MaterialToolbar extends StatelessWidget {
  const MaterialToolbar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final style = AppComponentTheme.of(context).toolbarStyle;
    if (style == null) return child;
    return IconButtonTheme(
      data: IconButtonThemeData(style: style),
      child: child,
    );
  }
}
