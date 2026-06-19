import 'dart:async';

import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import 'chat_timestamp.dart';

/// A timeline day-boundary used by [FloatingDateHeader] to decide which date
/// label is currently under the top edge of the viewport.
class DateBoundary {
  /// Display label, e.g. "今天" / "昨天" / "3月5日".
  final String label;

  /// Earliest (oldest) message timestamp (ms string) belonging to this day,
  /// used to order boundaries.
  final String leadingTimestamp;

  const DateBoundary({required this.label, required this.leadingTimestamp});
}

/// Telegram-style floating date chip pinned to the top of the chat viewport.
///
/// Appears (fades in) while the list is scrolling and fades out ~1.6s after
/// scrolling stops. The displayed date is the day of whichever message is
/// currently at the top edge of the viewport. Works with the reversed
/// (`reverse: true`) timeline because it inspects rendered geometry rather
/// than relying on scroll offset direction.
class FloatingDateHeader extends StatefulWidget {
  final ScrollController scrollController;
  final GlobalKey scrollViewportKey;

  /// Day boundaries derived from the timeline, ordered oldest → newest.
  final List<DateBoundary> boundaries;

  /// Keys of the rendered date separators, one per [boundaries] entry, used
  /// to read on-screen positions. May be empty before first layout; the chip
  /// just hides in that case.
  final List<GlobalKey> separatorKeys;

  const FloatingDateHeader({
    super.key,
    required this.scrollController,
    required this.scrollViewportKey,
    required this.boundaries,
    required this.separatorKeys,
  });

  @override
  State<FloatingDateHeader> createState() => _FloatingDateHeaderState();
}

class _FloatingDateHeaderState extends State<FloatingDateHeader> {
  String? _currentLabel;
  bool _visible = false;
  double? _lastPixels;
  bool _scrollingTowardOlder = false;
  Timer? _hideTimer;

  static const _hideDelay = Duration(milliseconds: 1600);

  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.scrollController.hasClients) {
        _lastPixels = widget.scrollController.position.pixels;
      }
    });
  }

  @override
  void didUpdateWidget(covariant FloatingDateHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.scrollController, widget.scrollController)) {
      oldWidget.scrollController.removeListener(_onScroll);
      widget.scrollController.addListener(_onScroll);
      _lastPixels = null;
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.scrollController.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    _hideTimer?.cancel();
    if (widget.scrollController.hasClients) {
      final pixels = widget.scrollController.position.pixels;
      final previous = _lastPixels;
      if (previous != null) {
        final delta = pixels - previous;
        if (delta.abs() > 0.01) {
          // reverse:true timelines increase their scroll offset toward history.
          _scrollingTowardOlder = delta > 0;
        }
      }
      _lastPixels = pixels;
    }
    final label = _computeCurrentLabel();
    if (!_visible || label != _currentLabel) {
      setState(() {
        _visible = true;
        _currentLabel = label;
      });
    }
    _hideTimer = Timer(_hideDelay, () {
      if (mounted) setState(() => _visible = false);
    });
  }

  /// Determine the day label for the message currently sitting at the top
  /// edge of the viewport, by inspecting the rendered separator positions.
  String? _computeCurrentLabel() {
    final viewportBox =
        widget.scrollViewportKey.currentContext?.findRenderObject()
            as RenderBox?;
    if (viewportBox == null || !viewportBox.hasSize) return _currentLabel;

    // Pick the nearest rendered day separator at or above the viewport top.
    const activationLine = 1.0;
    int? bestIndex;
    double bestTop = double.negativeInfinity;
    final keys = widget.separatorKeys;
    for (var i = 0; i < widget.boundaries.length && i < keys.length; i++) {
      final box = keys[i].currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero, ancestor: viewportBox).dy;
      if (top <= activationLine && top >= bestTop) {
        bestTop = top;
        bestIndex = i;
      }
    }

    final resolvedIndex = bestIndex == null
        ? null
        : resolveFloatingDateBoundaryIndex(
            separatorIndex: bestIndex,
            boundaryCount: widget.boundaries.length,
            scrollingTowardOlder: _scrollingTowardOlder,
          );
    return (resolvedIndex == null
            ? null
            : widget.boundaries[resolvedIndex].label) ??
        _currentLabel ??
        (widget.boundaries.isEmpty ? null : widget.boundaries.last.label);
  }

  @override
  Widget build(BuildContext context) {
    final label = _currentLabel ?? _computeCurrentLabel();
    final show = _visible && label != null;
    return Positioned(
      top: 10,
      left: 0,
      right: 0,
      child: Center(
        child: AnimatedOpacity(
          opacity: show ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          child: IgnorePointer(
            child: label == null
                ? const SizedBox.shrink()
                : _DateChip(label: label),
          ),
        ),
      ),
    );
  }
}

int? resolveFloatingDateBoundaryIndex({
  required int separatorIndex,
  required int boundaryCount,
  required bool scrollingTowardOlder,
}) {
  if (boundaryCount <= 0 ||
      separatorIndex < 0 ||
      separatorIndex >= boundaryCount) {
    return null;
  }
  if (!scrollingTowardOlder) return separatorIndex;
  return separatorIndex > 0 ? separatorIndex - 1 : 0;
}

class _DateChip extends StatelessWidget {
  final String label;
  const _DateChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(AppRadii.tag),
        border: Border.all(
          color: AppColors.surfaceVariant.withValues(alpha: 0.6),
          width: 0.6,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.onSurface,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Build the ordered day boundaries (oldest → newest) plus their separator
/// keys from the displayed messages. Each boundary represents the first
/// message of a new day; the separator that marks it is the [DateSeparator]
/// rendered just above that message in the reversed timeline.
List<DateBoundary> buildDateBoundaries(List<String> timestamps) {
  final boundaries = <DateBoundary>[];
  String? lastKey;
  for (final ts in timestamps) {
    final key = chatDateKey(ts);
    if (key != lastKey) {
      lastKey = key;
      boundaries.add(
        DateBoundary(label: formatChatDate(ts), leadingTimestamp: ts),
      );
    }
  }
  return boundaries;
}
