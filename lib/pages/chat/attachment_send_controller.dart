import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/mutable_state.dart';
import '../../src/rust/api/matrix.dart' as rust;
import 'attachment_image_preparation.dart';
import 'attachment_media_draft.dart';
import 'attachment_media_utils.dart';
import 'blurhash_codec.dart';
import 'send_flight.dart';
import 'latest_message_control.dart';

/// Owns attachment batches and optimistic messages independently of panel layout.
/// Host callbacks preserve preview-route and shared-draft lifetime decisions.
class AttachmentSendController {
  AttachmentSendController({
    required this.container,
    required this.draftKey,
    required this.draft,
    required this.roomId,
    required this.totalMembers,
    required this.isMounted,
    required this.previewOpen,
    required this.hasSharedDraft,
    required this.enforceAccount,
    required this.onChanged,
    required this.onError,
    required this.onRefresh,
    required this.resolveSendPresentation,
    required this.onMessageQueued,
    required this.onMessageSent,
    required this.onClose,
  });

  final ProviderContainer container;
  final RoomAccountKey draftKey;
  final AttachmentMediaDraft draft;
  final String Function() roomId;
  final int Function() totalMembers;
  final bool Function() isMounted;
  final bool Function() previewOpen;
  final bool Function() hasSharedDraft;
  final bool Function() enforceAccount;
  final VoidCallback onChanged;
  final ValueChanged<String> onError;
  final Future<void> Function(String) onRefresh;
  final MessageSendPresentation Function() resolveSendPresentation;
  final void Function(String, MessageSendPresentation) onMessageQueued;
  final void Function(MessageSendPresentation, bool) onMessageSent;
  final VoidCallback onClose;
  bool isSending = false;

  void _setSending(bool value) {
    isSending = value;
    onChanged();
  }

  /// Local ids of images whose upload was accepted and whose server echo the
  /// current batch still has to wait for.
  final _settledLocalIds = <String>{};

  /// Whether the running batch inserted its messages optimistically, so
  /// [_finishBatch] can report that to the timeline. Polls and locations share
  /// the batch path but only appear once the server echoes them.
  bool _batchInsertedOptimistically = false;

  /// Presentation resolved once per batch. [resolveSendPresentation] has side
  /// effects (it cancels an in-flight flight and arms the burst suppression),
  /// so the optimistic rows must reuse the batch's own answer rather than
  /// resolving a second one.
  MessageSendPresentation _batchPresentation = MessageSendPresentation.quiet;

  Future<bool> sendSelectedMedia({
    bool closePicker = true,
    bool includeReply = true,
  }) async {
    _ensureCanSend();
    final items = List<AttachmentMediaItem>.of(draft.selected);
    if (isSending || items.isEmpty) return false;
    final description = draft.description.text.trim();
    final caption = description.isEmpty ? null : description;
    final lastImage = items.lastIndexWhere((item) => item.isImage);
    final replyState = container.read(replyingToProvider(draftKey).notifier);
    final replyTo = includeReply ? replyState.value : null;
    var albumRoot = draft.albumRootEventId;
    final album =
        albumRoot != null || items.where((item) => item.isImage).length > 1;
    await _runBatch(
      [
        for (var index = 0; index < items.length; index++)
          () async {
            final eventId = await _sendSingleMedia(
              items[index],
              caption: index == lastImage ? caption : null,
              albumRoot: albumRoot,
              replyToEventId: replyTo?.id,
              replyToUserId: replyTo == null || replyTo.isMe
                  ? null
                  : replyTo.senderId,
            );
            if (album && albumRoot == null && eventId != null) {
              albumRoot = eventId;
              draft.albumRootEventId = eventId;
            }
          },
      ],
      draft.selected,
      closePicker: closePicker,
    );
    final sent = (isMounted() || hasSharedDraft()) && draft.selected.isEmpty;
    if (sent &&
        replyTo != null &&
        replyState.mounted &&
        replyState.value?.id == replyTo.id) {
      replyState.value = null;
    }
    return sent;
  }

  /// Optimistically inserts the picked image as a local outgoing message so
  /// the bubble and its entrance animation appear before the upload starts.
  /// Returns the local message id used to reconcile or fail the entry.
  String _queueLocalImage({
    required PreparedAttachmentImage prepared,
    required String? caption,
    required rust.ImageMessageMetadata metadata,
  }) {
    final timestamp = nextLocalOutgoingTimestamp(container, roomId(), draftKey);
    final id =
        '$localOutgoingPendingPrefix${DateTime.now().microsecondsSinceEpoch}';
    final local = LocalOutgoingMessage(
      message: rust.ChatMessage(
        id: id,
        senderId: draftKey.userId,
        senderName: '我',
        content: caption ?? prepared.filename,
        caption: caption,
        imageMetadata: metadata,
        inReplyTo: metadata.replyToEventId,
        mentionedUserIds: const [],
        mentionsRoom: false,
        timestamp: timestamp.toString(),
        isMe: true,
        msgType: rust.MessageType.image,
        // The real `mxc://` source only exists after the upload; the bubble
        // renders [localImageBytes] meanwhile.
        imageUrl: '$localOutgoingPreviewUrlPrefix$id',
        imageWidth: prepared.width,
        imageHeight: prepared.height,
        filename: prepared.filename,
        fileSize: prepared.bytes.length,
        mimeType: prepared.mimeType,
        isEdited: false,
        editHistory: const [],
        reactions: const [],
        readers: const [],
        totalMembers: totalMembers(),
      ),
      localImageBytes: prepared.bytes,
      replyToUserId: metadata.replyToUserId,
    );
    upsertLocalOutgoingMessageInState(_outgoingState, local);
    _batchInsertedOptimistically = true;
    onMessageQueued(sendFlightId(id), _batchPresentation);
    return id;
  }

