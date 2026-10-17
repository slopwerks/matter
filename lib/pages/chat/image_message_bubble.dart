import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/matrix_html/matrix_html_renderer.dart';
import '../../features/matrix_html/matrix_link_router.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/chat_visual_settings_provider.dart';
import '../../providers/image_view_history.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/neu_colors.dart';
import 'image_loading_policy.dart';
import 'image_media.dart';
import 'image_placeholders.dart';
import 'image_viewer.dart';
import 'message_group.dart' show enabledNeuBubbleShadows;
import 'message_text.dart';
import 'send_flight.dart';

const _minimumImageBubbleHeight = 72.0;

class ImageMessageBubble extends ConsumerStatefulWidget {
  final String? imageUrl;
  final String? mediaSourceJson;
  final int? imageWidth;
  final int? imageHeight;
  final int? fileSize;
  final String? mimeType;
  final String? filename;
  final rust.ChatMessage? message;

  /// Bytes of a picked-but-not-yet-uploaded image, rendered instead of
  /// resolving [imageUrl]. Set only on optimistic local outgoing rows.
  final Uint8List? previewBytes;
  final String? roomId;
  final Iterable<rust.ChatMessage> galleryMessages;
  final ImageHistoryLoader? loadOlderImages;
  final ValueChanged<String>? onMessageJumpRequested;
  final ValueChanged<rust.ChatMessage>? onMessageReplyRequested;
  final ValueChanged<rust.ChatRoom>? onMessageForwarded;
  final String? caption;
  final String? captionFormattedBody;
  final Map<String, String> mentionDisplayNames;
  final List<String> mentionedUserIds;
  final MessageMentionTapHandler? onMentionTap;
  final bool isMe;
  final Object heroTag;
  final bool isSticker;
  final Widget metadata;
  final BorderRadius? borderRadius;
  final VoidCallback? onLoaded;
  final Size? displaySize;
  final bool showCaption;

  const ImageMessageBubble({
    super.key,
    this.imageUrl,
    this.mediaSourceJson,
    this.imageWidth,
    this.imageHeight,
    this.fileSize,
    this.mimeType,
    this.filename,
    this.message,
    this.previewBytes,
    this.roomId,
    this.galleryMessages = const [],
    this.loadOlderImages,
    this.onMessageJumpRequested,
    this.onMessageReplyRequested,
    this.onMessageForwarded,
    this.caption,
    this.captionFormattedBody,
    this.mentionDisplayNames = const {},
    this.mentionedUserIds = const [],
    this.onMentionTap,
    required this.isMe,
    required this.heroTag,
    this.isSticker = false,
    required this.metadata,
    this.borderRadius,
    this.onLoaded,
    this.displaySize,
    this.showCaption = true,
  });

  @override
  ConsumerState<ImageMessageBubble> createState() => _ImageMessageBubbleState();
}

class _ImageMessageBubbleState extends ConsumerState<ImageMessageBubble> {
  String? _resolvedUrl;
  Uint8List? _decryptedBytes;
  bool _isLoadingEncrypted = false;
  bool _encryptedLoadFailed = false;
  bool _resolveFailed = false;
  int? _thumbnailWidth;
  int? _thumbnailHeight;
  int _resolveGeneration = 0;
  bool _spoilerRevealed = false;

  /// Preview bytes kept after the server echo replaced the optimistic row.
  ///
  /// When the echo arrives, [ImageMessageBubble.previewBytes] goes away before
  /// the real `mxc://` thumbnail has been fetched, which used to drop the
  /// bubble back to its blurhash/loading placeholder for a frame — the visible
  /// flash between "my local picture" and "the server's copy". Holding the
  /// picked bytes here keeps them painted underneath until the network image
  /// actually has a frame, then they are released.
  Uint8List? _stickyPreviewBytes;

  /// Whether the resolved/decrypted server image has produced a frame yet.
  bool _serverImageReady = false;

