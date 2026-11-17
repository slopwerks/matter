import 'package:flutter/material.dart';

import '../theme/material_theme.dart';
import 'cascade_title.dart';
import 'material_adaptive_shell.dart';

/// Root pages share the prototype's compact tonal header and plain pane header.
class MaterialRootHeader extends StatelessWidget
    implements PreferredSizeWidget {
  static bool isCompact(BuildContext context) =>
      (MaterialAdaptiveShell.windowOf(context) ??
          MaterialWindowClass.fromWidth(MediaQuery.sizeOf(context).width)) ==
      MaterialWindowClass.compact;

  const MaterialRootHeader({
    super.key,
    required this.title,
    required this.compact,
    this.search,
    this.actions = const [],
  });

  final String title;
  final bool compact;
  final Widget? search;
  final List<Widget> actions;

  @override
  Size get preferredSize => Size.fromHeight(
    (compact ? 76 : kToolbarHeight) + (search == null ? 0 : 74),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = materialRootHeaderStyle(theme, compact: compact);
    final profile = compact ? MaterialAdaptiveShell.profileOf(context) : null;
    return SizedBox(
      height: preferredSize.height + MediaQuery.paddingOf(context).top,
      child: AppBar(
        automaticallyImplyLeading: false,
        toolbarHeight: compact ? 76 : kToolbarHeight,
        backgroundColor: style.fill,
        foregroundColor: style.foreground,
        titleTextStyle: style.title,
        shape: style.shape,
        clipBehavior: Clip.antiAlias,
        title: CascadeTitle(text: title, style: style.title!),
        actions: [...actions, ?profile, const SizedBox(width: 12)],
        flexibleSpace: compact
            ? IgnorePointer(
                child: Stack(
                  children: [
                    PositionedDirectional(
                      end: -96,
                      top: -128,
                      width: 280,
                      height: 280,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: style.decoration,
                        ),
                      ),
                    ),
                    PositionedDirectional(
                      end: -46,
                      top: 34,
                      width: 170,
                      height: 170,
                      child: Transform.rotate(
                        angle: .28,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(48),
                            color: style.decoration,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              )
            : null,
        bottom: search == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(74),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                  child: Theme(
                    data: theme.copyWith(
                      searchBarTheme: theme.searchBarTheme.copyWith(
                        backgroundColor: WidgetStatePropertyAll(
                          style.searchFill,
                        ),
                      ),
                    ),
                    child: search!,
                  ),
                ),
              ),
      ),
    );
  }
}