  MutableState<List<LocalOutgoingMessage>> get _outgoingState =>
      container.read(localOutgoingMessagesProvider(draftKey).notifier);

  /// Marks a queued image upload as failed so the bubble keeps showing the
  /// picked bytes with an error affordance instead of vanishing.
  void _failLocalMedia(String localId) {
    final outgoing = _outgoingState;
    final existing = outgoing.value.where(
      (message) => message.message.id == localId,
    );
    if (existing.isEmpty) return;
    final failed = copyLocalOutgoingMessageWithId(
      existing.first,
      failedLocalOutgoingId(localId),
    );
    markLocalOutgoingMessageFailedInState(outgoing, localId, failed);
  }

  /// Marks a queued image upload as accepted and records it for the batch's
  /// single reconciliation run once every item has settled.
  ///
  /// The poll is driven by the captured [ProviderContainer] because the
  /// preview route can dispose this widget while the upload is in flight.
  void _settleLocalMedia(String localId) {
    final outgoing = _outgoingState;
    _settledLocalIds.add(
      markLocalOutgoingMessageSentInState(outgoing, localId),
    );
  }

  /// Polls the timeline until every accepted image in the batch has been
  /// replaced by its server echo, or the retry budget runs out. One ladder per
  /// batch instead of one per image.
  void _reconcileSettledLocalMedia() {
    if (_settledLocalIds.isEmpty) return;
    final outgoing = _outgoingState;
    final ids = Set<String>.of(_settledLocalIds);
    _settledLocalIds.clear();
    unawaited(
      reconcileSentLocalMessagesInState(
        outgoing,
        () => refreshMessagesContainer(container, roomId()),
        () => container.read(activeUserIdProvider) == draftKey.userId,
        ids,
      ),
    );
  }

  Future<String?> _sendSingleMedia(
    AttachmentMediaItem item, {
    String? caption,
    String? albumRoot,
    String? replyToEventId,
    String? replyToUserId,
  }) async {
    final original = await item.original;
    final file = original.file;
    final filename = item.editedFilename ?? original.filename;
    final mime =
        item.editedMimeType ??
        resolveAttachmentMime(original.filename, file.mimeType);
    if (item.isImage) {
      final PreparedAttachmentImage prepared;
      if (item.editedBytes == null && item.asset != null) {
        prepared = await prepareAttachmentAssetImage(
          asset: item.asset!,
          file: File(file.path),
          filename: filename,
          mimeType: mime,
          compress: item.compress,
        );
      } else {
        final rawBytes = item.editedBytes ?? await readAttachmentBytes(file);
        final detectedMime = mime ?? detectImageMime(rawBytes);
        if (detectedMime?.startsWith('image/') != true) {
          throw '无法识别图片格式';
        }
        prepared = await prepareAttachmentBufferedImage(
          rawBytes,
          filename: filename,
          mimeType: detectedMime!,
          compress: item.compress,
        );
      }
      final blurhash = await encodeImageBlurhash(prepared.bytes);
      _ensureCanSend();
      final metadata = rust.ImageMessageMetadata(
        albumRoot: albumRoot,
        replyToEventId: replyToEventId,
        replyToUserId: replyToUserId,
        blurhash: blurhash,
        spoiler: item.spoiler,
      );
      // Insert the bubble before uploading: the upload can take a long time on
      // a large image or a slow connection and the user should not have to
      // wait for it (and for the echo download) before seeing their message.
      final localId = _queueLocalImage(
        prepared: prepared,
        caption: caption,
        metadata: metadata,
      );
      try {
        final eventId = await rust.sendImageMessage(
          accountUserId: draftKey.userId,
          roomId: roomId(),
          imageData: prepared.bytes,
          filename: prepared.filename,
          mimeType: prepared.mimeType,
          width: prepared.width,
          height: prepared.height,
          caption: caption,
          metadata: metadata,
        );
        _settleLocalMedia(localId);
        return eventId;
      } catch (_) {
        _failLocalMedia(localId);
        rethrow;
      }
    } else {
      final bytes = await readAttachmentBytes(file);
      _ensureCanSend();
      if (item.asset?.type == AssetType.video ||
          classifyAttachmentMime(mime) == AttachmentMediaKind.video) {
        final size = item.asset?.size;
        await rust.sendVideoMessage(
          accountUserId: draftKey.userId,
          roomId: roomId(),
          videoData: bytes,
          filename: filename,
          mimeType: mime?.startsWith('video/') == true ? mime : null,
          size: bytes.length,
          width: size?.width.round(),
          height: size?.height.round(),
          durationMs: item.asset?.videoDuration.inMilliseconds,
        );
      } else {
        await rust.sendFileMessage(
          accountUserId: draftKey.userId,
          roomId: roomId(),
          fileData: bytes,
          filename: filename,
          mimeType: mime,
          size: bytes.length,
        );
      }
    }
    return null;
  }

