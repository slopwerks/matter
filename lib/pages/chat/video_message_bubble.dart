import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../providers/auth_provider.dart';
import '../../providers/authenticated_media_cache.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/app_theme.dart';
import 'decrypted_video_source.dart';

class VideoMessageBubble extends ConsumerStatefulWidget {
  final String? videoUrl;
  final String? mediaSourceJson;
  final String filename;
  final int? videoWidth;
  final int? videoHeight;
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
    required this.isMe,
    required this.heroTag,
    required this.metadata,
    this.onLoaded,
  });

  @override
  ConsumerState<VideoMessageBubble> createState() => _VideoMessageBubbleState();
}

class _VideoMessageBubbleState extends ConsumerState<VideoMessageBubble> {
  VideoPlayerController? _controller;
  PreparedVideoSource? _preparedSource;
  Object? _error;
  int _initializationId = 0;
  double _previewVolume = 0;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void didUpdateWidget(covariant VideoMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoUrl != widget.videoUrl ||
        oldWidget.mediaSourceJson != widget.mediaSourceJson) {
      _initialize();
    }
  }

  Future<void> _initialize() async {
    final initializationId = ++_initializationId;
    final oldController = _controller;
    final oldPreparedSource = _preparedSource;
    _controller = null;
    _preparedSource = null;
    _error = null;
    await oldController?.dispose();
    await oldPreparedSource?.cleanup();

    VideoPlayerController? controller;
    PreparedVideoSource? preparedSource;
    try {
      final videoUrl = widget.videoUrl;
      if (videoUrl == null) {
        final mediaSourceJson = widget.mediaSourceJson;
        if (mediaSourceJson == null) {
          throw StateError('Missing encrypted video source');
        }
        final bytes = await rust.downloadMediaSourceBytes(
          mediaSourceJson: mediaSourceJson,
          maxSizeBytes: 16 * 1024 * 1024,
        );
        preparedSource = await prepareDecryptedVideoSource(
          Uint8List.fromList(bytes),
          widget.filename,
        );
        controller = preparedSource.controller;
      } else {
        final resolvedUrl = videoUrl.startsWith('mxc://')
            ? await resolveMxcUrlFull(ref, videoUrl)
            : videoUrl;
        if (resolvedUrl == null || resolvedUrl.isEmpty) {
          throw StateError('Unable to resolve video URL');
        }
        final isMatrixMedia = isCurrentHomeserverMatrixMediaUrl(
          resolvedUrl,
          ref.read(currentUserProvider)?.homeserver,
        );
        final token = ref.read(currentAccessTokenProvider);
        controller = VideoPlayerController.networkUrl(
          Uri.parse(resolvedUrl),
          httpHeaders: token == null || !isMatrixMedia
              ? const {}
              : {'Authorization': 'Bearer $token'},
        );
      }
      await controller.initialize();
      await controller.setVolume(0);
      if (!mounted || initializationId != _initializationId) {
        await controller.dispose();
        await preparedSource?.cleanup();
        return;
      }
      setState(() {
        _preparedSource = preparedSource;
        _controller = controller;
      });
      widget.onLoaded?.call();
    } catch (error) {
      await controller?.dispose();
      await preparedSource?.cleanup();
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    _initializationId++;
    final controller = _controller;
    final preparedSource = _preparedSource;
    _controller = null;
    _preparedSource = null;
    unawaited(_disposeVideoSource(controller, preparedSource));
    super.dispose();
  }

  Future<void> _disposeVideoSource(
    VideoPlayerController? controller,
    PreparedVideoSource? preparedSource,
  ) async {
    await controller?.dispose();
    await preparedSource?.cleanup();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final size = _bubbleSize(
      context,
      controller?.value.isInitialized == true
          ? controller!.value.aspectRatio
          : null,
    );
    return Container(
      width: size.width,
      height: size.height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: widget.isMe
            ? AppColors.primary.withValues(alpha: 0.3)
            : AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: controller == null
                ? _buildPlaceholder(_error != null)
                : ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: controller,
                    builder: (context, value, child) =>
                        _buildPlayer(context, controller),
                  ),
          ),
          widget.metadata,
        ],
      ),
    );
  }

  Widget _buildPlayer(BuildContext context, VideoPlayerController controller) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          child: Hero(
            tag: widget.heroTag,
            createRectTween: (begin, end) => RectTween(begin: begin, end: end),
            child: _VideoHeroSurface(
              controller: controller,
              fit: BoxFit.contain,
              borderRadius: BorderRadius.circular(14),
              showPlayButton: !controller.value.isPlaying,
            ),
          ),
        ),
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openPreview(context, controller),
          ),
        ),
        if (!controller.value.isPlaying)
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
          child: VideoProgressIndicator(
            controller,
            allowScrubbing: false,
            padding: EdgeInsets.zero,
            colors: VideoProgressColors(
              playedColor: AppColors.primary,
              bufferedColor: Colors.white38,
              backgroundColor: Colors.white24,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPlaceholder(bool failed) {
    return Center(
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
    );
  }

  Future<void> _openPreview(
    BuildContext context,
    VideoPlayerController controller,
  ) async {
    await controller.setVolume(_previewVolume);
    if (!context.mounted) return;
    await Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        opaque: false,
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 280),
        pageBuilder: (context, animation, secondaryAnimation) =>
            _FullscreenVideo(
              controller: controller,
              heroTag: widget.heroTag,
              routeAnimation: animation,
            ),
      ),
    );
    final previewVolume = controller.value.volume;
    if (mounted) {
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

class _VideoFrame extends StatelessWidget {
  final VideoPlayerController controller;
  final BoxFit fit;

  const _VideoFrame({required this.controller, required this.fit});

  @override
  Widget build(BuildContext context) {
    final size = controller.value.size;
    return ColoredBox(
      color: Colors.black,
      child: FittedBox(
        fit: fit,
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: VideoPlayer(controller),
        ),
      ),
    );
  }
}

