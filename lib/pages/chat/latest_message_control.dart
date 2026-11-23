import 'dart:ui' show lerpDouble;

import 'package:material_ui/material_ui.dart';

import '../../theme/neu_colors.dart';
import '../../theme/material_theme.dart';

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
  final Widget? unreadControl;
  final VoidCallback onPressed;

  const LatestMessageControl({
    super.key,
    required this.visible,
    required this.showSentNotice,
    this.unreadControl,
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

  Widget _buildNotice(double value, double expandedWidth) {
    final characters = _noticeText.runes
        .map(String.fromCharCode)
        .toList(growable: false);
    return ExcludeSemantics(
      child: OverflowBox(
        minWidth: 0,
        maxWidth: expandedWidth,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < characters.length; index++)
                Builder(
                  builder: (context) {
                    final colors = context.neu;
                    final material = context.isMaterial;
                    final style = material
                        ? materialLatestMessageStyle(Theme.of(context))
                        : null;
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
                          style: style != null
                              ? (isViewCharacter ? style.action : style.notice)
                              : TextStyle(
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
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final theme = Theme.of(context);
    final material = context.isMaterial;
    final radius = BorderRadius.circular(NeuRadius.surface);
    final style = material ? materialLatestMessageStyle(theme) : null;
    final shape = style?.shape ?? RoundedRectangleBorder(borderRadius: radius);
    final painter = TextPainter(
      text: TextSpan(text: _noticeText, style: style?.action),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: Directionality.of(context),
    )..layout();
    final expandedWidth = material
        ? (painter.width + 2 * materialTimelinePillInset).clamp(
            48.0,
            MediaQuery.sizeOf(context).width - 32,
          )
        : _expandedWidth;
    final height = material ? materialTimelinePillHeight(context) : 44.0;
    painter.text = TextSpan(text: '回到最新', style: theme.textTheme.labelMedium);
    painter.layout();
    final jumpWidth =
        painter.width +
        materialTimelinePillIcon +
        4 +
        2 * materialTimelinePillInset;
    painter.dispose();
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
              // Keep the controller mounted while unread navigation occupies the slot.
              // Restore it only after the sent notice has finished retracting.
              if (!widget.showSentNotice &&
                  _replacementController.isDismissed &&
                  widget.unreadControl != null) {
                return widget.unreadControl!;
              }
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
                    customBorder: shape,
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        vertical:
                            material &&
                                theme.materialTapTargetSize ==
                                    MaterialTapTargetSize.padded
                            ? (kMinInteractiveDimension - height).clamp(
                                    0.0,
                                    double.infinity,
                                  ) /
                                  2
                            : 0,
                      ),
                      child: Ink(
                        width: lerpDouble(
                          material ? jumpWidth : _collapsedWidth,
                          expandedWidth,
                          widthProgress,
                        ),
                        height: height,
                        decoration: material
                            ? ShapeDecoration(
                                color: theme.colorScheme.secondaryContainer,
                                shape: shape,
                              )
                            : BoxDecoration(
                                color: colors.surfaceStrong.withValues(
                                  alpha: 0.96,
                                ),
                                borderRadius: radius,
                                border: Border.all(color: colors.glassBorder),
                              ),
                        padding: material
                            ? const EdgeInsets.all(materialTimelinePillInset)
                            : EdgeInsets.zero,
                        child: ClipPath(
                          clipper: ShapeBorderClipper(shape: shape),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Opacity(
                                opacity: 1 - arrowExit,
                                child: Transform.translate(
                                  offset: Offset(0, -6 * arrowExit),
                                  child: material
                                      ? FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            spacing: 4,
                                            children: [
                                              Icon(
                                                Icons
                                                    .keyboard_arrow_down_rounded,
                                                size: materialTimelinePillIcon,
                                                color: theme
                                                    .colorScheme
                                                    .onSecondaryContainer,
                                              ),
                                              Text(
                                                '回到最新',
                                                style: theme
                                                    .textTheme
                                                    .labelMedium
                                                    ?.copyWith(
                                                      color: theme
                                                          .colorScheme
                                                          .onSecondaryContainer,
                                                    ),
                                              ),
                                            ],
                                          ),
                                        )
                                      : Icon(
                                          Icons.keyboard_arrow_down_rounded,
                                          color: colors.text,
                                          size: 25,
                                        ),
                                ),
                              ),
                              _buildNotice(
                                value,
                                material
                                    ? expandedWidth -
                                          2 * materialTimelinePillInset
                                    : expandedWidth,
                              ),
                            ],
                          ),
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
