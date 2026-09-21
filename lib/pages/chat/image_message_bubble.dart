import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/matrix_html/matrix_html_renderer.dart';
import '../../features/matrix_html/matrix_link_router.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/neu_colors.dart';
import '../../widgets/app_avatar.dart';
import 'message_group.dart' show neuBubbleShadows;
import 'message_text.dart';
import 'send_flight.dart';

enum _OriginalImageState { thumbnail, resolving, loading, loaded, failed }

const _minimumImageBubbleHeight = 72.0;

class ImageMessageBubble extends ConsumerStatefulWidget {
  final String roomId;
  final String messageId;
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
    required this.roomId,
    required this.messageId,
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
  int? _thumbnailWidth;
  int? _thumbnailHeight;

  void _handleMediaLoaded() {
    if (!mounted) return;
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
    final colors = context.neu;
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
      onLoaded: _handleMediaLoaded,
      onError: _handleMediaError,
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
            ? colors.accent.withValues(alpha: 0.3)
            : colors.card,
        borderRadius: mediaBorderRadius,
        boxShadow: widget.isSticker || hasCaption
            ? null
            : neuBubbleShadows(colors),
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
      onTap: () => _openPreview(url, bytes),
      child: RepaintBoundary(child: _withCaption(bubble, caption, hasCaption)),
    );
  }

  /// 收集会话内全部图片(按时间升序),以当前图为起始页打开预览;
  /// 缓存里找不到当前消息(极少见)时退化为单图预览。
  void _openPreview(String? url, Uint8List? bytes) {
    final entries = <_PreviewImageEntry>[];
    for (final message in ref.read(messageCacheProvider(widget.roomId))) {
      if (message.msgType != rust.MessageType.image) continue;
      if (message.imageUrl == null && message.mediaSourceJson == null) {
        continue;
      }
      entries.add(
        _PreviewImageEntry(
          messageId: message.id,
          imageUrl: message.imageUrl,
          mediaSourceJson: message.mediaSourceJson,
          aspectRatio: _aspectRatioOf(message.imageWidth, message.imageHeight),
        ),
      );
    }
    var index = entries.indexWhere(
      (entry) => entry.messageId == widget.messageId,
    );
    if (index < 0) {
      entries
        ..clear()
        ..add(
          _PreviewImageEntry(
            messageId: widget.messageId,
            imageUrl: widget.imageUrl,
            mediaSourceJson: widget.mediaSourceJson,
            aspectRatio: _imageAspectRatio,
          ),
        );
      index = 0;
    }
    // 起始页复用气泡已解析好的 URL/字节,保证秒开;heroTag 必须与气泡一致
    // 才能配对 Hero 动画。
    final initial = entries[index];
    entries[index] = _PreviewImageEntry(
      messageId: initial.messageId,
      imageUrl: initial.imageUrl,
      mediaSourceJson: initial.mediaSourceJson,
      aspectRatio: _imageAspectRatio,
      heroTag: widget.heroTag,
      initialResolvedUrl: url,
      initialBytes: bytes,
    );
    Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder(
        opaque: false,
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 280),
        pageBuilder: (_, animation, _) => _BubbleExpandingPreview(
          images: entries,
          initialIndex: index,
          animation: animation,
        ),
      ),
    );
  }

  static double _aspectRatioOf(int? width, int? height) {
    if (width != null && height != null && width > 0 && height > 0) {
      return width / height;
    }
    return 1.0;
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
        boxShadow: neuBubbleShadows(colors),
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
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(NeuRadius.content),
          topRight: const Radius.circular(NeuRadius.content),
          bottomLeft: Radius.circular(isMe ? NeuRadius.content : NeuRadius.tag),
          bottomRight: Radius.circular(
            isMe ? NeuRadius.tag : NeuRadius.content,
          ),
        ),
        boxShadow: neuBubbleShadows(colors),
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
    final colors = context.neu;
    return Container(
      width: bubbleSize.width,
      height: bubbleSize.height,
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: _bubbleBorderRadius,
        boxShadow: neuBubbleShadows(colors),
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
    final colors = context.neu;
    final accent = isMe ? colors.onAccent : colors.accent;
    final style = Theme.of(context).textTheme.bodyMedium!.copyWith(
      color: isMe ? colors.onAccent : colors.text,
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

/// 预览里的一页图片。起始页可带气泡已解析好的 URL/字节(秒开)和 heroTag。
class _PreviewImageEntry {
  final String messageId;
  final String? imageUrl;
  final String? mediaSourceJson;
  final double aspectRatio;
  final Object? heroTag;
  final String? initialResolvedUrl;
  final Uint8List? initialBytes;

  const _PreviewImageEntry({
    required this.messageId,
    required this.imageUrl,
    required this.mediaSourceJson,
    required this.aspectRatio,
    this.heroTag,
    this.initialResolvedUrl,
    this.initialBytes,
  });

  String? get originalMxcUrl {
    final url = imageUrl;
    return url != null && url.startsWith('mxc://') ? url : null;
  }
}

/// Full-screen image preview that expands from the bubble's on-screen position.
class _BubbleExpandingPreview extends ConsumerStatefulWidget {
  final List<_PreviewImageEntry> images;
  final int initialIndex;
  final Animation<double> animation;

  const _BubbleExpandingPreview({
    required this.images,
    required this.initialIndex,
    required this.animation,
  });

  @override
  ConsumerState<_BubbleExpandingPreview> createState() =>
      _BubbleExpandingPreviewState();
}

class _BubbleExpandingPreviewState
    extends ConsumerState<_BubbleExpandingPreview>
    with SingleTickerProviderStateMixin {
  /// 垂直拖动超过该距离(或甩动超过该速度)时退出预览。
  static const _dismissDistance = 140.0;
  static const _dismissVelocity = 800.0;

  late final _pageController = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  String? _fullUrl;
  _OriginalImageState _originalState = _OriginalImageState.thumbnail;
  bool _zoomed = false;
  double _dragY = 0;
  late final _settleController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  Animation<double>? _settleAnimation;

  @override
  void initState() {
    super.initState();
    _settleController.addListener(() {
      final animation = _settleAnimation;
      if (animation != null) setState(() => _dragY = animation.value);
    });
  }

  @override
  void dispose() {
    _settleController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _close() => Navigator.of(context).pop();

  void _onVerticalDragStart(DragStartDetails details) {
    _settleController.stop();
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    setState(() => _dragY += details.delta.dy);
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (_dragY.abs() > _dismissDistance || velocity.abs() > _dismissVelocity) {
      _close();
      return;
    }
    _settleAnimation = Tween<double>(begin: _dragY, end: 0).animate(
      CurvedAnimation(parent: _settleController, curve: Curves.easeOutCubic),
    );
    _settleController.forward(from: 0);
  }

  void _setZoomed(bool zoomed) {
    if (_zoomed == zoomed) return;
    setState(() => _zoomed = zoomed);
  }

  void _onPageChanged(int index) {
    setState(() {
      _index = index;
      _fullUrl = null;
      _originalState = _OriginalImageState.thumbnail;
      _zoomed = false;
    });
  }

  Future<void> _loadFull() async {
    if (_originalState == _OriginalImageState.resolving ||
        _originalState == _OriginalImageState.loading ||
        _originalState == _OriginalImageState.loaded) {
      return;
    }

    setState(() => _originalState = _OriginalImageState.resolving);

    final entry = widget.images[_index];
    final fullUrl = entry.originalMxcUrl != null
        ? await resolveMxcUrlFull(ref, entry.originalMxcUrl)
        : entry.imageUrl;

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
        final dragProgress =
            (_dragY.abs() / (MediaQuery.sizeOf(context).height * 0.45)).clamp(
              0.0,
              1.0,
            );
        final fade = 1 - dragProgress;

        return Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  color: Colors.black.withValues(alpha: backgroundValue * fade),
                ),
              ),
              GestureDetector(
                onVerticalDragStart: _zoomed ? null : _onVerticalDragStart,
                onVerticalDragUpdate: _zoomed ? null : _onVerticalDragUpdate,
                onVerticalDragEnd: _zoomed ? null : _onVerticalDragEnd,
                child: Opacity(
                  opacity: animationValue,
                  child: Transform.translate(
                    offset: Offset(0, _dragY),
                    child: Transform.scale(
                      scale: 1 - dragProgress * 0.15,
                      child: PageView.builder(
                        controller: _pageController,
                        physics: _zoomed
                            ? const NeverScrollableScrollPhysics()
                            : null,
                        itemCount: widget.images.length,
                        onPageChanged: _onPageChanged,
                        itemBuilder: _buildPage,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: MediaQuery.of(context).padding.top + 12,
                left: 16,
                right: 16,
                child: Row(
                  children: [
                    _ViewerGlassButton(
                      tooltip: '关闭',
                      onPressed: _close,
                      opacity: chromeValue * fade,
                      child: const Icon(Icons.close_rounded, size: 22),
                    ),
                    const Spacer(),
                    if (widget.images[_index].originalMxcUrl != null)
                      _buildOriginalButton(chromeValue * fade),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPage(BuildContext context, int index) {
    final entry = widget.images[index];
    final isCurrent = index == _index;
    final overrideUrl =
        isCurrent &&
            (_originalState == _OriginalImageState.loading ||
                _originalState == _OriginalImageState.loaded)
        ? _fullUrl
        : null;
    return _PreviewImagePage(
      key: ValueKey(entry.messageId),
      entry: entry,
      overrideUrl: overrideUrl,
      withHero: isCurrent && entry.heroTag != null,
      onZoomChanged: isCurrent ? _setZoomed : null,
      onImageLoaded: _handlePreviewImageLoaded,
      onImageError: _handlePreviewImageError,
    );
  }

  Widget _buildOriginalButton(double opacity) {
    return _ViewerGlassButton(
      onPressed: _canLoadOriginal ? _loadFull : null,
      opacity: opacity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isOriginalBusy)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2,
              ),
            )
          else
            Icon(_originalButtonIcon, color: _originalButtonColor, size: 18),
          const SizedBox(width: 6),
          Text(
            _originalButtonLabel,
            style: TextStyle(color: _originalButtonColor, fontSize: 14),
          ),
        ],
      ),
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

/// 预览里的一页:按需把 mxc:// 解析成缩略图 URL,或把加密附件解密成字节。
class _PreviewImagePage extends ConsumerStatefulWidget {
  final _PreviewImageEntry entry;

  /// 当前页加载了原图时的替换 URL;非当前页恒为 null。
  final String? overrideUrl;
  final bool withHero;
  final ValueChanged<bool>? onZoomChanged;
  final ValueChanged<String>? onImageLoaded;
  final ValueChanged<String>? onImageError;

  const _PreviewImagePage({
    super.key,
    required this.entry,
    required this.overrideUrl,
    required this.withHero,
    this.onZoomChanged,
    this.onImageLoaded,
    this.onImageError,
  });

  @override
  ConsumerState<_PreviewImagePage> createState() => _PreviewImagePageState();
}

class _PreviewImagePageState extends ConsumerState<_PreviewImagePage> {
  String? _resolvedUrl;
  Uint8List? _bytes;
  int? _resolveWidth;
  int? _resolveHeight;

  @override
  void initState() {
    super.initState();
    _resolvedUrl = widget.entry.initialResolvedUrl;
    _bytes = widget.entry.initialBytes;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final width = (size.width * dpr).round();
    final height = (size.height * dpr).round();
    if (width != _resolveWidth || height != _resolveHeight) {
      _resolveWidth = width;
      _resolveHeight = height;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    if (_resolvedUrl != null || _bytes != null) return;
    final entry = widget.entry;
    final imageUrl = entry.imageUrl;
    if (imageUrl == null) {
      final json = entry.mediaSourceJson;
      if (json == null) return;
      try {
        final bytes = await rust.downloadMediaSourceBytes(
          mediaSourceJson: json,
          maxSizeBytes: 16 * 1024 * 1024,
        );
        if (mounted) setState(() => _bytes = Uint8List.fromList(bytes));
      } catch (_) {
        // 解密失败:页面停在 loading 占位,可左右滑走再滑回重试。
      }
    } else if (imageUrl.startsWith('mxc://')) {
      final url = await resolveMxcUrl(
        ref,
        imageUrl,
        width: _resolveWidth,
        height: _resolveHeight,
      );
      if (mounted && url != null) setState(() => _resolvedUrl = url);
    } else {
      setState(() => _resolvedUrl = imageUrl);
    }
  }

  @override
  Widget build(BuildContext context) {
    final imageUrl = widget.overrideUrl ?? _resolvedUrl;
    final bytes = _bytes;
    if (imageUrl == null && bytes == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
      );
    }
    return _PreviewImageFrame(
      heroTag: widget.withHero ? widget.entry.heroTag : null,
      imageUrl: imageUrl,
      imageBytes: bytes,
      aspectRatio: widget.entry.aspectRatio,
      onZoomChanged: widget.onZoomChanged,
      onLoaded: imageUrl == null
          ? null
          : () => widget.onImageLoaded?.call(imageUrl),
      onError: imageUrl == null
          ? null
          : () => widget.onImageError?.call(imageUrl),
    );
  }
}

class _PreviewImageFrame extends StatefulWidget {
  final Object? heroTag;
  final String? imageUrl;
  final Uint8List? imageBytes;
  final double aspectRatio;
  final ValueChanged<bool>? onZoomChanged;
  final VoidCallback? onLoaded;
  final VoidCallback? onError;

  const _PreviewImageFrame({
    required this.heroTag,
    required this.imageUrl,
    required this.imageBytes,
    required this.aspectRatio,
    this.onZoomChanged,
    this.onLoaded,
    this.onError,
  });

  @override
  State<_PreviewImageFrame> createState() => _PreviewImageFrameState();
}

class _PreviewImageFrameState extends State<_PreviewImageFrame>
    with SingleTickerProviderStateMixin {
  /// 双击逐级放大到的倍率;超过最高档后再双击回到原图大小。
  static const _zoomLevels = [2.0, 4.0];

  final _transformationController = TransformationController();
  late final _zoomAnimController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  late Animation<Matrix4> _zoomAnimation = ConstantTween(
    Matrix4.identity(),
  ).animate(_zoomAnimController);
  Offset? _doubleTapPosition;
  bool _isZoomed = false;

  @override
  void initState() {
    super.initState();
    _zoomAnimController.addListener(() {
      _transformationController.value = _zoomAnimation.value;
    });
    _transformationController.addListener(_handleTransform);
  }

  /// 1x 时禁掉 InteractiveViewer 的平移,把垂直/水平拖动让给
  /// 外层的退出手势和 PageView;放大后才由它接管平移。
  void _handleTransform() {
    final zoomed = _transformationController.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed == _isZoomed) return;
    setState(() => _isZoomed = zoomed);
    widget.onZoomChanged?.call(zoomed);
  }

  @override
  void dispose() {
    _zoomAnimController.dispose();
    _transformationController.dispose();
    super.dispose();
  }

  void _onDoubleTap() {
    final tapped = _doubleTapPosition;
    final current = _transformationController.value.getMaxScaleOnAxis();
    final double targetScale;
    if (current < _zoomLevels.first - .1) {
      targetScale = _zoomLevels.first;
    } else if (current < _zoomLevels.last - .1) {
      targetScale = _zoomLevels.last;
    } else {
      targetScale = 1;
    }

    final Matrix4 target;
    if (targetScale == 1 || tapped == null) {
      target = Matrix4.identity();
    } else {
      // 以双击点为焦点放大:放大前后,手指下的内容点保持在原位。
      final scenePoint = _transformationController.toScene(tapped);
      target = Matrix4.identity()
        ..translateByDouble(tapped.dx, tapped.dy, 0, 1)
        ..scaleByDouble(targetScale, targetScale, targetScale, 1)
        ..translateByDouble(-scenePoint.dx, -scenePoint.dy, 0, 1);
    }

    _zoomAnimation =
        Matrix4Tween(begin: _transformationController.value, end: target)
            .chain(CurveTween(curve: Curves.easeOutCubic))
            .animate(_zoomAnimController);
    _zoomAnimController.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = _containedSize(
          Size(constraints.maxWidth, constraints.maxHeight),
          widget.aspectRatio,
        );

        final media = _HeroImageClip(
          borderRadius: BorderRadius.zero,
          // Cache the image display list below the changing zoom transform.
          child: RepaintBoundary(
            child: _MediaImage(
              imageUrl: widget.imageUrl,
              imageBytes: widget.imageBytes,
              fit: BoxFit.contain,
              onLoaded: widget.onLoaded,
              onError: widget.onError,
            ),
          ),
        );
        final heroTag = widget.heroTag;

        return GestureDetector(
          onDoubleTapDown: (details) =>
              _doubleTapPosition = details.localPosition,
          onDoubleTap: _onDoubleTap,
          child: InteractiveViewer(
            transformationController: _transformationController,
            onInteractionStart: (_) => _zoomAnimController.stop(),
            minScale: 1.0,
            maxScale: _zoomLevels.last,
            clipBehavior: Clip.hardEdge,
            panEnabled: _isZoomed,
            child: SizedBox(
              width: constraints.maxWidth,
              height: constraints.maxHeight,
              child: Center(
                child: SizedBox(
                  width: size.width,
                  height: size.height,
                  child: heroTag == null
                      ? media
                      : Hero(
                          tag: heroTag,
                          createRectTween: (begin, end) =>
                              RectTween(begin: begin, end: end),
                          flightShuttleBuilder: _roundedImageFlightShuttle,
                          child: media,
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
          return ColoredBox(
            color: context.neu.card,
            child: const Center(
              child: Icon(Icons.broken_image_rounded, color: Colors.white54),
            ),
          );
        },
      );
    }

    final url = imageUrl;
    if (url == null || url.isEmpty) {
      return ColoredBox(color: context.neu.card);
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

/// 查看器顶部的磨砂玻璃按钮。查看器的背景固定为黑色遮罩,
/// 玻璃用固定的深色半透明填充(不随明暗主题切换),
/// 保证在纯白图片上按钮依然可见。
///
/// 边框不用 [PaintingStyle.stroke] 描边:Impeller 在部分平台
/// (如无 MSAA 的桌面 GLES)不给超椭圆描边做抗锯齿。改为描边色
/// 整铺 + 内缩形状填充,填充在所有平台上都有抗锯齿。
class _ViewerGlassButton extends StatelessWidget {
  const _ViewerGlassButton({
    required this.child,
    required this.onPressed,
    this.tooltip,
    this.padding = const EdgeInsets.all(9),
    this.opacity = 1,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final String? tooltip;
  final EdgeInsetsGeometry padding;

  /// 查看器入场/退场的淡入淡出系数。
  ///
  /// 不能用 [Opacity] 包裹整个按钮:离屏图层会让 [BackdropFilter]
  /// 在动画过程中采不到背后的图片,动画结束(图层被优化掉)时模糊
  /// 突然生效,观感是按钮凭空弹出。改为把系数乘进玻璃颜色的 alpha,
  /// 模糊全程贴着真实背景;图标和文字再单独淡入淡出。
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final alpha = opacity * (onPressed == null ? .45 : 1);
    final outer = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(20),
    );
    final inner = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(19),
    );
    Widget button = Container(
      decoration: ShapeDecoration(
        shape: outer,
        color: Colors.white.withValues(alpha: .18 * alpha),
      ),
      padding: const EdgeInsets.all(1),
      child: Container(
        padding: padding,
        decoration: ShapeDecoration(
          shape: inner,
          color: Colors.black.withValues(alpha: .45 * alpha),
        ),
        child: IconTheme.merge(
          data: const IconThemeData(color: Colors.white),
          child: Opacity(opacity: alpha, child: child),
        ),
      ),
    );
    // 完全透明时连模糊一起跳过,否则图片上会残留一块无色的模糊斑。
    if (alpha > 0) {
      button = ClipPath.shape(
        shape: outer,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: button,
        ),
      );
    }
    button = MouseRegion(
      cursor: onPressed != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: button,
      ),
    );
    final tooltip = this.tooltip;
    if (tooltip != null) {
      button = Tooltip(message: tooltip, child: button);
    }
    return button;
  }
}