class _VideoHeroSurface extends StatelessWidget {
  final VideoPlayerController controller;
  final BoxFit fit;
  final BorderRadius borderRadius;
  final bool showPlayButton;

  const _VideoHeroSurface({
    required this.controller,
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
        _VideoFrame(controller: controller, fit: fit),
        if (showPlayButton) const Center(child: _PlayButton()),
      ],
    ),
  );
}

class _PlayButton extends StatelessWidget {
  const _PlayButton();

  @override
  Widget build(BuildContext context) => Container(
    width: 52,
    height: 52,
    decoration: const BoxDecoration(
      color: Colors.black54,
      shape: BoxShape.circle,
    ),
    child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 34),
  );
}

class _FullscreenVideo extends StatefulWidget {
  final VideoPlayerController controller;
  final Object heroTag;
  final Animation<double> routeAnimation;

  const _FullscreenVideo({
    required this.controller,
    required this.heroTag,
    required this.routeAnimation,
  });

  @override
  State<_FullscreenVideo> createState() => _FullscreenVideoState();
}

class _FullscreenVideoState extends State<_FullscreenVideo> {
  bool _isFullscreen = false;
  bool _controlsVisible = true;
  bool _volumePanelVisible = false;
  Timer? _hideControlsTimer;

  @override
  void initState() {
    super.initState();
    _scheduleControlsHide();
  }

  void _scheduleControlsHide() {
    _hideControlsTimer?.cancel();
    if (!widget.controller.value.isPlaying || _volumePanelVisible) return;
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    setState(() {
      _controlsVisible = !_controlsVisible;
      if (!_controlsVisible) _volumePanelVisible = false;
    });
    if (_controlsVisible) _scheduleControlsHide();
  }

  void _togglePlayback() {
    final controller = widget.controller;
    controller.value.isPlaying ? controller.pause() : controller.play();
    setState(() => _controlsVisible = true);
    _scheduleControlsHide();
  }

  void _toggleVolumePanel() {
    setState(() {
      _controlsVisible = true;
      _volumePanelVisible = !_volumePanelVisible;
    });
    _scheduleControlsHide();
  }

