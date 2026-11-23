import 'package:flutter/material.dart';

import '../../theme/material_theme.dart';
import '../../widgets/material_press.dart';

class MaterialUnreadPill extends StatelessWidget {
  const MaterialUnreadPill({
    super.key,
    required this.label,
    required this.onJump,
    required this.onMarkRead,
    required this.below,
    required this.loading,
    required this.failed,
  });

  final String label;
  final VoidCallback? onJump;
  final VoidCallback? onMarkRead;
  final bool below;
  final bool loading;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final height = materialTimelinePillHeight(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        IconButton.filledTonal(
          tooltip: '全部标为已读',
          onPressed: onMarkRead,
          style: IconButton.styleFrom(
            fixedSize: Size.square(height),
            minimumSize: Size.zero,
            visualDensity: VisualDensity.standard,
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
            foregroundColor: Theme.of(context).colorScheme.onSurface,
            padding: const EdgeInsets.all(materialTimelinePillInset),
            shape: const CircleBorder(),
          ),
          icon: const Icon(Icons.check_rounded, size: materialTimelinePillIcon),
        ),
        Flexible(
          child: MaterialPress(
            builder: (states) => FilledButton.icon(
              statesController: states,
              style: materialUnreadJumpStyle(context),
              onPressed: onJump,
              label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
              icon: loading
                  ? const SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      failed
                          ? Icons.refresh
                          : below
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_up,
                      size: materialTimelineArrow,
                    ),
            ),
          ),
        ),
      ],
    );
  }
}
