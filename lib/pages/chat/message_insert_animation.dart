import 'package:flutter/material.dart';

/// A lightweight optimistic-message entrance for sends visible in the chat.
///
/// The row grows upward from its bottom edge so existing messages are pushed
/// toward older history instead of the new bubble flying across the viewport.
class MessageInsertAnimation extends StatefulWidget {
  final Widget child;
  final bool animate;
  final bool slideFromRight;

  const MessageInsertAnimation({
    super.key,
    required this.child,
    this.animate = true,
    this.slideFromRight = false,
  });

  @override
  State<MessageInsertAnimation> createState() => _MessageInsertAnimationState();
}

class _MessageInsertAnimationState extends State<MessageInsertAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _size;
  late final Animation<double> _opacity;
  late final Animation<Offset> _position;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _size = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0, 0.9, curve: Curves.easeOutCubic),
    );
    _opacity = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.12, 1, curve: Curves.easeOut),
    );
    _position = Tween<Offset>(
      begin: widget.slideFromRight ? const Offset(0.08, 0) : Offset.zero,
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    if (widget.animate) {
      _controller.forward();
    } else {
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: SizeTransition(
        sizeFactor: _size,
        alignment: Alignment.bottomRight,
        child: FadeTransition(
          opacity: _opacity,
          child: SlideTransition(position: _position, child: widget.child),
        ),
      ),
    );
  }
}
