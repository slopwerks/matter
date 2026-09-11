import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/markdown/markdown_composer.dart';
import '../../features/markdown/markdown_source_store.dart';
import '../../features/matrix_html/matrix_html_parser.dart';
import '../../features/matrix_html/matrix_html_renderer.dart';
import '../../features/matrix_html/matrix_link_router.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import 'action_failure_message.dart';
import '../../src/rust/api/matrix.dart' hide redactMessage;
import '../../theme/neu_colors.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/glass.dart';
import '../../widgets/neu_decoration.dart';
import '../../widgets/sheets.dart';
import 'chat_timestamp.dart';
import 'emoji_picker_panel.dart';
import 'message_input.dart'
    show editingDraftProvider, editingSendInFlightProvider;
import 'file_message_bubble.dart';
import 'forward_message_sheet.dart';
import 'image_message_bubble.dart';
import 'link_preview.dart';
import 'location_message_bubble.dart';
import 'message_insert_animation.dart';
import 'message_reader_page.dart';
import 'message_text.dart';
import 'poll_message_bubble.dart';
import 'video_message_bubble.dart';
import 'send_flight.dart';

/// The HTML a text message should render with: the sender's formatted body,
/// or HTML rebuilt from the markdown source when the sender's HTML lost its
/// table structure. Null for plain-text messages.
String? effectiveFormattedHtml(ChatMessage message) =>
    recoverDegradedTableHtml(
      body: message.content,
      formattedBody: message.formattedBody,
    ) ??
    message.formattedBody;

/// 新拟物气泡装饰:超椭圆圆角 + 对角渐变填充 + 双向收敛投影。
/// 配方与 [NeuDecoration] 的 raised/intensity .7 一致,但接受分角
/// [BorderRadius],以保留同发送者聚合时的拼接圆角。
Decoration neuBubbleDecoration(
  NeuColors colors, {
  required bool isMe,
  required BorderRadius borderRadius,
}) {
  const offset = 3.8 * .7;
  return ShapeDecoration(
    shape: RoundedSuperellipseBorder(borderRadius: borderRadius),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: isMe
          ? [neuShift(colors.accent, .08), neuShift(colors.accent, -.06)]
          : [neuShift(colors.card, .055), neuShift(colors.card, -.05)],
    ),
    shadows: neuBubbleShadows(colors, offset: offset),
  );
}

/// 与 [NeuDecoration] raised/intensity .7 观感一致的柔和小投影
/// (BoxShadow 形式,供 BoxDecoration 的媒体气泡复用)。
List<BoxShadow> neuBubbleShadows(NeuColors colors, {double offset = 2.66}) => [
  BoxShadow(
    color: colors.shadowDark.withValues(alpha: .72),
    blurRadius: offset * 2.3,
    offset: Offset(offset, offset),
  ),
  BoxShadow(
    color: colors.shadowLight.withValues(alpha: colors.highlightAlpha),
    blurRadius: offset * 1.5,
    offset: Offset(-offset, -offset),
  ),
];

class MessageGroup {
  final String senderId;
  final String senderName;
  final bool isMe;
  final List<ChatMessage> messages;
  final bool startsCluster;
  bool endsCluster;

  MessageGroup({
    required this.senderId,
    required this.senderName,
    required this.isMe,
    required this.messages,
    this.startsCluster = true,
    this.endsCluster = true,
  });
}

class MessageGroupWidget extends ConsumerWidget {
  final MessageGroup group;
  final bool showAvatar;
  final String roomId;
  final Map<String, ChatMessage> messageIndex;
  final Map<String, GlobalKey> messageAnchorKeys;
  final Map<String, String> remoteToLocalFlightId;
  final Set<String> insertionAnimationIds;
  final Set<String> lateralInsertionAnimationIds;
  final Map<String, Contact> membersById;
  final String? senderAvatarUrl;
  final bool compact;
  final ScrollController? scrollController;
  final GlobalKey? scrollViewportKey;
  final double stickyBottomInset;
  final VoidCallback? onImageLoaded;
  final VoidCallback? onReplyRequested;
  final ValueChanged<String>? onMentionRequested;
  final ValueChanged<String>? onMessageJumpRequested;
  final ValueChanged<ChatRoom>? onMessageForwarded;

  const MessageGroupWidget({
    super.key,
    required this.group,
    required this.roomId,
    required this.messageIndex,
    this.messageAnchorKeys = const {},
    this.remoteToLocalFlightId = const {},
    this.insertionAnimationIds = const {},
    this.lateralInsertionAnimationIds = const {},
    this.membersById = const {},
    this.showAvatar = true,
    this.senderAvatarUrl,
    this.compact = false,
    this.scrollController,
    this.scrollViewportKey,
    this.stickyBottomInset = 0,
    this.onImageLoaded,
    this.onReplyRequested,
    this.onMentionRequested,
    this.onMessageJumpRequested,
    this.onMessageForwarded,
  });

  static const double _avatarSize = 36.0;
  static const double _avatarSlotWidth = 44.0;
  static const double _messageBottomPadding = 1.0;
  static const double _groupBottomGap = 9.0;
  static const double _joinedRadius = 6.0;

  /// Stable row key for list identity. Local outgoing messages keep the same
  /// key across pending/sent/failed prefix changes so the [SendFlightTarget]
  /// state (and its animation target position) survives id transitions.
  /// Matched remote events also reuse the local flight id so the animation can
  /// follow the message to its final position.
  String? _messageFlightId(ChatMessage message) =>
      messageSendFlightId(message.id, remoteToLocalFlightId);

  String _messageRowKey(ChatMessage message) {
    // Preserve the bubble and loaded media while the server event takes over.
    final flightId = _messageFlightId(message);
    if (flightId != null) return 'message-row:$flightId';
    return 'message-row:${message.id}';
  }

