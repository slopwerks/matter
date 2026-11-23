import 'package:material_ui/material_ui.dart';

/// Caps the content width on wide screens and centers it horizontally.
///
/// Below [maxWidth] the child is laid out untouched, so compact (mobile)
/// layouts are unaffected.
class MaxContentWidth extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  final bool usePaneSize;

  const MaxContentWidth({
    super.key,
    required this.child,
    this.maxWidth = 720,
    this.usePaneSize = false,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: usePaneSize
            ? LayoutBuilder(
                builder: (context, constraints) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(size: constraints.biggest),
                  child: child,
                ),
              )
            : child,
      ),
    );
  }
}
