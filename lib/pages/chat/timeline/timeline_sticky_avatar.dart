import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../theme/neu_colors.dart';
import '../../../widgets/app_avatar.dart';

class TimelineStickyAvatarGroup extends StatefulWidget {
  final bool showAvatar;
  final String fallback;
  final String? avatarUrl;
  final ScrollController? scrollController;
  final GlobalKey? scrollViewportKey;
  final double avatarSize;
  final double avatarSlotWidth;
  final double bottomInset;
  final VoidCallback? onAvatarLongPress;
  final Widget Function(ValueNotifier<double>? avatarSwipeOffset)
  messagesBuilder;

  const TimelineStickyAvatarGroup({
    super.key,
    required this.showAvatar,
    required this.fallback,
    required this.avatarUrl,
    required this.scrollController,
    required this.scrollViewportKey,
    required this.avatarSize,
    required this.avatarSlotWidth,
    required this.bottomInset,
    required this.onAvatarLongPress,
    required this.messagesBuilder,
  });

  @override
  State<TimelineStickyAvatarGroup> createState() =>
      TimelineStickyAvatarGroupState();
}

class TimelineStickyAvatarGroupState extends State<TimelineStickyAvatarGroup> {
  final ValueNotifier<double> _avatarSwipeOffset = ValueNotifier(0);

  @override
  void dispose() {
    _avatarSwipeOffset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (widget.showAvatar)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: widget.avatarSlotWidth,
            child: _StickyGroupAvatar(
              key: const ValueKey('sticky-group-avatar-slot'),
              fallback: widget.fallback,
              avatarUrl: widget.avatarUrl,
              scrollController: widget.scrollController,
              scrollViewportKey: widget.scrollViewportKey,
              avatarSize: widget.avatarSize,
              bottomInset: widget.bottomInset,
              swipeOffset: _avatarSwipeOffset,
              onLongPress: widget.onAvatarLongPress,
            ),
          ),
        Padding(
          key: const ValueKey('sticky-group-messages-layer'),
          padding: EdgeInsets.only(left: widget.avatarSlotWidth),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: widget.showAvatar ? widget.avatarSize : 0,
            ),
            child: widget.messagesBuilder(
              widget.showAvatar ? _avatarSwipeOffset : null,
            ),
          ),
        ),
      ],
    );
  }
}

class _StickyGroupAvatar extends SingleChildRenderObjectWidget {
  final String fallback;
  final String? avatarUrl;
  final ScrollController? scrollController;
  final GlobalKey? scrollViewportKey;
  final double avatarSize;
  final double bottomInset;
  final ValueNotifier<double> swipeOffset;
  final VoidCallback? onLongPress;

  _StickyGroupAvatar({
    super.key,
    required this.fallback,
    required this.avatarUrl,
    required this.scrollController,
    required this.scrollViewportKey,
    required this.avatarSize,
    required this.bottomInset,
    required this.swipeOffset,
    required this.onLongPress,
  }) : super(
         child: GestureDetector(
           key: const ValueKey('message-sender-avatar'),
           behavior: HitTestBehavior.opaque,
           onLongPress: onLongPress,
           child: AppAvatar(
             fallback: fallback,
             size: avatarSize,
             radius: NeuRadius.content,
             url: avatarUrl,
           ),
         ),
       );

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderStickyGroupAvatar(
      scrollController: scrollController,
      scrollViewportKey: scrollViewportKey,
      avatarSize: avatarSize,
      bottomInset: bottomInset,
      swipeOffset: swipeOffset,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderStickyGroupAvatar renderObject,
  ) {
    renderObject
      ..scrollController = scrollController
      ..scrollViewportKey = scrollViewportKey
      ..avatarSize = avatarSize
      ..bottomInset = bottomInset
      ..swipeOffset = swipeOffset;
  }
}

class _RenderStickyGroupAvatar extends RenderProxyBox {
  ScrollController? _scrollController;
  GlobalKey? scrollViewportKey;
  double _avatarSize;
  double _bottomInset;
  ValueNotifier<double> _swipeOffset;

  _RenderStickyGroupAvatar({
    required this._scrollController,
    required this.scrollViewportKey,
    required this._avatarSize,
    required this._bottomInset,
    required this._swipeOffset,
  });

  ScrollController? get scrollController => _scrollController;

  set scrollController(ScrollController? value) {
    if (identical(value, _scrollController)) return;
    if (attached) {
      _scrollController?.removeListener(markNeedsPaint);
      value?.addListener(markNeedsPaint);
    }
    _scrollController = value;
    markNeedsPaint();
  }

  double get avatarSize => _avatarSize;

  set avatarSize(double value) {
    if (value == _avatarSize) return;
    _avatarSize = value;
    markNeedsLayout();
  }

  double get bottomInset => _bottomInset;

  set bottomInset(double value) {
    if (value == _bottomInset) return;
    _bottomInset = value;
    markNeedsPaint();
  }

  ValueNotifier<double> get swipeOffset => _swipeOffset;

  set swipeOffset(ValueNotifier<double> value) {
    if (identical(value, _swipeOffset)) return;
    if (attached) {
      _swipeOffset.removeListener(markNeedsPaint);
      value.addListener(markNeedsPaint);
    }
    _swipeOffset = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _scrollController?.addListener(markNeedsPaint);
    _swipeOffset.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _scrollController?.removeListener(markNeedsPaint);
    _swipeOffset.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    child?.layout(
      BoxConstraints.tight(Size.square(_avatarSize)),
      parentUsesSize: false,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    context.paintChild(child, offset + _avatarPaintOffset());
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    return result.addWithPaintOffset(
      offset: _avatarPaintOffset(),
      position: position,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final paintOffset = _avatarPaintOffset();
    transform.translateByDouble(paintOffset.dx, paintOffset.dy, 0, 1);
  }

  double get debugHorizontalPaintOffset => _avatarPaintOffset().dx;

  bool get debugIsSticky {
    final avatarTop = _avatarTopInSlot();
    return (avatarTop - _maxAvatarTop).abs() > 0.5;
  }

  Offset _avatarPaintOffset() {
    final avatarTop = _avatarTopInSlot();
    final isAtDefault = (avatarTop - _maxAvatarTop).abs() <= 0.5;
    return Offset(isAtDefault ? -_swipeOffset.value : 0, avatarTop);
  }

  double _avatarTopInSlot() {
    final maxTop = _maxAvatarTop;
    final controller = _scrollController;
    if (controller == null || !controller.hasClients) return maxTop;
    final viewportBox =
        scrollViewportKey?.currentContext?.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.hasSize || !hasSize) {
      return maxTop;
    }

    final slotTop = localToGlobal(Offset.zero, ancestor: viewportBox).dy;
    final stickyTop = viewportBox.size.height - _bottomInset - _avatarSize;
    return (stickyTop - slotTop).clamp(0.0, maxTop);
  }

  double get _maxAvatarTop =>
      (size.height - _avatarSize).clamp(0.0, double.infinity);
}
