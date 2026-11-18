import 'package:flutter/material.dart';

import '../../theme/neu_colors.dart';
import '../../widgets/neu_decoration.dart';
import '../../widgets/neu_surface.dart';

class DateSeparator extends StatelessWidget {
  final String dateLabel;

  const DateSeparator({super.key, required this.dateLabel});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: context.isMaterial
            ? MaterialTimelineDateLabel(label: dateLabel)
            : NeuSurface(
                depth: NeuDepth.flat,
                color: context.neu.surfaceStrong,
                radius: NeuRadius.nav,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 5,
                ),
                child: Text(
                  dateLabel,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
      ),
    );
  }
}

class MaterialTimelineDateLabel extends StatelessWidget {
  const MaterialTimelineDateLabel({
    super.key,
    required this.label,
    this.floating = false,
  });

  final String label;
  final bool floating;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: floating
          ? theme.colorScheme.surfaceContainerHigh
          : theme.colorScheme.surfaceContainer,
      shape: const StadiumBorder(),
      elevation: floating ? 1 : 0,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        child: Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