  bool get _spoilerHidden =>
      widget.message?.imageMetadata?.spoiler == true && !_spoilerRevealed;

  void _revealSpoiler() {
    setState(() => _spoilerRevealed = true);
    final room = widget.roomId;
    final id = widget.message?.id;
    if (room != null && id != null) {
      ref
          .read(
            imageViewHistoryProvider((
              account: ref.read(activeUserIdProvider) ?? 'anonymous',
              room: room,
            )).notifier,
          )
          .viewed(id);
    }
    _resolveUrl();
  }

  void _handleMediaLoaded() {
    if (!mounted) return;
    // The server copy is on screen: the local preview underneath is now dead
    // weight, so release it instead of holding a full image buffer alive. The
    // rebuild is what drops the handover Stack back to a single image.
    if (_stickyPreviewBytes != null || !_serverImageReady) {
      setState(() {
        _stickyPreviewBytes = null;
        _serverImageReady = true;
      });
    }
    widget.onLoaded?.call();
    notifySendFlightTargetReady(context);
  }

  void _handleMediaError() {
    if (mounted) notifySendFlightTargetReady(context);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final bubbleSize = _bubbleSize(context);
    final nextWidth = (bubbleSize.width * pixelRatio).round();
    final nextHeight = (bubbleSize.height * pixelRatio).round();
    final cachedUrl = widget.isSticker
        ? null
        : cachedOriginalMxcUrl(ref, widget.imageUrl);
    if (cachedUrl != null) _resolvedUrl = cachedUrl;
    if (_thumbnailWidth != nextWidth ||
        _thumbnailHeight != nextHeight ||
        _resolvedUrl == null) {
      _thumbnailWidth = nextWidth;
      _thumbnailHeight = nextHeight;
      _resolveUrl();
    }
  }