  Widget _anchoredMessage(ChatMessage message, Widget child) {
    final anchorKey = messageAnchorKeys[message.id];
    return KeyedSubtree(
      key: ValueKey(_messageRowKey(message)),
      child: anchorKey == null
          ? child
          : KeyedSubtree(key: anchorKey, child: child),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isMe = group.isMe;
    final mentionDisplayNames = <String, String>{
      for (final entry in membersById.entries) entry.key: entry.value.name,
    };
    final isEventGroup = group.messages.every(
      (m) => m.msgType == MessageType.event,
    );

    if (isEventGroup) {
      return Padding(
        padding: EdgeInsets.only(
          left: 12,
          right: 12,
          bottom: group.endsCluster ? _groupBottomGap : 0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: group.messages
              .asMap()
              .entries
              .map(
                (e) => _anchoredMessage(
                  e.value,
                  _buildMessage(
                    context,
                    ref,
                    e.value,
                    false,
                    membersById: membersById,
                    mentionDisplayNames: mentionDisplayNames,
                    isFirst: e.key == 0 && group.startsCluster,
                    isLast:
                        e.key == group.messages.length - 1 && group.endsCluster,
                  ),
                ),
              )
              .toList(),
        ),
      );
    }

    if (isMe) {
      return Padding(
        padding: EdgeInsets.only(
          left: 12,
          right: 12,
          bottom: group.endsCluster ? _groupBottomGap : 0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: group.messages
              .asMap()
              .entries
              .map(
                (e) => _anchoredMessage(
                  e.value,
                  _buildMessage(
                    context,
                    ref,
                    e.value,
                    true,
                    membersById: membersById,
                    mentionDisplayNames: mentionDisplayNames,
                    isFirst: e.key == 0 && group.startsCluster,
                    isLast:
                        e.key == group.messages.length - 1 && group.endsCluster,
                  ),
                ),
              )
              .toList(),
        ),
      );
    }

    final messagesColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: group.messages
          .asMap()
          .entries
          .map(
            (e) => _anchoredMessage(
              e.value,
              _buildMessage(
                context,
                ref,
                e.value,
                false,
                membersById: membersById,
                mentionDisplayNames: mentionDisplayNames,
                isFirst: e.key == 0 && group.startsCluster,
                isLast: e.key == group.messages.length - 1 && group.endsCluster,
              ),
            ),
          )
          .toList(),
    );

    if (compact) {
      return Padding(
        padding: EdgeInsets.only(
          left: 12,
          right: 12,
          bottom: group.endsCluster ? _groupBottomGap : 0,
        ),
        child: messagesColumn,
      );
    }

    return Padding(
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        bottom: group.endsCluster ? _groupBottomGap : 0,
      ),
      child: _StickyAvatarMessageGroup(
        showAvatar: showAvatar,
        fallback: group.senderName,
        avatarUrl: senderAvatarUrl,
        scrollController: scrollController,
        scrollViewportKey: scrollViewportKey,
        avatarSize: _avatarSize,
        avatarSlotWidth: _avatarSlotWidth,
        bottomInset: stickyBottomInset,
        onAvatarLongPress: onMentionRequested == null
            ? null
            : () => onMentionRequested!(group.senderId),
        messagesBuilder: (avatarSwipeOffset) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: group.messages
              .asMap()
              .entries
              .map(
                (e) => _anchoredMessage(
                  e.value,
                  _buildMessage(
                    context,
                    ref,
                    e.value,
                    false,
                    membersById: membersById,
                    mentionDisplayNames: mentionDisplayNames,
                    isFirst: e.key == 0 && group.startsCluster,
                    isLast:
                        e.key == group.messages.length - 1 && group.endsCluster,
                    linkedAvatarOffset: e.key == group.messages.length - 1
                        ? avatarSwipeOffset
                        : null,
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  Widget _buildMessage(
    BuildContext context,
    WidgetRef ref,
    ChatMessage message,
    bool isMe, {
    required Map<String, Contact> membersById,
    required Map<String, String> mentionDisplayNames,
    bool isFirst = false,
    bool isLast = false,
    ValueNotifier<double>? linkedAvatarOffset,
  }) {
    if (message.msgType == MessageType.event) {
      BuildContext? eventContext;
      return GestureDetector(
        onLongPress: () =>
            _showContextMenu(eventContext ?? context, ref, message),
        child: Padding(
          padding: EdgeInsets.only(
            top: isFirst ? 2 : 1,
            bottom: _messageBottomPadding,
          ),
          child: Builder(
            builder: (ctx) {
              eventContext = ctx;
              return _buildEventMessage(context, message);
            },
          ),
        ),
      );
    }

    final flightId = _messageFlightId(message);
    final visualMessageId = flightId ?? message.id;
    final isLocalOutgoing = isLocalOutgoingMessage(message.id);
    final isLocalFailed = isLocalOutgoingFailedMessage(message.id);
    final isLocalSent = isLocalOutgoingSentMessage(message.id);
    final messageBorderRadius = _messageBorderRadius(
      isMe: isMe,
      isFirst: isFirst,
      isLast: isLast,
    );
    final metadata = _buildMessageMetadata(
      context,
      ref,
      message,
      overlay: message.msgType != MessageType.text,
    );
    void onMentionTap(String userId) =>
        _showMemberProfile(context, userId, membersById[userId]);
    final readerHtml = message.msgType == MessageType.text
        ? effectiveFormattedHtml(message)
        : null;
    final VoidCallback? onReadFullScreen =
        readerHtml != null && readerHtml.isNotEmpty
        ? () => _openReaderFullScreen(
            context,
            html: readerHtml,
            mentionDisplayNames: mentionDisplayNames,
          )
        : null;
    final coreBubble =
        message.msgType == MessageType.video &&
            (message.imageUrl != null || message.mediaSourceJson != null)
        ? VideoMessageBubble(
            key: ValueKey('video-bubble:$visualMessageId'),
            videoUrl: message.imageUrl,
            mediaSourceJson: message.mediaSourceJson,
            filename: message.content,
            videoWidth: message.imageWidth,
            videoHeight: message.imageHeight,
            isMe: isMe,
            heroTag: 'video-preview:$visualMessageId',
            metadata: metadata,
            onLoaded: onImageLoaded,
          )
        : (message.msgType == MessageType.image ||
                  message.msgType == MessageType.sticker) &&
              (message.imageUrl != null || message.mediaSourceJson != null)
        ? ImageMessageBubble(
            key: ValueKey('image-bubble:$visualMessageId'),
            imageUrl: message.imageUrl,
            mediaSourceJson: message.mediaSourceJson,
            imageWidth: message.imageWidth,
            imageHeight: message.imageHeight,
            caption: message.caption,
            captionFormattedBody: message.captionFormattedBody,
            mentionDisplayNames: mentionDisplayNames,
            mentionedUserIds: message.mentionedUserIds,
            onMentionTap: onMentionTap,
            isMe: isMe,
            heroTag: 'image-preview:$visualMessageId',
            isSticker: message.msgType == MessageType.sticker,
            metadata: metadata,
            borderRadius: messageBorderRadius,
            onLoaded: onImageLoaded,
          )
        : message.msgType == MessageType.poll && message.poll != null
        ? PollMessageBubble(
            key: ValueKey('poll-bubble:${message.id}'),
            roomId: roomId,
            pollStartEventId: message.id,
            poll: message.poll!,
            isMe: isMe,
            metadata: metadata,
          )
        : message.msgType == MessageType.location && message.geoUri != null
        ? LocationMessageBubble(
            key: ValueKey('location-bubble:${message.id}'),
            body: message.content,
            geoUri: message.geoUri!,
            isMe: isMe,
            metadata: metadata,
          )
        : message.msgType == MessageType.file &&
              (message.mediaSourceJson != null || message.imageUrl != null)
        ? FileMessageBubble(
            key: ValueKey('file-bubble:${message.id}'),
            filename: message.filename ?? message.content,
            caption: message.caption,
            fileSize: message.fileSize,
            mediaSourceJson: message.mediaSourceJson,
            imageUrl: message.imageUrl,
            isMe: isMe,
            metadata: metadata,
          )
        : _buildTextBubble(
            context,
            ref,
            message,
            isMe,
            isFirst: isFirst,
            isLast: isLast,
            formattedBody: readerHtml,
            mentionDisplayNames: mentionDisplayNames,
            onMentionTap: onMentionTap,
          );
    final bubble = coreBubble;
    // Capture the bubble's own build context so the floating menu can anchor
    // to the bubble rect rather than the whole message-group rect. The outer
    // `_buildMessage` context resolves to the group's outer render object.
    BuildContext? bubbleContext;
    final trackedBubble = Builder(
      builder: (ctx) {
        bubbleContext = ctx;
        return bubble;
      },
    );
    final displayedBubble = flightId != null
        ? SendFlightTarget(
            key: ValueKey(flightId),
            messageId: message.id,
            flightId: flightId,
            latestScrollController: scrollController,
            lockEndAtLatest: true,
            waitForTargetReady: message.msgType == MessageType.sticker,
            endBorderRadius: messageBorderRadius,
            bottomInset: stickyBottomInset,
            child: trackedBubble,
          )
        : trackedBubble;

    final messageRow = GestureDetector(
      onLongPress: isLocalOutgoing
          ? (isLocalFailed
                ? () => _showFailedMessageMenu(
                    bubbleContext ?? context,
                    ref,
                    message,
                  )
                : null)
          : () => _showContextMenu(
              bubbleContext ?? context,
              ref,
              message,
              onReadFullScreen: onReadFullScreen,
            ),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: EdgeInsets.only(
          top: isFirst ? 2 : 1,
          bottom: _messageBottomPadding,
        ),
        child: Column(
          crossAxisAlignment: isMe
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (isMe && isLocalOutgoing) ...[
                  _buildLocalOutgoingStatus(
                    context,
                    isLocalFailed,
                    isLocalSent,
                  ),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  key: ValueKey('message-bubble-slot:$visualMessageId'),
                  fit: FlexFit.loose,
                  child: displayedBubble,
                ),
                if (!isMe && isLocalOutgoing) ...[
                  const SizedBox(width: 6),
                  _buildLocalOutgoingStatus(
                    context,
                    isLocalFailed,
                    isLocalSent,
                  ),
                ],
              ],
            ),
            if (message.reactions.isNotEmpty)
              _buildReactionsRow(context, ref, message, isMe),
          ],
        ),
      ),
    );

    final displayedRow = flightId != null
        ? MessageInsertAnimation(
            key: ValueKey('message-insert:$flightId'),
            animate: insertionAnimationIds.contains(flightId),
            slideFromRight: lateralInsertionAnimationIds.contains(flightId),
            child: messageRow,
          )
        : messageRow;
    return SizedBox(
      width: double.infinity,
      child: _SwipeToReply(
        key: ValueKey('swipe-reply:$visualMessageId'),
        onReply: isLocalOutgoing
            ? null
            : () => _startReply(context, ref, message),
        linkedOffset: linkedAvatarOffset,
        child: Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: displayedRow,
        ),
      ),
    );
  }