  Future<void> sendFiles(List<XFile> files) => _runBatch(
    files
        .map(
          (file) =>
              () => _sendSingleFile(file),
        )
        .toList(),
    files,
  );

  Future<void> _sendSingleFile(XFile file) async {
    final bytes = await readAttachmentBytes(file);
    _ensureCanSend();
    await rust.sendFileMessage(
      accountUserId: draftKey.userId,
      roomId: roomId(),
      fileData: bytes,
      filename: file.name,
      mimeType: resolveAttachmentMime(file.name, file.mimeType),
      size: bytes.length,
    );
  }

  Future<void> sendPoll(
    String question,
    List<String> answers,
    bool disclosed,
    int maxSelections,
  ) => _runBatch([
    () => rust.sendPoll(
      accountUserId: draftKey.userId,
      roomId: roomId(),
      question: question,
      answers: answers,
      disclosed: disclosed,
      maxSelections: maxSelections,
    ),
  ], null);

  Future<void> sendLocation(String body, String geoUri) => _runBatch([
    () => rust.sendLocation(
      accountUserId: draftKey.userId,
      roomId: roomId(),
      body: body,
      geoUri: geoUri,
    ),
  ], null);

  void _ensureCanSend() {
    if (!isMounted()) throw StateError('附件发送已取消');
    if (enforceAccount() &&
        container.read(activeUserIdProvider) != draftKey.userId) {
      throw StateError('账号已切换，请重新选择附件');
    }
  }

  /// Sends a batch of individual send operations, tracking per-item success so
  /// a partial failure does not re-send already-delivered items on retry, and
  /// so a refresh failure is never misreported as a send failure.
  ///
  /// [items] carries the source selection so successfully-sent entries can be
  /// pruned from the UI; pass `null` for non-batch sends (poll/location/edit).
  Future<void> _runBatch(
    List<Future<void> Function()> ops,
    List<dynamic>? items, {
    bool closePicker = true,
  }) async {
    if (isSending || ops.isEmpty) return;
    _setSending(true);
    draft.setSending(true);
    final presentation = resolveSendPresentation();
    _batchPresentation = presentation;
    _settledLocalIds.clear();
    _batchInsertedOptimistically = false;
    var sent = 0;
    try {
      for (var i = 0; i < ops.length; i++) {
        if (!isMounted()) return;
        try {
          _ensureCanSend();
          await ops[i]();
          sent++;
          if (!isMounted() && !previewOpen() && !hasSharedDraft()) return;
          // Prune the head: ops and items advance in lockstep, so after a
          // success the list tail == remaining unsent items. On full success
          // the list is empty; on partial failure the user keeps the unsent
          // remainder, so a retry never re-sends delivered items.
          if (items != null && items.isNotEmpty) {
            items.removeAt(0);
            draft.selectionChanged();
          }
          if (isMounted()) onChanged();
        } catch (e) {
          if (sent > 0) {
            await _finishBatch(presentation, closePicker: false);
          }
          if (isMounted()) {
            onError(sent > 0 ? '已发送 $sent 项; 随后失败: $e' : '发送失败: $e');
          }
          return;
        }
      }
      await _finishBatch(presentation, closePicker: closePicker);
    } finally {
      // Every exit path funnels through here, so a single flush covers full
      // success, partial failure, and the preview route's detached sends.
      _reconcileSettledLocalMedia();
      if (isMounted() && isSending) _setSending(false);
      if (isMounted() || previewOpen() || hasSharedDraft()) {
        draft.setSending(false);
      }
    }
  }

  /// Best-effort refresh + completion callback. A refresh error is swallowed
  /// (it does not invalidate already-sent messages).
  Future<void> _finishBatch(
    MessageSendPresentation presentation, {
    required bool closePicker,
  }) async {
    try {
      await onRefresh(roomId());
    } catch (_) {
      // Refresh is best-effort; never surface as a send failure.
    }
    if (!isMounted()) return;
    onMessageSent(presentation, _batchInsertedOptimistically);
    if (closePicker) {
      _setSending(false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (isMounted()) onClose();
      });
    }
  }
}
