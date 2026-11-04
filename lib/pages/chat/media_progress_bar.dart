import 'package:flutter/material.dart';

import '../../theme/neu_colors.dart';
import 'media_playback.dart';

class MediaProgressBar extends StatelessWidget {
  final MediaPlayback controller;
  final bool allowScrubbing;

  const MediaProgressBar({
    super.key,
    required this.controller,
    this.allowScrubbing = false,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final duration = controller.duration.inMilliseconds;
      double fraction(Duration position) =>
          duration > 0 ? (position.inMilliseconds / duration).clamp(0, 1) : 0;
      void seek(Offset offset) {
        if (duration <= 0 || constraints.maxWidth <= 0) return;
        final progress = (offset.dx / constraints.maxWidth).clamp(0, 1);
        controller.seek(Duration(milliseconds: (duration * progress).round()));
      }

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: allowScrubbing
            ? (details) => seek(details.localPosition)
            : null,
        onHorizontalDragUpdate: allowScrubbing
            ? (details) => seek(details.localPosition)
            : null,
        child: SizedBox(
          height: allowScrubbing ? 20 : 3,
          child: Center(
            child: SizedBox(
              height: 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: Colors.white24),
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: fraction(controller.buffer),
                    child: const ColoredBox(color: Colors.white38),
                  ),
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: fraction(controller.position),
                    child: ColoredBox(color: context.neu.accent),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
