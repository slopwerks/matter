import 'package:flutter/material.dart';

/// Caps the content width on wide screens and centers it horizontally.
///
/// Below [maxWidth] the child is laid out untouched, so compact (mobile)
/// layouts are unaffected.
class MaxContentWidth extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  const MaxContentWidth({super.key, required this.child, this.maxWidth = 720});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth <= maxWidth) return child;
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: child,
          ),
        );
      },
    );
  }
}