  @override
  void didUpdateWidget(covariant ImageMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.imageUrl != oldWidget.imageUrl ||
        widget.mediaSourceJson != oldWidget.mediaSourceJson ||
        (widget.previewBytes == null) != (oldWidget.previewBytes == null)) {
      _resolveGeneration++;
      _spoilerRevealed = false;
      _resolvedUrl = null;
      _decryptedBytes = null;
      _isLoadingEncrypted = false;
      _encryptedLoadFailed = false;
      _resolveFailed = false;
    }
    // Local row handed over to its server echo: keep painting the picked bytes
    // until the network copy has a frame, so the swap is invisible.
    final wasLocalPreview = oldWidget.previewBytes != null;
    if (wasLocalPreview && widget.previewBytes == null) {
      _stickyPreviewBytes = oldWidget.previewBytes;
      _serverImageReady = false;
    } else if (widget.previewBytes != null) {
      _stickyPreviewBytes = null;
      _serverImageReady = false;
    }
    if (widget.imageUrl != oldWidget.imageUrl ||
        widget.imageWidth != oldWidget.imageWidth ||
        widget.imageHeight != oldWidget.imageHeight ||
        widget.mediaSourceJson != oldWidget.mediaSourceJson ||
        widget.displaySize != oldWidget.displaySize ||
        widget.fileSize != oldWidget.fileSize ||
        widget.mimeType != oldWidget.mimeType ||
        widget.filename != oldWidget.filename ||
        (_resolvedUrl == null && _decryptedBytes == null)) {
      _resolveUrl();
    }
  }

  Future<void> _resolveUrl() async {
    if (_spoilerHidden) return;
    // An optimistic image already has its pixels: there is no `mxc://` source
    // to resolve until the upload produces one.
    if (widget.previewBytes != null) return;
    if (widget.imageUrl == null && _isLoadingEncrypted) return;
    final generation = ++_resolveGeneration;
    _resolveFailed = false;
    final account = ref.read(activeUserIdProvider);
    bool isCurrent() =>
        mounted &&
        generation == _resolveGeneration &&
        ref.read(activeUserIdProvider) == account;
    final imageUrl = widget.imageUrl;
    if (imageUrl == null) {
      final mediaSourceJson = widget.mediaSourceJson;
      if (mediaSourceJson == null) return;
      _isLoadingEncrypted = true;
      _encryptedLoadFailed = false;
      try {
        final bytes = await rust.downloadMediaSourceBytes(
          mediaSourceJson: mediaSourceJson,
          maxSizeBytes: 16 * 1024 * 1024,
        );
        if (isCurrent()) {
          setState(() => _decryptedBytes = Uint8List.fromList(bytes));
          widget.onLoaded?.call();
        }
      } catch (_) {
        if (isCurrent()) setState(() => _encryptedLoadFailed = true);
      } finally {
        if (generation == _resolveGeneration) _isLoadingEncrypted = false;
      }
    } else if (imageUrl.startsWith('mxc://')) {
      final url = _shouldUseOriginal
          ? await resolveMxcUrlFull(ref, imageUrl)
          : await resolveMxcUrl(
              ref,
              imageUrl,
              width: _thumbnailWidth,
              height: _thumbnailHeight,
              useOriginalIfCached: !widget.isSticker,
            );
      if (isCurrent()) {
        setState(() {
          _resolvedUrl = url;
          _resolveFailed = url == null;
        });
        if (url != null) widget.onLoaded?.call();
      }
    } else {
      _resolvedUrl = imageUrl;
      widget.onLoaded?.call();
    }
  }

  /// Builds the bubble's picture.
  ///
  /// Usually this is a single image, but during the optimistic-to-server
  /// handover both sources exist for a moment: the picked bytes are still the
  /// only thing with pixels, while the server copy has not been fetched yet.
  /// In that window the preview is painted as the base layer and the server
  /// image is stacked on top, so the two never trade places through an empty
  /// placeholder.
  Widget _buildMedia(
    BuildContext context, {
    required String? url,
    required Uint8List? bytes,
    required Uint8List? previewBytes,
    required Uint8List? serverBytes,
    required bool needsShortImageBackdrop,
    required int? cacheWidth,
    required int? cacheHeight,
  }) {
    final fit =
        widget.isSticker ||
            needsShortImageBackdrop ||
            (widget.displaySize == null &&
                context.isMaterial &&
                _fittedBubbleSize(context).height < _minimumImageBubbleHeight)
        ? BoxFit.contain
        : BoxFit.cover;
    Widget image({
      required String? imageUrl,
      required Uint8List? imageBytes,
      required Key key,
      VoidCallback? onLoaded,
      Widget? placeholder,
    }) => ChatMediaImage(
      key: key,
      imageUrl: imageUrl,
      imageBytes: imageBytes,
      blurhash: widget.message?.imageMetadata?.blurhash,
      fit: fit,
      onLoaded: onLoaded,
      onError: _handleMediaError,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
      placeholder: placeholder,
    );

    final serverSource = serverBytes != null || url != null;
    // Handover: keep the local picture underneath until the server one paints.
    // The server layer must not draw its own blurhash/spinner over it, hence
    // the empty placeholder — otherwise the placeholder itself is the flash.
    if (previewBytes != null && !_serverImageReady && serverSource) {
      return Stack(
        fit: StackFit.expand,
        children: [
          image(
            imageUrl: null,
            imageBytes: previewBytes,
            key: const ValueKey('msg-image-preview'),
          ),
          image(
            imageUrl: url,
            imageBytes: serverBytes,
            key: const ValueKey('msg-image-server'),
            onLoaded: _handleMediaLoaded,
            placeholder: const SizedBox.shrink(),
          ),
        ],
      );
    }
    return image(
      imageUrl: url,
      imageBytes: bytes,
      key: ValueKey('msg-image:${widget.heroTag}'),
      onLoaded: _handleMediaLoaded,
    );
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(activeUserIdProvider) ?? 'anonymous';
    if (widget.roomId != null && widget.message != null) {
      final viewed = ref.watch(
        imageViewHistoryProvider((account: account, room: widget.roomId!)),
      );
      if (_spoilerHidden && viewed.contains(widget.message!.id)) {
        _spoilerRevealed = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _resolveUrl();
        });
      }
    }
    final originalUrl = ref.watch(
      mxcUrlCacheProvider.select(
        (cache) => widget.isSticker
            ? null
            : cache['$account::${widget.imageUrl}|original'],
      ),
    );
    final colors = context.neu;
    final url = originalUrl ?? _resolvedUrl;
    final serverBytes = _decryptedBytes;
    final previewBytes = widget.previewBytes ?? _stickyPreviewBytes;
    final bytes = previewBytes ?? serverBytes;
    final bubbleSize = _bubbleSize(context);
    final caption = widget.caption?.trim();
    final hasCaption =
        widget.showCaption &&
        !widget.isSticker &&
        caption != null &&
        caption.isNotEmpty;
    final mediaBorderRadius = hasCaption
        ? BorderRadius.zero
        : _bubbleBorderRadius;
    final needsShortImageBackdrop = _needsShortImageBackdrop(context);
    // Keep original files intact in the disk cache, especially animated GIFs.
    final cacheWidth = originalUrl == null ? _thumbnailWidth : null;
    final cacheHeight = originalUrl == null ? _thumbnailHeight : null;

    if (_spoilerHidden) {
      return _withCaption(
        Container(
          width: bubbleSize.width,
          height: bubbleSize.height,
          decoration: BoxDecoration(borderRadius: mediaBorderRadius),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Positioned.fill(
                child: SpoilerImageCover(
                  hash: widget.message?.imageMetadata?.blurhash,
                  reason: widget.message?.imageMetadata?.spoilerReason,
                  color: colors.card,
                  onReveal: _revealSpoiler,
                ),
              ),
              widget.metadata,
            ],
          ),
        ),
        caption,
        hasCaption,
      );
    }

    if (url == null && bytes == null) {
      final placeholder =
          (!_resolveFailed &&
                  !_encryptedLoadFailed &&
                  widget.message?.imageMetadata?.blurhash != null) ||
              (_isLoadingEncrypted && !_encryptedLoadFailed)
          ? _buildLoading(context, bubbleSize)
          : _buildBroken(context, bubbleSize);
      return _withCaption(
        Stack(children: [placeholder, widget.metadata]),
        caption,
        hasCaption,
      );
    }

    final media = _buildMedia(
      context,
      url: url,
      bytes: bytes,
      previewBytes: previewBytes,
      serverBytes: serverBytes,
      needsShortImageBackdrop: needsShortImageBackdrop,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
    );
    final bubble = Container(
      width: bubbleSize.width,
      height: bubbleSize.height,
      decoration: BoxDecoration(
        color: widget.isSticker
            ? Colors.transparent
            : isMe
            ? colors.accent.withValues(alpha: 0.3)
            : colors.card,
        borderRadius: mediaBorderRadius,
        boxShadow: widget.displaySize != null || widget.isSticker || hasCaption
            ? null
            : enabledNeuBubbleShadows(context, colors),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        alignment: Alignment.bottomRight,
        children: [
          if (needsShortImageBackdrop)
            Positioned.fill(
              child: ImageFiltered(
                key: ValueKey('image-blurred-background:${widget.heroTag}'),
                imageFilter: ImageFilter.blur(
                  sigmaX:
                      ChatVisualSettingsScope.of(context)
                          .imageBlurOptimizationEnabled
                      ? 8
                      : 14,
                  sigmaY:
                      ChatVisualSettingsScope.of(context)
                          .imageBlurOptimizationEnabled
                      ? 8
                      : 14,
                ),
                child: Transform.scale(
                  scale: 1.12,
                  child: ChatMediaImage(
                    imageUrl: url,
                    imageBytes: bytes,
                    fit: BoxFit.cover,
                    cacheWidth: cacheWidth,
                    cacheHeight: cacheHeight,
                  ),
                ),
              ),
            ),
          if (needsShortImageBackdrop)
            Positioned.fill(
              child: ColoredBox(color: Colors.black.withValues(alpha: 0.12)),
            ),
          Positioned.fill(
            child: widget.isSticker
                ? RepaintBoundary(child: media)
                : Hero(
                    tag: widget.heroTag,
                    createRectTween: (begin, end) =>
                        RectTween(begin: begin, end: end),
                    flightShuttleBuilder: roundedImageFlightShuttle,
                    child: HeroImageClip(
                      borderRadius: mediaBorderRadius,
                      child: RepaintBoundary(child: media),
                    ),
                  ),
          ),
          widget.metadata,
        ],
      ),
    );

    if (widget.isSticker) return RepaintBoundary(child: bubble);
    return GestureDetector(
      onTap: () => Navigator.of(context, rootNavigator: true).push(
        PageRouteBuilder(
          opaque: false,
          transitionDuration: const Duration(milliseconds: 320),
          reverseTransitionDuration: const Duration(milliseconds: 280),
          pageBuilder: (_, animation, _) => ChatImageViewer(
            initialSource: ImageViewerSource(
              heroTag: widget.heroTag,
              message: widget.message,
              imageUrl: widget.imageUrl,
              mediaSourceJson: widget.mediaSourceJson,
              previewUrl: url,
              imageBytes: bytes,
              width: widget.imageWidth,
              height: widget.imageHeight,
              fileSize: widget.fileSize,
              mimeType: widget.mimeType,
              filename: widget.filename,
              caption: widget.caption,
              roomId: widget.roomId,
              spoilerRevealed: _spoilerRevealed,
            ),
            messages: widget.galleryMessages,
            roomId: widget.roomId,
            animation: animation,
            onMessageJumpRequested: widget.onMessageJumpRequested,
            onMessageReplyRequested: widget.onMessageReplyRequested,
            onMessageForwarded: widget.onMessageForwarded,
            loadOlderImages: widget.loadOlderImages,
          ),
        ),
      ),
      child: _withCaption(bubble, caption, hasCaption),
    );
  }

  Widget _withCaption(Widget bubble, String? caption, bool hasCaption) {
    if (!hasCaption || caption == null) return bubble;
    final colors = context.neu;
    return Container(
      key: const ValueKey('image-caption-bubble'),
      width: _bubbleSize(context).width,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: widget.isMe ? colors.accent : colors.card,
        borderRadius: _bubbleBorderRadius,
        boxShadow: enabledNeuBubbleShadows(context, colors),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          bubble,
          ImageMessageCaption(
            text: caption,
            formattedBody: widget.captionFormattedBody,
            isMe: widget.isMe,
            mentionDisplayNames: widget.mentionDisplayNames,
            mentionedUserIds: widget.mentionedUserIds,
            onMentionTap: widget.onMentionTap,
          ),
        ],
      ),
    );
  }

  bool get isMe => widget.isMe;

  BorderRadius get _bubbleBorderRadius =>
      widget.borderRadius ??
      BorderRadius.only(
        topLeft: const Radius.circular(NeuRadius.content),
        topRight: const Radius.circular(NeuRadius.content),
        bottomLeft: Radius.circular(
          widget.isMe ? NeuRadius.content : NeuRadius.tag,
        ),
        bottomRight: Radius.circular(
          widget.isMe ? NeuRadius.tag : NeuRadius.content,
        ),
      );

  double get _imageAspectRatio {
    final width = widget.imageWidth;
    final height = widget.imageHeight;
    return width != null && height != null && width > 0 && height > 0
        ? width / height
        : 1;
  }

  bool get _shouldUseOriginal =>
      !widget.isSticker &&
      (shouldAutoLoadOriginal(
            fileSize: widget.fileSize,
            mimeType: widget.mimeType,
            filename: widget.filename,
          ) ||
          cachedOriginalMxcUrl(ref, widget.imageUrl) != null);

  Size _bubbleSize(BuildContext context) {
    if (widget.displaySize != null) return widget.displaySize!;
    final fittedSize = _fittedBubbleSize(context);
    if (widget.isSticker || fittedSize.height >= _minimumImageBubbleHeight) {
      return fittedSize;
    }
    return Size(fittedSize.width, _minimumImageBubbleHeight);
  }

  bool _needsShortImageBackdrop(BuildContext context) =>
      widget.displaySize == null &&
      !widget.isSticker &&
      ChatVisualSettingsScope.of(context).shortImageBlurredBackdropEnabled &&
      _fittedBubbleSize(context).height < _minimumImageBubbleHeight;

  Size _fittedBubbleSize(BuildContext context) {
    if (widget.displaySize != null) return widget.displaySize!;
    final maxHeight = widget.isSticker ? 160.0 : 280.0;
    final maxWidth = widget.isSticker
        ? 160.0
        : (MediaQuery.sizeOf(context).width * 0.65)
              .clamp(0.0, 480.0)
              .toDouble();
    final aspectRatio = _imageAspectRatio;
    var width = maxWidth;
    var height = width / aspectRatio;
    if (height > maxHeight) {
      height = maxHeight;
      width = height * aspectRatio;
    }
    return Size(width, height);
  }

  Widget _buildBroken(BuildContext context, Size bubbleSize) {
    final colors = context.neu;
    return Container(
      width: bubbleSize.width,
      height: bubbleSize.height,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isMe ? colors.accent.withValues(alpha: 0.3) : colors.card,
        borderRadius: _bubbleBorderRadius,
        boxShadow: widget.displaySize == null
            ? enabledNeuBubbleShadows(context, colors)
            : null,
      ),
      child: Center(
        child: Icon(
          Icons.broken_image_rounded,
          color: colors.textTertiary,
          size: 32,
        ),
      ),
    );
  }

  Widget _buildLoading(BuildContext context, Size bubbleSize) {
    return Container(
      width: bubbleSize.width,
      height: bubbleSize.height,
      decoration: BoxDecoration(
        color: context.neu.card,
        borderRadius: _bubbleBorderRadius,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          BlurhashPlaceholder(
            hash: widget.message?.imageMetadata?.blurhash,
            color: context.neu.card,
          ),
          if (widget.message?.imageMetadata?.blurhash == null)
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ],
      ),
    );
  }
}

