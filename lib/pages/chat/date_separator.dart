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
        child: NeuSurface(
          depth: NeuDepth.flat,
          color: context.neu.surfaceStrong,
          radius: NeuRadius.nav,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          child: Text(dateLabel, style: Theme.of(context).textTheme.bodySmall),
        ),
      ),
    );
  }
}
