import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/markdown/markdown_composer.dart';
import '../../../features/markdown/markdown_source_store.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/chat_provider.dart';
import '../../../providers/mutable_state.dart';
import '../../../src/rust/api/matrix.dart' as rust;
import '../latest_message_control.dart';
import 'composer_draft_controller.dart';

/// Shared text-send pipeline for the inline input and a full-screen composer
/// that may outlive it. Capture surviving notifiers before the network wait;
/// [refreshContainer] keeps post-send refresh independent of the caller's ref.
Future<bool> sendDraftText(
  WidgetRef ref, {
  required String roomId,
  required RoomAccountKey draftKey,
  required String rawText,
  required int totalMembers,
  ValueNotifier<bool>? sendInFlight,
  bool composerHoldsDraft = false,
  ProviderContainer? refreshContainer,
  void Function(Object error)? onError,
  void Function(MessageSendPresentation presentation, bool success)?
  onMessageSent,
  void Function(String localId, MessageSendPresentation presentation)?
  onMessageQueued,
  MessageSendPresentation Function()? resolveSendPresentation,
}) async {
  final text = rawText.trim();
  if (text.isEmpty) return false;
  final compiled = const MarkdownComposer().compile(text);
  if (compiled.body.trim().isEmpty) return false;

  final editing = ref.read(editingMessageProvider(draftKey));
  final replyTo = ref.read(replyingToProvider(draftKey));
  final replyState = ref.read(replyingToProvider(draftKey).notifier);
  final draftState = ref.read(messageDraftProvider(draftKey).notifier);
  final editingState = ref.read(editingMessageProvider(draftKey).notifier);
  final editDraftState = ref.read(editingDraftProvider(draftKey).notifier);
  final editingSendState = ref.read(
    editingSendInFlightProvider(draftKey).notifier,
  );
  String? ownedEditingSendId;
  if (editing != null) {
    if (editingSendState.value != null) {
      final error = StateError('An edit is already being sent');
      onError?.call(error);
      return false;
    }
    ownedEditingSendId = editing.id;
    editingSendState.value = editing.id;
  }
  bool accountStillActive() =>
      refreshContainer == null ||
      refreshContainer.read(activeUserIdProvider) == draftKey.userId;
  MutableState<List<LocalOutgoingMessage>>? fallbackOutgoing;
  LocalOutgoingMessage? fallbackFailedMessage;
  if (composerHoldsDraft && editing == null) {
    final outgoingState = ref.read(
      localOutgoingMessagesProvider(draftKey).notifier,
    );
    fallbackOutgoing = outgoingState;
    var timestamp = DateTime.now().millisecondsSinceEpoch;
    for (final message in ref.read(messageCacheProvider(roomId))) {
      final candidate = int.tryParse(message.timestamp) ?? 0;
      if (candidate >= timestamp) timestamp = candidate + 1;
    }
    for (final outgoing in outgoingState.value) {
      final candidate = int.tryParse(outgoing.message.timestamp) ?? 0;
      if (candidate >= timestamp) timestamp = candidate + 1;
    }
    final failedId =
        '$localOutgoingFailedPrefix${DateTime.now().microsecondsSinceEpoch}';
    fallbackFailedMessage = LocalOutgoingMessage(
      message: rust.ChatMessage(
        id: failedId,
        senderId: draftKey.userId,
        senderName: '我',
        content: compiled.body,
        formattedBody: compiled.formattedBody,
        mentionedUserIds: compiled.mentionedUserIds,
        mentionsRoom: compiled.mentionsRoom,
        timestamp: timestamp.toString(),
        isMe: true,
        msgType: rust.MessageType.text,
        inReplyTo: replyTo?.id,
        isEdited: false,
        editHistory: const [],
        reactions: const [],
        readers: const [],
        totalMembers: totalMembers,
      ),
      replyToUserId: (replyTo == null || replyTo.isMe)
          ? null
          : replyTo.senderId,
      markdownSource: compiled.source,
    );
  }

  sendInFlight?.value = true;
  if (editing == null) {
    if (composerHoldsDraft) {
      draftState.value = '';
    }
    // Consume only this send's relation, before the network wait. A newer
    // reply selected while sending belongs to the next draft.
    if (replyTo != null) replyState.value = null;
  }
  try {
    String remoteEventId;
    if (editing != null) {
      remoteEventId = await rust.editMessage(
        accountUserId: draftKey.userId,
        roomId: roomId,
        eventId: editing.id,
        message: compiled.toRust(),
        previousMentionedUserIds: editing.mentionedUserIds,
        previousMentionsRoom: editing.mentionsRoom,
      );
    } else if (replyTo != null) {
      remoteEventId = await rust.sendReply(
        accountUserId: draftKey.userId,
        roomId: roomId,
        message: compiled.toRust(),
        replyToEventId: replyTo.id,
        replyToUserId: replyTo.isMe ? null : replyTo.senderId,
      );
    } else {
      remoteEventId = await rust.sendMessage(
        accountUserId: draftKey.userId,
        roomId: roomId,
        message: compiled.toRust(),
      );
    }
    var persistMarkdownSource = false;
    if (accountStillActive()) {
      final canPersist = await _canPersistMarkdownSource(roomId);
      persistMarkdownSource = accountStillActive() && canPersist;
    }
    try {
      await const MarkdownSourceStore().save(
        userId: draftKey.userId,
        roomId: roomId,
        eventId: editing?.id ?? remoteEventId,
        source: compiled.source,
        body: compiled.body,
        formattedBody: compiled.formattedBody,
        persist: persistMarkdownSource,
      );
    } catch (e) {
      // Accepted sends must not become retryable failures if source caching fails.
      debugPrint('Failed to save markdown source: $e');
    }
    if (editing != null) {
      final currentEditDraft = editDraftState.value;
      final stillSendingSameText =
          editingState.value?.id == editing.id &&
          (currentEditDraft == null ||
              (currentEditDraft.editingId == editing.id &&
                  currentEditDraft.text == rawText));
      if (stillSendingSameText) {
        editingState.value = null;
        editDraftState.value = null;
      } else if (editingState.value?.id == editing.id) {
        // Keep a newer draft, but advance its accepted mention baseline.
        editingState.value = _acceptedEditedMessage(editing, compiled);
      }
    }
    if ((editing != null || composerHoldsDraft) && accountStillActive()) {
      unawaited(
        refreshContainer != null
            ? refreshMessagesContainer(refreshContainer, roomId)
            : refreshMessages(ref, roomId),
      );
    }
    return true;
  } catch (e) {
    if (composerHoldsDraft && editing == null) {
      final stateStillConsumed =
          draftState.value == '' &&
          replyState.value == null &&
          editingState.value == null &&
          editDraftState.value == null;
      // Never overwrite newer remounted work. Preserve this send as a failed
      // timeline entry if the original consumed providers are no longer free.
      if (!stateStillConsumed) {
        if (fallbackOutgoing != null && fallbackFailedMessage != null) {
          final failedId = fallbackFailedMessage.message.id;
          if (!fallbackOutgoing.value.any(
            (entry) => entry.message.id == failedId,
          )) {
            fallbackOutgoing.value = [
              ...fallbackOutgoing.value,
              fallbackFailedMessage,
            ];
          }
        }
        onError?.call(e);
        return false;
      }
      draftState.value = rawText;
      if (replyTo != null) replyState.value = replyTo;
    }
    onError?.call(e);
    return false;
  } finally {
    if (ownedEditingSendId != null &&
        editingSendState.value == ownedEditingSendId) {
      editingSendState.value = null;
    }
    sendInFlight?.value = false;
  }
}

