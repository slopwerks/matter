import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/markdown/markdown_composer.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/chat_provider.dart';
import '../../../providers/mutable_state.dart';
import '../../../src/rust/api/matrix.dart' as rust;
import '../composer_picker_panel.dart' show StickerFlightPreview;
import '../latest_message_control.dart';
import '../send_flight.dart';
import '../sticker_catalog.dart';
import 'composer_draft_controller.dart';
import 'composer_send.dart';

/// Optimistic presentation around the shared text-send core, plus sticker
/// sending. Captures state cells before awaits to survive input disposal.
class ComposerSendController {
  ComposerSendController({
    required this.ref,
    required this.draftKey,
    required this.context,
    required this.isMounted,
    required this.textController,
    required this.textFieldKey,
    required this.totalMembers,
    required this.sourceLoading,
    required this.composerOpen,
    required this.shouldRestoreKeyboard,
    required this.showKeyboard,
    required this.stopTyping,
    required this.onChanged,
    required this.resolveSendPresentation,
    required this.onMessageQueued,
    required this.onMessageSent,
  });

  final WidgetRef ref;
  final RoomAccountKey draftKey;
  final BuildContext Function() context;
  final bool Function() isMounted;
  final TextEditingController textController;
  final GlobalKey textFieldKey;
  final int Function() totalMembers;
  final bool Function() sourceLoading;
  final bool Function() composerOpen;
  final bool Function() shouldRestoreKeyboard;
  final VoidCallback showKeyboard;
  final VoidCallback stopTyping;
  final VoidCallback onChanged;
  final MessageSendPresentation Function() resolveSendPresentation;
  final void Function(String, MessageSendPresentation) onMessageQueued;
  final void Function(MessageSendPresentation, bool) onMessageSent;
  bool isSending = false;

  void _setSending(bool value) {
    isSending = value;
    if (isMounted()) onChanged();
  }

  Future<bool> sendText(
    String rawText, {
    void Function(Object)? onDetachedError,
  }) async {
    final text = rawText.trim();
    if (text.isEmpty ||
        isSending ||
        sourceLoading() ||
        ref.read(editingSendInFlightProvider(draftKey)) != null) {
      return false;
    }
    final container = ProviderScope.containerOf(context(), listen: false);
    final compiled = const MarkdownComposer().compile(text);
    if (compiled.body.trim().isEmpty) return false;
    final editing = ref.read(editingMessageProvider(draftKey));
    final replyTo = ref.read(replyingToProvider(draftKey));
    final replyState = ref.read(replyingToProvider(draftKey).notifier);
    final draftState = ref.read(messageDraftProvider(draftKey).notifier);
    final restoreKeyboard = shouldRestoreKeyboard();
    final localId = editing == null
        ? '$localOutgoingPendingPrefix${DateTime.now().microsecondsSinceEpoch}'
        : null;
    final timestamp = localId != null ? _nextLocalTimestamp() : null;
    final presentation = localId != null ? resolveSendPresentation() : null;
    MutableState<List<LocalOutgoingMessage>>? outgoing;
    LocalOutgoingMessage? failed;
    if (localId != null) {
      if (presentation == MessageSendPresentation.flight) {
        _registerTextFlight(localId, compiled.body);
      }
      onMessageQueued(sendFlightId(localId), presentation!);
      final replyUser = replyTo == null || replyTo.isMe
          ? null
          : replyTo.senderId;
      outgoing = ref.read(localOutgoingMessagesProvider(draftKey).notifier);
      failed = LocalOutgoingMessage(
        message: _localTextMessage(
          id: failedLocalOutgoingId(localId),
          compiled: compiled,
          inReplyTo: replyTo?.id,
          timestamp: timestamp,
        ),
        replyToUserId: replyUser,
        markdownSource: compiled.source,
      );
      upsertLocalOutgoingMessage(
        ref,
        draftKey,
        LocalOutgoingMessage(
          message: _localTextMessage(
            id: localId,
            compiled: compiled,
            inReplyTo: replyTo?.id,
            timestamp: timestamp,
          ),
          replyToUserId: replyUser,
          markdownSource: compiled.source,
        ),
      );
      textController.clear();
    }
    _setSending(true);
    Object? sendError;
    final sent = await sendDraftText(
      ref,
      roomId: draftKey.roomId,
      draftKey: draftKey,
      rawText: rawText,
      totalMembers: totalMembers(),
      onError: (error) => sendError = error,
      refreshContainer: container,
    );

    if (!sent) {
      if (localId != null && outgoing != null) {
        if (composerOpen()) {
          // The editor owns retries: remove the local echo, restore only free
          // relation/draft state, and never leave a second retryable bubble.
          outgoing.value = outgoing.value
              .where((entry) => entry.message.id != localId)
              .toList();
          if (replyTo != null && replyState.value == null) {
            replyState.value = replyTo;
          }
          if (editing == null && draftState.value.isEmpty) {
            draftState.value = rawText;
          }
        } else if (failed != null) {
          markLocalOutgoingMessageFailedInState(outgoing, localId, failed);
        }
      }
      final active = container.read(activeUserIdProvider) == draftKey.userId;
      _setSending(false);
      if (!active) return false;
      final error = sendError ?? StateError('send failed');
      if (isMounted()) {
        ScaffoldMessenger.of(context()).showSnackBar(
          SnackBar(
            content: Text('发送失败: $error'),
            duration: const Duration(seconds: 2),
          ),
        );
        if (restoreKeyboard) showKeyboard();
      } else {
        onDetachedError?.call(error);
      }
      return false;
    }
    final active = container.read(activeUserIdProvider) == draftKey.userId;
    if (!isMounted() || !active) {
      if (localId != null && outgoing != null) {
        outgoing.value = outgoing.value
            .where((entry) => entry.message.id != localId)
            .toList();
      }
      if (!isMounted() && active && localId != null) {
        unawaited(refreshMessagesContainer(container, draftKey.roomId));
      }
      if (isMounted()) _setSending(false);
      return true;
    }
    final sentId = localId == null
        ? null
        : markLocalOutgoingMessageSentInState(outgoing!, localId);
    stopTyping();
    if (localId != null) {
      onMessageSent(presentation!, true);
      unawaited(reconcileSentLocalMessage(ref, draftKey, sentId!));
    }
    _setSending(false);
    return true;
  }

