import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/interaction_mode_provider.dart';
import '../../../providers/text_selection_target.dart';
import '../../../src/rust/api/matrix.dart' hide redactMessage;
import '../../../theme/material_theme.dart';
import '../../../theme/neu_colors.dart';
import '../../../theme/tokens/app_typography.dart';

import '../../../features/markdown/markdown_composer.dart';
import '../../../features/matrix_html/matrix_html_parser.dart';
import '../../../features/matrix_html/matrix_html_renderer.dart';
import '../../../features/matrix_html/matrix_link_router.dart';
import '../message_text.dart';
import '../link_preview.dart';
import 'timeline_bubble_frame.dart';
import 'timeline_text_metadata_layout.dart';

/// The HTML a text message should render with: the sender's formatted body,
/// or HTML rebuilt from the markdown source when the sender's HTML lost its
/// table structure. Null for plain-text messages.
String? effectiveFormattedHtml(ChatMessage message) =>
    recoverDegradedTableHtml(
      body: message.content,
      formattedBody: message.formattedBody,
    ) ??
    message.formattedBody;

class TimelineTextBubble extends ConsumerWidget {
  const TimelineTextBubble({
    super.key,
    required this.message,
    required this.isMe,
    required this.isFirst,
    required this.isLast,
    required this.formattedBody,
    required this.mentionDisplayNames,
    required this.onMentionTap,
    required this.messageIndex,
    required this.metadata,
    this.onMessageJumpRequested,
  });
  final ChatMessage message;
  final bool isMe;
  final bool isFirst;
  final bool isLast;
  final String? formattedBody;
  final Map<String, String> mentionDisplayNames;
  final MessageMentionTapHandler onMentionTap;
  final Map<String, ChatMessage> messageIndex;
  final Widget metadata;
  final ValueChanged<String>? onMessageJumpRequested;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A long press on touch opens the message menu; text becomes selectable
    // only after the menu asked for it.
    final selecting = ref.watch(textSelectionTargetProvider) == message.id;
    final selectable =
        selecting ||
        ref
            .watch(interactionModeProvider)
            .usesKeyboardMouse(Theme.of(context).platform);
    final formattedBody = this.formattedBody;
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    final typography = AppTypography.maybeOf(context);
    final maxBubbleWidth = TimelineBubbleFrame.maxWidth(context);
    final bodyBase = typography?.chatBody ?? textTheme.bodyLarge!;
    final textStyle = bodyBase.copyWith(
      color: isMe ? outgoingBubbleForeground(context) : colors.text,
      height: context.isMaterial ? 1.625 : 1.35,
    );
    final previewTextSource = formattedBody == null || formattedBody.isEmpty
        ? message.content
        : matrixHtmlTextExcludingCode(formattedBody);
    final urlMatches = detectMessageUrls(previewTextSource);
    List<Uri> previewUris = [];
    for (final match in urlMatches) {
      if (matrixUserIdFromUri(match.uri) == null) {
        previewUris.add(match.uri);
      }
    }
    const linkRouter = MatrixLinkRouter();
    final hasReply = message.inReplyTo != null;
    final hasFormattedBody = formattedBody?.isNotEmpty == true;
    final readerHtml = hasFormattedBody ? formattedBody : null;
    final replyContent = hasReply ? _getReplyContent(message.inReplyTo!) : null;
    final replyPreviewWidth = replyContent == null
        ? 0.0
        : _replyPreviewWidth(context, replyContent, isMe, maxBubbleWidth - 28);
    final senderHeader = !isMe && isFirst
        ? Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text(
              message.senderName,
              style: textTheme.bodySmall?.copyWith(
                color: colors.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          )
        : null;
    final linkPreview = previewUris.isNotEmpty
        ? Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              spacing: 7,
              children: previewUris
                  .map(
                    (previewUri) => LinkPreviewCard(
                      key: ValueKey('link-preview:${message.id}:$previewUri'),
                      uri: previewUri,
                      isMe: isMe,
                      width: maxBubbleWidth - 28,
                      onOpen: linkRouter.open,
                    ),
                  )
                  .toList(),
            ),
          )
        : null;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ?senderHeader,
        if (replyContent != null)
          _buildReplyPreview(context, message.inReplyTo!, replyContent, isMe),
        if (readerHtml != null)
          MatrixHtmlMessage(
            key: ValueKey('formatted-body:${message.id}'),
            html: readerHtml,
            style: textStyle,
            accentColor: isMe
                ? outgoingBubbleForeground(context)
                : colors.accent,
            mentionDisplayNames: mentionDisplayNames,
            onMentionTap: onMentionTap,
            trailingMetadata: metadata,
            minWidth: replyPreviewWidth,
            selectable: selectable,
          )
        else
          TimelineAdaptiveTextMetadata(
            key: ValueKey('adaptive-text-metadata:${message.id}'),
            text: message.content,
            textStyle: textStyle,
            metadata: metadata,
            maxWidth: maxBubbleWidth - 28,
            minWidth: replyPreviewWidth,
            linkColor: isMe ? outgoingBubbleForeground(context) : colors.accent,
            onUrlTap: linkRouter.open,
            mentionDisplayNames: mentionDisplayNames,
            mentionedUserIds: message.mentionedUserIds,
            onMentionTap: onMentionTap,
            selectable: selecting,
          ),
        ?linkPreview,
      ],
    );
    return TimelineBubbleFrame(
      bubbleKey: ValueKey('text-bubble:${message.id}'),
      isMe: isMe,
      isFirst: isFirst,
      isLast: isLast,
      // The outline marks the bubble whose text accepts a drag right now.
      child: selecting
          // A touch anywhere else drops the selection mode again.
          ? TapRegion(
              onTapOutside: (_) =>
                  ref.read(textSelectionTargetProvider.notifier).clear(),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: colors.accent, width: 1.5),
                  borderRadius: BorderRadius.circular(NeuRadius.tag),
                ),
                child: content,
              ),
            )
          : content,
    );
  }

  Widget _buildReplyPreview(
    BuildContext context,
    String replyToId,
    String replyContent,
    bool isMe,
  ) {
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
            style: _replyPreviewTextStyle(context, isMe),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }

  TextStyle _replyPreviewTextStyle(BuildContext context, bool isMe) {
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

  double _replyPreviewWidth(
    BuildContext context,
    String replyContent,
    bool isMe,
    double maxWidth,
  ) {
    const horizontalPadding = 16.0;
    final textMaxWidth = math.max(0.0, maxWidth - horizontalPadding);
    final painter = TextPainter(
      text: TextSpan(
        text: replyContent,
        style: _replyPreviewTextStyle(context, isMe),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 2,
      ellipsis: '...',
    )..layout(maxWidth: textMaxWidth);
    final lines = painter.computeLineMetrics();
    final widestLine = lines.fold<double>(
      0,
      (width, line) => math.max(width, line.width),
    );
    return math.min(maxWidth, widestLine + horizontalPadding);
  }

  String _getReplyContent(String replyToId) {
    final found = messageIndex[replyToId];
    if (found != null) {
      return '${found.senderName}: ${found.content}';
    }
    return '...';
  }
}
