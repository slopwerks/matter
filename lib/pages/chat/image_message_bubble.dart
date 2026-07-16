import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/matrix_html/matrix_html_renderer.dart';
import '../../features/matrix_html/matrix_link_router.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/app_theme.dart';
import '../../widgets/app_avatar.dart';
import 'message_text.dart';

enum _OriginalImageState { thumbnail, resolving, loading, loaded, failed }

const _minimumImageBubbleHeight = 72.0;

class ImageMessageBubble extends ConsumerStatefulWidget {
  final String? imageUrl;
  final String? mediaSourceJson;
  final int? imageWidth;
  final int? imageHeight;
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

  const ImageMessageBubble({
    super.key,
    this.imageUrl,
    this.mediaSourceJson,
    this.imageWidth,
    this.imageHeight,
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
  });

  @override
  ConsumerState<ImageMessageBubble> createState() => _ImageMessageBubbleState();
}

class _ImageMessageBubbleState extends ConsumerState<ImageMessageBubble> {
  String? _resolvedUrl;
  Uint8List? _decryptedBytes;
  bool _isLoadingEncrypted = false;
  bool _encryptedLoadFailed = false;
  String? _originalMxcUrl;
  int? _thumbnailWidth;
  int? _thumbnailHeight;

  @override
  void initState() {
    super.initState();
    _originalMxcUrl = widget.imageUrl?.startsWith('mxc://') == true
        ? widget.imageUrl
        : null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final bubbleSize = _bubbleSize(context);
    final nextWidth = (bubbleSize.width * pixelRatio).round();
    final nextHeight = (bubbleSize.height * pixelRatio).round();
    final useOriginalCache = _shouldUseOriginalCache;
    final cachedUrl = widget.imageUrl == null
        ? null
        : cachedResolvedMxcUrl(
            ref,
            widget.imageUrl,
            width: useOriginalCache ? null : nextWidth,
            height: useOriginalCache ? null : nextHeight,
          );
    if (cachedUrl != null && _resolvedUrl != cachedUrl) {
      _resolvedUrl = cachedUrl;
    }
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
        widget.imageWidth != oldWidget.imageWidth ||
        widget.imageHeight != oldWidget.imageHeight ||
        widget.mediaSourceJson != oldWidget.mediaSourceJson ||
        (_resolvedUrl == null && _decryptedBytes == null)) {
      _resolveUrl();
    }
  }

  Future<void> _resolveUrl() async {
    final imageUrl = widget.imageUrl;
    if (imageUrl == null) {
      final mediaSourceJson = widget.mediaSourceJson;
      if (mediaSourceJson == null || _isLoadingEncrypted) return;
      _isLoadingEncrypted = true;
      _encryptedLoadFailed = false;
      try {
        final bytes = await rust.downloadMediaSourceBytes(
          mediaSourceJson: mediaSourceJson,
          maxSizeBytes: 16 * 1024 * 1024,
        );
        if (mounted) {
          setState(() => _decryptedBytes = Uint8List.fromList(bytes));
          widget.onLoaded?.call();
        }
      } catch (_) {
        if (mounted) setState(() => _encryptedLoadFailed = true);
      } finally {
        _isLoadingEncrypted = false;
      }
    } else if (imageUrl.startsWith('mxc://')) {
      final useOriginalCache = _shouldUseOriginalCache;
      final url = await resolveMxcUrl(
        ref,
        imageUrl,
        width: useOriginalCache ? null : _thumbnailWidth,
        height: useOriginalCache ? null : _thumbnailHeight,
      );
      if (mounted && url != null) {
        setState(() => _resolvedUrl = url);
        widget.onLoaded?.call();
      }
    } else {
      if (mounted) {
        setState(() => _resolvedUrl = imageUrl);
      } else {
        _resolvedUrl = imageUrl;
      }
      widget.onLoaded?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = _resolvedUrl;
    final bytes = _decryptedBytes;
    final bubbleSize = _bubbleSize(context);
    final caption = widget.caption?.trim();
    final hasCaption =
        !widget.isSticker && caption != null && caption.isNotEmpty;
    final mediaBorderRadius = hasCaption
        ? BorderRadius.zero
        : _bubbleBorderRadius;
    final needsShortImageBackdrop = _needsShortImageBackdrop(context);

    if (url == null && bytes == null) {
      final placeholder = _isLoadingEncrypted && !_encryptedLoadFailed
          ? _buildLoading(context, bubbleSize)
          : _buildBroken(context, bubbleSize);
      return _withCaption(
        Stack(children: [placeholder, widget.metadata]),
        caption,
        hasCaption,
      );
    }

    final media = _MediaImage(
      key: ValueKey('msg-image:${widget.heroTag}'),
      imageUrl: url,
      imageBytes: bytes,
      fit: widget.isSticker || needsShortImageBackdrop
          ? BoxFit.contain
          : BoxFit.cover,
      onLoaded: widget.onLoaded,
      cacheWidth: _thumbnailWidth,
      cacheHeight: _thumbnailHeight,
    );
    final bubble = Container(
      width: bubbleSize.width,
      height: bubbleSize.height,
      decoration: BoxDecoration(
        color: widget.isSticker
            ? Colors.transparent
            : isMe
            ? AppColors.primary.withValues(alpha: 0.3)
            : AppColors.surfaceElevated,
        borderRadius: mediaBorderRadius,
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        alignment: Alignment.bottomRight,
        children: [
          if (needsShortImageBackdrop)
            Positioned.fill(
              child: ImageFiltered(
                key: ValueKey('image-blurred-background:${widget.heroTag}'),
                imageFilter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                child: Transform.scale(
                  scale: 1.12,
                  child: _MediaImage(
                    imageUrl: url,
                    imageBytes: bytes,
                    fit: BoxFit.cover,
                    cacheWidth: _thumbnailWidth,
                    cacheHeight: _thumbnailHeight,
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
                    flightShuttleBuilder: _roundedImageFlightShuttle,
                    child: _HeroImageClip(
                      borderRadius: mediaBorderRadius,
                      child: media,
                    ),
                  ),
          ),
          widget.metadata,
        ],
      ),
    );

    if (widget.isSticker) {
      return RepaintBoundary(child: bubble);
    }

    return GestureDetector(
      onTap: () {
        Navigator.of(context, rootNavigator: true).push(
          PageRouteBuilder(
            opaque: false,
            transitionDuration: const Duration(milliseconds: 320),
            reverseTransitionDuration: const Duration(milliseconds: 280),
            pageBuilder: (_, animation, _) => _BubbleExpandingPreview(
              heroTag: widget.heroTag,
              imageUrl: url,
              imageBytes: bytes,
              originalMxcUrl: _originalMxcUrl,
              imageAspectRatio: _imageAspectRatio,
              animation: animation,
            ),
          ),
        );
      },
      child: _withCaption(bubble, caption, hasCaption),
    );
  }

  Widget _withCaption(Widget bubble, String? caption, bool hasCaption) {
    if (!hasCaption || caption == null) return bubble;
    return Container(
      key: const ValueKey('image-caption-bubble'),
      width: _bubbleSize(context).width,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: widget.isMe ? AppColors.primary : AppColors.surfaceElevated,
        borderRadius: _bubbleBorderRadius,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          bubble,
          _ImageCaption(
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
        topLeft: const Radius.circular(AppRadii.content),
        topRight: const Radius.circular(AppRadii.content),
        bottomLeft: Radius.circular(
          widget.isMe ? AppRadii.content : AppRadii.tag,
        ),
        bottomRight: Radius.circular(
          widget.isMe ? AppRadii.tag : AppRadii.content,
        ),
      );

  double get _imageAspectRatio {
    final sourceWidth = widget.imageWidth;
    final sourceHeight = widget.imageHeight;
    if (sourceWidth != null &&
        sourceHeight != null &&
        sourceWidth > 0 &&
        sourceHeight > 0) {
      return sourceWidth / sourceHeight;
    }
    return 1.0;
  }

  bool get _shouldUseOriginalCache {
    if (widget.isSticker) return false;
    final width = widget.imageWidth;
    final height = widget.imageHeight;
    return width != null &&
        height != null &&
        width > 0 &&
        height > 0 &&
        width <= 512 &&
        height <= 512;
  }

  Size _bubbleSize(BuildContext context) {
    final fittedSize = _fittedBubbleSize(context);
    if (widget.isSticker || fittedSize.height >= _minimumImageBubbleHeight) {
      return fittedSize;
    }
    return Size(fittedSize.width, _minimumImageBubbleHeight);
  }

  bool _needsShortImageBackdrop(BuildContext context) =>
      !widget.isSticker &&
      _fittedBubbleSize(context).height < _minimumImageBubbleHeight;

  Size _fittedBubbleSize(BuildContext context) {
    final maxHeight = widget.isSticker ? 160.0 : 280.0;
    final maxWidth = widget.isSticker
        ? 160.0
        : MediaQuery.sizeOf(context).width * 0.65;
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
    return Container(
      width: bubbleSize.width,
      height: bubbleSize.height,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isMe
            ? AppColors.primary.withValues(alpha: 0.3)
            : AppColors.surfaceElevated,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(AppRadii.content),
          topRight: const Radius.circular(AppRadii.content),
          bottomLeft: Radius.circular(isMe ? AppRadii.content : AppRadii.tag),
          bottomRight: Radius.circular(isMe ? AppRadii.tag : AppRadii.content),
        ),
      ),
      child: const Center(
        child: Icon(
          Icons.broken_image_rounded,
          color: AppColors.onSurfaceVariant,
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
        color: AppColors.surfaceElevated,
        borderRadius: _bubbleBorderRadius,
      ),
      child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
    );
  }
}

class _ImageCaption extends StatelessWidget {
  final String text;
  final String? formattedBody;
  final bool isMe;
  final Map<String, String> mentionDisplayNames;
  final List<String> mentionedUserIds;
  final MessageMentionTapHandler? onMentionTap;

  const _ImageCaption({
    required this.text,
    required this.formattedBody,
    required this.isMe,
    required this.mentionDisplayNames,
    required this.mentionedUserIds,
    required this.onMentionTap,
  });

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: isMe ? Colors.white : AppColors.onBackground,
      fontSize: 14,
      height: 1.35,
    );
    return Container(
      key: const ValueKey('image-caption'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: formattedBody?.isNotEmpty == true
          ? MatrixHtmlMessage(
              html: formattedBody!,
              style: style,
              accentColor: isMe ? Colors.white : AppColors.secondary,
              mentionDisplayNames: mentionDisplayNames,
              onMentionTap: onMentionTap,
            )
          : MessageText(
              text,
              style: style,
              mentionColor: isMe ? Colors.white : AppColors.secondary,
              linkColor: isMe ? Colors.white : AppColors.secondary,
              onUrlTap: const MatrixLinkRouter().open,
              mentionDisplayNames: mentionDisplayNames,
              mentionedUserIds: mentionedUserIds,
              onMentionTap: onMentionTap,
            ),
    );
  }
}

/// Full-screen image preview that expands from the bubble's on-screen position.
class _BubbleExpandingPreview extends ConsumerStatefulWidget {
  final Object heroTag;
  final String? imageUrl;
  final Uint8List? imageBytes;
  final String? originalMxcUrl;
  final double imageAspectRatio;
  final Animation<double> animation;

  const _BubbleExpandingPreview({
    required this.heroTag,
    required this.imageUrl,
    required this.imageBytes,
    required this.originalMxcUrl,
    required this.imageAspectRatio,
    required this.animation,
  });

  @override
  ConsumerState<_BubbleExpandingPreview> createState() =>
      _BubbleExpandingPreviewState();
}

class _BubbleExpandingPreviewState
    extends ConsumerState<_BubbleExpandingPreview> {
  String? _fullUrl;
  _OriginalImageState _originalState = _OriginalImageState.thumbnail;

  void _close() => Navigator.of(context).pop();

  Future<void> _loadFull() async {
    if (_originalState == _OriginalImageState.resolving ||
        _originalState == _OriginalImageState.loading ||
        _originalState == _OriginalImageState.loaded) {
      return;
    }

    setState(() => _originalState = _OriginalImageState.resolving);

    final fullUrl = widget.originalMxcUrl != null
        ? await resolveMxcUrlFull(ref, widget.originalMxcUrl)
        : widget.imageUrl;

    if (!mounted) return;
    if (fullUrl == null || fullUrl.isEmpty) {
      setState(() => _originalState = _OriginalImageState.failed);
      return;
    }

    setState(() {
      _fullUrl = fullUrl;
      _originalState = _OriginalImageState.loading;
    });
  }

  void _handlePreviewImageLoaded(String loadedUrl) {
    if (loadedUrl == _fullUrl &&
        _originalState == _OriginalImageState.loading) {
      setState(() => _originalState = _OriginalImageState.loaded);
    }
  }

  void _handlePreviewImageError(String failedUrl) {
    if (failedUrl == _fullUrl &&
        (_originalState == _OriginalImageState.loading ||
            _originalState == _OriginalImageState.resolving)) {
      setState(() => _originalState = _OriginalImageState.failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final imageUrl =
        _originalState == _OriginalImageState.loading ||
            _originalState == _OriginalImageState.loaded
        ? _fullUrl ?? widget.imageUrl
        : widget.imageUrl;

    return AnimatedBuilder(
      animation: widget.animation,
      builder: (context, _) {
        final animationValue = widget.animation.value;
        final backgroundValue = Curves.easeOut.transform(animationValue);
        final chromeValue = const Interval(
          0.45,
          1.0,
          curve: Curves.easeOut,
        ).transform(animationValue);

        return Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  color: Colors.black.withValues(alpha: backgroundValue),
                ),
              ),
              Center(
                child: _PreviewImageFrame(
                  heroTag: widget.heroTag,
                  imageUrl: imageUrl,
                  imageBytes: widget.imageBytes,
                  aspectRatio: widget.imageAspectRatio,
                  onLoaded: imageUrl == null
                      ? null
                      : () => _handlePreviewImageLoaded(imageUrl),
                  onError: imageUrl == null
                      ? null
                      : () => _handlePreviewImageError(imageUrl),
                ),
              ),
              Positioned(
                top: MediaQuery.of(context).padding.top,
                left: 0,
                right: 0,
                child: Opacity(
                  opacity: chromeValue,
                  child: AppBar(
                    backgroundColor: Colors.transparent,
                    elevation: 0,
                    leading: IconButton(
                      icon: const Icon(
                        Icons.close_rounded,
                        color: Colors.white,
                      ),
                      onPressed: _close,
                    ),
                    actions: [
                      if (widget.originalMxcUrl != null)
                        TextButton.icon(
                          onPressed: _canLoadOriginal ? _loadFull : null,
                          icon: _isOriginalBusy
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  _originalButtonIcon,
                                  color: _originalButtonColor,
                                  size: 20,
                                ),
                          label: Text(
                            _originalButtonLabel,
                            style: TextStyle(
                              color: _originalButtonColor,
                              fontSize: 14,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  bool get _isOriginalBusy =>
      _originalState == _OriginalImageState.resolving ||
      _originalState == _OriginalImageState.loading;

  bool get _canLoadOriginal =>
      _originalState == _OriginalImageState.thumbnail ||
      _originalState == _OriginalImageState.failed;

  IconData get _originalButtonIcon {
    switch (_originalState) {
      case _OriginalImageState.loaded:
        return Icons.check_circle_rounded;
      case _OriginalImageState.failed:
        return Icons.refresh_rounded;
      case _OriginalImageState.thumbnail:
      case _OriginalImageState.resolving:
      case _OriginalImageState.loading:
        return Icons.hd_rounded;
    }
  }

  String get _originalButtonLabel {
    switch (_originalState) {
      case _OriginalImageState.thumbnail:
        return '原图';
      case _OriginalImageState.resolving:
        return '获取中';
      case _OriginalImageState.loading:
        return '加载中';
      case _OriginalImageState.loaded:
        return '已原图';
      case _OriginalImageState.failed:
        return '重试原图';
    }
  }

  Color get _originalButtonColor {
    switch (_originalState) {
      case _OriginalImageState.loaded:
        return Colors.white54;
      case _OriginalImageState.failed:
        return Colors.redAccent.shade100;
      case _OriginalImageState.thumbnail:
      case _OriginalImageState.resolving:
      case _OriginalImageState.loading:
        return Colors.white;
    }
  }
}

class _PreviewImageFrame extends StatelessWidget {
  final Object heroTag;
  final String? imageUrl;
  final Uint8List? imageBytes;
  final double aspectRatio;
  final VoidCallback? onLoaded;
  final VoidCallback? onError;

  const _PreviewImageFrame({
    required this.heroTag,
    required this.imageUrl,
    required this.imageBytes,
    required this.aspectRatio,
    this.onLoaded,
    this.onError,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = _containedSize(
          Size(constraints.maxWidth, constraints.maxHeight),
          aspectRatio,
        );

        return InteractiveViewer(
          minScale: 1.0,
          maxScale: 4.0,
          clipBehavior: Clip.none,
          child: SizedBox(
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            child: Center(
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: Hero(
                  tag: heroTag,
                  createRectTween: (begin, end) =>
                      RectTween(begin: begin, end: end),
                  flightShuttleBuilder: _roundedImageFlightShuttle,
                  child: _HeroImageClip(
                    borderRadius: BorderRadius.zero,
                    child: _MediaImage(
                      imageUrl: imageUrl,
                      imageBytes: imageBytes,
                      fit: BoxFit.contain,
                      onLoaded: onLoaded,
                      onError: onError,
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

  Size _containedSize(Size bounds, double sourceAspectRatio) {
    final safeAspectRatio = sourceAspectRatio > 0 ? sourceAspectRatio : 1.0;
    var width = bounds.width;
    var height = width / safeAspectRatio;

    if (height > bounds.height) {
      height = bounds.height;
      width = height * safeAspectRatio;
    }

    return Size(width, height);
  }
}

class _HeroImageClip extends StatelessWidget {
  final BorderRadius borderRadius;
  final Widget child;

  const _HeroImageClip({required this.borderRadius, required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(borderRadius: borderRadius, child: child);
  }
}

class _MediaImage extends StatelessWidget {
  final String? imageUrl;
  final Uint8List? imageBytes;
  final BoxFit fit;
  final VoidCallback? onLoaded;
  final VoidCallback? onError;
  final int? cacheWidth;
  final int? cacheHeight;

  const _MediaImage({
    required this.imageUrl,
    required this.imageBytes,
    this.fit = BoxFit.cover,
    this.onLoaded,
    this.onError,
    this.cacheWidth,
    this.cacheHeight,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final bytes = imageBytes;
    if (bytes != null) {
      var notified = false;
      return Image.memory(
        bytes,
        fit: fit,
        width: double.infinity,
        height: double.infinity,
        cacheWidth: cacheWidth,
        cacheHeight: cacheHeight,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (!notified && (frame != null || wasSynchronouslyLoaded)) {
            notified = true;
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => onLoaded?.call(),
            );
          }
          return child;
        },
        errorBuilder: (context, error, stackTrace) {
          WidgetsBinding.instance.addPostFrameCallback((_) => onError?.call());
          return const ColoredBox(
            color: AppColors.surfaceElevated,
            child: Center(
              child: Icon(Icons.broken_image_rounded, color: Colors.white54),
            ),
          );
        },
      );
    }

    final url = imageUrl;
    if (url == null || url.isEmpty) {
      return const ColoredBox(color: AppColors.surfaceElevated);
    }
    return AuthenticatedImageMessage(
      imageUrl: url,
      fit: fit,
      onLoaded: onLoaded,
      onError: onError,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
    );
  }
}

Widget _roundedImageFlightShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection flightDirection,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final fromHero = fromHeroContext.widget as Hero;
  final toHero = toHeroContext.widget as Hero;
  final fromChild = fromHero.child;
  final toChild = toHero.child;

  if (fromChild is! _HeroImageClip || toChild is! _HeroImageClip) {
    return fromChild;
  }

  return AnimatedBuilder(
    animation: animation,
    child: fromChild.child,
    builder: (context, child) {
      final t = flightDirection == HeroFlightDirection.push
          ? animation.value
          : 1 - animation.value;
      return ClipRRect(
        borderRadius: BorderRadius.lerp(
          fromChild.borderRadius,
          toChild.borderRadius,
          t,
        )!,
        child: child,
      );
    },
  );
}
