import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:photo_manager/photo_manager.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/chat_visual_settings_provider.dart';
import '../../providers/mutable_state.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/neu_colors.dart';
import '../../widgets/glass.dart';
import '../../widgets/neu_decoration.dart';
import '../../widgets/neu_surface.dart';
import '../chat/latest_message_control.dart';
import 'attachment_caption_composer.dart';
import 'blurhash_codec.dart';
import 'attachment_image_preview_page.dart';
import 'attachment_media_draft.dart';
import 'attachment_media_gallery.dart';
import 'attachment_media_utils.dart';
import 'send_flight.dart';

export 'attachment_media_utils.dart'
    show
        AttachmentMediaKind,
        resolveAttachmentMime,
        classifyAttachmentMime,
        detectImageMime;

export 'attachment_media_gallery.dart' show attachmentMediaOrder;

/// The four attachment modes offered by the floating frosted-glass bar.
enum AttachmentTab { media, file, poll, location }

const _attachmentDockHeight = 72.0;
const _attachmentDockGap = 8.0;
const _attachmentSendButtonHeight = 44.0;
const _attachmentDockClearance = _attachmentDockHeight + _attachmentDockGap;
const _attachmentSendBarClearance =
    _attachmentDockClearance + _attachmentSendButtonHeight + _attachmentDockGap;
const _pollOptionAnimationDuration = Duration(milliseconds: 180);

/// Whether [photo_manager]'s native gallery grid works on this platform.
/// On Web/Linux/Windows it has no implementation and must be replaced with a
/// [file_selector] fallback to avoid MissingPluginException.
bool get photoManagerSupported =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

/// An inline attachment panel that starts at the keyboard height and expands
/// as the active content is dragged upward.
class AttachmentPicker extends StatefulWidget {
  final double height;
  final double maxHeight;
  final String roomId;
  final String accountUserId;
  final Future<void> Function(String roomId) onRefresh;
  final MessageSendPresentation Function() resolveSendPresentation;
  final void Function(
    MessageSendPresentation presentation,
    bool insertedOptimistically,
  )
  onMessageSent;

  /// Announces an optimistic image row so the timeline can play its entrance
  /// animation, exactly like a text or sticker send.
  final void Function(
    String stableMessageId,
    MessageSendPresentation presentation,
  )
  onMessageQueued;
  final int totalMembers;
  final ValueChanged<double> onHeightChanged;
  final VoidCallback onClose;

  const AttachmentPicker({
    super.key,
    required this.height,
    required this.maxHeight,
    required this.roomId,
    required this.accountUserId,
    required this.onRefresh,
    required this.resolveSendPresentation,
    required this.onMessageSent,
    required this.onMessageQueued,
    required this.totalMembers,
    required this.onHeightChanged,
    required this.onClose,
  });

  @override
  State<AttachmentPicker> createState() => _AttachmentPickerState();
}

class _AttachmentPickerState extends State<AttachmentPicker> {
  late final DraggableScrollableController _sheetController;
  late final ValueNotifier<double> _sheetExtent;
  AttachmentTab _tab = AttachmentTab.media;
  final Set<AttachmentTab> _visitedTabs = {AttachmentTab.media};
  late final String _accountUserId;
  bool _isSending = false;
  bool _isPickingFiles = false;
  final _mediaDraft = AttachmentMediaDraft();
  bool _previewOpen = false;

  /// Room/account pair the optimistic image rows belong to. [AttachmentPicker]
  /// is handed `accountUserId` from the composer's own draft key, so this is
  /// the same cell the text send path writes to.
  late final RoomAccountKey _draftKey;

  /// Providers outlive this widget, so the send pipeline keeps writing
  /// through them even while the image preview route has replaced it.
  late final ProviderContainer _container;

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

  /// Every Dart/FRB upload buffer is capped to avoid multiplying a very large
  /// allocation while it crosses the bridge into Rust.
  static const int _maxBufferedBytes = attachmentMaxBufferedBytes;
  static const int _maxImageEdge = 4096;
  static const int _maxImageQuality = 92;

  @override
  void initState() {
    super.initState();
    _accountUserId = widget.accountUserId;
    _container = ProviderScope.containerOf(context, listen: false);
    _draftKey = (roomId: widget.roomId, userId: widget.accountUserId);
    _sheetController = DraggableScrollableController();
    _sheetExtent = ValueNotifier<double>(0);
  }

  @override
  void dispose() {
    _sheetController.dispose();
    _sheetExtent.dispose();
    if (!_previewOpen) _mediaDraft.dispose();
    super.dispose();
  }

  Future<void> _openPreview(
    AttachmentMediaItem item,
    List<AttachmentMediaItem> images,
  ) async {
    if (_isSending || _previewOpen) return;
    _previewOpen = true;
    FocusManager.instance.primaryFocus?.unfocus();
    final route = MaterialPageRoute<bool>(
      fullscreenDialog: true,
      builder: (_) => AttachmentImagePreviewPage(
        draft: _mediaDraft,
        images: images,
        initialImage: item,
        onCaptionFocus: _expandForCaption,
        onSend: () => _sendSelectedMedia(closePicker: false),
      ),
    );
    try {
      final sent = await Navigator.of(context, rootNavigator: true).push(route);
      await route.completed;
      if (mounted && sent == true) widget.onClose();
    } finally {
      _previewOpen = false;
      if (!mounted) _mediaDraft.dispose();
    }
  }

