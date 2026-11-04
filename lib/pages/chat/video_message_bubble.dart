import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../providers/auth_provider.dart';
import '../../theme/neu_colors.dart';
import 'chat_media_source.dart';
import 'media_preparation.dart';
import 'prepared_media_source.dart';
import 'media_playback.dart';
import 'media_progress_bar.dart';
import 'video_controls.dart';
import 'message_group.dart' show enabledNeuBubbleShadows;

class VideoMessageBubble extends ConsumerStatefulWidget {
  final String? videoUrl;
  final String? mediaSourceJson;
  final String filename;
  final int? videoWidth;
  final int? videoHeight;
  final int? durationMs;
  final bool isMe;
  final Object heroTag;
  final Widget metadata;
  final VoidCallback? onLoaded;

  const VideoMessageBubble({
    super.key,
    this.videoUrl,
    this.mediaSourceJson,
    required this.filename,
    this.videoWidth,
    this.videoHeight,
    this.durationMs,
    required this.isMe,
    required this.heroTag,
    required this.metadata,
    this.onLoaded,
  });

  @override
  ConsumerState<VideoMessageBubble> createState() => _VideoMessageBubbleState();
}

class _VideoMessageBubbleState extends ConsumerState<VideoMessageBubble> {
  MediaPlayback? _controller;
  VideoController? _videoController;
  PreparedMediaSource? _preparedSource;
  Object? _error;
  int _initializationId = 0;
  double _previewVolume = 0;
  MediaPreparation? _preparation;
  Route<void>? _previewRoute;

  @override
  void initState() {
    super.initState();
    ref.listenManual(
      currentUserProvider.select((user) => (user?.id, user?.homeserver)),
      (previous, next) => _accountChanged(),
    );
    ref.listenManual(sessionReadyProvider, (previous, next) {
      if (previous == true && !next) _accountChanged();
    });
    _initialize();
  }

