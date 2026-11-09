import 'package:flutter/material.dart';

import '../theme/app_component_theme.dart';
import 'glass.dart';

/// A toolbar over the page's fading surface. Reserve its height in the scroll
/// content and extend the Scaffold body behind it.
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
  backgroundColor: Colors.transparent,
  surfaceTintColor: Colors.transparent,
  elevation: 0,
  scrolledUnderElevation: 0,
  flexibleSpace: const IgnorePointer(
    child: SizedBox.expand(child: TopFadeBlur(useShader: true)),
  ),
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
