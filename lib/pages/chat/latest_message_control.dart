import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../theme/neu_colors.dart';

/// Sending while closer than this fraction of the visible timeline scrolls
/// directly to the newest message.
const double kAutoScrollToLatestViewportFraction = 0.8;

/// The composer-to-bubble flight is reserved for the normal at-bottom state.
const double kSendFlightViewportFraction = 0.10;

/// The latest-message button appears after the user moves this far away.
const double kLatestMessageControlShowViewportFraction = 0.5;

/// Once visible, the button remains until the user returns this close.
const double kLatestMessageControlHideViewportFraction = 0.15;

enum MessageSendPresentation { flight, insert, quiet }

MessageSendPresentation resolveMessageSendPresentation({
  required double distanceFromLatest,
  required double viewportDimension,
}) {
  if (viewportDimension <= 0) return MessageSendPresentation.flight;
  if (distanceFromLatest <= viewportDimension * kSendFlightViewportFraction) {
    return MessageSendPresentation.flight;
  }
  if (shouldAutoScrollToLatest(
    distanceFromLatest: distanceFromLatest,
    viewportDimension: viewportDimension,
  )) {
    return MessageSendPresentation.insert;
  }
  return MessageSendPresentation.quiet;
}

bool shouldAutoScrollToLatest({
  required double distanceFromLatest,
  required double viewportDimension,
}) {
  if (viewportDimension <= 0) return true;
  return distanceFromLatest <=
      viewportDimension * kAutoScrollToLatestViewportFraction;
}

bool shouldShowLatestMessageControl({
  required double distanceFromLatest,
  required double viewportDimension,
  required bool currentlyVisible,
}) {
  if (viewportDimension <= 0) return currentlyVisible;
  final threshold = currentlyVisible
      ? kLatestMessageControlHideViewportFraction
      : kLatestMessageControlShowViewportFraction;
  return distanceFromLatest > viewportDimension * threshold;
}

class LatestMessageControl extends StatefulWidget {
  final bool visible;
  final bool showSentNotice;
  final VoidCallback onPressed;

  const LatestMessageControl({
    super.key,
    required this.visible,
    required this.showSentNotice,
    required this.onPressed,
  });

  @override
  State<LatestMessageControl> createState() => _LatestMessageControlState();
}

class _LatestMessageControlState extends State<LatestMessageControl>
    with SingleTickerProviderStateMixin {
  static const _noticeText = '消息已发送 · 查看';
  static const _collapsedWidth = 44.0;
  static const _expandedWidth = 150.0;

  late final AnimationController _replacementController;

  @override
  void initState() {
    super.initState();
    _replacementController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
      reverseDuration: const Duration(milliseconds: 420),
      value: widget.showSentNotice ? 1 : 0,
    );
  }

  @override
  void didUpdateWidget(covariant LatestMessageControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showSentNotice == widget.showSentNotice) return;
    if (widget.showSentNotice) {
      _replacementController.forward();
    } else {
      _replacementController.reverse();
    }
  }

  @override
  void dispose() {
    _replacementController.dispose();
    super.dispose();
  }

  double _intervalProgress(
    double value, {
    required double start,
    required double end,
  }) {
    return Curves.easeOutCubic.transform(
      ((value - start) / (end - start)).clamp(0.0, 1.0),
    );
  }

  Widget _buildNotice(double value) {
    final characters = _noticeText.runes
        .map(String.fromCharCode)
        .toList(growable: false);
    return ExcludeSemantics(
      child: OverflowBox(
        minWidth: 0,
        maxWidth: _expandedWidth,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var index = 0; index < characters.length; index++)
              Builder(
                builder: (context) {
                  final colors = context.neu;
                  final start = 0.12 + index * 0.045;
                  final progress = _intervalProgress(
                    value,
                    start: start,
                    end: (start + 0.28).clamp(0.0, 1.0),
                  );
                  final isViewCharacter = index >= characters.length - 2;
                  return Opacity(
                    opacity: progress,
                    child: Transform.translate(
                      offset: Offset(0, 7 * (1 - progress)),
                      child: Text(
                        characters[index],
                        style: TextStyle(
                          color: isViewCharacter
                              ? colors.accentPressed
                              : colors.text,
                          fontSize: 13.5,
                          fontWeight: isViewCharacter
                              ? FontWeight.w700
                              : FontWeight.w600,
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    return IgnorePointer(
      ignoring: !widget.visible,
      child: AnimatedOpacity(
        opacity: widget.visible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        child: AnimatedScale(
          scale: widget.visible ? 1 : 0.88,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutBack,
          child: AnimatedBuilder(
            animation: _replacementController,
            builder: (context, _) {
              final value = _replacementController.value;
              final widthProgress = _intervalProgress(
                value,
                start: 0,
                end: 0.65,
              );
              final arrowExit = _intervalProgress(value, start: 0, end: 0.22);
              return Semantics(
                button: true,
                label: widget.showSentNotice ? '消息已发送，查看最新消息' : '滚动到最新消息',
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: widget.onPressed,
                    borderRadius: BorderRadius.circular(NeuRadius.surface),
                    child: Ink(
                      width: lerpDouble(
                        _collapsedWidth,
                        _expandedWidth,
                        widthProgress,
                      ),
                      height: 44,
                      decoration: BoxDecoration(
                        color: colors.surfaceStrong.withValues(alpha: 0.96),
                        borderRadius: BorderRadius.circular(NeuRadius.surface),
                        border: Border.all(color: colors.glassBorder),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(NeuRadius.surface),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Opacity(
                              opacity: 1 - arrowExit,
                              child: Transform.translate(
                                offset: Offset(0, -6 * arrowExit),
                                child: Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  color: colors.text,
                                  size: 25,
                                ),
                              ),
                            ),
                            _buildNotice(value),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
