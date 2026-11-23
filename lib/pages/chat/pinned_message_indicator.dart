import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// A moving window keeps many pins legible without growing the header.
class PinnedMessageIndicator extends StatelessWidget {
  final int count;
  final int index;
  final Color color;

  const PinnedMessageIndicator({
    super.key,
    required this.count,
    required this.index,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final visible = math.min(count, 5);
    final start = (index - visible ~/ 2).clamp(0, count - visible);
    return Semantics(
      label: '第 ${index + 1} 条置顶消息，共 $count 条',
      child: SizedBox(
        width: 3,
        height: 30,
        child: Column(
          spacing: 2,
          children: [
            for (var slot = 0; slot < visible; slot++)
              Expanded(
                child: AnimatedContainer(
                  key: ValueKey('pin-segment:${start + slot}'),
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 180),
                  decoration: BoxDecoration(
                    color: color.withValues(
                      alpha: start + slot == index ? 1 : 0.25,
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
