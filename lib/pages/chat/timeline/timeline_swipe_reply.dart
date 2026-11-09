import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../theme/neu_colors.dart';

/// Left-swipe reply affordance. The host owns message identity and reply state;
/// a null callback disables the gesture (e.g. for local outgoing messages).
class TimelineSwipeReply extends StatefulWidget {
  final Widget child;
  final VoidCallback? onReply;
  final ValueNotifier<double>? linkedOffset;

  const TimelineSwipeReply({
    super.key,
    required this.child,
    required this.onReply,
    this.linkedOffset,
  });

  @override
  State<TimelineSwipeReply> createState() => _TimelineSwipeReplyState();
}

class _TimelineSwipeReplyState extends State<TimelineSwipeReply>
    with SingleTickerProviderStateMixin {
  // Keep the rightmost 40dp free for the system back gesture.
  static const double _edgeExclusionWidth = 40;
  static const double _triggerDistance = 56;
  static const double _maxDistance = 72;
  static const Duration _settleDuration = Duration(milliseconds: 180);

  late final AnimationController _dragController;
  bool _dragStartedInReplyRegion = false;
  bool _thresholdFeedbackSent = false;

  @override
  void initState() {
    super.initState();
    _dragController = AnimationController(
      vsync: this,
      lowerBound: 0,
      upperBound: _maxDistance,
      duration: _settleDuration,
    )..addListener(_syncLinkedOffset);
  }

  @override
  void didUpdateWidget(covariant TimelineSwipeReply oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.linkedOffset, widget.linkedOffset)) return;
    oldWidget.linkedOffset?.value = 0;
    _syncLinkedOffset();
  }

  @override
  void dispose() {
    widget.linkedOffset?.value = 0;
    _dragController.removeListener(_syncLinkedOffset);
    _dragController.dispose();
    super.dispose();
  }

  void _syncLinkedOffset() {
    widget.linkedOffset?.value = _dragController.value;
  }

  void _handleDragDown(DragDownDetails details) {
    final width = context.size?.width;
    _dragStartedInReplyRegion =
        width != null && details.localPosition.dx < width - _edgeExclusionWidth;
  }

  void _handleDragStart(DragStartDetails details) {
    if (!_dragStartedInReplyRegion) return;
    _dragController.stop();
    _thresholdFeedbackSent = _dragController.value >= _triggerDistance;
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    if (!_dragStartedInReplyRegion) return;
    final distance = (_dragController.value - details.delta.dx).clamp(
      0.0,
      _maxDistance,
    );
    _dragController.value = distance;
    final reachedThreshold = distance >= _triggerDistance;
    if (reachedThreshold && !_thresholdFeedbackSent) {
      _thresholdFeedbackSent = true;
      HapticFeedback.mediumImpact();
    } else if (!reachedThreshold) {
      _thresholdFeedbackSent = false;
    }
  }

  void _handleDragEnd(DragEndDetails details) {
    if (!_dragStartedInReplyRegion) return;
    _dragStartedInReplyRegion = false;
    final shouldReply = _dragController.value >= _triggerDistance;
    _settle();
    if (shouldReply) widget.onReply?.call();
  }

  void _handleDragCancel() {
    // A hit-test path can outlive the widget when the pointer is cancelled
    // after its row was removed. Its animation controller is already disposed.
    if (!mounted || !_dragStartedInReplyRegion) return;
    _dragStartedInReplyRegion = false;
    _settle();
  }

  void _settle() {
    _thresholdFeedbackSent = false;
    _dragController.animateBack(
      0,
      duration: _settleDuration,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onReply != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      dragStartBehavior: DragStartBehavior.down,
      onHorizontalDragDown: enabled ? _handleDragDown : null,
      onHorizontalDragStart: enabled ? _handleDragStart : null,
      onHorizontalDragUpdate: enabled ? _handleDragUpdate : null,
      onHorizontalDragEnd: enabled ? _handleDragEnd : null,
      onHorizontalDragCancel: enabled ? _handleDragCancel : null,
      // Accepted drags receive onEnd even for PointerCancelEvent. Observe
      // cancellation inside the detector so its hit-test entry runs first,
      // clears the reply latch and settles before the recognizer ends.
      child: Listener(
        onPointerCancel: (_) => _handleDragCancel(),
        child: AnimatedBuilder(
          animation: _dragController,
          child: widget.child,
          builder: (context, child) {
            final progress = (_dragController.value / _triggerDistance).clamp(
              0.0,
              1.0,
            );
            return Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.centerRight,
              children: [
                Positioned(
                  right: 5,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: Opacity(
                      opacity: progress,
                      child: Transform.scale(
                        scale: 0.72 + (0.28 * progress),
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: context.neu.accent.withValues(alpha: .14),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.reply_rounded,
                            color: context.neu.accent,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Transform.translate(
                  key: const ValueKey('swipe-reply-content'),
                  offset: Offset(-_dragController.value, 0),
                  child: child,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
