import 'package:flutter/material.dart';

import '../theme/app_component_theme.dart';

/// Shared M3 top app bar; its opaque surface and controls come from the theme.
AppBar buildFloatingAppBar({
  required Widget title,
  Widget? leading,
  List<Widget>? actions,
  PreferredSizeWidget? bottom,
  double toolbarHeight = kToolbarHeight,
  double? titleSpacing,
  bool automaticallyImplyLeading = true,
}) => AppBar(
  title: title,
  leading: leading == null
      ? null
      : Center(child: MaterialToolbar(child: leading)),
  actions: actions == null
      ? null
      : [
          MaterialToolbar(
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 6,
                children: actions,
              ),
            ),
          ),
        ],
  bottom: bottom,
  toolbarHeight: toolbarHeight,
  titleSpacing: titleSpacing,
  automaticallyImplyLeading: automaticallyImplyLeading,
  surfaceTintColor: Colors.transparent,
  elevation: 0,
  scrolledUnderElevation: 0,
);

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
