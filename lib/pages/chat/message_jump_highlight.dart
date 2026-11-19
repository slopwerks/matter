import 'package:flutter/material.dart';

import '../../theme/neu_colors.dart';

/// Paints a temporary location cue without changing message layout or gestures.
class MessageJumpHighlight extends StatefulWidget {
  final String messageId;
  final ValueNotifier<String?> target;
  final Widget child;
  final Set<String> collectionIds;

  const MessageJumpHighlight({
    super.key,
    required this.messageId,
    required this.target,
    required this.child,
    this.collectionIds = const {},
  });

  @override
  State<MessageJumpHighlight> createState() => _MessageJumpHighlightState();
}

class _MessageJumpHighlightState extends State<MessageJumpHighlight>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
    value: 1,
  );

  @override
  void initState() {
    super.initState();
    widget.target.addListener(_onTarget);
  }

  void _onTarget() {
    if (widget.target.value == widget.messageId ||
        widget.collectionIds.contains(widget.target.value)) {
      _controller.forward(from: 0);
    } else {
      _controller.value = 1;
    }
  }

  @override
  void didUpdateWidget(MessageJumpHighlight oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.target != widget.target) {
      oldWidget.target.removeListener(_onTarget);
      widget.target.addListener(_onTarget);
    }
  }

  @override
  void dispose() {
    widget.target.removeListener(_onTarget);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    child: widget.child,
    builder: (context, child) => CustomPaint(
      foregroundPainter: _MessageHighlightPainter(
        context.neu.accent.withValues(alpha: 0.22 * (1 - _controller.value)),
      ),
      child: child,
    ),
  );
}

/// Screen lifts the existing pixels instead of tinting over and dimming text.
class _MessageHighlightPainter extends CustomPainter {
  final Color color;

  const _MessageHighlightPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (color.a == 0) return;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = color
        ..blendMode = BlendMode.screen,
    );
  }

  @override
  bool shouldRepaint(_MessageHighlightPainter oldDelegate) =>
      oldDelegate.color != color;
}
