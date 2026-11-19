import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

typedef _TabFrame = ({double offset, double opacity});

/// Keeps visited tabs mounted. Dock navigation uses a short slide and fade;
/// horizontal drags move adjacent pages by their full width.
class MobileTabView extends StatefulWidget {
  const MobileTabView({
    super.key,
    required this.index,
    required this.children,
    required this.position,
    required this.onChanged,
  });

  final int index;
  final List<Widget> children;
  final ValueNotifier<double> position;
  final ValueChanged<int> onChanged;

  @override
  State<MobileTabView> createState() => _MobileTabViewState();
}

class _MobileTabViewState extends State<MobileTabView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Set<int> _visited = {widget.index};
  late int _target = widget.index;
  late Map<int, _TabFrame> _begin = {widget.index: (offset: 0, opacity: 1)};
  late Map<int, _TabFrame> _end = _begin;
  late double _positionFrom = widget.index.toDouble();
  late double _positionTo = _positionFrom;
  Map<int, _TabFrame> _dragFrames = {};
  int? _dragOrigin;
  double _dragOffset = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      value: 1,
    )..addListener(_publishPosition);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _publishPosition();
    });
  }

  @override
  void didUpdateWidget(MobileTabView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index == _target) return;
    final frames = _visibleFrames;
    final direction = (widget.index - _target).sign.toDouble();
    frames.putIfAbsent(
      widget.index,
      () => (offset: direction * .12, opacity: 0),
    );
    _target = widget.index;
    _dragOrigin = null;
    _animate(frames, {
      for (final entry in frames.entries)
        entry.key: entry.key == _target
            ? (offset: 0, opacity: 1)
            : (offset: entry.value.offset - direction * .04, opacity: 0),
    });
  }

  Map<int, _TabFrame> get _frames => {
    for (final entry in _begin.entries)
      entry.key: (
        offset:
            entry.value.offset +
            (_end[entry.key]!.offset - entry.value.offset) * _controller.value,
        opacity:
            entry.value.opacity +
            (_end[entry.key]!.opacity - entry.value.opacity) *
                _controller.value,
      ),
  };

  Map<int, _TabFrame> get _visibleFrames => {
    for (final entry in _frames.entries)
      if (entry.value.opacity > 0 && entry.value.offset.abs() < 1)
        entry.key: entry.value,
  };

  void _publishPosition() {
    widget.position.value =
        _positionFrom + (_positionTo - _positionFrom) * _controller.value;
  }

  void _animate(Map<int, _TabFrame> begin, Map<int, _TabFrame> end) {
    _controller.stop();
    _begin = begin;
    _end = end;
    _visited.addAll(begin.keys);
    _positionFrom = widget.position.value;
    _positionTo = _target.toDouble();
    _controller.value = 0;
    _controller.animateTo(1, curve: Curves.easeOutCubic);
  }

  void _startDrag(DragStartDetails details) {
    _controller.stop();
    _dragFrames = _visibleFrames;
    // During a tap transition, take over from the most visible actual tab,
    // rather than a skipped tab beneath the dock's travelling highlight.
    _dragOrigin = _dragFrames.entries
        .reduce((a, b) => a.value.opacity > b.value.opacity ? a : b)
        .key;
    _target = _dragOrigin!;
    _dragOffset = 0;
    if (widget.index != _target) widget.onChanged(_target);
  }

  void _updateDrag(DragUpdateDetails details, double width, double direction) {
    final origin = _dragOrigin;
    if (origin == null) return;
    _dragOffset = (_dragOffset - details.primaryDelta! / width * direction)
        .clamp(-1.0, 1.0)
        .clamp(
          -origin.toDouble(),
          (widget.children.length - 1 - origin).toDouble(),
        );
    final next = origin + _dragOffset.sign.toInt();
    final progress = _dragOffset.abs();
    final frames = {
      for (final entry in _dragFrames.entries)
        entry.key: (
          offset: entry.value.offset - _dragOffset,
          opacity: entry.key == origin || entry.key == next
              ? entry.value.opacity + (1 - entry.value.opacity) * progress
              : entry.value.opacity * (1 - progress),
        ),
    };
    if (next != origin) {
      frames.putIfAbsent(
        next,
        () => (offset: _dragOffset.sign - _dragOffset, opacity: 1.0),
      );
    }
    setState(() {
      _begin = _end = frames;
      _visited.addAll(frames.keys);
      _positionFrom = _positionTo = origin + _dragOffset;
    });
    _publishPosition();
  }

  void _endDrag(double velocity, double direction) {
    final origin = _dragOrigin;
    if (origin == null) return;
    final logicalVelocity = -velocity * direction;
    final advance = logicalVelocity.abs() >= kMinFlingVelocity
        ? logicalVelocity.sign.toInt()
        : (_dragOffset.abs() > .5 ? _dragOffset.sign.toInt() : 0);
    _target = (origin + advance).clamp(0, widget.children.length - 1);
    final frames = _visibleFrames;
    frames.putIfAbsent(
      _target,
      () => (offset: (_target - origin).toDouble(), opacity: 1),
    );
    setState(() {
      _dragOrigin = null;
      _animate(frames, {
        for (final entry in frames.entries)
          entry.key: (
            offset: (entry.key - _target).sign.toDouble(),
            opacity: entry.key == origin || entry.key == _target ? 1 : 0,
          ),
      });
    });
    if (widget.index != _target) widget.onChanged(_target);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final direction = Directionality.of(context) == TextDirection.ltr
        ? 1.0
        : -1.0;
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        onHorizontalDragStart: _startDrag,
        onHorizontalDragUpdate: (details) =>
            _updateDrag(details, constraints.maxWidth, direction),
        onHorizontalDragEnd: (details) =>
            _endDrag(details.primaryVelocity!, direction),
        onHorizontalDragCancel: () {
          if (_dragOrigin != null) _endDrag(0, direction);
        },
        child: ClipRect(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final frames = _frames;
              return Stack(
                fit: StackFit.expand,
                children: [
                  for (var index = 0; index < widget.children.length; index++)
                    if (_visited.contains(index))
                      Offstage(
                        key: ValueKey(index),
                        offstage:
                            frames[index] == null ||
                            frames[index]!.opacity == 0 ||
                            frames[index]!.offset.abs() >= 1,
                        child: TickerMode(
                          enabled:
                              frames[index] != null &&
                              frames[index]!.opacity > 0 &&
                              frames[index]!.offset.abs() < 1,
                          child: ExcludeFocus(
                            excluding: index != _target,
                            child: IgnorePointer(
                              ignoring: index != _target,
                              child: FractionalTranslation(
                                translation: Offset(
                                  (frames[index]?.offset ?? 0) * direction,
                                  0,
                                ),
                                child: Opacity(
                                  opacity: frames[index]?.opacity ?? 0,
                                  child: widget.children[index],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
