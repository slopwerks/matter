import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../src/rust/api/matrix.dart' hide redactMessage;
import '../../../theme/neu_colors.dart';

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

class TimelineTextBubble extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final formattedBody = this.formattedBody;
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    final maxBubbleWidth = TimelineBubbleFrame.maxWidth(context);
    final textStyle = textTheme.bodyLarge!.copyWith(
      color: isMe ? colors.onAccent : colors.text,
      height: 1.35,
    );
    final previewTextSource = formattedBody == null || formattedBody.isEmpty
        ? message.content
        : matrixHtmlTextExcludingCode(formattedBody);
    final urlMatches = detectMessageUrls(previewTextSource);
    Uri? previewUri;
    for (final match in urlMatches) {
      if (matrixUserIdFromUri(match.uri) == null) {
        previewUri = match.uri;
        break;
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
    final linkPreview = previewUri != null
        ? Padding(
            padding: const EdgeInsets.only(top: 8),
            child: LinkPreviewCard(
              key: ValueKey('link-preview:${message.id}:$previewUri'),
              uri: previewUri,
              isMe: isMe,
              width: maxBubbleWidth - 28,
              onOpen: linkRouter.open,
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
            accentColor: isMe ? colors.onAccent : colors.accent,
            mentionDisplayNames: mentionDisplayNames,
            onMentionTap: onMentionTap,
            trailingMetadata: metadata,
            minWidth: replyPreviewWidth,
          )
        else
          TimelineAdaptiveTextMetadata(
            key: ValueKey('adaptive-text-metadata:${message.id}'),
            text: message.content,
            textStyle: textStyle,
            metadata: metadata,
            maxWidth: maxBubbleWidth - 28,
            minWidth: replyPreviewWidth,
            linkColor: isMe ? colors.onAccent : colors.accent,
            onUrlTap: linkRouter.open,
            mentionDisplayNames: mentionDisplayNames,
            mentionedUserIds: message.mentionedUserIds,
            onMentionTap: onMentionTap,
          ),
        ?linkPreview,
      ],
    );
    return TimelineBubbleFrame(
      bubbleKey: ValueKey('text-bubble:${message.id}'),
      isMe: isMe,
      isFirst: isFirst,
      isLast: isLast,
      child: content,
    );
  }

  Widget _buildReplyPreview(
    BuildContext context,
    String replyToId,
    String replyContent,
    bool isMe,
  ) {
    final colors = context.neu;
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
            color: isMe
                ? Colors.white.withValues(alpha: 0.16)
                : colors.base.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(NeuRadius.tag),
            border: Border(
              left: BorderSide(
                color: isMe ? Colors.white70 : colors.accent,
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
    return Theme.of(context).textTheme.bodySmall!.copyWith(
      color: isMe
          ? colors.onAccent.withValues(alpha: 0.7)
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