class ImageMessageCaption extends StatelessWidget {
  final String text;
  final String? formattedBody;
  final bool isMe;
  final Map<String, String> mentionDisplayNames;
  final List<String> mentionedUserIds;
  final MessageMentionTapHandler? onMentionTap;

  const ImageMessageCaption({
    super.key,
    required this.text,
    required this.formattedBody,
    required this.isMe,
    required this.mentionDisplayNames,
    required this.mentionedUserIds,
    required this.onMentionTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final accent = isMe ? colors.onAccent : colors.accent;
    final style = Theme.of(context).textTheme.bodyMedium!
        .copyWith(color: isMe ? colors.onAccent : colors.text, height: 1.35);
    return Container(
      key: const ValueKey('image-caption'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: formattedBody?.isNotEmpty == true
          ? MatrixHtmlMessage(
              html: formattedBody!,
              style: style,
              accentColor: accent,
              mentionDisplayNames: mentionDisplayNames,
              onMentionTap: onMentionTap,
            )
          : MessageText(
              text,
              style: style,
              mentionColor: accent,
              linkColor: accent,
              onUrlTap: const MatrixLinkRouter().open,
              mentionDisplayNames: mentionDisplayNames,
              mentionedUserIds: mentionedUserIds,
              onMentionTap: onMentionTap,
            ),
    );
  }
}
