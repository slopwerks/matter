import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/markdown/markdown_source_store.dart';
import '../../features/matrix_html/matrix_html_renderer.dart';
import '../../features/matrix_html/matrix_link_router.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' hide redactMessage;
import '../../theme/app_theme.dart';
import '../../widgets/app_avatar.dart';
import 'chat_timestamp.dart';
import 'emoji_picker_panel.dart';
import 'forward_message_sheet.dart';
import 'image_message_bubble.dart';
import 'link_preview.dart';
import 'message_insert_animation.dart';
import 'message_text.dart';
import 'video_message_bubble.dart';
import 'message_input.dart';
import 'send_flight.dart';

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
  final Map<String, String> remoteToLocalFlightId;
  final Set<String> insertionAnimationIds;
  final Map<String, Contact> membersById;
  final String? senderAvatarUrl;
  final bool compact;
  final ScrollController? scrollController;
  final GlobalKey? scrollViewportKey;
  final double stickyBottomInset;
  final VoidCallback? onImageLoaded;
  final VoidCallback? onReplyRequested;
  final ValueChanged<ChatRoom>? onMessageForwarded;

  const MessageGroupWidget({
    super.key,
    required this.group,
    required this.roomId,
    required this.messageIndex,
    this.remoteToLocalFlightId = const {},
    this.insertionAnimationIds = const {},
    this.membersById = const {},
    this.showAvatar = true,
    this.senderAvatarUrl,
    this.compact = false,
    this.scrollController,
    this.scrollViewportKey,
    this.stickyBottomInset = 0,
    this.onImageLoaded,
    this.onReplyRequested,
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
  String? _messageFlightId(ChatMessage message) {
    final matchedFlightId = remoteToLocalFlightId[message.id];
    if (matchedFlightId != null) return matchedFlightId;
    if (isLocalOutgoingMessage(message.id)) return sendFlightId(message.id);
    return null;
  }

  String _messageRowKey(ChatMessage message) {
    final flightId = _messageFlightId(message);
    if (flightId != null) return 'message-row:$flightId';
    return 'message-row:${message.id}';
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
                (e) => KeyedSubtree(
                  key: ValueKey(_messageRowKey(e.value)),
                  child: _buildMessage(
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
                (e) => KeyedSubtree(
                  key: ValueKey(_messageRowKey(e.value)),
                  child: _buildMessage(
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
            (e) => KeyedSubtree(
              key: ValueKey(_messageRowKey(e.value)),
              child: _buildMessage(
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
        messagesBuilder: (avatarSwipeOffset) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: group.messages
              .asMap()
              .entries
              .map(
                (e) => KeyedSubtree(
                  key: ValueKey(_messageRowKey(e.value)),
                  child: _buildMessage(
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
      return GestureDetector(
        onLongPress: () => _showContextMenu(context, ref, message),
        child: Padding(
          padding: EdgeInsets.only(
            top: isFirst ? 2 : 1,
            bottom: _messageBottomPadding,
          ),
          child: _buildEventMessage(context, message),
        ),
      );
    }

    final isLocalOutgoing = isLocalOutgoingMessage(message.id);
    final isLocalFailed = isLocalOutgoingFailedMessage(message.id);
    final isLocalSent = isLocalOutgoingSentMessage(message.id);
    final metadata = _buildMessageMetadata(
      context,
      ref,
      message,
      overlay: message.msgType != MessageType.text,
    );
    void onMentionTap(String userId) =>
        _showMemberProfile(context, userId, membersById[userId]);
    final coreBubble =
        message.msgType == MessageType.video &&
            (message.imageUrl != null || message.mediaSourceJson != null)
        ? VideoMessageBubble(
            key: ValueKey('video-bubble:${message.id}'),
            videoUrl: message.imageUrl,
            mediaSourceJson: message.mediaSourceJson,
            filename: message.content,
            videoWidth: message.imageWidth,
            videoHeight: message.imageHeight,
            isMe: isMe,
            heroTag: 'video-preview:${message.id}',
            metadata: metadata,
            onLoaded: onImageLoaded,
          )
        : (message.msgType == MessageType.image ||
                  message.msgType == MessageType.sticker) &&
              (message.imageUrl != null || message.mediaSourceJson != null)
        ? ImageMessageBubble(
            key: ValueKey('image-bubble:${message.id}'),
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
            heroTag: 'image-preview:${message.id}',
            isSticker: message.msgType == MessageType.sticker,
            metadata: metadata,
            borderRadius: _messageBorderRadius(
              isMe: isMe,
              isFirst: isFirst,
              isLast: isLast,
            ),
            onLoaded: onImageLoaded,
          )
        : _buildTextBubble(
            context,
            ref,
            message,
            isMe,
            isFirst: isFirst,
            isLast: isLast,
            mentionDisplayNames: mentionDisplayNames,
            onMentionTap: onMentionTap,
          );
    final bubble = coreBubble;
    final flightId = _messageFlightId(message);
    final displayedBubble = flightId != null
        ? SendFlightTarget(
            key: ValueKey(flightId),
            messageId: message.id,
            flightId: flightId,
            latestScrollController: scrollController,
            lockEndAtLatest: true,
            child: bubble,
          )
        : bubble;

    final messageRow = GestureDetector(
      onLongPress: isLocalOutgoing
          ? null
          : () => _showContextMenu(context, ref, message),
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
                  _buildLocalOutgoingStatus(isLocalFailed, isLocalSent),
                  const SizedBox(width: 6),
                ],
                Flexible(fit: FlexFit.loose, child: displayedBubble),
                if (!isMe && isLocalOutgoing) ...[
                  const SizedBox(width: 6),
                  _buildLocalOutgoingStatus(isLocalFailed, isLocalSent),
                ],
              ],
            ),
            if (message.reactions.isNotEmpty)
              _buildReactionsRow(context, ref, message, isMe),
          ],
        ),
      ),
    );

    if (isLocalOutgoing) {
      final shouldAnimateInsertion =
          flightId != null && insertionAnimationIds.contains(flightId);
      return shouldAnimateInsertion
          ? MessageInsertAnimation(
              key: ValueKey('message-insert:$flightId'),
              child: messageRow,
            )
          : messageRow;
    }
    return SizedBox(
      width: double.infinity,
      child: _SwipeToReply(
        key: ValueKey('swipe-reply:${message.id}'),
        onReply: () => _startReply(ref, message),
        linkedOffset: linkedAvatarOffset,
        child: Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: messageRow,
        ),
      ),
    );
  }

  Widget _buildLocalOutgoingStatus(bool failed, bool sent) {
    if (failed) {
      return const Padding(
        padding: EdgeInsets.only(bottom: 6),
        child: Icon(Icons.error_rounded, color: AppColors.error, size: 18),
      );
    }
    if (sent) {
      return const Padding(
        padding: EdgeInsets.only(bottom: 6),
        child: Tooltip(
          message: '已发送，等待服务器同步',
          child: Icon(
            Icons.schedule_rounded,
            color: AppColors.onSurfaceVariant,
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
          color: AppColors.onSurfaceVariant.withValues(alpha: 0.72),
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
            isMe: isMe,
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
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.surface),
        ),
        child: Padding(
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
                style: const TextStyle(
                  color: AppColors.onBackground,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 5),
              SelectableText(
                userId,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.onSurfaceVariant,
                  fontSize: 13,
                ),
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

  Widget _buildTextBubble(
    BuildContext context,
    WidgetRef ref,
    ChatMessage message,
    bool isMe, {
    bool isFirst = false,
    bool isLast = false,
    required Map<String, String> mentionDisplayNames,
    required MessageMentionTapHandler onMentionTap,
  }) {
    final maxBubbleWidth = MediaQuery.of(context).size.width * 0.70;
    final textStyle = TextStyle(
      color: isMe ? Colors.white : AppColors.onBackground,
      fontSize: 15,
      height: 1.35,
    );
    final urlMatches = detectMessageUrls(message.content);
    Uri? previewUri;
    for (final match in urlMatches) {
      if (matrixUserIdFromUri(match.uri) == null) {
        previewUri = match.uri;
        break;
      }
    }
    const linkRouter = MatrixLinkRouter();
    final metadata = _buildMessageMetadata(context, ref, message);
    final metadataWidth = _messageMetadataWidth(context, message);
    final hasReply = message.inReplyTo != null;
    final hasFormattedBody = message.formattedBody?.isNotEmpty == true;
    final replyContent = hasReply ? _getReplyContent(message.inReplyTo!) : null;
    final replyPreviewWidth = replyContent == null
        ? 0.0
        : _replyPreviewWidth(context, replyContent, isMe, maxBubbleWidth - 28);
    final senderHeader = !isMe && isFirst
        ? Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text(
              message.senderName,
              style: TextStyle(
                color: AppColors.primary.withValues(alpha: 0.85),
                fontSize: 12.5,
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
          _buildReplyPreview(context, replyContent, isMe),
        if (hasFormattedBody)
          MatrixHtmlMessage(
            key: ValueKey('formatted-body-metadata:${message.id}'),
            html: message.formattedBody!,
            style: textStyle,
            accentColor: isMe ? Colors.white : AppColors.secondary,
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
            metadataWidth: metadataWidth,
            maxWidth: maxBubbleWidth - 28,
            minWidth: replyPreviewWidth,
            linkColor: isMe ? Colors.white : AppColors.secondary,
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
      decoration: BoxDecoration(
        color: isMe ? AppColors.primary : AppColors.surfaceElevated,
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
    final outer = const Radius.circular(AppRadii.content);
    final joined = const Radius.circular(_joinedRadius);
    if (isMe) {
      return BorderRadius.only(
        topLeft: outer,
        topRight: isFirst ? outer : joined,
        bottomLeft: outer,
        bottomRight: isLast ? const Radius.circular(AppRadii.tag) : joined,
      );
    }
    return BorderRadius.only(
      topLeft: isFirst ? outer : joined,
      topRight: outer,
      bottomLeft: isLast ? const Radius.circular(AppRadii.tag) : joined,
      bottomRight: outer,
    );
  }

  void _showEditHistory(BuildContext context, ChatMessage message) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.8,
        expand: false,
        builder: (context, scrollController) {
          return Container(
            decoration: const BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(AppRadii.surface),
              ),
            ),
            child: Column(
              children: [
                // Handle bar
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 8, bottom: 12),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.onSurfaceVariant.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(
                    '编辑记录',
                    style: TextStyle(
                      color: AppColors.onBackground,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Divider(color: AppColors.surfaceVariant, height: 0.5),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 16,
                    ),
                    itemCount: message.editHistory.length,
                    itemBuilder: (context, index) {
                      final isOriginal = index == 0;
                      final isLatest = index == message.editHistory.length - 1;
                      String label;
                      if (isOriginal) {
                        label = '原始';
                      } else if (isLatest) {
                        label = '最新';
                      } else {
                        label = '第 $index 次编辑';
                      }
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isLatest
                                        ? AppColors.primary.withValues(
                                            alpha: 0.15,
                                          )
                                        : AppColors.surfaceVariant.withValues(
                                            alpha: 0.5,
                                          ),
                                    borderRadius: BorderRadius.circular(
                                      AppRadii.tag,
                                    ),
                                  ),
                                  child: Text(
                                    label,
                                    style: TextStyle(
                                      color: isLatest
                                          ? AppColors.primary
                                          : AppColors.onSurfaceVariant,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              message.editHistory[index],
                              style: const TextStyle(
                                color: AppColors.onBackground,
                                fontSize: 14,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildReplyPreview(
    BuildContext context,
    String replyContent,
    bool isMe,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: (isMe ? Colors.white : AppColors.primary).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppRadii.tag),
        border: Border(
          left: BorderSide(
            color: isMe ? Colors.white : AppColors.primary,
            width: 2,
          ),
        ),
      ),
      child: Text(
        replyContent,
        style: _replyPreviewTextStyle(isMe),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  TextStyle _replyPreviewTextStyle(bool isMe) {
    return TextStyle(
      color: isMe
          ? Colors.white.withValues(alpha: 0.7)
          : AppColors.onSurfaceVariant,
      fontSize: 12,
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
      text: TextSpan(text: replyContent, style: _replyPreviewTextStyle(isMe)),
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Center(
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.82,
            minHeight: 24,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.surfaceVariant.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(AppRadii.tag),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                _eventIcon(message),
                size: 13,
                color: AppColors.onSurfaceVariant,
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  message.content,
                  style: const TextStyle(
                    color: AppColors.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    height: 1.2,
                  ),
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
    final foreground = overlay
        ? Colors.white.withValues(alpha: 0.9)
        : message.isMe
        ? Colors.white.withValues(alpha: 0.65)
        : AppColors.onSurfaceVariant;
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (message.isEdited) ...[
          GestureDetector(
            onTap: () => _showEditHistory(context, message),
            child: Text(
              '已编辑',
              style: TextStyle(
                color: foreground.withValues(alpha: 0.75),
                fontSize: 10,
              ),
            ),
          ),
          const SizedBox(width: 5),
        ],
        Text(
          formatMessageTime(message.timestamp),
          style: TextStyle(
            color: foreground,
            fontSize: 10.5,
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

  double _messageMetadataWidth(BuildContext context, ChatMessage message) {
    double textWidth(String text, double fontSize) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(fontSize: fontSize),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      return painter.width;
    }

    var width = textWidth(formatMessageTime(message.timestamp), 10.5);
    if (message.isEdited) {
      width += 5 + textWidth('已编辑', 10);
    }
    if (message.isMe) {
      width += 4 + 15;
    }
    return width;
  }

  /// Bottom sheet listing the members who read a message and when.
  void _showReadReceipts(
    BuildContext context,
    WidgetRef ref,
    ChatMessage message,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) =>
          _ReadReceiptsSheet(message: message, roomId: roomId),
    );
  }

  Widget _buildQuickReactions(
    BuildContext context,
    WidgetRef ref,
    ChatMessage message,
  ) {
    const quickEmojis = ['👍', '❤️', '😂', '😮', '😢', '🙏'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            ...quickEmojis.map(
              (emoji) => _quickEmoji(context, ref, message, emoji),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadii.tag),
                onTap: () {
                  // Close the context menu, then open the full emoji picker.
                  Navigator.of(context).pop();
                  _showEmojiPicker(context, ref, message);
                },
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(
                    Icons.add_rounded,
                    color: AppColors.onSurfaceVariant,
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

  Widget _quickEmoji(
    BuildContext context,
    WidgetRef ref,
    ChatMessage message,
    String emoji,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.tag),
        onTap: () async {
          Navigator.of(context).pop();
          await _sendReactionAndRefresh(context, ref, message.id, emoji);
        },
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(emoji, style: const TextStyle(fontSize: 22)),
        ),
      ),
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
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => Container(
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.surface),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.surface),
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.5,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 12, 4),
                  child: Row(
                    children: [
                      const Text(
                        '选择表情',
                        style: TextStyle(
                          color: AppColors.onBackground,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: () => Navigator.of(sheetContext).pop(),
                        child: const Icon(
                          Icons.close_rounded,
                          color: AppColors.onSurfaceVariant,
                          size: 22,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: EmojiPickerPanel(
                    onEmojiSelected: (emoji) async {
                      Navigator.of(sheetContext).pop();
                      await _sendReactionAndRefresh(
                        context,
                        ref,
                        message.id,
                        emoji,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showContextMenu(
    BuildContext context,
    WidgetRef ref,
    ChatMessage message,
  ) {
    final pageContext = context;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.surface),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Quick emoji reaction bar (not for system/event messages).
              if (message.msgType != MessageType.event)
                _buildQuickReactions(context, ref, message),
              if (message.msgType == MessageType.text)
                _MenuItem(
                  icon: Icons.copy_rounded,
                  label: '复制',
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: message.content));
                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('已复制'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                ),
              _MenuItem(
                icon: Icons.reply_rounded,
                label: '回复',
                onTap: () {
                  Navigator.of(context).pop();
                  _startReply(ref, message);
                },
              ),
              if (message.msgType != MessageType.event)
                _MenuItem(
                  icon: Icons.forward_rounded,
                  label: '转发',
                  onTap: () async {
                    Navigator.of(context).pop();
                    final targetRoom = await showForwardMessageSheet(
                      context: pageContext,
                      sourceRoomId: roomId,
                      message: message,
                    );
                    if (targetRoom != null) {
                      onMessageForwarded?.call(targetRoom);
                    }
                  },
                ),
              if (message.isMe) ...[
                const Divider(color: AppColors.surfaceVariant, height: 0.5),
                if (message.msgType == MessageType.text)
                  _MenuItem(
                    icon: Icons.edit_outlined,
                    label: '编辑',
                    onTap: () {
                      Navigator.of(context).pop();
                      ref.read(editingMessageProvider(roomId).notifier).value =
                          message;
                    },
                  ),
                _MenuItem(
                  icon: Icons.delete_outline_rounded,
                  label: '撤回',
                  iconColor: AppColors.error,
                  textColor: AppColors.error,
                  onTap: () async {
                    Navigator.of(context).pop();
                    try {
                      await redactMessage(ref, roomId, message.id);
                      await const MarkdownSourceStore().delete(
                        roomId: roomId,
                        eventId: message.id,
                      );
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('撤回失败: $e'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      }
                    }
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _startReply(WidgetRef ref, ChatMessage message) {
    ref.read(editingMessageProvider(roomId).notifier).value = null;
    ref.read(replyingToProvider(roomId).notifier).value = message;
    onReplyRequested?.call();
  }
}

class _SwipeToReply extends StatefulWidget {
  final Widget child;
  final VoidCallback onReply;
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
  static const double _triggerDistance = 56;
  static const double _maxDistance = 72;
  static const Duration _settleDuration = Duration(milliseconds: 180);

  late final AnimationController _dragController;
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

  void _handleDragStart(DragStartDetails details) {
    _dragController.stop();
    _thresholdFeedbackSent = _dragController.value >= _triggerDistance;
  }

  void _handleDragUpdate(DragUpdateDetails details) {
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
    final shouldReply = _dragController.value >= _triggerDistance;
    _settle();
    if (shouldReply) widget.onReply();
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
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      dragStartBehavior: DragStartBehavior.down,
      onHorizontalDragStart: _handleDragStart,
      onHorizontalDragUpdate: _handleDragUpdate,
      onHorizontalDragEnd: _handleDragEnd,
      onHorizontalDragCancel: _settle,
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
                          color: AppColors.primary.withValues(alpha: 0.14),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.reply_rounded,
                          color: AppColors.primary,
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
  final double metadataWidth;
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
    required this.metadataWidth,
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? math.min(constraints.maxWidth, maxWidth)
            : maxWidth;
        final textScaler = MediaQuery.textScalerOf(context);
        final span = messageTextSpan(
          text,
          style: textStyle,
          mentionColor: AppColors.secondary,
          mentionDisplayNames: mentionDisplayNames,
          mentionedUserIds: mentionedUserIds,
        );
        final textPainter = TextPainter(
          text: span,
          textDirection: Directionality.of(context),
          textScaler: textScaler,
        )..layout(maxWidth: availableWidth);
        final lines = textPainter.computeLineMetrics();
        final lastLineWidth = lines.isEmpty ? 0.0 : lines.last.width;
        final widestLine = lines.fold<double>(
          0,
          (width, line) => math.max(width, line.width),
        );
        const gap = 8.0;
        final inline = lastLineWidth + gap + metadataWidth <= availableWidth;
        final naturalWidth = lines.length > 1
            ? availableWidth
            : math.min(
                availableWidth,
                math.max(widestLine, lastLineWidth + gap + metadataWidth),
              );
        final width = math.min(
          availableWidth,
          math.max(minWidth, naturalWidth),
        );
        final metadataHeight = math.max(15.0, textScaler.scale(10.5));
        final height = inline
            ? math.max(textPainter.height, metadataHeight)
            : textPainter.height + 3 + metadataHeight;

        return SizedBox(
          width: width,
          height: height,
          child: Stack(
            children: [
              Positioned(
                left: 0,
                top: 0,
                width: width,
                child: MessageText(
                  text,
                  style: textStyle,
                  mentionColor: AppColors.secondary,
                  linkColor: linkColor,
                  onUrlTap: onUrlTap,
                  mentionDisplayNames: mentionDisplayNames,
                  mentionedUserIds: mentionedUserIds,
                  onMentionTap: onMentionTap,
                ),
              ),
              Positioned(
                key: ValueKey(inline ? 'metadata-inline' : 'metadata-below'),
                right: 0,
                bottom: 0,
                child: metadata,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? iconColor;
  final Color? textColor;

  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconColor,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.surface),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: iconColor ?? AppColors.onSurface, size: 22),
            const SizedBox(width: 14),
            Text(
              label,
              style: TextStyle(
                color: textColor ?? AppColors.onBackground,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A single aggregated reaction chip shown below a bubble.
class _ReactionChip extends StatelessWidget {
  final Reaction reaction;
  final bool reacted;
  final bool isMe;
  final VoidCallback onTap;

  const _ReactionChip({
    super.key,
    required this.reaction,
    required this.reacted,
    required this.isMe,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final highlight = reacted
        ? (isMe ? Colors.white.withValues(alpha: 0.25) : AppColors.primary)
        : AppColors.surfaceElevated;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: highlight,
          borderRadius: BorderRadius.circular(AppRadii.tag),
          border: reacted && !isMe
              ? Border.all(
                  color: AppColors.primary.withValues(alpha: 0.4),
                  width: 1,
                )
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(reaction.key, style: const TextStyle(fontSize: 13)),
            const SizedBox(width: 3),
            Text(
              '${reaction.senders.length}',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: reacted
                    ? (isMe
                          ? Colors.white.withValues(alpha: 0.9)
                          : AppColors.primary)
                    : AppColors.onSurfaceVariant,
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
    return Container(
      margin: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.surface),
      ),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.6,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '已读 ${message.readers.length}',
                        style: const TextStyle(
                          color: AppColors.onBackground,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: const Icon(
                        Icons.close_rounded,
                        color: AppColors.onSurfaceVariant,
                        size: 22,
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: message.readers.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Center(
                          child: Text(
                            '暂无已读',
                            style: TextStyle(
                              color: AppColors.onSurfaceVariant,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        padding: const EdgeInsets.only(bottom: 8),
                        itemCount: message.readers.length,
                        itemBuilder: (context, index) {
                          final reader = message.readers[index];
                          return _ReadReceiptRow(
                            reader: reader,
                            roomId: roomId,
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
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

  _StickyGroupAvatar({
    super.key,
    required this.fallback,
    required this.avatarUrl,
    required this.scrollController,
    required this.scrollViewportKey,
    required this.avatarSize,
    required this.bottomInset,
    required this.swipeOffset,
  }) : super(
         child: AppAvatar(
           fallback: fallback,
           size: avatarSize,
           radius: AppRadii.content,
           url: avatarUrl,
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
            radius: AppRadii.content,
            url: _avatarUrl,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.reader.displayName,
              style: const TextStyle(
                color: AppColors.onBackground,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
