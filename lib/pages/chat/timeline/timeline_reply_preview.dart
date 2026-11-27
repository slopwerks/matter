import 'package:material_ui/material_ui.dart';

import '../../../theme/material_theme.dart';
import '../../../theme/neu_colors.dart';
import '../../../theme/tokens/app_typography.dart';
import 'timeline_bubble_frame.dart';

class TimelineReplyPreview extends StatelessWidget {
  const TimelineReplyPreview({
    super.key,
    required this.replyToId,
    required this.replyContent,
    required this.isMe,
    this.onMessageJumpRequested,
  });
  final String replyToId;
  final String replyContent;
  final bool isMe;
  final ValueChanged<String>? onMessageJumpRequested;
  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final style = context.isMaterial
        ? materialTimelinePreviewStyle(Theme.of(context))
        : null;
    return Semantics(
      button: true,
      label: '跳转到被回复的消息',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onMessageJumpRequested == null
            ? null
            : () => onMessageJumpRequested!(replyToId),
        child: Container(
          key: ValueKey('reply-preview:$replyToId'),
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color:
                style?.fill ??
                (isMe
                    ? Colors.white.withValues(alpha: 0.16)
                    : colors.base.withValues(alpha: 0.65)),
            borderRadius: style?.radius ?? BorderRadius.circular(NeuRadius.tag),
            border: Border(
              left: BorderSide(
                color:
                    style?.accent ??
                    (isMe ? outgoingBubbleForeground(context) : colors.accent),
                width: 3,
              ),
            ),
          ),
          child: Text(
            replyContent,
            style: replyPreviewTextStyle(context, isMe),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

TextStyle replyPreviewTextStyle(BuildContext context, bool isMe) {
  final colors = context.neu;
  final theme = Theme.of(context);
  final typography = AppTypography.maybeOf(context);
  final small = theme.textTheme.bodySmall!;
  return small.copyWith(
    fontFamily: typography?.chatBody.fontFamily ?? small.fontFamily,
    fontFamilyFallback:
        typography?.chatBody.fontFamilyFallback ?? small.fontFamilyFallback,
    fontSize: (small.fontSize ?? 12) * (typography?.chatScale ?? 1.0),
    color: context.isMaterial
        ? materialTimelinePreviewStyle(theme).foreground
        : isMe
        ? outgoingBubbleForeground(context).withValues(alpha: 0.7)
        : colors.textTertiary,
    height: 1.3,
  );
}