  int _nextLocalTimestamp() {
    var timestamp = DateTime.now().millisecondsSinceEpoch;
    for (final message in ref.read(messageCacheProvider(draftKey.roomId))) {
      final ts = int.tryParse(message.timestamp) ?? 0;
      if (ts >= timestamp) timestamp = ts + 1;
    }
    for (final outgoing in ref.read(localOutgoingMessagesProvider(draftKey))) {
      final ts = int.tryParse(outgoing.message.timestamp) ?? 0;
      if (ts >= timestamp) timestamp = ts + 1;
    }
    return timestamp;
  }

  rust.ChatMessage _localTextMessage({
    required String id,
    required CompiledMarkdownMessage compiled,
    String? inReplyTo,
    int? timestamp,
  }) => rust.ChatMessage(
    id: id,
    senderId: ref.read(currentUserProvider)?.id ?? '',
    senderName: '我',
    content: compiled.body,
    formattedBody: compiled.formattedBody,
    mentionedUserIds: compiled.mentionedUserIds,
    mentionsRoom: compiled.mentionsRoom,
    timestamp: (timestamp ?? DateTime.now().millisecondsSinceEpoch).toString(),
    isMe: true,
    msgType: rust.MessageType.text,
    inReplyTo: inReplyTo,
    isEdited: false,
    editHistory: const [],
    reactions: const [],
    readers: const [],
    totalMembers: totalMembers(),
  );

  void _registerTextFlight(String id, String text) {
    final box = textFieldKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return;
    unawaited(
      registerSendFlight(
        id,
        SendFlightSpec(
          sourceRect: box.localToGlobal(Offset.zero) & box.size,
          kind: SendFlightKind.text,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                text,
                maxLines: 5,
                overflow: TextOverflow.clip,
                style: const TextStyle(decoration: TextDecoration.none),
              ),
            ),
          ),
        ),
      ),
    );
  }

  rust.ChatMessage _localStickerMessage({
    required String id,
    required StickerItem sticker,
    int? timestamp,
  }) => rust.ChatMessage(
    id: id,
    senderId: ref.read(currentUserProvider)?.id ?? '',
    senderName: '我',
    content: sticker.body,
    mentionedUserIds: const [],
    mentionsRoom: false,
    timestamp: (timestamp ?? DateTime.now().millisecondsSinceEpoch).toString(),
    isMe: true,
    msgType: rust.MessageType.sticker,
    imageUrl: sticker.imageUrl,
    mediaSourceJson: jsonEncode(sticker.imageUrl),
    mimeType: sticker.mimeType,
    imageWidth: sticker.width,
    imageHeight: sticker.height,
    isEdited: false,
    editHistory: const [],
    reactions: const [],
    readers: const [],
    totalMembers: totalMembers(),
  );

  Future<void> sendSticker(StickerItem sticker, Rect? sourceRect) async {
    final imageUrl = sticker.imageUrl;
    if (imageUrl == null) {
      ScaffoldMessenger.of(context()).showSnackBar(
        const SnackBar(
          content: Text('贴纸缺少图片地址'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    final id =
        '$localOutgoingPendingPrefix${DateTime.now().microsecondsSinceEpoch}';
    final timestamp = _nextLocalTimestamp();
    final presentation = resolveSendPresentation();
    if (presentation == MessageSendPresentation.flight && sourceRect != null) {
      unawaited(
        registerSendFlight(
          id,
          SendFlightSpec(
            sourceRect: sourceRect,
            kind: SendFlightKind.sticker,
            child: StickerFlightPreview(sticker: sticker),
          ),
        ),
      );
    }
    onMessageQueued(sendFlightId(id), presentation);
    final outgoing = ref.read(localOutgoingMessagesProvider(draftKey).notifier);
    final failed = LocalOutgoingMessage(
      message: _localStickerMessage(
        id: failedLocalOutgoingId(id),
        sticker: sticker,
        timestamp: timestamp,
      ),
      sourceImageUrl: imageUrl,
    );
    upsertLocalOutgoingMessage(
      ref,
      draftKey,
      LocalOutgoingMessage(
        message: _localStickerMessage(
          id: id,
          sticker: sticker,
          timestamp: timestamp,
        ),
        sourceImageUrl: imageUrl,
      ),
    );
    try {
      await rust.sendSticker(
        roomId: draftKey.roomId,
        imageUrl: imageUrl,
        body: sticker.body,
        mimeType: sticker.mimeType,
        width: sticker.width,
        height: sticker.height,
      );
      final sentId = markLocalOutgoingMessageSentInState(outgoing, id);
      if (!isMounted()) return;
      stopTyping();
      onMessageSent(presentation, true);
      unawaited(reconcileSentLocalMessage(ref, draftKey, sentId));
    } catch (_) {
      markLocalOutgoingMessageFailedInState(outgoing, id, failed);
    }
  }
}
