import 'package:material_ui/material_ui.dart';

import '../../theme/neu_colors.dart';
import '../../theme/material_theme.dart';
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
    final style = materialTimelineDateStyle(
      Theme.of(context),
      floating: floating,
    );
    return Material(
      color: style.fill,
      shape: style.shape,
      elevation: style.elevation,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        child: Text(label, style: style.label),
      ),
    );
  }
}