  void _expandForCaption() {
    if (!mounted) return;
    widget.onHeightChanged(widget.maxHeight);
    if (_sheetController.isAttached) {
      unawaited(
        _sheetController.animateTo(
          1,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  Future<bool> _sendSelectedMedia({bool closePicker = true}) async {
    _ensureCanSend();
    final items = List<AttachmentMediaItem>.of(_mediaDraft.selected);
    if (_isSending || items.isEmpty) return false;
    final description = _mediaDraft.description.text.trim();
    final caption = description.isEmpty ? null : description;
    final lastImage = items.lastIndexWhere((item) => item.isImage);
    var albumRoot = _mediaDraft.albumRootEventId;
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
            );
            if (album && albumRoot == null && eventId != null) {
              albumRoot = eventId;
              _mediaDraft.albumRootEventId = eventId;
            }
          },
      ],
      _mediaDraft.selected,
      closePicker: closePicker,
    );
    return mounted && _mediaDraft.selected.isEmpty;
  }

  /// Optimistically inserts the picked image as a local outgoing message so
  /// the bubble and its entrance animation appear before the upload starts.
  /// Returns the local message id used to reconcile or fail the entry.
  String _queueLocalImage({
    required _PreparedImage prepared,
    required String? caption,
    required rust.ImageMessageMetadata metadata,
  }) {
    final timestamp = nextLocalOutgoingTimestamp(
      _container,
      widget.roomId,
      _draftKey,
    );
    final id =
        '$localOutgoingPendingPrefix${DateTime.now().microsecondsSinceEpoch}';
    final local = LocalOutgoingMessage(
      message: rust.ChatMessage(
        id: id,
        senderId: _draftKey.userId,
        senderName: '我',
        content: caption ?? prepared.filename,
        caption: caption,
        imageMetadata: metadata,
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
        totalMembers: widget.totalMembers,
      ),
      localImageBytes: prepared.bytes,
    );
    upsertLocalOutgoingMessageInState(_outgoingState, local);
    _batchInsertedOptimistically = true;
    widget.onMessageQueued(sendFlightId(id), _batchPresentation);
    return id;
  }