  Future<void> _toggleFullscreen() async {
    if (_isFullscreen) {
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      if (mounted) setState(() => _isFullscreen = false);
    } else {
      final isLandscape = widget.controller.value.aspectRatio >= 1;
      await SystemChrome.setPreferredOrientations(
        isLandscape
            ? const [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : const [DeviceOrientation.portraitUp],
      );
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      if (mounted) setState(() => _isFullscreen = true);
    }
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    if (_isFullscreen) {
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<VideoPlayerValue>(
    valueListenable: widget.controller,
    builder: (context, value, child) => AnimatedBuilder(
      animation: widget.routeAnimation,
      builder: (context, child) => Material(
        type: MaterialType.transparency,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black.withValues(
                  alpha: Curves.easeOut.transform(widget.routeAnimation.value),
                ),
              ),
            ),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
                child: Center(
                  child: AspectRatio(
                    aspectRatio: value.aspectRatio,
                    child: Hero(
                      tag: widget.heroTag,
                      createRectTween: (begin, end) =>
                          RectTween(begin: begin, end: end),
                      child: _VideoHeroSurface(
                        controller: widget.controller,
                        fit: BoxFit.contain,
                        borderRadius: BorderRadius.zero,
                        showPlayButton: !value.isPlaying,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (!value.isPlaying)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _togglePlayback,
                child: const SizedBox.square(dimension: 76),
              ),
            Positioned(
              top: MediaQuery.paddingOf(context).top,
              left: 4,
              child: AnimatedOpacity(
                opacity: _controlsVisible ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: IgnorePointer(
                  ignoring: !_controlsVisible,
                  child: IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    color: Colors.white,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 16,
              bottom: MediaQuery.paddingOf(context).bottom + 92,
              child: AnimatedScale(
                scale: _volumePanelVisible ? 1 : 0.92,
                duration: const Duration(milliseconds: 160),
                child: AnimatedOpacity(
                  opacity: _volumePanelVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 160),
                  child: IgnorePointer(
                    ignoring: !_volumePanelVisible,
                    child: _VolumePanel(
                      value: value.volume,
                      onChanged: widget.controller.setVolume,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: MediaQuery.paddingOf(context).bottom + 16,
              child: AnimatedSlide(
                offset: _controlsVisible ? Offset.zero : const Offset(0, 0.3),
                duration: const Duration(milliseconds: 180),
                child: AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.58),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          VideoProgressIndicator(
                            widget.controller,
                            allowScrubbing: true,
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            colors: VideoProgressColors(
                              playedColor: AppColors.primary,
                              bufferedColor: Colors.white38,
                              backgroundColor: Colors.white24,
                            ),
                          ),
                          Row(
                            children: [
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                tooltip: value.isPlaying ? '暂停' : '播放',
                                color: Colors.white,
                                onPressed: _togglePlayback,
                                icon: Icon(
                                  value.isPlaying
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                ),
                              ),
                              Text(
                                '${_formatDuration(value.position)} / '
                                '${_formatDuration(value.duration)}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                              const Spacer(),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                tooltip: '音量',
                                color: Colors.white,
                                onPressed: _toggleVolumePanel,
                                icon: Icon(_volumeIcon(value.volume)),
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                tooltip: _isFullscreen ? '退出全屏' : '全屏播放',
                                color: Colors.white,
                                onPressed: _toggleFullscreen,
                                icon: Icon(
                                  _isFullscreen
                                      ? Icons.fullscreen_exit_rounded
                                      : Icons.fullscreen_rounded,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _VolumePanel extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;

  const _VolumePanel({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: Container(
      width: 210,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: value == 0 ? '恢复声音' : '静音',
            color: Colors.white,
            onPressed: () => onChanged(value == 0 ? 1 : 0),
            icon: Icon(_volumeIcon(value), size: 21),
          ),
          Expanded(
            child: Slider(value: value, onChanged: onChanged, min: 0, max: 1),
          ),
        ],
      ),
    ),
  );
}

IconData _volumeIcon(double volume) {
  if (volume == 0) return Icons.volume_off_rounded;
  if (volume < 0.5) return Icons.volume_down_rounded;
  return Icons.volume_up_rounded;
}

String _formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:$minutes:$seconds'
      : '${duration.inMinutes}:$seconds';
}
