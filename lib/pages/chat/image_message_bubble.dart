import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/chat_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_avatar.dart';

enum _OriginalImageState { thumbnail, resolving, loading, loaded, failed }

class ImageMessageBubble extends ConsumerStatefulWidget {
  final String imageUrl;
  final int? imageWidth;
  final int? imageHeight;
  final String timestamp;
  final bool isMe;
  final Object heroTag;
  final VoidCallback? onLoaded;

  const ImageMessageBubble({
    super.key,
    required this.imageUrl,
    this.imageWidth,
    this.imageHeight,
    required this.timestamp,
    required this.isMe,
    required this.heroTag,
    this.onLoaded,
  });

  @override
  ConsumerState<ImageMessageBubble> createState() => _ImageMessageBubbleState();
}

class _ImageMessageBubbleState extends ConsumerState<ImageMessageBubble> {
  String? _resolvedUrl;
  String? _originalMxcUrl;
  int? _thumbnailWidth;
  int? _thumbnailHeight;

  @override
  void initState() {
    super.initState();
    _originalMxcUrl = widget.imageUrl.startsWith('mxc://')
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
    final cachedUrl = cachedResolvedMxcUrl(
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
        _resolvedUrl == null) {
      _resolveUrl();
    }
  }

  Future<void> _resolveUrl() async {
    if (widget.imageUrl.startsWith('mxc://')) {
      final useOriginalCache = _shouldUseOriginalCache;
      final url = await resolveMxcUrl(
        ref,
        widget.imageUrl,
        width: useOriginalCache ? null : _thumbnailWidth,
        height: useOriginalCache ? null : _thumbnailHeight,
      );
      if (mounted && url != null) {
        setState(() => _resolvedUrl = url);
        widget.onLoaded?.call();
      }
    } else {
      if (mounted) {
        setState(() => _resolvedUrl = widget.imageUrl);
      } else {
        _resolvedUrl = widget.imageUrl;
      }
      widget.onLoaded?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = _resolvedUrl;
    final bubbleSize = _bubbleSize(context);

    if (url == null || url.isEmpty) {
      return _buildBroken(context, bubbleSize);
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
              originalMxcUrl: _originalMxcUrl,
              imageAspectRatio: _imageAspectRatio,
              animation: animation,
            ),
          ),
        );
      },
      child: Container(
        width: bubbleSize.width,
        height: bubbleSize.height,
        decoration: BoxDecoration(
          color: isMe
              ? AppColors.primary.withValues(alpha: 0.3)
              : AppColors.surfaceElevated,
          borderRadius: _bubbleBorderRadius,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          alignment: Alignment.bottomRight,
          children: [
            Positioned.fill(
              child: Hero(
                tag: widget.heroTag,
                createRectTween: (begin, end) =>
                    RectTween(begin: begin, end: end),
                flightShuttleBuilder: _roundedImageFlightShuttle,
                child: _HeroImageClip(
                  borderRadius: _bubbleBorderRadius,
                  child: AuthenticatedImageMessage(
                    key: ValueKey(
                      'msg-image:${widget.imageUrl}:${widget.timestamp}',
                    ),
                    imageUrl: url,
                    onLoaded: widget.onLoaded,
                    cacheWidth: _thumbnailWidth,
                    cacheHeight: _thumbnailHeight,
                  ),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.5),
                  ],
                ),
              ),
              child: Text(
                widget.timestamp,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 10.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool get isMe => widget.isMe;

  BorderRadius get _bubbleBorderRadius => BorderRadius.only(
    topLeft: const Radius.circular(AppRadii.content),
    topRight: const Radius.circular(AppRadii.content),
    bottomLeft: Radius.circular(widget.isMe ? AppRadii.content : AppRadii.tag),
    bottomRight: Radius.circular(widget.isMe ? AppRadii.tag : AppRadii.content),
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
    const maxHeight = 280.0;
    final maxWidth = MediaQuery.sizeOf(context).width * 0.65;
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
}

/// Full-screen image preview that expands from the bubble's on-screen position.
class _BubbleExpandingPreview extends ConsumerStatefulWidget {
  final Object heroTag;
  final String imageUrl;
  final String? originalMxcUrl;
  final double imageAspectRatio;
  final Animation<double> animation;

  const _BubbleExpandingPreview({
    required this.heroTag,
    required this.imageUrl,
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
                  aspectRatio: widget.imageAspectRatio,
                  onLoaded: () => _handlePreviewImageLoaded(imageUrl),
                  onError: () => _handlePreviewImageError(imageUrl),
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
  final String imageUrl;
  final double aspectRatio;
  final VoidCallback? onLoaded;
  final VoidCallback? onError;

  const _PreviewImageFrame({
    required this.heroTag,
    required this.imageUrl,
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
                    child: AuthenticatedImageMessage(
                      imageUrl: imageUrl,
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
