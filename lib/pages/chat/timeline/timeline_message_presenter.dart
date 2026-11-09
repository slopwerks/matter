import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../src/rust/api/matrix.dart' hide redactMessage;
import '../../../theme/neu_colors.dart';

import '../../../providers/chat_provider.dart';
import '../file_message_bubble.dart';
import '../image_message_bubble.dart';
import '../image_message_collection.dart';
import '../image_message_runs.dart';
import '../image_viewer.dart' show ImageHistoryLoader;
import '../location_message_bubble.dart';
import '../message_insert_animation.dart';
import '../poll_message_bubble.dart';
import '../video_message_bubble.dart';
import '../send_flight.dart';
import 'timeline_bubble_frame.dart';
import 'timeline_reactions_bar.dart';
import 'timeline_swipe_reply.dart';
import 'timeline_text_bubble.dart';
import 'timeline_message_metadata.dart';
import 'timeline_message_actions.dart';

class TimelineMessagePresenter {
  const TimelineMessagePresenter({
    required this.roomId,
    required this.messageIndex,
    required this.messageAnchorKeys,
    required this.remoteToLocalFlightId,
    required this.insertionAnimationIds,
    required this.lateralInsertionAnimationIds,
    required this.localImagePreviews,
    required this.actions,
    required this.anchor,
    this.scrollController,
    this.stickyBottomInset = 0,
    this.onImageLoaded,
    this.onMessageJumpRequested,
    this.onMessageForwarded,
    this.loadOlderImages,
  });
  final String roomId;
  final Map<String, ChatMessage> messageIndex;
  final Map<String, GlobalKey> messageAnchorKeys;
  final Map<String, String> remoteToLocalFlightId;
  final Set<String> insertionAnimationIds;
  final Set<String> lateralInsertionAnimationIds;
  final Map<String, Uint8List> localImagePreviews;
  final TimelineMessageActions actions;
  final Widget Function(
    ChatMessage,
    Widget, {
    bool collection,
    Set<String> collectionIds,
  })
  anchor;
  final ScrollController? scrollController;
  final double stickyBottomInset;
  final VoidCallback? onImageLoaded;
  final ValueChanged<String>? onMessageJumpRequested;
  final ValueChanged<ChatRoom>? onMessageForwarded;
  final ImageHistoryLoader? loadOlderImages;
  Widget buildMessage(
    BuildContext context,
    WidgetRef ref,
    ChatMessage message,
    bool isMe, {
    required Map<String, Contact> membersById,
    required Map<String, String> mentionDisplayNames,
    bool isFirst = false,
    bool isLast = false,
    ValueNotifier<double>? linkedAvatarOffset,
    ChatImageRun? imageRun,
    Widget? collectionBubble,
  }) {
    if (message.msgType == MessageType.event) {
      BuildContext? eventContext;
      return GestureDetector(
        onSecondaryTap: () =>
            actions.showContextMenu(eventContext ?? context, ref, message),
        onLongPress: () =>
            actions.showContextMenu(eventContext ?? context, ref, message),
        child: Padding(
          padding: EdgeInsets.only(top: isFirst ? 2 : 1, bottom: 1.0),
          child: Builder(
            builder: (ctx) {
              eventContext = ctx;
              return buildEventMessage(context, message);
            },
          ),
        ),
      );
    }

    final flightId = imageRun == null
        ? messageSendFlightId(message.id, remoteToLocalFlightId)
        : null;
    final visualMessageId =
        imageRun?.messages.first.id ?? flightId ?? message.id;
    final isLocalOutgoing = isLocalOutgoingMessage(message.id);
    final isLocalFailed = isLocalOutgoingFailedMessage(message.id);
    final isLocalSent = isLocalOutgoingSentMessage(message.id);
    // An optimistic image has no `mxc://` source yet, so its bubble is fed
    // the picked bytes instead of resolving a URL.
    final previewBytes = localImagePreviews[message.id];
    final messageBorderRadius = timelineBubbleBorderRadius(
      context,
      isMe: isMe,
      isFirst: isFirst,
      isLast: isLast,
    );
    final metadata = TimelineMessageMetadata(
      message: message,
      roomId: roomId,
      overlay: message.msgType != MessageType.text,
    );
    void onMentionTap(String userId) =>
        actions.showMemberProfile(context, userId, membersById[userId]);
    final readerHtml = message.msgType == MessageType.text
        ? effectiveFormattedHtml(message)
        : null;
    final VoidCallback? onReadFullScreen =
        readerHtml != null && readerHtml.isNotEmpty
        ? () => actions.openReaderFullScreen(
            context,
            html: readerHtml,
            mentionDisplayNames: mentionDisplayNames,
          )
        : null;
    if (imageRun != null && collectionBubble == null) {
      return ImageMessageCollection(
        key: ValueKey('image-collection:${imageRun.messages.first.id}'),
        messages: imageRun.messages,
        selected: message,
        album: imageRun.album,
        isMe: isMe,
        borderRadius: messageBorderRadius,
        shadows: enabledNeuBubbleShadows(context, context.neu),
        anchors: messageAnchorKeys,
        metadata: metadata,
        collapsedBuilder: (bubble) => buildMessage(
          context,
          ref,
          message,
          isMe,
          membersById: membersById,
          mentionDisplayNames: mentionDisplayNames,
          isFirst: isFirst,
          isLast: isLast,
          linkedAvatarOffset: linkedAvatarOffset,
          imageRun: imageRun,
          collectionBubble: bubble,
        ),
        expandedBuilder: (collapseButton) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: isMe
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            collapseButton,
            for (var index = 0; index < imageRun.messages.length; index++)
              anchor(
                imageRun.messages[index],
                buildMessage(
                  context,
                  ref,
                  imageRun.messages[index],
                  isMe,
                  membersById: membersById,
                  mentionDisplayNames: mentionDisplayNames,
                  isFirst: index == 0 && isFirst,
                  isLast: index == imageRun.messages.length - 1 && isLast,
                  linkedAvatarOffset: index == imageRun.messages.length - 1
                      ? linkedAvatarOffset
                      : null,
                ),
              ),
          ],
        ),
        captionBuilder: (image) {
          final text = image.caption ?? image.sharedCaption;
          return text == null || text.trim().isEmpty
              ? null
              : ImageMessageCaption(
                  text: text,
                  formattedBody: image.captionFormattedBody,
                  isMe: isMe,
                  mentionDisplayNames: mentionDisplayNames,
                  mentionedUserIds: image.mentionedUserIds,
                  onMentionTap: onMentionTap,
                );
        },
        tileBuilder: (image, size, radius) => Builder(
          builder: (tileContext) => GestureDetector(
            onSecondaryTap: () =>
                actions.showContextMenu(tileContext, ref, image),
            onLongPress: () => actions.showContextMenu(tileContext, ref, image),
            child: ImageMessageBubble(
              key: ValueKey('image-bubble:${image.id}'),
              imageUrl: image.imageUrl,
              mediaSourceJson: image.mediaSourceJson,
              imageWidth: image.imageWidth,
              imageHeight: image.imageHeight,
              fileSize: image.fileSize,
              mimeType: image.mimeType,
              filename: image.filename ?? image.content,
              message: image,
              roomId: roomId,
              galleryMessages: messageIndex.values,
              loadOlderImages: loadOlderImages,
              onMessageJumpRequested: onMessageJumpRequested,
              onMessageReplyRequested: (reply) =>
                  actions.startReply(context, ref, reply),
              onMessageForwarded: onMessageForwarded,
              isMe: isMe,
              heroTag: 'image-preview:${image.id}',
              metadata: const SizedBox.shrink(),
              borderRadius: radius,
              displaySize: size,
              showCaption: false,
              onLoaded: onImageLoaded,
            ),
          ),
        ),
      );
    }
    final coreBubble =
        collectionBubble ??
        (message.msgType == MessageType.video &&
                (message.imageUrl != null || message.mediaSourceJson != null)
            ? VideoMessageBubble(
                key: ValueKey('video-bubble:$visualMessageId'),
                videoUrl: message.imageUrl,
                roomId: roomId,
                fileSize: message.fileSize,
                mediaSourceJson: message.mediaSourceJson,
                filename: message.content,
                videoWidth: message.imageWidth,
                videoHeight: message.imageHeight,
                durationMs: message.durationMs,
                isMe: isMe,
                heroTag: 'video-preview:$visualMessageId',
                metadata: metadata,
                onLoaded: onImageLoaded,
              )
            : (message.msgType == MessageType.image ||
                      message.msgType == MessageType.sticker) &&
                  (message.imageUrl != null ||
                      message.mediaSourceJson != null ||
                      previewBytes != null)
            ? ImageMessageBubble(
                key: ValueKey('image-bubble:$visualMessageId'),
                imageUrl: message.imageUrl,
                mediaSourceJson: message.mediaSourceJson,
                previewBytes: previewBytes,
                imageWidth: message.imageWidth,
                imageHeight: message.imageHeight,
                fileSize: message.fileSize,
                mimeType: message.mimeType,
                filename: message.filename ?? message.content,
                message: message,
                roomId: roomId,
                galleryMessages: messageIndex.values,
                loadOlderImages: loadOlderImages,
                onMessageJumpRequested: onMessageJumpRequested,
                onMessageReplyRequested: (replyMessage) =>
                    actions.startReply(context, ref, replyMessage),
                onMessageForwarded: onMessageForwarded,
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
                roomId: roomId,
                messageId: message.id,
                filename: message.filename ?? message.content,
                caption: message.caption,
                fileSize: message.fileSize,
                mimeType: message.mimeType,
                durationMs: message.durationMs,
                mediaSourceJson: message.mediaSourceJson,
                imageUrl: message.imageUrl,
                isMe: isMe,
                metadata: metadata,
              )
            : TimelineTextBubble(
                message: message,
                isMe: isMe,
                metadata: TimelineMessageMetadata(
                  message: message,
                  roomId: roomId,
                ),
                messageIndex: messageIndex,
                onMessageJumpRequested: onMessageJumpRequested,
                isFirst: isFirst,
                isLast: isLast,
                formattedBody: readerHtml,
                mentionDisplayNames: mentionDisplayNames,
                onMentionTap: onMentionTap,
              ));
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

    final VoidCallback? openMenu = isLocalOutgoing
        ? (isLocalFailed
              ? () => actions.showFailedMessageMenu(
                  bubbleContext ?? context,
                  ref,
                  message,
                )
              : null)
        : () => actions.showContextMenu(
            bubbleContext ?? context,
            ref,
            message,
            onReadFullScreen: onReadFullScreen,
          );
    final messageRow = GestureDetector(
      onSecondaryTap: openMenu,
      onLongPress: openMenu,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: EdgeInsets.only(top: isFirst ? 2 : 1, bottom: 1.0),
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
            for (final reactionMessage in imageRun?.messages ?? [message])
              if (reactionMessage.reactions.isNotEmpty)
                TimelineReactionsBar(
                  message: reactionMessage,
                  isMe: isMe,
                  onToggle: (emoji) => toggleTimelineReaction(
                    context,
                    ref,
                    roomId: roomId,
                    eventId: reactionMessage.id,
                    emoji: emoji,
                  ),
                ),
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
      child: TimelineSwipeReply(
        key: ValueKey('swipe-reply:$visualMessageId'),
        onReply: isLocalOutgoing
            ? null
            : () => actions.startReply(context, ref, message),
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
}