  Widget _buildLocalOutgoingStatus(
    BuildContext context,
    bool failed,
    bool sent,
  ) {
    final colors = context.neu;
    if (failed) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Icon(Icons.error_rounded, color: colors.error, size: 18),
      );
    }
    if (sent) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Tooltip(
          message: '已发送，等待服务器同步',
          child: Icon(
            Icons.schedule_rounded,
            color: colors.textTertiary,
            size: 16,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SizedBox.square(
        dimension: 12,
        child: CircularProgressIndicator(
          strokeWidth: 1.6,
          color: colors.textTertiary.withValues(alpha: 0.72),
        ),
      ),
    );
  }

  /// Renders the aggregated emoji reactions below a bubble.
  Widget _buildReactionsRow(
    BuildContext context,
    WidgetRef ref,
    ChatMessage message,
    bool isMe,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        alignment: isMe ? WrapAlignment.end : WrapAlignment.start,
        children: message.reactions.map((reaction) {
          final reacted = reaction.myEventId != null;
          return _ReactionChip(
            key: ValueKey('${message.id}:${reaction.key}'),
            reaction: reaction,
            reacted: reacted,
            onTap: () async {
              try {
                if (reacted) {
                  // Toggle off: redact our own reaction event.
                  await redactMessage(ref, roomId, reaction.myEventId!);
                } else {
                  await sendReaction(
                    roomId: roomId,
                    eventId: message.id,
                    key: reaction.key,
                  );
                  await refreshMessages(ref, roomId);
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('回应失败: $e'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              }
            },
          );
        }).toList(),
      ),
    );
  }

  void _showMemberProfile(
    BuildContext context,
    String userId,
    Contact? member,
  ) {
    final memberName = member?.name.trim();
    final displayName = memberName == null || memberName.isEmpty
        ? userId
        : memberName;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        key: ValueKey('mention-profile:$userId'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: GlassPanel(
          radius: NeuRadius.nav,
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppAvatar(
                fallback: displayName,
                size: 64,
                radius: 20,
                url: member?.avatarUrl,
              ),
              const SizedBox(height: 14),
              Text(
                displayName,
                textAlign: TextAlign.center,
                style: Theme.of(dialogContext).textTheme.titleLarge,
              ),
              const SizedBox(height: 5),
              SelectableText(
                userId,
                textAlign: TextAlign.center,
                style: Theme.of(dialogContext).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('关闭'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Opens the full-screen reader for a formatted message. The reader
  /// lives on the root navigator and can outlive this bubble (responsive
  /// layout switch), so mentions inside it are shown through the
  /// navigator's context instead of this bubble's.
  void _openReaderFullScreen(
    BuildContext context, {
    required String html,
    required Map<String, String> mentionDisplayNames,
  }) {
    final navigator = Navigator.of(context, rootNavigator: true);
    openMessageReader(
      context,
      html: html,
      mentionDisplayNames: mentionDisplayNames,
      onMentionTap: (userId) {
        final navContext = navigator.context;
        if (navContext.mounted) {
          _showMemberProfile(navContext, userId, membersById[userId]);
        }
      },
    );
  }

  Widget _buildTextBubble(
    BuildContext context,
    WidgetRef ref,
    ChatMessage message,
    bool isMe, {
    bool isFirst = false,
    bool isLast = false,
    required String? formattedBody,
    required Map<String, String> mentionDisplayNames,
    required MessageMentionTapHandler onMentionTap,
  }) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    final maxBubbleWidth = math.min(
      MediaQuery.of(context).size.width * 0.68,
      520.0,
    );
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
    final metadata = _buildMessageMetadata(context, ref, message);
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
          _AdaptiveTextMetadata(
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
    final bubble = Container(
      key: ValueKey('text-bubble:${message.id}'),
      constraints: BoxConstraints(maxWidth: maxBubbleWidth),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: neuBubbleDecoration(
        colors,
        isMe: isMe,
        borderRadius: _messageBorderRadius(
          isMe: isMe,
          isFirst: isFirst,
          isLast: isLast,
        ),
      ),
      child: content,
    );
    return bubble;
  }

  BorderRadius _messageBorderRadius({
    required bool isMe,
    required bool isFirst,
    required bool isLast,
  }) {
    final outer = const Radius.circular(NeuRadius.content);
    final joined = const Radius.circular(_joinedRadius);
    if (isMe) {
      return BorderRadius.only(
        topLeft: outer,
        topRight: isFirst ? outer : joined,
        bottomLeft: outer,
        bottomRight: isLast ? const Radius.circular(NeuRadius.tag) : joined,
      );
    }
    return BorderRadius.only(
      topLeft: isFirst ? outer : joined,
      topRight: outer,
      bottomLeft: isLast ? const Radius.circular(NeuRadius.tag) : joined,
      bottomRight: outer,
    );
  }

  void _showEditHistory(BuildContext context, ChatMessage message) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    showNeuSheet(
      context: context,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
              child: Text('编辑记录', style: textTheme.titleMedium),
            ),
            for (var index = 0; index < message.editHistory.length; index++)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: index == message.editHistory.length - 1
                            ? colors.accentSoft
                            : colors.card.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(NeuRadius.tag),
                      ),
                      child: Text(
                        index == 0
                            ? '原始'
                            : index == message.editHistory.length - 1
                            ? '最新'
                            : '第 $index 次编辑',
                        style: textTheme.labelSmall?.copyWith(
                          color: index == message.editHistory.length - 1
                              ? colors.accent
                              : colors.textTertiary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      message.editHistory[index],
                      style: textTheme.bodyMedium?.copyWith(
                        color: colors.text,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
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

  IconData _eventIcon(ChatMessage message) {
    final content = message.content;
    if (content.contains('加入') || content.contains('邀请')) {
      return Icons.person_add_rounded;
    }
    if (content.contains('退出') ||
        content.contains('离开') ||
        content.contains('踢出') ||
        content.contains('移出')) {
      return Icons.person_remove_rounded;
    }
    if (content.contains('创建')) {
      return Icons.add_circle_outline_rounded;
    }
    if (content.contains('修改') ||
        content.contains('更改') ||
        content.contains('设置')) {
      return Icons.edit_rounded;
    }
    return Icons.info_outline_rounded;
  }

  Widget _buildEventMessage(BuildContext context, ChatMessage message) {
    final colors = context.neu;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Center(
        child: Container(
          constraints: BoxConstraints(
            maxWidth: math.min(MediaQuery.of(context).size.width * 0.82, 640.0),
            minHeight: 24,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: colors.card.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(NeuRadius.tag),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(_eventIcon(message), size: 13, color: colors.textTertiary),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  message.content,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(height: 1.2),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageMetadata(
    BuildContext context,
    WidgetRef ref,
    ChatMessage message, {
    bool overlay = false,
  }) {
    final colors = context.neu;
    final labelStyle = Theme.of(context).textTheme.labelSmall;
    final foreground = overlay
        ? Colors.white.withValues(alpha: 0.9)
        : message.isMe
        ? colors.onAccent.withValues(alpha: 0.65)
        : colors.textTertiary;
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (message.isEdited) ...[
          GestureDetector(
            onTap: () => _showEditHistory(context, message),
            child: Text(
              '已编辑',
              style: labelStyle?.copyWith(
                color: foreground.withValues(alpha: 0.75),
              ),
            ),
          ),
          const SizedBox(width: 5),
        ],
        Text(
          formatMessageTime(message.timestamp),
          style: labelStyle?.copyWith(
            color: foreground,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (message.isMe) ...[
          const SizedBox(width: 4),
          _buildReadIndicator(context, ref, message, color: foreground),
        ],
      ],
    );

    if (!overlay) {
      return KeyedSubtree(
        key: ValueKey('message-metadata:${message.id}'),
        child: content,
      );
    }
    return Positioned(
      right: 7,
      bottom: 6,
      child: Container(
        key: ValueKey('message-metadata:${message.id}'),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: content,
      ),
    );
  }

  Widget _buildReadIndicator(
    BuildContext context,
    WidgetRef ref,
    ChatMessage message, {
    required Color color,
  }) {
    final others = message.totalMembers - 1;
    if (others <= 0) {
      return const SizedBox.square(dimension: 15);
    }

    final readCount = message.readers.length;
    final icon = readCount == 0 ? Icons.done_rounded : Icons.done_all_rounded;
    final label = readCount == 0 ? '尚未已读' : '已读 $readCount/$others，点击查看';
    return Tooltip(
      message: label,
      child: GestureDetector(
        key: ValueKey('message-read-receipt:${message.id}'),
        onTap: readCount > 0
            ? () => _showReadReceipts(context, ref, message)
            : null,
        behavior: HitTestBehavior.opaque,
        child: Icon(icon, size: 15, color: color),
      ),
    );
  }

  /// Bottom sheet listing the members who read a message and when.
  void _showReadReceipts(
    BuildContext context,
    WidgetRef ref,
    ChatMessage message,
  ) {
    showNeuSheet(
      context: context,
      child: _ReadReceiptsSheet(message: message, roomId: roomId),
    );
  }

  Future<void> _sendReactionAndRefresh(
    BuildContext context,
    WidgetRef ref,
    String eventId,
    String emoji,
  ) async {
    try {
      await sendReaction(roomId: roomId, eventId: eventId, key: emoji);
      await refreshMessages(ref, roomId);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('回应失败: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  /// Full emoji picker panel (pure-Dart, no native plugin).
  void _showEmojiPicker(
    BuildContext context,
    WidgetRef ref,
    ChatMessage message,
  ) {
    final colors = context.neu;
    showNeuSheet(
      context: context,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 4),
            child: Row(
              children: [
                Text('选择表情', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Icon(
                    Icons.close_rounded,
                    color: colors.textTertiary,
                    size: 22,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.5,
            child: EmojiPickerPanel(
              onEmojiSelected: (emoji) async {
                Navigator.of(context).pop();
                await _sendReactionAndRefresh(context, ref, message.id, emoji);
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showContextMenu(
    BuildContext context,
    WidgetRef ref,
    ChatMessage message, {
    VoidCallback? onReadFullScreen,
  }) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final overlayContext = overlay.context;
    final container = ProviderScope.containerOf(context, listen: false);
    // Geometry of the long-pressed bubble, for popover positioning.
    final renderObject = context.findRenderObject();
    final Rect? bubbleRect = renderObject is RenderBox && renderObject.hasSize
        ? (renderObject.localToGlobal(Offset.zero) & renderObject.size)
        : null;
    final menuAccount = ref.read(activeUserIdProvider) ?? '';
    final canPin =
        message.msgType != MessageType.event &&
        !isLocalOutgoingMessage(message.id);
    bool? isPinned;
    var pinStateLoading = canPin;
    var menuOpen = true;

    late OverlayEntry entry;
    void close() {
      menuOpen = false;
      entry.remove();
    }

    entry = OverlayEntry(
      builder: (_) => _FloatingMessageMenu(
        message: message,
        isMe: message.isMe,
        bubbleRect: bubbleRect,
        onClose: close,
        onReadFullScreen: onReadFullScreen,
        onCopy: () async {
          await Clipboard.setData(ClipboardData(text: message.content));
          if (overlayContext.mounted) {
            neuToast(overlayContext, '已复制');
          }
        },
        onReply: () => _startReply(overlayContext, ref, message),
        onForward: () async {
          final targetRoom = await showForwardMessageSheet(
            context: overlayContext,
            sourceRoomId: roomId,
            message: message,
          );
          if (targetRoom != null) {
            onMessageForwarded?.call(targetRoom);
          }
        },
        onEdit: () {
          final roomAccountKey = activeRoomAccountKey(ref, roomId);
          if (_blockEditingTransition(overlayContext, ref, roomAccountKey)) {
            return;
          }
          ref.read(replyingToProvider(roomAccountKey).notifier).value = null;
          ref.read(editingMessageProvider(roomAccountKey).notifier).value =
              message;
        },
        onRecall: () async {
          try {
            await redactMessage(ref, roomId, message.id);
            await const MarkdownSourceStore().delete(
              userId:
                  ref.read(activeUserIdProvider) ??
                  ref.read(currentUserProvider)?.id ??
                  'anonymous',
              roomId: roomId,
              eventId: message.id,
            );
          } catch (e) {
            if (overlayContext.mounted) {
              ScaffoldMessenger.of(overlayContext).showSnackBar(
                SnackBar(
                  content: Text('撤回失败: $e'),
                  duration: const Duration(seconds: 2),
                ),
              );
            }
          }
        },
        isPinned: isPinned,
        pinStateLoading: pinStateLoading,
        onPin: isPinned == null
            ? null
            : () async {
                try {
                  final target = !isPinned!;
                  final pinned = await setPinnedMessage(
                    accountUserId: menuAccount,
                    roomId: roomId,
                    eventId: message.id,
                    pinned: target,
                  );
                  if (overlayContext.mounted) {
                    ScaffoldMessenger.of(overlayContext).showSnackBar(
                      SnackBar(
                        content: Text(pinned ? '消息已置顶' : '已取消置顶'),
                        duration: const Duration(seconds: 1),
                      ),
                    );
                  }
                  if (overlayContext.mounted) {
                    container.invalidate(
                      pinnedMessagesProvider((
                        roomId: roomId,
                        userId: menuAccount,
                      )),
                    );
                  }
                } catch (error) {
                  if (!overlayContext.mounted) {
                    return;
                  }
                  final timedOut = isMutationTimeout(error);
                  if (timedOut) {
                    // A timeout may still land server-side: the queued operation
                    // keeps running in the background, and setPinnedMessage
                    // returns the request value, not the final state. Tell the
                    // user to confirm instead of claiming a failed pin.
                    ScaffoldMessenger.of(overlayContext).showSnackBar(
                      const SnackBar(
                        content: Text('置顶操作超时，状态可能已更新，请刷新确认'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                    return;
                  }
                  // Non-timeout failures go through the shared wording (Chinese,
                  // partial-success passthrough) — one source for all pages.
                  ScaffoldMessenger.of(overlayContext).showSnackBar(
                    SnackBar(
                      content: Text(actionFailureMessage(error)),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              },
        onReact: (emoji) =>
            _sendReactionAndRefresh(overlayContext, ref, message.id, emoji),
        onShowFullEmojiPicker: () =>
            _showEmojiPicker(overlayContext, ref, message),
      ),
    );
    // Confirm the menu appeared with a light haptic.
    HapticFeedback.selectionClick();
    overlay.insert(entry);
    if (!canPin) return;
    try {
      final pinnedIds = await getPinnedEventIds(
        accountUserId: menuAccount,
        roomId: roomId,
      );
      if (!menuOpen || !overlayContext.mounted) return;
      isPinned = pinnedIds.contains(message.id);
      pinStateLoading = false;
      entry.markNeedsBuild();
    } catch (error) {
      if (!menuOpen || !overlayContext.mounted) return;
      pinStateLoading = false;
      entry.markNeedsBuild();
      debugPrint('Unable to load pinned state: $error');
      // Without the state read the menu cannot offer pin/unpin at all — say
      // so instead of silently dropping the entry.
      ScaffoldMessenger.of(overlayContext).showSnackBar(
        SnackBar(
          content: Text('无法获取置顶状态，请重试: ${actionFailureMessage(error)}'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  bool _blockEditingTransition(
    BuildContext context,
    WidgetRef ref,
    RoomAccountKey roomAccountKey,
  ) {
    if (ref.read(editingSendInFlightProvider(roomAccountKey)) == null) {
      return false;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('编辑正在发送，请稍候'),
        duration: Duration(seconds: 1),
      ),
    );
    return true;
  }

  void _startReply(BuildContext context, WidgetRef ref, ChatMessage message) {
    final roomAccountKey = activeRoomAccountKey(ref, roomId);
    if (_blockEditingTransition(context, ref, roomAccountKey)) return;
    ref.read(editingMessageProvider(roomAccountKey).notifier).value = null;
    ref.read(editingDraftProvider(roomAccountKey).notifier).value = null;
    ref.read(replyingToProvider(roomAccountKey).notifier).value = message;
    onReplyRequested?.call();
  }

  /// Menu for a failed local outgoing message: retry the send or drop the
  /// message. Failed sends are otherwise a dead end — no long-press menu,
  /// no retry, no delete — so the user can only retype the message.
  void _showFailedMessageMenu(
    BuildContext context,
    WidgetRef ref,
    ChatMessage message,
  ) {
    final colors = context.neu;
    final roomAccountKey = activeRoomAccountKey(ref, roomId);
    final canRetry = message.msgType == MessageType.text;
    showNeuSheet<void>(
      context: context,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          NeuSheetItem(
            icon: Icons.refresh_rounded,
            label: '重试发送',
            color: canRetry ? null : colors.textTertiary,
            trailing: canRetry
                ? null
                : Text(
                    '仅文本消息支持重试',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
            onTap: !canRetry
                ? () {}
                : () async {
                    Navigator.of(context).pop();
                    try {
                      await retryFailedLocalMessage(
                        ref,
                        roomAccountKey,
                        message.id,
                      );
                      if (context.mounted &&
                          ref.read(activeUserIdProvider) ==
                              roomAccountKey.userId) {
                        neuToast(context, '已重新发送');
                      }
                    } catch (error) {
                      if (context.mounted &&
                          ref.read(activeUserIdProvider) ==
                              roomAccountKey.userId) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('重试失败: $error'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      }
                    }
                  },
          ),
          NeuSheetItem(
            icon: Icons.delete_outline_rounded,
            label: '删除消息',
            color: colors.error,
            onTap: () {
              Navigator.of(context).pop();
              removeLocalOutgoingMessage(ref, roomAccountKey, message.id);
            },
          ),
        ],
      ),
    );
  }
}

class _SwipeToReply extends StatefulWidget {
  final Widget child;
  final VoidCallback? onReply;
  final ValueNotifier<double>? linkedOffset;

  const _SwipeToReply({
    super.key,
    required this.child,
    required this.onReply,
    this.linkedOffset,
  });

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply>
    with SingleTickerProviderStateMixin {
  // 与系统返回手势区对齐：Android CDD 规定侧滑返回触发区最大为 40dp。
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
  void didUpdateWidget(covariant _SwipeToReply oldWidget) {
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
    if (!_dragStartedInReplyRegion) return;
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
                          color: context.neu.accent.withValues(alpha: 0.14),
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
    );
  }
}

class _AdaptiveTextMetadata extends StatelessWidget {
  final String text;
  final TextStyle textStyle;
  final Widget metadata;
  final double maxWidth;
  final double minWidth;
  final Color linkColor;
  final MessageUrlTapHandler? onUrlTap;
  final Map<String, String> mentionDisplayNames;
  final List<String> mentionedUserIds;
  final MessageMentionTapHandler? onMentionTap;

  const _AdaptiveTextMetadata({
    super.key,
    required this.text,
    required this.textStyle,
    required this.metadata,
    required this.maxWidth,
    this.minWidth = 0,
    required this.linkColor,
    this.onUrlTap,
    this.mentionDisplayNames = const {},
    this.mentionedUserIds = const [],
    this.onMentionTap,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: _AdaptiveTextMetadataRenderWidget(
        minWidth: minWidth,
        text: MessageText(
          text,
          style: textStyle,
          mentionColor: linkColor,
          linkColor: linkColor,
          onUrlTap: onUrlTap,
          mentionDisplayNames: mentionDisplayNames,
          mentionedUserIds: mentionedUserIds,
          onMentionTap: onMentionTap,
        ),
        metadata: metadata,
      ),
    );
  }
}

class _AdaptiveTextMetadataRenderWidget extends MultiChildRenderObjectWidget {
  final double minWidth;

  _AdaptiveTextMetadataRenderWidget({
    required Widget text,
    required Widget metadata,
    required this.minWidth,
  }) : super(children: [text, metadata]);

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderAdaptiveTextMetadata(minWidth: minWidth);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderAdaptiveTextMetadata renderObject,
  ) {
    renderObject.minWidth = minWidth;
  }
}

class _AdaptiveTextMetadataParentData
    extends ContainerBoxParentData<RenderBox> {}

class _RenderAdaptiveTextMetadata extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _AdaptiveTextMetadataParentData>,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          _AdaptiveTextMetadataParentData
        > {
  static const _horizontalGap = 8.0;
  static const _verticalGap = 3.0;

  _RenderAdaptiveTextMetadata({required this._minWidth});

  double _minWidth;

  set minWidth(double value) {
    if (_minWidth == value) return;
    _minWidth = value;
    markNeedsLayout();
  }

  RenderParagraph get _text => firstChild! as RenderParagraph;

  RenderBox get _metadata => childAfter(_text)!;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _AdaptiveTextMetadataParentData) {
      child.parentData = _AdaptiveTextMetadataParentData();
    }
  }

  @override
  void performLayout() {
    final childConstraints = constraints.loosen();
    _metadata.layout(childConstraints, parentUsesSize: true);
    _text.layout(childConstraints, parentUsesSize: true);

    final textLength = _text.text.toPlainText().length;
    final trailingOffset = _text.getOffsetForCaret(
      TextPosition(offset: textLength),
      Rect.zero,
    );
    final trailingWidth =
        trailingOffset.dx + _horizontalGap + _metadata.size.width;
    final width = constraints.constrainWidth(
      math.max(_minWidth, math.max(_text.size.width, trailingWidth)),
    );
    final inline = trailingWidth <= width + 0.001;
    final height = inline
        ? math.max(_text.size.height, _metadata.size.height)
        : _text.size.height + _verticalGap + _metadata.size.height;
    size = constraints.constrain(Size(width, height));

    final textParentData = _text.parentData! as _AdaptiveTextMetadataParentData;
    textParentData.offset = Offset.zero;
    final metadataParentData =
        _metadata.parentData! as _AdaptiveTextMetadataParentData;
    metadataParentData.offset = Offset(
      math.max(0, size.width - _metadata.size.width),
      inline
          ? math.max(0, size.height - _metadata.size.height)
          : _text.size.height + _verticalGap,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    defaultPaint(context, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return defaultHitTestChildren(result, position: position);
  }
}

/// An icon-over-text action button used inside the floating message menu.
class _IconTextAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  const _IconTextAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final c = color ?? colors.textSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NeuRadius.tag),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: c, size: 22),
            const SizedBox(height: 3),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: color ?? colors.text,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A floating popover menu anchored near a long-pressed message bubble.
///
/// Renders as an [OverlayEntry] with a full-screen dismiss barrier. It measures
/// its own size on the first frame (off-screen, invisible), then repositions
/// itself above or below the bubble and fades in.
class _FloatingMessageMenu extends StatefulWidget {
  final ChatMessage message;
  final bool isMe;
  final Rect? bubbleRect;
  final VoidCallback onClose;
  final VoidCallback onCopy;
  final VoidCallback onReply;
  final VoidCallback onForward;
  final VoidCallback onEdit;
  final VoidCallback onRecall;
  final bool? isPinned;
  final bool pinStateLoading;
  final VoidCallback? onPin;
  final void Function(String emoji) onReact;
  final VoidCallback onShowFullEmojiPicker;
  final VoidCallback? onReadFullScreen;

  const _FloatingMessageMenu({
    required this.message,
    required this.isMe,
    required this.bubbleRect,
    required this.onClose,
    required this.onCopy,
    required this.onReply,
    required this.onForward,
    required this.onEdit,
    required this.onRecall,
    required this.isPinned,
    required this.pinStateLoading,
    required this.onPin,
    required this.onReact,
    required this.onShowFullEmojiPicker,
    this.onReadFullScreen,
  });

  @override
  State<_FloatingMessageMenu> createState() => _FloatingMessageMenuState();
}

class _FloatingMessageMenuState extends State<_FloatingMessageMenu> {
  static const _quickEmojis = ['👍', '❤️', '😂', '😮', '😢', '🙏'];
  static const _gap = 8.0;

  final _menuKey = GlobalKey();
  double? _left;
  double? _top;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureAndPosition());
  }

  @override
  void didUpdateWidget(covariant _FloatingMessageMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pinStateLoading != widget.pinStateLoading) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _measureAndPosition(),
      );
    }
  }

  void _measureAndPosition() {
    final ro = _menuKey.currentContext?.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return;
    final pos = _resolvePosition(ro.size);
    if (mounted) {
      setState(() {
        _left = pos.left;
        _top = pos.top;
        _ready = true;
      });
    }
  }

  ({double left, double top}) _resolvePosition(Size size) {
    final mq = MediaQuery.of(context);
    final w = mq.size.width;
    final h = mq.size.height;
    final safe = mq.padding;
    final mLeft = safe.left + 8;
    final mRight = w - safe.right - 8;

    final b = widget.bubbleRect;
    if (b == null) {
      final left = (w - size.width) / 2;
      return (left: left.clamp(mLeft, mRight - size.width), top: safe.top + 16);
    }

    final spaceAbove = b.top - safe.top;
    final spaceBelow = h - b.bottom - safe.bottom;
    final placeAbove =
        spaceAbove >= size.height + _gap || spaceAbove >= spaceBelow;
    final top = placeAbove ? b.top - _gap - size.height : b.bottom + _gap;

    var left = widget.isMe ? b.right - size.width : b.left;
    if (left < mLeft) left = mLeft;
    if (left + size.width > mRight) left = mRight - size.width;
    if (left < mLeft) left = mLeft;

    return (left: left, top: top);
  }

  /// Closes the menu, then runs the selected action.
  void _select(VoidCallback action) {
    widget.onClose();
    action();
  }

  Widget _buildEmojiRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ..._quickEmojis.map((emoji) => _emojiButton(emoji)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: InkWell(
                borderRadius: BorderRadius.circular(NeuRadius.tag),
                onTap: () => _select(widget.onShowFullEmojiPicker),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(
                    Icons.add_rounded,
                    color: context.neu.textTertiary,
                    size: 22,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emojiButton(String emoji) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(NeuRadius.tag),
        onTap: () => _select(() => widget.onReact(emoji)),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(emoji, style: const TextStyle(fontSize: 22)),
        ),
      ),
    );
  }

  Widget _buildActionRow() {
    final msg = widget.message;
    final isEvent = msg.msgType == MessageType.event;
    final isText = msg.msgType == MessageType.text;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isText)
              _IconTextAction(
                icon: Icons.copy_rounded,
                label: '复制',
                onTap: () => _select(widget.onCopy),
              ),
            if (widget.onReadFullScreen != null)
              _IconTextAction(
                icon: Icons.article_outlined,
                label: '全屏阅读',
                onTap: () => _select(widget.onReadFullScreen!),
              ),
            _IconTextAction(
              icon: Icons.reply_rounded,
              label: '回复',
              onTap: () => _select(widget.onReply),
            ),
            if (!isEvent)
              _IconTextAction(
                icon: Icons.forward_rounded,
                label: '转发',
                onTap: () => _select(widget.onForward),
              ),
            if (!isEvent && widget.onPin != null)
              _IconTextAction(
                icon: widget.isPinned!
                    ? Icons.push_pin_rounded
                    : Icons.push_pin_outlined,
                label: widget.isPinned! ? '取消置顶' : '置顶',
                onTap: () => _select(widget.onPin!),
              ),
            if (!isEvent && widget.pinStateLoading)
              SizedBox(
                width: 56,
                height: 48,
                child: Center(
                  child: SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: context.neu.textTertiary,
                    ),
                  ),
                ),
              ),
            if (widget.isMe && isText)
              _IconTextAction(
                icon: Icons.edit_outlined,
                label: '编辑',
                onTap: () => _select(widget.onEdit),
              ),
            if (widget.isMe)
              _IconTextAction(
                icon: Icons.delete_outline_rounded,
                label: '撤回',
                color: context.neu.error,
                onTap: () => _select(widget.onRecall),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMenu() {
    final msg = widget.message;
    final isEvent = msg.msgType == MessageType.event;
    return Material(
      type: MaterialType.transparency,
      child: GlassPanel(
        key: _menuKey,
        radius: NeuRadius.surface,
        padding: EdgeInsets.zero,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isEvent) _buildEmojiRow(),
            if (!isEvent) Divider(color: context.neu.hairline, height: 0.5),
            _buildActionRow(),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Full-screen dismiss barrier.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: _left ?? 0,
          top: _top ?? 0,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: _ready ? 1 : 0),
            duration: const Duration(milliseconds: 90),
            curve: Curves.easeOutCubic,
            builder: (_, v, child) => Opacity(
              opacity: v,
              child: Transform.scale(
                scale: 0.88 + 0.12 * v,
                alignment: widget.isMe
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: child,
              ),
            ),
            child: _buildMenu(),
          ),
        ),
      ],
    );
  }
}

/// A single aggregated reaction chip shown below a bubble.
class _ReactionChip extends StatelessWidget {
  final Reaction reaction;
  final bool reacted;
  final VoidCallback onTap;

  const _ReactionChip({
    super.key,
    required this.reaction,
    required this.reacted,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: NeuDecoration(
          colors: colors,
          depth: NeuDepth.pressed,
          radius: NeuRadius.nav,
          intensity: .6,
          borderColor: reacted ? colors.accent : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(reaction.key, style: const TextStyle(fontSize: 13)),
            const SizedBox(width: 3),
            Text(
              '${reaction.senders.length}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: reacted ? colors.accent : colors.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet listing who read a message and when (Telegram-style).
class _ReadReceiptsSheet extends ConsumerWidget {
  final ChatMessage message;
  final String roomId;

  const _ReadReceiptsSheet({required this.message, required this.roomId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '已读 ${message.readers.length}',
                  style: textTheme.titleMedium,
                ),
              ),
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Icon(
                  Icons.close_rounded,
                  color: colors.textTertiary,
                  size: 22,
                ),
              ),
            ],
          ),
        ),
        if (message.readers.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(child: Text('暂无已读', style: textTheme.bodyMedium)),
          )
        else
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 8),
            itemCount: message.readers.length,
            itemBuilder: (context, index) {
              final reader = message.readers[index];
              return _ReadReceiptRow(reader: reader, roomId: roomId);
            },
          ),
      ],
    );
  }
}

class _StickyAvatarMessageGroup extends StatefulWidget {
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

  const _StickyAvatarMessageGroup({
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
  State<_StickyAvatarMessageGroup> createState() =>
      _StickyAvatarMessageGroupState();
}

class _StickyAvatarMessageGroupState extends State<_StickyAvatarMessageGroup> {
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

/// A single row in the read-receipts sheet: avatar + name.
/// (No read time: the Matrix protocol stores one receipt position per user,
/// not a per-message read time, so we surface *who* read but not *when*.)
class _ReadReceiptRow extends ConsumerStatefulWidget {
  final MessageReader reader;
  final String roomId;

  const _ReadReceiptRow({required this.reader, required this.roomId});

  @override
  ConsumerState<_ReadReceiptRow> createState() => _ReadReceiptRowState();
}

class _ReadReceiptRowState extends ConsumerState<_ReadReceiptRow> {
  String? _avatarUrl;

  @override
  void initState() {
    super.initState();
    _resolveAvatar();
  }

  Future<void> _resolveAvatar() async {
    final url = await resolveMxcUrlAvatar(ref, widget.reader.avatarUrl);
    if (mounted && url != _avatarUrl) {
      setState(() => _avatarUrl = url);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          AppAvatar(
            fallback: widget.reader.displayName,
            size: 40,
            radius: NeuRadius.content,
            url: _avatarUrl,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.reader.displayName,
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
