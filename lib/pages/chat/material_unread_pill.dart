import 'package:flutter/material.dart';

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
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 8,
    children: [
      IconButton.filledTonal(
        tooltip: '全部标为已读',
        onPressed: onMarkRead,
        style: IconButton.styleFrom(
          minimumSize: const Size.square(36),
          padding: EdgeInsets.zero,
          shape: const CircleBorder(),
        ),
        icon: const Icon(Icons.done_all_rounded, size: 18),
      ),
      Flexible(
        child: MaterialPress(
          builder: (states) => FilledButton.icon(
            statesController: states,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              shape: const StadiumBorder(),
            ),
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
                    size: 18,
                  ),
          ),
        ),
      ),
    ],
  );
}