  MutableState<List<LocalOutgoingMessage>> get _outgoingState =>
      _container.read(localOutgoingMessagesProvider(_draftKey).notifier);

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
        () => refreshMessagesContainer(_container, widget.roomId),
        () => _container.read(activeUserIdProvider) == _draftKey.userId,
        ids,
      ),
    );
  }

  Future<String?> _sendSingleMedia(
    AttachmentMediaItem item, {
    String? caption,
    String? albumRoot,
  }) async {
    final original = await item.original;
    final file = original.file;
    final filename = item.editedFilename ?? original.filename;
    final mime =
        item.editedMimeType ??
        resolveAttachmentMime(original.filename, file.mimeType);
    if (item.isImage) {
      final prepared = item.editedBytes == null && item.asset != null
          ? await _prepareAssetImage(
              asset: item.asset!,
              file: File(file.path),
              filename: filename,
              mimeType: mime,
              compress: item.compress,
            )
          : await _prepareBufferedImage(
              item.editedBytes ?? await _readXFileBytes(file),
              filename: filename,
              mimeType: mime!,
              compress: item.compress,
            );
      final blurhash = await encodeImageBlurhash(prepared.bytes);
      _ensureCanSend();
      final metadata = rust.ImageMessageMetadata(
        albumRoot: albumRoot,
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
          accountUserId: _accountUserId,
          roomId: widget.roomId,
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
      final bytes = await _readXFileBytes(file);
      _ensureCanSend();
      if (item.asset?.type == AssetType.video ||
          classifyAttachmentMime(mime) == AttachmentMediaKind.video) {
        final size = item.asset?.size;
        await rust.sendVideoMessage(
          accountUserId: _accountUserId,
          roomId: widget.roomId,
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
          accountUserId: _accountUserId,
          roomId: widget.roomId,
          fileData: bytes,
          filename: filename,
          mimeType: mime,
          size: bytes.length,
        );
      }
    }
    return null;
  }

  Future<void> _sendFiles(List<XFile> files) => _runBatch(
    files
        .map(
          (file) =>
              () => _sendSingleFile(file),
        )
        .toList(),
    files,
  );

  Future<void> _pickFiles() async {
    if (_isSending || _isPickingFiles) return;
    setState(() => _isPickingFiles = true);
    try {
      final files = List<XFile>.of(await openFiles());
      if (!mounted || files.isEmpty) return;
      await _sendFiles(files);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('选择文件失败: $error')));
      }
    } finally {
      if (mounted) setState(() => _isPickingFiles = false);
    }
  }

  Future<void> _sendSingleFile(XFile file) async {
    final bytes = await _readXFileBytes(file);
    _ensureCanSend();
    await rust.sendFileMessage(
      accountUserId: _accountUserId,
      roomId: widget.roomId,
      fileData: bytes,
      filename: file.name,
      mimeType: resolveAttachmentMime(file.name, file.mimeType),
      size: bytes.length,
    );
  }

  Future<Uint8List> _readXFileBytes(XFile file) async {
    _ensureBufferedSize(await file.length(), '文件');
    final bytes = await file.readAsBytes();
    _ensureBufferedSize(bytes.length, '文件');
    return bytes;
  }

  Future<_PreparedImage> _prepareAssetImage({
    required AssetEntity asset,
    required File file,
    required String filename,
    required String? mimeType,
    bool compress = true,
  }) async {
    final sourceSize = asset.size;
    if (sourceSize.width <= 0 || sourceSize.height <= 0) {
      final original = await _readFileBytes(file, '图片');
      final detectedMime = mimeType ?? resolveAttachmentMime(filename, null);
      if (detectedMime?.startsWith('image/') != true) {
        throw '无法识别图片格式';
      }
      return _prepareBufferedImage(
        original,
        filename: filename,
        mimeType: detectedMime!,
        compress: compress,
      );
    }

    if (!compress || mimeType == 'image/gif' || mimeType == 'image/webp') {
      if (mimeType?.startsWith('image/') != true) throw '无法识别图片格式';
      return _PreparedImage(
        bytes: await _readFileBytes(file, '图片'),
        filename: filename,
        mimeType: mimeType!,
        width: sourceSize.width.round(),
        height: sourceSize.height.round(),
      );
    }
    final target = _boundedImageSize(sourceSize);
    final shouldConvert =
        !_canSendOriginalImageMime(mimeType) ||
        sourceSize.width > _maxImageEdge ||
        sourceSize.height > _maxImageEdge;
    if (shouldConvert) {
      try {
        final compressed = await FlutterImageCompress.compressWithFile(
          file.path,
          minWidth: target.width,
          minHeight: target.height,
          quality: _maxImageQuality,
          format: CompressFormat.jpeg,
        );
        if (compressed != null && compressed.isNotEmpty) {
          return await _jpegImage(
            compressed,
            filename: filename,
            expectedSize: target,
          );
        }
      } catch (_) {
        // A correctly typed original is still safe when it is already bounded.
      }
    }

    if (sourceSize.width > _maxImageEdge || sourceSize.height > _maxImageEdge) {
      throw '图片缩放失败';
    }
    if (mimeType?.startsWith('image/') != true) {
      throw '无法识别图片格式';
    }
    final original = await _readFileBytes(file, '图片');
    return _PreparedImage(
      bytes: original,
      filename: filename,
      mimeType: mimeType!,
      width: sourceSize.width.round(),
      height: sourceSize.height.round(),
    );
  }

  Future<_PreparedImage> _prepareBufferedImage(
    Uint8List original, {
    required String filename,
    required String mimeType,
    bool compress = true,
  }) async {
    final sourceSize = await decodeAttachmentImageSize(original);
    if (!compress || mimeType == 'image/gif' || mimeType == 'image/webp') {
      return _PreparedImage(
        bytes: original,
        filename: filename,
        mimeType: mimeType,
        width: sourceSize?.width.round(),
        height: sourceSize?.height.round(),
      );
    }
    if (sourceSize == null) throw '无法读取图片尺寸';
    final target = _boundedImageSize(sourceSize);
    final shouldConvert =
        !_canSendOriginalImageMime(mimeType) ||
        sourceSize.width > _maxImageEdge ||
        sourceSize.height > _maxImageEdge;
    if (!shouldConvert) {
      return _PreparedImage(
        bytes: original,
        filename: filename,
        mimeType: mimeType,
        width: sourceSize.width.round(),
        height: sourceSize.height.round(),
      );
    }

    try {
      final compressed = await FlutterImageCompress.compressWithList(
        original,
        minWidth: target.width,
        minHeight: target.height,
        quality: _maxImageQuality,
        format: CompressFormat.jpeg,
      );
      if (compressed.isNotEmpty) {
        return await _jpegImage(
          compressed,
          filename: filename,
          expectedSize: target,
        );
      }
    } catch (_) {
      // Preserve a correctly typed original only when it is already bounded.
    }

    if (sourceSize.width > _maxImageEdge || sourceSize.height > _maxImageEdge) {
      throw '图片缩放失败';
    }
    return _PreparedImage(
      bytes: original,
      filename: filename,
      mimeType: mimeType,
      width: sourceSize.width.round(),
      height: sourceSize.height.round(),
    );
  }

  Future<_PreparedImage> _jpegImage(
    Uint8List bytes, {
    required String filename,
    required ({int width, int height}) expectedSize,
  }) async {
    _ensureBufferedSize(bytes.length, '图片');
    final actual = await decodeAttachmentImageSize(bytes);
    final width = actual?.width.round() ?? expectedSize.width;
    final height = actual?.height.round() ?? expectedSize.height;
    if (width > _maxImageEdge || height > _maxImageEdge) {
      throw '图片缩放后仍超过 ${_maxImageEdge}px';
    }
    return _PreparedImage(
      bytes: bytes,
      filename: attachmentFilenameWithExtension(filename, 'jpg'),
      mimeType: 'image/jpeg',
      width: width,
      height: height,
    );
  }

  Future<Uint8List> _readFileBytes(File file, String label) async {
    _ensureBufferedSize(await file.length(), label);
    final bytes = await file.readAsBytes();
    _ensureBufferedSize(bytes.length, label);
    return bytes;
  }

  void _ensureBufferedSize(int length, String label) {
    if (length > _maxBufferedBytes) {
      throw '$label超过 ${_maxBufferedBytes ~/ 1024 ~/ 1024}MB 限制';
    }
  }

  Future<void> _sendPoll(
    String question,
    List<String> answers,
    bool disclosed,
    int maxSelections,
  ) => _runBatch([
    () => rust.sendPoll(
      accountUserId: _accountUserId,
      roomId: widget.roomId,
      question: question,
      answers: answers,
      disclosed: disclosed,
      maxSelections: maxSelections,
    ),
  ], null);

  Future<void> _sendLocation(String body, String geoUri) => _runBatch([
    () => rust.sendLocation(
      accountUserId: _accountUserId,
      roomId: widget.roomId,
      body: body,
      geoUri: geoUri,
    ),
  ], null);

  void _ensureCanSend() {
    if (!mounted) throw StateError('附件发送已取消');
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
    if (_isSending || ops.isEmpty) return;
    setState(() => _isSending = true);
    _mediaDraft.setSending(true);
    final presentation = widget.resolveSendPresentation();
    _batchPresentation = presentation;
    _settledLocalIds.clear();
    _batchInsertedOptimistically = false;
    var sent = 0;
    try {
      for (var i = 0; i < ops.length; i++) {
        if (!mounted) return;
        try {
          await ops[i]();
          sent++;
          if (!mounted && !_previewOpen) return;
          // Prune the head: ops and items advance in lockstep, so after a
          // success the list tail == remaining unsent items. On full success
          // the list is empty; on partial failure the user keeps the unsent
          // remainder, so a retry never re-sends delivered items.
          if (items != null && items.isNotEmpty) {
            items.removeAt(0);
            _mediaDraft.selectionChanged();
          }
          if (mounted) setState(() {});
        } catch (e) {
          if (sent > 0) {
            await _finishBatch(presentation, closePicker: false);
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(sent > 0 ? '已发送 $sent 项; 随后失败: $e' : '发送失败: $e'),
                duration: const Duration(seconds: 2),
              ),
            );
          }
          return;
        }
      }
      await _finishBatch(presentation, closePicker: closePicker);
    } finally {
      // Every exit path funnels through here, so a single flush covers full
      // success, partial failure, and the preview route's detached sends.
      _reconcileSettledLocalMedia();
      if (mounted && _isSending) setState(() => _isSending = false);
      if (mounted || _previewOpen) _mediaDraft.setSending(false);
    }
  }

  /// Best-effort refresh + completion callback. A refresh error is swallowed
  /// (it does not invalidate already-sent messages).
  Future<void> _finishBatch(
    MessageSendPresentation presentation, {
    required bool closePicker,
  }) async {
    try {
      await widget.onRefresh(widget.roomId);
    } catch (_) {
      // Refresh is best-effort; never surface as a send failure.
    }
    if (!mounted) return;
    widget.onMessageSent(presentation, _batchInsertedOptimistically);
    if (closePicker) {
      setState(() => _isSending = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onClose();
      });
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _mediaDraft,
    builder: (context, _) => _buildPanel(context),
  );

  Widget _buildPanel(BuildContext context) {
    final maxHeight = math.max(widget.height, widget.maxHeight);
    final minSize = (widget.height / maxHeight).clamp(0.01, 1.0);
    if (_sheetExtent.value == 0) _sheetExtent.value = minSize;

    return ValueListenableBuilder<double>(
      valueListenable: _sheetExtent,
      builder: (context, extent, _) {
        final visibleHeight = (extent * maxHeight).clamp(
          widget.height,
          maxHeight,
        );
        return SizedBox(
          width: double.infinity,
          height: visibleHeight,
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.bottomCenter,
              minHeight: maxHeight,
              maxHeight: maxHeight,
              child: SizedBox(
                width: double.infinity,
                height: maxHeight,
                child: NotificationListener<DraggableScrollableNotification>(
                  onNotification: (notification) {
                    if ((_sheetExtent.value - notification.extent).abs() >
                        0.0005) {
                      _sheetExtent.value = notification.extent;
                      widget.onHeightChanged(notification.extent * maxHeight);
                    }
                    return false;
                  },
                  child: DraggableScrollableSheet(
                    controller: _sheetController,
                    expand: false,
                    initialChildSize: minSize,
                    minChildSize: minSize,
                    maxChildSize: 1,
                    builder: (context, scrollController) => _buildSheet(
                      context,
                      scrollController,
                      maxHeight: maxHeight,
                      minSize: minSize,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSheet(
    BuildContext context,
    ScrollController scrollController, {
    required double maxHeight,
    required double minSize,
  }) {
    final colors = context.neu;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Container(
        decoration: NeuDecoration(
          colors: colors,
          superellipseEnabled: ChatVisualSettingsScope.of(context)
              .superellipseBorderEnabled,
          radius: NeuRadius.surface,
          intensity: .6,
        ),
        child: Material(
          type: MaterialType.transparency,
          clipBehavior: Clip.antiAlias,
          shape:
              (ChatVisualSettingsScope.maybeOf(context)
                      ?.superellipseBorderEnabled ??
                  true)
              ? RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(NeuRadius.surface),
                )
              : RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(NeuRadius.surface),
                ),
          child: Column(
            children: [
              GestureDetector(
                key: const ValueKey('attachment-panel-drag-handle'),
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: (details) => _dragSheet(
                  details.primaryDelta ?? 0,
                  maxHeight: maxHeight,
                  minSize: minSize,
                ),
                onVerticalDragEnd: (details) => _settleSheet(
                  details.primaryVelocity ?? 0,
                  minSize: minSize,
                ),
                child: SizedBox(
                  height: 32,
                  child: Center(
                    child: Container(
                      width: 34,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colors.textTertiary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
              Divider(height: 1, color: colors.hairline),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: IndexedStack(
                        index: _tab.index,
                        children: [
                          _buildTabBody(AttachmentTab.media, scrollController),
                          const SizedBox.shrink(),
                          _buildTabBody(AttachmentTab.poll, scrollController),
                          _buildTabBody(
                            AttachmentTab.location,
                            scrollController,
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child:
                          _tab == AttachmentTab.media &&
                              _mediaDraft.selected.isNotEmpty
                          ? AttachmentCaptionComposer(
                              draft: _mediaDraft,
                              allowDescription: _mediaDraft.hasImages,
                              onFocus: _expandForCaption,
                              onClear: () {
                                _mediaDraft.selected.clear();
                                _mediaDraft.selectionChanged();
                                FocusManager.instance.primaryFocus?.unfocus();
                              },
                              onSend: () {
                                unawaited(_sendSelectedMedia());
                              },
                            )
                          : _FrostedTabBar(
                              tab: _tab,
                              isFileBusy: _isPickingFiles,
                              onTabChanged: _isSending || _isPickingFiles
                                  ? null
                                  : _selectTab,
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTabBody(
    AttachmentTab tab,
    ScrollController sheetScrollController,
  ) {
    if (!_visitedTabs.contains(tab)) return const SizedBox.shrink();
    final scrollController = _tab == tab ? sheetScrollController : null;
    return switch (tab) {
      AttachmentTab.media =>
        photoManagerSupported
            ? AttachmentGalleryTab(
                draft: _mediaDraft,
                scrollController: scrollController,
                onPreview: _openPreview,
              )
            : AttachmentMediaFallback(
                draft: _mediaDraft,
                scrollController: scrollController,
                onPreview: _openPreview,
              ),
      AttachmentTab.poll => _PollTabBody(
        isSending: _isSending,
        scrollController: scrollController,
        onSendPoll: _sendPoll,
      ),
      AttachmentTab.location => _LocationTabBody(
        isSending: _isSending,
        scrollController: scrollController,
        onSendLocation: _sendLocation,
      ),
      AttachmentTab.file => const SizedBox.shrink(),
    };
  }

  void _selectTab(AttachmentTab tab) {
    if (tab == AttachmentTab.file) {
      unawaited(_pickFiles());
      return;
    }
    setState(() {
      _visitedTabs.add(tab);
      _tab = tab;
    });
  }

  void _dragSheet(
    double delta, {
    required double maxHeight,
    required double minSize,
  }) {
    if (!_sheetController.isAttached) return;
    final target = (_sheetController.size - delta / maxHeight).clamp(
      minSize,
      1.0,
    );
    _sheetController.jumpTo(target);
  }

  Future<void> _settleSheet(double velocity, {required double minSize}) async {
    if (!_sheetController.isAttached) return;
    final target =
        velocity < -300 ||
            (velocity <= 300 &&
                _sheetController.size > minSize + (1 - minSize) / 2)
        ? 1.0
        : minSize;
    await _sheetController.animateTo(
      target,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }
}

// ── Frosted-glass mode bar ────────────────────────────────────────────

class _FrostedTabBar extends StatelessWidget {
  final AttachmentTab tab;
  final bool isFileBusy;
  final ValueChanged<AttachmentTab>? onTabChanged;

  const _FrostedTabBar({
    required this.tab,
    required this.isFileBusy,
    required this.onTabChanged,
  });

  @override
  Widget build(BuildContext context) {
    final items = const [
      _TabItem(AttachmentTab.media, Icons.photo_library_rounded, '图片'),
      _TabItem(AttachmentTab.file, Icons.folder_rounded, '文件'),
      _TabItem(AttachmentTab.poll, Icons.poll_rounded, '投票'),
      _TabItem(AttachmentTab.location, Icons.location_on_rounded, '地址'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: SizedBox(
        key: const ValueKey('attachment-tab-bar'),
        height: _attachmentDockHeight - _attachmentDockGap,
        child: GlassPanel(
          radius: NeuRadius.nav,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (final item in items)
                _TabButton(
                  item: item,
                  selected: tab == item.tab,
                  busy: item.tab == AttachmentTab.file && isFileBusy,
                  onTap: onTabChanged == null
                      ? null
                      : () => onTabChanged!(item.tab),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabItem {
  final AttachmentTab tab;
  final IconData icon;
  final String label;
  const _TabItem(this.tab, this.icon, this.label);
}

class _TabButton extends StatelessWidget {
  final _TabItem item;
  final bool selected;
  final bool busy;
  final VoidCallback? onTap;

  const _TabButton({
    required this.item,
    required this.selected,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final color = selected ? colors.accent : colors.textTertiary;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.accent,
                ),
              )
            else
              Icon(item.icon, color: color, size: 24),
            const SizedBox(height: 2),
            Text(
              item.label,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Media tab: gallery grid + multi-select ───────────────────────────

class _SendBar extends StatelessWidget {
  final String label;
  final bool isSending;
  final bool enabled;
  final VoidCallback onSend;

  const _SendBar({
    required this.label,
    required this.isSending,
    required this.onSend,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final active = enabled && !isSending;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, _attachmentDockClearance),
        child: Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            height: _attachmentSendButtonHeight,
            child: NeuButton(
              key: const ValueKey('attachment-send-button'),
              accent: true,
              radius: NeuRadius.nav,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              onPressed: active ? onSend : null,
              icon: isSending
                  ? SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.onAccent,
                      ),
                    )
                  : const Icon(Icons.send_rounded),
              child: Text(label),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Poll tab ─────────────────────────────────────────────────────────

class _PollTabBody extends StatefulWidget {
  final bool isSending;
  final ScrollController? scrollController;
  final Future<void> Function(
    String question,
    List<String> answers,
    bool disclosed,
    int maxSelections,
  )
  onSendPoll;

  const _PollTabBody({
    required this.isSending,
    required this.scrollController,
    required this.onSendPoll,
  });

  @override
  State<_PollTabBody> createState() => _PollTabBodyState();
}

class _PollTabBodyState extends State<_PollTabBody> {
  final _question = TextEditingController();
  final List<_PollAnswerDraft> _answers = [
    _PollAnswerDraft(0),
    _PollAnswerDraft(1),
  ];
  var _nextAnswerId = 2;
  bool _disclosed = false;
  bool _allowMultiple = false;

  @override
  void dispose() {
    _question.dispose();
    for (final answer in _answers) {
      answer.controller.dispose();
    }
    super.dispose();
  }

  bool get _canSend {
    if (_question.text.trim().isEmpty) return false;
    final valid = _validAnswers.length;
    return valid >= 2;
  }

  List<String> get _validAnswers => _answers
      .where((answer) => answer.visible)
      .map((answer) => answer.controller.text.trim())
      .where((answer) => answer.isNotEmpty)
      .toList();

  int get _visibleAnswerCount =>
      _answers.where((answer) => answer.visible).length;

  void _addAnswer() {
    if (widget.isSending || _visibleAnswerCount >= 20) return;
    final answer = _PollAnswerDraft(_nextAnswerId++, visible: false);
    setState(() => _answers.add(answer));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_answers.contains(answer)) return;
      setState(() => answer.visible = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final answerContext = answer.fieldContext;
        if (!mounted || answerContext == null) return;
        unawaited(
          Scrollable.ensureVisible(
            answerContext,
            alignment: 0.25,
            duration: _pollOptionAnimationDuration,
            curve: Curves.easeOutCubic,
          ),
        );
      });
    });
  }

  void _removeAnswer(_PollAnswerDraft answer) {
    if (widget.isSending || !answer.visible || _visibleAnswerCount <= 2) {
      return;
    }
    setState(() => answer.visible = false);
    Future<void>.delayed(_pollOptionAnimationDuration, () {
      if (!mounted) return;
      setState(() => _answers.remove(answer));
      answer.controller.dispose();
    });
  }

  List<Widget> _buildAnswerRows() {
    var visibleIndex = 0;
    return [
      for (final answer in _answers)
        _buildAnswerRow(answer, answer.visible ? visibleIndex++ : 0),
    ];
  }

  Widget _buildAnswerRow(_PollAnswerDraft answer, int index) {
    return AnimatedSize(
      duration: _pollOptionAnimationDuration,
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: answer.visible
          ? Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Builder(
                builder: (context) {
                  answer.fieldContext = context;
                  return _PollOptionInput(
                    key: ValueKey('poll-option-${answer.id}'),
                    controller: answer.controller,
                    index: index,
                    enabled: !widget.isSending,
                    showRemoveButton: _visibleAnswerCount > 2,
                    onChanged: (_) => setState(() {}),
                    onRemove: () => _removeAnswer(answer),
                  );
                },
              ),
            )
          : const SizedBox.shrink(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    return Stack(
      children: [
        Positioned.fill(
          child: ListView(
            controller: widget.scrollController,
            padding: const EdgeInsets.fromLTRB(
              16,
              16,
              16,
              _attachmentSendBarClearance,
            ),
            children: [
              TextField(
                controller: _question,
                enabled: !widget.isSending,
                style: Theme.of(context).textTheme.bodyLarge,
                decoration: const InputDecoration(labelText: '问题'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              ..._buildAnswerRows(),
              TextButton.icon(
                onPressed: widget.isSending || _visibleAnswerCount >= 20
                    ? null
                    : _addAnswer,
                icon: Icon(Icons.add_rounded, color: colors.accent),
                label: Text('添加选项', style: TextStyle(color: colors.accent)),
              ),
              SwitchListTile(
                title: Text(
                  '公开投票结果',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                value: _disclosed,
                onChanged: widget.isSending
                    ? null
                    : (v) => setState(() => _disclosed = v),
                activeThumbColor: colors.accent,
              ),
              SwitchListTile(
                title: Text(
                  '允许多选',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                value: _allowMultiple,
                onChanged: widget.isSending
                    ? null
                    : (v) => setState(() => _allowMultiple = v),
                activeThumbColor: colors.accent,
              ),
            ],
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _SendBar(
            label: '发送',
            isSending: widget.isSending,
            enabled: _canSend,
            onSend: () {
              final answers = _validAnswers;
              unawaited(
                widget.onSendPoll(
                  _question.text.trim(),
                  answers,
                  _disclosed,
                  _allowMultiple ? answers.length : 1,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PollAnswerDraft {
  final int id;
  final TextEditingController controller = TextEditingController();
  BuildContext? fieldContext;
  bool visible;

  _PollAnswerDraft(this.id, {this.visible = true});
}

class _PollOptionInput extends StatelessWidget {
  final TextEditingController controller;
  final int index;
  final bool enabled;
  final bool showRemoveButton;
  final ValueChanged<String> onChanged;
  final VoidCallback? onRemove;

  const _PollOptionInput({
    super.key,
    required this.controller,
    required this.index,
    required this.enabled,
    required this.showRemoveButton,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: ValueKey('poll-option-input-$index'),
            controller: controller,
            enabled: enabled,
            style: Theme.of(context).textTheme.bodyLarge,
            decoration: InputDecoration(hintText: '选项 ${index + 1}'),
            onChanged: onChanged,
          ),
        ),
        AnimatedContainer(
          duration: _pollOptionAnimationDuration,
          curve: Curves.easeOutCubic,
          width: showRemoveButton ? 44 : 0,
          clipBehavior: Clip.hardEdge,
          decoration: const BoxDecoration(),
          child: showRemoveButton
              ? Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: SizedBox.square(
                    dimension: 40,
                    child: IconButton(
                      tooltip: '删除选项',
                      icon: Icon(
                        Icons.remove_circle_outline_rounded,
                        color: context.neu.textTertiary,
                      ),
                      onPressed: enabled ? onRemove : null,
                      padding: EdgeInsets.zero,
                    ),
                  ),
                )
              : null,
        ),
      ],
    );
  }
}

// ── Location tab ─────────────────────────────────────────────────────

class _LocationTabBody extends StatefulWidget {
  final bool isSending;
  final ScrollController? scrollController;
  final Future<void> Function(String body, String geoUri) onSendLocation;

  const _LocationTabBody({
    required this.isSending,
    required this.scrollController,
    required this.onSendLocation,
  });

  @override
  State<_LocationTabBody> createState() => _LocationTabBodyState();
}

class _LocationTabBodyState extends State<_LocationTabBody> {
  final MapController _mapController = MapController();
  ll.LatLng? _selected;
  bool _locating = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_locate());
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _locate() async {
    setState(() {
      _locating = true;
      _error = null;
    });
    try {
      final point = await currentAttachmentLocation();
      if (!mounted) return;
      setState(() {
        _selected = point;
        _locating = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _mapController.move(point, 16);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _locating = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final selected = _selected;
    if (selected == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            24,
            24,
            24,
            _attachmentDockClearance,
          ),
          child: _locating
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: colors.accent),
                    const SizedBox(height: 12),
                    Text(
                      '正在获取当前位置',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.location_off_rounded,
                      color: colors.textTertiary,
                      size: 36,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _error ?? '无法获取当前位置',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 12),
                    NeuButton(
                      onPressed: widget.isSending ? null : _locate,
                      icon: const Icon(Icons.my_location_rounded),
                      child: const Text('重新定位'),
                    ),
                  ],
                ),
        ),
      );
    }

    final geoUri = canonicalGeoUri(
      selected.latitude.toString(),
      selected.longitude.toString(),
    )!;
    return Stack(
      children: [
        // Keep the sheet controller attached without covering map gestures.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 0,
          child: SingleChildScrollView(
            controller: widget.scrollController,
            primary: false,
            physics: const NeverScrollableScrollPhysics(),
            child: const SizedBox(height: 1),
          ),
        ),
        Positioned.fill(
          child: FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: selected,
              initialZoom: 16,
              maxZoom: 19,
              onTap: (_, point) {
                if (!widget.isSending) setState(() => _selected = point);
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'moe.aks.matter',
              ),
              MarkerLayer(
                markers: [
                  Marker(
                    point: selected,
                    width: 44,
                    height: 44,
                    alignment: Alignment.topCenter,
                    child: Icon(
                      Icons.location_on_rounded,
                      size: 42,
                      color: colors.accent,
                    ),
                  ),
                ],
              ),
              SimpleAttributionWidget(
                alignment: Alignment.topLeft,
                backgroundColor: colors.surfaceStrong.withValues(alpha: 0.82),
                source: const Text(
                  'OpenStreetMap contributors',
                  style: TextStyle(fontSize: 9),
                ),
                onTap: () {
                  unawaited(
                    launchUrl(
                      Uri.parse('https://www.openstreetmap.org/copyright'),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        Positioned(
          top: 10,
          right: 10,
          child: _locating
              ? NeuSurface(
                  depth: NeuDepth.flat,
                  radius: 20,
                  width: 40,
                  height: 40,
                  padding: const EdgeInsets.all(11),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.accent,
                  ),
                )
              : NeuIconButton(
                  tooltip: '回到当前位置',
                  size: 40,
                  onPressed: widget.isSending ? null : _locate,
                  icon: Icons.my_location_rounded,
                ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _SendBar(
            label: '发送',
            isSending: widget.isSending,
            onSend: () => widget.onSendLocation('位置', geoUri),
          ),
        ),
      ],
    );
  }
}

// ── Helpers ──────────────────────────────────────────────────────────

class _PreparedImage {
  final Uint8List bytes;
  final String filename;
  final String mimeType;
  final int? width;
  final int? height;

  const _PreparedImage({
    required this.bytes,
    required this.filename,
    required this.mimeType,
    required this.width,
    required this.height,
  });
}

bool _canSendOriginalImageMime(String? mimeType) => const {
  'image/jpeg',
  'image/jpg',
  'image/png',
  'image/gif',
  'image/webp',
}.contains(mimeType);

({int width, int height}) _boundedImageSize(Size source) {
  if (source.width <= 0 || source.height <= 0) {
    return (
      width: _AttachmentPickerState._maxImageEdge,
      height: _AttachmentPickerState._maxImageEdge,
    );
  }
  final longest = source.width > source.height ? source.width : source.height;
  final scale = longest > _AttachmentPickerState._maxImageEdge
      ? _AttachmentPickerState._maxImageEdge / longest
      : 1.0;
  final width = (source.width * scale).floor();
  final height = (source.height * scale).floor();
  return (width: width > 0 ? width : 1, height: height > 0 ? height : 1);
}

final _decimalCoordinate = RegExp(r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$');

double? _parseCoordinate(String raw, {required double maxAbsolute}) {
  final valueText = raw.trim();
  if (!_decimalCoordinate.hasMatch(valueText)) return null;
  final value = double.tryParse(valueText);
  if (value == null || !value.isFinite || value.abs() > maxAbsolute) {
    return null;
  }
  return value;
}

String _formatCoordinate(double value) {
  if (value == 0) return '0';
  var result = value.toStringAsFixed(12);
  result = result.replaceFirst(RegExp(r'0+$'), '');
  return result.replaceFirst(RegExp(r'\.$'), '');
}

@visibleForTesting
String? canonicalGeoUri(String latitude, String longitude) {
  final lat = _parseCoordinate(latitude, maxAbsolute: 90);
  final lng = _parseCoordinate(longitude, maxAbsolute: 180);
  if (lat == null || lng == null) return null;
  return 'geo:${_formatCoordinate(lat)},${_formatCoordinate(lng)}';
}

@visibleForTesting
Future<ll.LatLng> currentAttachmentLocation() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw const _AttachmentLocationException('请先开启系统定位服务');
  }

  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied) {
    throw const _AttachmentLocationException('未获得定位权限');
  }
  if (permission == LocationPermission.deniedForever) {
    throw const _AttachmentLocationException('定位权限已被永久拒绝，请在系统设置中开启');
  }

  final position = await Geolocator.getCurrentPosition(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      timeLimit: Duration(seconds: 12),
    ),
  );
  return ll.LatLng(position.latitude, position.longitude);
}

class _AttachmentLocationException implements Exception {
  final String message;

  const _AttachmentLocationException(this.message);

  @override
  String toString() => message;
}
