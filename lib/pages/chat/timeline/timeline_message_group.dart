import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../src/rust/api/matrix.dart' hide redactMessage;

import '../../../providers/auth_provider.dart';
import '../../../providers/image_view_history.dart';
import '../image_message_runs.dart';
import '../image_viewer.dart' show ImageHistoryLoader;
import '../message_jump_highlight.dart';
import '../send_flight.dart';
import 'timeline_clustering.dart';
import 'timeline_message_presenter.dart';
import 'timeline_message_actions.dart';
import 'timeline_sticky_avatar.dart';

class MessageGroupWidget extends ConsumerWidget {
  final MessageGroup group;
  final bool showAvatar;
  final String roomId;
  final Map<String, ChatMessage> messageIndex;
  final Map<String, GlobalKey> messageAnchorKeys;
  final ValueNotifier<String?>? jumpHighlight;
  final Map<String, String> remoteToLocalFlightId;
  final Set<String> insertionAnimationIds;
  final Set<String> lateralInsertionAnimationIds;

  /// Decoded preview bytes for optimistic image rows, keyed by the image
  /// message's local id. Lets the bubble paint the picked file before the
  /// upload has produced a `mxc://` source.
  final Map<String, Uint8List> localImagePreviews;
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
  final ImageHistoryLoader? loadOlderImages;

  const MessageGroupWidget({
    super.key,
    required this.group,
    required this.roomId,
    required this.messageIndex,
    this.messageAnchorKeys = const {},
    this.jumpHighlight,
    this.remoteToLocalFlightId = const {},
    this.insertionAnimationIds = const {},
    this.lateralInsertionAnimationIds = const {},
    this.localImagePreviews = const {},
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
    this.loadOlderImages,
  });

  static const double _avatarSize = 36.0;
  static const double _avatarSlotWidth = 44.0;
  static const double _groupBottomGap = 9.0;

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

  Widget _anchoredMessage(
    ChatMessage message,
    Widget child, {
    bool collection = false,
    Set<String> collectionIds = const {},
  }) {
    if (jumpHighlight != null) {
      child = MessageJumpHighlight(
        messageId: message.id,
        collectionIds: collectionIds,
        target: jumpHighlight!,
        child: child,
      );
    }
    final anchorKey = collection ? null : messageAnchorKeys[message.id];
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
                  _presenter.buildMessage(
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
          children: _buildMessageRows(context, ref, true, mentionDisplayNames),
        ),
      );
    }

    final messagesColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: _buildMessageRows(context, ref, false, mentionDisplayNames),
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
      child: TimelineStickyAvatarGroup(
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
          children: _buildMessageRows(
            context,
            ref,
            false,
            mentionDisplayNames,
            linkedAvatarOffset: avatarSwipeOffset,
          ),
        ),
      ),
    );
  }

  List<Widget> _buildMessageRows(
    BuildContext context,
    WidgetRef ref,
    bool isMe,
    Map<String, String> mentionDisplayNames, {
    ValueNotifier<double>? linkedAvatarOffset,
  }) {
    final runs = group.imageRuns ?? chatImageRuns(group.messages);
    final viewed = runs.any((run) => run.collection)
        ? ref.watch(
            imageViewHistoryProvider((
              account: ref.watch(activeUserIdProvider) ?? 'anonymous',
              room: roomId,
            )),
          )
        : const <String>[];
    final rows = <Widget>[];
    for (var index = 0; index < runs.length; index++) {
      final run = runs[index];
      var selected = run.messages.last;
      if (run.collection && !run.album) {
        final imagesById = {for (final image in run.messages) image.id: image};
        for (final id in viewed.reversed) {
          final image = imagesById[id];
          if (image != null) {
            selected = image;
            break;
          }
        }
      }
      rows.add(
        _anchoredMessage(
          run.messages.first,
          _presenter.buildMessage(
            context,
            ref,
            selected,
            isMe,
            membersById: membersById,
            mentionDisplayNames: mentionDisplayNames,
            isFirst: index == 0 && group.startsCluster,
            isLast: index == runs.length - 1 && group.endsCluster,
            linkedAvatarOffset: index == runs.length - 1
                ? linkedAvatarOffset
                : null,
            imageRun: run.collection ? run : null,
          ),
          collection: run.collection,
          collectionIds: run.collection
              ? run.messages.map((m) => m.id).toSet()
              : const {},
        ),
      );
    }
    return rows;
  }

  TimelineMessagePresenter get _presenter => TimelineMessagePresenter(
    roomId: roomId,
    messageIndex: messageIndex,
    messageAnchorKeys: messageAnchorKeys,
    remoteToLocalFlightId: remoteToLocalFlightId,
    insertionAnimationIds: insertionAnimationIds,
    lateralInsertionAnimationIds: lateralInsertionAnimationIds,
    localImagePreviews: localImagePreviews,
    actions: TimelineMessageActions(
      roomId: roomId,
      membersById: membersById,
      onReplyRequested: onReplyRequested,
      onMessageForwarded: onMessageForwarded,
    ),
    anchor: _anchoredMessage,
    scrollController: scrollController,
    stickyBottomInset: stickyBottomInset,
    onImageLoaded: onImageLoaded,
    onMessageJumpRequested: onMessageJumpRequested,
    onMessageForwarded: onMessageForwarded,
    loadOlderImages: loadOlderImages,
  );
}