rust.ChatMessage _acceptedEditedMessage(
  rust.ChatMessage original,
  CompiledMarkdownMessage accepted,
) => rust.ChatMessage(
  id: original.id,
  senderId: original.senderId,
  senderName: original.senderName,
  content: accepted.body,
  formattedBody: accepted.formattedBody,
  caption: original.caption,
  captionFormattedBody: original.captionFormattedBody,
  sharedCaption: original.sharedCaption,
  mentionedUserIds: accepted.mentionedUserIds,
  mentionsRoom: accepted.mentionsRoom,
  timestamp: original.timestamp,
  isMe: original.isMe,
  msgType: original.msgType,
  imageUrl: original.imageUrl,
  mediaSourceJson: original.mediaSourceJson,
  imageWidth: original.imageWidth,
  imageHeight: original.imageHeight,
  filename: original.filename,
  fileSize: original.fileSize,
  mimeType: original.mimeType,
  durationMs: original.durationMs,
  geoUri: original.geoUri,
  poll: original.poll,
  inReplyTo: original.inReplyTo,
  isEdited: true,
  editHistory: original.editHistory,
  reactions: original.reactions,
  readers: original.readers,
  totalMembers: original.totalMembers,
);

Future<bool> _canPersistMarkdownSource(String roomId) async {
  try {
    return !await rust.isRoomEncrypted(roomId: roomId);
  } catch (_) {
    return false;
  }
}