  @override
  void didUpdateWidget(covariant VideoMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoUrl != widget.videoUrl ||
        oldWidget.mediaSourceJson != widget.mediaSourceJson) {
      _initialize();
    } else if (oldWidget.durationMs != widget.durationMs) {
      _controller?.setDurationMetadata(widget.durationMs);
    }
  }

  void _accountChanged() {
    _initializationId++;
    _preparation?.cancel();
    _closePreview();
    final controller = _controller;
    final source = _preparedSource;
    _controller = null;
    _videoController = null;
    _preparedSource = null;
    unawaited(_disposeVideoSource(controller, source));
    if (mounted) setState(() => _error = StateError('Media account changed'));
  }

  void _closePreview() {
    final route = _previewRoute;
    _previewRoute = null;
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        route.navigator?.removeRoute(route);
      });
    }
  }

  Future<void> _initialize() async {
    final initializationId = ++_initializationId;
    _preparation?.cancel();
    _closePreview();
    final preparation = _preparation = MediaPreparation();
    final oldController = _controller;
    final oldPreparedSource = _preparedSource;
    final videoUrl = widget.videoUrl;
    final mediaSourceJson = widget.mediaSourceJson;
    final filename = widget.filename;
    _controller = null;
    _videoController = null;
    _preparedSource = null;
    _error = null;
    await _disposeVideoSource(oldController, oldPreparedSource);
    if (!mounted || initializationId != _initializationId) return;

    MediaPlayback? controller;
    PreparedMediaSource? preparedSource;
    try {
      preparedSource = await prepareChatMediaSource(
        ref: ref,
        url: videoUrl,
        mediaSourceJson: mediaSourceJson,
        filename: filename,
        preparation: preparation,
      );
      if (!mounted || initializationId != _initializationId) {
        await preparedSource.cleanup();
        return;
      }
      controller = MediaPlayback();
      final videoController = VideoController(controller.player);
      await videoController.platform.future;
      await controller.setVolume(0);
      await controller.open(
        preparedSource.media,
        durationMs: widget.durationMs,
      );
      if (!mounted || initializationId != _initializationId) {
        await _disposeVideoSource(controller, preparedSource);
        return;
      }
      setState(() {
        _preparedSource = preparedSource;
        _controller = controller;
        _videoController = videoController;
      });
      widget.onLoaded?.call();
    } catch (error) {
      await _disposeVideoSource(controller, preparedSource);
      if (mounted && initializationId == _initializationId) {
        setState(() => _error = error);
      }
    }
  }

  @override
  void dispose() {
    _initializationId++;
    _preparation?.cancel();
    _closePreview();
    final controller = _controller;
    final preparedSource = _preparedSource;
    _controller = null;
    _preparedSource = null;
    unawaited(_disposeVideoSource(controller, preparedSource));
    super.dispose();
  }

  Future<void> _disposeVideoSource(
    MediaPlayback? controller,
    PreparedMediaSource? preparedSource,
  ) async {
    try {
      await controller?.close();
    } finally {
      await preparedSource?.cleanup();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return ListenableBuilder(
      listenable: controller ?? const AlwaysStoppedAnimation(0),
      builder: (context, child) {
        final size = _bubbleSize(
          context,
          controller?.player.state.width == null
              ? null
              : controller?.aspectRatio,
        );
        final colors = context.neu;
        return Container(
          width: size.width,
          height: size.height,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: widget.isMe
                ? colors.accent.withValues(alpha: 0.3)
                : colors.card,
            borderRadius: BorderRadius.circular(NeuRadius.button),
            boxShadow: enabledNeuBubbleShadows(context, colors),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: controller == null
                    ? _buildPlaceholder(_error != null)
                    : controller.error != null
                    ? _buildPlaceholder(true)
                    : _buildPlayer(context, controller),
              ),
              widget.metadata,
            ],
          ),
        );
      },
    );
  }

  Widget _buildPlayer(BuildContext context, MediaPlayback controller) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          child: Hero(
            tag: widget.heroTag,
            createRectTween: (begin, end) => RectTween(begin: begin, end: end),
            child: _VideoHeroSurface(
              videoController: _videoController!,
              fit: BoxFit.contain,
              borderRadius: BorderRadius.circular(NeuRadius.button),
              showPlayButton: !controller.isPlaying,
            ),
          ),
        ),
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openPreview(context, controller),
          ),
        ),
        if (!controller.isPlaying)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: controller.play,
            child: const SizedBox.square(dimension: 72),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 3,
          child: MediaProgressBar(controller: controller),
        ),
      ],
    );
  }

  Widget _buildPlaceholder(bool failed) {
    return GestureDetector(
      onTap: failed
          ? () {
              setState(() => _error = null);
              unawaited(_initialize());
            }
          : null,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (failed)
              const Icon(Icons.videocam_off_rounded, color: Colors.white70)
            else
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            const SizedBox(height: 8),
            Text(
              failed ? '无法播放此视频' : '正在加载视频…',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openPreview(
    BuildContext context,
    MediaPlayback controller,
  ) async {
    if (_previewRoute != null) return;
    await controller.setVolume(_previewVolume);
    if (!context.mounted || !identical(_controller, controller)) return;
    final videoController = _videoController!;
    final route = _previewRoute = PageRouteBuilder<void>(
      opaque: false,
      transitionDuration: const Duration(milliseconds: 320),
      reverseTransitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (context, animation, secondaryAnimation) => AnimatedBuilder(
        animation: animation,
        builder: (context, child) => Material(
          type: MaterialType.transparency,
          child: ColoredBox(
            color: Colors.black.withValues(
              alpha: Curves.easeOut.transform(animation.value),
            ),
            child: VideoControls(
              playback: controller,
              onClose: () => Navigator.of(context).pop(),
              videoBuilder: (context, fit) => Hero(
                tag: widget.heroTag,
                createRectTween: (begin, end) =>
                    RectTween(begin: begin, end: end),
                child: _VideoHeroSurface(
                  videoController: videoController,
                  fit: fit,
                  borderRadius: BorderRadius.zero,
                  showPlayButton: false,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await Navigator.of(context, rootNavigator: true).push(route);
    if (identical(_previewRoute, route)) _previewRoute = null;
    final previewVolume = controller.volume;
    if (mounted && identical(_controller, controller)) {
      _previewVolume = previewVolume;
      await controller.setVolume(0);
    }
  }

  Size _bubbleSize(BuildContext context, double? playerAspectRatio) {
    const maxHeight = 320.0;
    final maxWidth = (MediaQuery.sizeOf(context).width * 0.68).clamp(
      180.0,
      360.0,
    );
    final metadataWidth = widget.videoWidth?.toDouble();
    final metadataHeight = widget.videoHeight?.toDouble();
    final metadataAspectRatio =
        metadataWidth != null &&
            metadataHeight != null &&
            metadataWidth > 0 &&
            metadataHeight > 0
        ? metadataWidth / metadataHeight
        : 16 / 9;
    final aspectRatio =
        playerAspectRatio != null &&
            playerAspectRatio.isFinite &&
            playerAspectRatio > 0
        ? playerAspectRatio
        : metadataAspectRatio;
    var width = maxWidth;
    var height = width / aspectRatio;
    if (height > maxHeight) {
      height = maxHeight;
      width = height * aspectRatio;
    }
    return Size(width, height);
  }
}

class _VideoHeroSurface extends StatelessWidget {
  final VideoController videoController;
  final BoxFit fit;
  final BorderRadius borderRadius;
  final bool showPlayButton;

  const _VideoHeroSurface({
    required this.videoController,
    required this.fit,
    required this.borderRadius,
    required this.showPlayButton,
  });

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: borderRadius,
    child: Stack(
      fit: StackFit.expand,
      alignment: Alignment.center,
      children: [
        // media_kit owns the reference-counted wakelock while this video plays.
        Video(controller: videoController, fit: fit, controls: NoVideoControls),
        if (showPlayButton)
          Center(
            child: Container(
              width: 52,
              height: 52,
              decoration: const BoxDecoration(
                color: Colors.black54,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.play_arrow_rounded,
                color: Colors.white,
                size: 34,
              ),
            ),
          ),
      ],
    ),
  );
}
