import 'package:material_ui/material_ui.dart';

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
    this.searchExpansion = 1,
    this.actions = const [],
  });

  final String title;
  final bool compact;
  final Widget? search;
  final double searchExpansion;
  final List<Widget> actions;

  double get _toolbarHeight => compact ? kToolbarHeight : 84;
  static const searchExtent = 68.0;

  @override
  Size get preferredSize => Size.fromHeight(
    _toolbarHeight + (search == null ? 0 : searchExtent * searchExpansion),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = materialRootHeaderStyle(theme, compact: compact);
    final profile = compact ? MaterialAdaptiveShell.profileOf(context) : null;
    final header = AppBar(
      automaticallyImplyLeading: false,
      toolbarHeight: _toolbarHeight,
      backgroundColor: style.fill,
      foregroundColor: style.foreground,
      titleTextStyle: style.title,
      clipBehavior: Clip.antiAlias,
      title: CascadeTitle(text: title, style: style.title!),
      actions: [...actions, ?profile, const SizedBox(width: 12)],
      flexibleSpace: compact
          ? MaterialHeaderDecoration(color: style.decoration)
          : null,
      bottom: search == null
          ? null
          : PreferredSize(
              preferredSize: Size.fromHeight(searchExtent * searchExpansion),
              child: ClipRect(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  heightFactor: searchExpansion,
                  child: Opacity(
                    opacity: searchExpansion,
                    child: Transform.scale(
                      scale: .8 + .2 * searchExpansion,
                      alignment: AlignmentDirectional.topEnd,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
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
                ),
              ),
            ),
    );
    return SizedBox(
      height: preferredSize.height + MediaQuery.paddingOf(context).top,
      child: style.shape == null
          ? header
          : ClipPath.shape(shape: style.shape!, child: header),
    );
  }
}

/// Shared tonal shapes behind Material page headers.
class MaterialHeaderDecoration extends StatelessWidget {
  const MaterialHeaderDecoration({super.key, required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Stack(
      children: [
        PositionedDirectional(
          end: -96,
          top: -128,
          width: 280,
          height: 280,
          child: DecoratedBox(
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
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
                color: color,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
