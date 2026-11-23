import 'package:material_ui/material_ui.dart';

import 'material_header_transition.dart';
import 'material_root_header.dart';

/// The search field and toolbar action share one reversible transition.
class MaterialSearchHeader extends StatelessWidget {
  const MaterialSearchHeader({
    super.key,
    required this.title,
    required this.search,
    required this.searchLabel,
    required this.collapsed,
    required this.onSearch,
    this.onEnd,
    this.iconKey,
    this.actions = const [],
  });

  final String title, searchLabel;
  final Widget search;
  final bool collapsed;
  final VoidCallback onSearch;
  final VoidCallback? onEnd;
  final Key? iconKey;
  final List<Widget> actions;

  static bool shouldCollapse(ScrollMetrics metrics, bool collapsed) =>
      MaterialHeaderTransition.shouldCollapse(
        metrics,
        collapsed,
        MaterialRootHeader.searchExtent,
      );

  @override
  Widget build(BuildContext context) {
    final compact = MaterialRootHeader.isCompact(context);
    return MaterialHeaderTransition(
      enabled: compact,
      collapsed: collapsed,
      child: search,
      onEnd: onEnd,
      builder: (_, expansion, field) => MaterialRootHeader(
        title: title,
        compact: compact,
        searchExpansion: expansion,
        search: expansion == 0
            ? null
            : _InteractiveHalf(active: expansion >= .5, child: field!),
        actions: [
          if (expansion < 1)
            ClipRect(
              child: Align(
                widthFactor: 1 - expansion,
                child: Opacity(
                  opacity: 1 - expansion,
                  child: _InteractiveHalf(
                    active: expansion < .5,
                    child: IconButton(
                      key: iconKey,
                      tooltip: searchLabel,
                      icon: const Icon(Icons.search_rounded),
                      onPressed: onSearch,
                    ),
                  ),
                ),
              ),
            ),
          ...actions,
        ],
      ),
    );
  }
}

class _InteractiveHalf extends StatelessWidget {
  const _InteractiveHalf({required this.active, required this.child});
  final bool active;
  final Widget child;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    excluding: !active,
    child: ExcludeFocus(
      excluding: !active,
      child: IgnorePointer(ignoring: !active, child: child),
    ),
  );
}

/// A pinned, editable search header above a directory's scrollable results.
class MaterialSearchDirectory extends StatefulWidget {
  const MaterialSearchDirectory({
    super.key,
    required this.title,
    required this.hint,
    required this.query,
    required this.searchBuilder,
    required this.body,
    this.iconKey,
    this.actions = const [],
  });
  final String title, hint, query;
  final Widget Function(FocusNode) searchBuilder;
  final Widget body;
  final Key? iconKey;
  final List<Widget> actions;
  @override
  State<MaterialSearchDirectory> createState() =>
      _MaterialSearchDirectoryState();
}

class _MaterialSearchDirectoryState extends State<MaterialSearchDirectory> {
  final _focus = FocusNode();
  bool _collapsed = false;
  bool _focusAfterExpand = false;

  void _sync(ScrollMetrics metrics) {
    if (_focusAfterExpand || _focus.hasFocus || widget.query.isNotEmpty) {
      return;
    }
    final next =
        MaterialRootHeader.isCompact(context) &&
        MaterialSearchHeader.shouldCollapse(metrics, _collapsed);
    if (next != _collapsed) setState(() => _collapsed = next);
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      MaterialSearchHeader(
        title: widget.title,
        searchLabel: widget.hint,
        search: widget.searchBuilder(_focus),
        collapsed: _collapsed && widget.query.isEmpty,
        actions: widget.actions,
        iconKey: widget.iconKey,
        onSearch: () => setState(() {
          _focusAfterExpand = true;
          _collapsed = false;
        }),
        onEnd: () {
          if (_focusAfterExpand) {
            _focusAfterExpand = false;
            _focus.requestFocus();
          }
        },
      ),
      Expanded(
        child: HeaderScrollListener(onScroll: _sync, child: widget.body),
      ),
    ],
  );
}
