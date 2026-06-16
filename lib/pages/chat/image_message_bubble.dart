import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/chat_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_avatar.dart';

class ImageMessageBubble extends ConsumerStatefulWidget {
  final String imageUrl;
  final int? imageWidth;
  final int? imageHeight;
  final String timestamp;
  final bool isMe;
  final VoidCallback? onLoaded;

  const ImageMessageBubble({
    super.key,
    required this.imageUrl,
    this.imageWidth,
    this.imageHeight,
    required this.timestamp,
    required this.isMe,
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
    if (widget.imageUrl != oldWidget.imageUrl || _resolvedUrl == null) {
      _resolveUrl();
    }
  }

  Future<void> _resolveUrl() async {
    if (widget.imageUrl.startsWith('mxc://')) {
      final url = await resolveMxcUrl(
        ref,
        widget.imageUrl,
        width: _thumbnailWidth,
        height: _thumbnailHeight,
      );
      if (mounted && url != null) {
        setState(() => _resolvedUrl = url);
        widget.onLoaded?.call();
      }
      // If null, _resolvedUrl stays null → shows broken; retried on next rebuild
    } else {
      _resolvedUrl = widget.imageUrl;
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
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => _ImagePreviewPage(
              thumbnailUrl: url,
              originalMxcUrl: _originalMxcUrl,
            ),
          ),
        );
      },
      child: Hero(
        tag: url,
        child: Container(
          width: bubbleSize.width,
          height: bubbleSize.height,
          decoration: BoxDecoration(
            color: isMe
                ? AppColors.primary.withValues(alpha: 0.3)
                : AppColors.surfaceElevated,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(AppRadii.content),
              topRight: const Radius.circular(AppRadii.content),
              bottomLeft: Radius.circular(
                widget.isMe ? AppRadii.content : AppRadii.tag,
              ),
              bottomRight: Radius.circular(
                widget.isMe ? AppRadii.tag : AppRadii.content,
              ),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            alignment: Alignment.bottomRight,
            children: [
              Positioned.fill(
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
      ),
    );
  }

  bool get isMe => widget.isMe;

  Size _bubbleSize(BuildContext context) {
    const maxHeight = 280.0;
    final maxWidth = MediaQuery.sizeOf(context).width * 0.65;
    final sourceWidth = widget.imageWidth;
    final sourceHeight = widget.imageHeight;
    final aspectRatio =
        sourceWidth != null &&
            sourceHeight != null &&
            sourceWidth > 0 &&
            sourceHeight > 0
        ? sourceWidth / sourceHeight
        : 1.0;

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

/// Image preview page with thumbnail + "原图" button.
class _ImagePreviewPage extends ConsumerStatefulWidget {
  final String thumbnailUrl;
  final String? originalMxcUrl;

  const _ImagePreviewPage({
    required this.thumbnailUrl,
    required this.originalMxcUrl,
  });

  @override
  ConsumerState<_ImagePreviewPage> createState() => _ImagePreviewPageState();
}

class _ImagePreviewPageState extends ConsumerState<_ImagePreviewPage> {
  String? _fullUrl;
  bool _loadingFull = false;
  bool _showFull = false;

  Future<void> _loadFull() async {
    if (_loadingFull) return;
    setState(() => _loadingFull = true);

    final fullUrl = widget.originalMxcUrl != null
        ? await resolveMxcUrlFull(ref, widget.originalMxcUrl)
        : widget.thumbnailUrl;

    if (mounted) {
      setState(() {
        _fullUrl = fullUrl;
        _loadingFull = false;
        _showFull = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          if (widget.originalMxcUrl != null)
            TextButton.icon(
              onPressed: _loadingFull ? null : _loadFull,
              icon: _loadingFull
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.hd_rounded, color: Colors.white, size: 20),
              label: Text(
                _showFull ? '原图' : '原图',
                style: TextStyle(
                  color: _showFull ? Colors.white54 : Colors.white,
                  fontSize: 14,
                ),
              ),
            ),
        ],
      ),
      body: Center(
        child: Hero(
          tag: widget.thumbnailUrl,
          child: _showFull && _fullUrl != null
              ? AuthenticatedImageMessage(imageUrl: _fullUrl!)
              : AuthenticatedImageMessage(imageUrl: widget.thumbnailUrl),
        ),
      ),
    );
  }
}
