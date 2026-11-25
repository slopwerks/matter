import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/diagnostics/media_diagnostics.dart';
import '../features/cache/media_decode_recovery.dart';
import '../providers/authenticated_media_cache.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/connection_provider.dart';
import '../theme/neu_colors.dart';

class AppAvatar extends ConsumerStatefulWidget {
  final double size;
  final String? url;
  final String fallback;
  final double radius;
  final double? materialRadius;
  final ({Color fill, Color foreground})? fallbackColors;

  const AppAvatar({
    super.key,
    this.size = 52,
    this.url,
    required this.fallback,
    this.radius = NeuRadius.content,
    this.materialRadius,
    this.fallbackColors,
  });

  @override
  ConsumerState<AppAvatar> createState() => _AppAvatarState();
}

class _AppAvatarState extends ConsumerState<AppAvatar> {
  String? _resolvedUrl;
  int? _targetPixelSize;
  int _resolveGeneration = 0;

  @override
  void initState() {
    super.initState();
  }

  void _syncResolution() {
    final url = widget.url;
    if (url == null || url.isEmpty) {
      _resolvedUrl = null;
      return;
    }
    if (!url.startsWith('mxc://')) {
      _resolvedUrl = url;
      return;
    }
    final cached = cachedResolvedMxcUrl(ref, url, width: 96, height: 96);
    if (cached != null && cached.isNotEmpty) {
      _resolvedUrl = cached;
      return;
    }
    unawaited(_resolveAsync(url, ++_resolveGeneration));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextPixelSize = _avatarPixelSize(context, widget.size);
    if (_targetPixelSize != nextPixelSize || _resolvedUrl == null) {
      _targetPixelSize = nextPixelSize;
      _syncResolution();
    }
  }

  @override
  void didUpdateWidget(covariant AppAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.size != oldWidget.size) {
      _targetPixelSize = _avatarPixelSize(context, widget.size);
    }
    if (widget.url != oldWidget.url || _resolvedUrl == null) {
      if (widget.url != oldWidget.url) {
        _resolvedUrl = null;
      }
      _syncResolution();
    }
  }

  Future<void> _resolveAsync(String url, int generation) async {
    final resolved = await resolveMxcUrlAvatar(ref, url);
    if (!mounted || generation != _resolveGeneration || widget.url != url) {
      return;
    }
    if (resolved != null && resolved != _resolvedUrl) {
      setState(() => _resolvedUrl = resolved);
    }
  }

  double get _radius => context.isMaterial
      ? widget.materialRadius ?? widget.size / 2
      : widget.radius;

  @override
  Widget build(BuildContext context) {
    final url = _resolvedUrl;

    if (url == null || url.isEmpty) {
      return _buildFallback(context);
    }

    // For HTTP URLs, use authenticated image loading
    final token = ref.watch(currentAccessTokenProvider);
    final currentUser = ref.watch(currentUserProvider);
    final activeUserId = ref.watch(activeUserIdProvider);
    final userId = currentUser?.id ?? activeUserId;
    final homeserver = currentUser?.homeserver;
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: context.neu.surfaceStrong,
        borderRadius: BorderRadius.circular(_radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: _AuthenticatedImage(
        key: ValueKey('avatar-image:$url'),
        url: url,
        token: token,
        userId: userId,
        homeserver: homeserver,
        fallback: _buildFallback(context),
        loadingPlaceholder: _buildFallback(context),
        useOldImageOnUrlChange: true,
        width: widget.size,
        height: widget.size,
        cacheWidth: _targetPixelSize,
        cacheHeight: _targetPixelSize,
      ),
    );
  }

  Widget _buildFallback(BuildContext context) {
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color:
            widget.fallbackColors?.fill ??
            (context.isMaterial
                ? Theme.of(context).colorScheme.secondaryContainer
                : context.neu.surfaceStrong),
        borderRadius: BorderRadius.circular(_radius),
      ),
      child: Center(
        child: Text(
          _initials,
          style: TextStyle(
            color:
                widget.fallbackColors?.foreground ??
                (context.isMaterial
                    ? Theme.of(context).colorScheme.onSecondaryContainer
                    : context.neu.accent),
            fontSize: widget.size * 0.38,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  String get _initials {
    final parts = widget.fallback
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return parts.isNotEmpty ? parts.first[0].toUpperCase() : '?';
  }
}

/// Cross-platform image widget using an Authorization header when required.
class _AuthenticatedImage extends ConsumerStatefulWidget {
  final String url;
  final String? token;
  final String? userId;
  final String? homeserver;
  final Widget fallback;
  final BoxFit? fit;
  final VoidCallback? onLoaded;
  final VoidCallback? onError;
  final double? width;
  final double? height;
  final int? cacheWidth;
  final int? cacheHeight;
  final bool useOldImageOnUrlChange;
  final Widget? loadingPlaceholder;

  const _AuthenticatedImage({
    super.key,
    required this.url,
    required this.token,
    required this.userId,
    required this.homeserver,
    required this.fallback,
    this.fit,
    this.onLoaded,
    this.onError,
    this.width,
    this.height,
    this.cacheWidth,
    this.cacheHeight,
    this.useOldImageOnUrlChange = false,
    this.loadingPlaceholder,
  });

  @override
  ConsumerState<_AuthenticatedImage> createState() =>
      _AuthenticatedImageState();
}

class _AuthenticatedImageState extends ConsumerState<_AuthenticatedImage> {
  bool _failed = false;
  int _retry = 0;
  int _generation = 0;
  Stopwatch _loadWatch = Stopwatch()..start();
  bool _failureLogged = false;
  bool _decodeRecoveryAttempted = false;
  bool _decodeFailed = false;
  bool _successNotified = false;
  ui.Image? _lastReadyImage;
  Object? _cachedImageSignature;
  Widget? _cachedImageWidget;

  ImageProvider _effectiveImageProvider(ImageProvider provider) =>
      ResizeImage.resizeIfNeeded(
        widget.cacheWidth,
        widget.cacheHeight,
        provider,
      );

  void _rememberFrame(ImageProvider provider, int generation) {
    final stream = _effectiveImageProvider(provider)
        .resolve(createLocalImageConfiguration(context));
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        if (mounted && generation == _generation) {
          _lastReadyImage?.dispose();
          _lastReadyImage = info.image.clone();
        }
        info.dispose();
      },
      onError: (Object error, StackTrace? stack) {
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
  }

  @override
  void dispose() {
    _lastReadyImage?.dispose();
    super.dispose();
  }

  Future<void> _recoverDecode(
    _AuthenticatedImage source,
    int generation,
  ) async {
    try {
      await recoverMediaDecodeCache(
        manager:
            authenticatedMediaCacheManager(
              url: source.url,
              userId: source.userId,
              homeserver: source.homeserver,
            ) ??
            CachedNetworkImageProvider.defaultCacheManager,
        url: source.url,
        cacheKey: authenticatedMediaCacheKey(
          url: source.url,
          userId: source.userId,
          homeserver: source.homeserver,
        ),
        width: source.cacheWidth,
        height: source.cacheHeight,
      );
      if (!mounted || _generation != generation) return;
      setState(() {
        _startLoad();
        _failed = false;
        _retry++;
      });
    } catch (error) {
      logMediaLoadFailure(
        url: source.url,
        error: error,
        elapsedMs: _loadWatch.elapsedMilliseconds,
        attempt: _retry + 1,
        connection: 'cache_recovery',
        authenticated: source.token != null,
        width: source.cacheWidth,
        height: source.cacheHeight,
      );
      if (mounted && _generation == generation) source.onError?.call();
    }
  }

  Widget? _retainedImage() => _lastReadyImage == null
      ? null
      : RawImage(
          image: _lastReadyImage,
          fit: widget.fit ?? BoxFit.cover,
          width: widget.width,
          height: widget.height,
        );

  void _startLoad() {
    _loadWatch = Stopwatch()..start();
    _failureLogged = false;
    _successNotified = false;
  }

  @override
  void didUpdateWidget(covariant _AuthenticatedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.userId != oldWidget.userId ||
        widget.homeserver != oldWidget.homeserver ||
        (!widget.useOldImageOnUrlChange && widget.url != oldWidget.url)) {
      _lastReadyImage?.dispose();
      _lastReadyImage = null;
    }
    if (widget.url != oldWidget.url ||
        widget.userId != oldWidget.userId ||
        widget.homeserver != oldWidget.homeserver ||
        widget.cacheWidth != oldWidget.cacheWidth ||
        widget.cacheHeight != oldWidget.cacheHeight ||
        (_failed && widget.token != oldWidget.token)) {
      _startLoad();
      _generation++;
      _decodeRecoveryAttempted = false;
      _decodeFailed = false;
    }
    if (widget.userId != oldWidget.userId ||
        widget.homeserver != oldWidget.homeserver ||
        (_failed &&
            (widget.url != oldWidget.url || widget.token != oldWidget.token))) {
      _failed = false;
      _retry++;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(connectionProvider, (previous, next) {
      if (_failed &&
          !_decodeFailed &&
          previous != AppConnectionState.connected &&
          next == AppConnectionState.connected) {
        // Rebuilding an equal image provider retains its failed stream.
        // Remount it to request the same URL again after sync recovers.
        setState(() {
          _startLoad();
          _failed = false;
          _retry++;
        });
      }
    });
    final isMatrixMedia = isCurrentHomeserverMatrixMediaUrl(
      widget.url,
      widget.homeserver,
    );
    final cacheKey = authenticatedMediaCacheKey(
      url: widget.url,
      userId: widget.userId,
      homeserver: widget.homeserver,
    );
    final cacheManager = authenticatedMediaCacheManager(
      url: widget.url,
      userId: widget.userId,
      homeserver: widget.homeserver,
    );
    final colors = context.neu;
    final signature = (
      _generation,
      _retry,
      widget.url,
      widget.token,
      widget.userId,
      widget.homeserver,
      widget.fit,
      widget.width,
      widget.height,
      widget.cacheWidth,
      widget.cacheHeight,
      widget.useOldImageOnUrlChange,
      colors.accent,
      colors.textTertiary,
      Theme.of(context).brightness,
    );
    if (_successNotified &&
        !_failed &&
        _cachedImageWidget != null &&
        _cachedImageSignature == signature) {
      return _cachedImageWidget!;
    }
    _cachedImageSignature = signature;
    _cachedImageWidget = CachedNetworkImage(
      key: ValueKey((_generation, _retry)),
      imageUrl: widget.url,
      cacheKey: cacheKey,
      cacheManager: cacheManager,
      httpHeaders: widget.token == null || !isMatrixMedia
          ? null
          : {'Authorization': 'Bearer ${widget.token}'},
      fit: widget.fit ?? BoxFit.cover,
      width: widget.width,
      height: widget.height,
      memCacheWidth: widget.cacheWidth,
      memCacheHeight: widget.cacheHeight,
      maxWidthDiskCache: widget.cacheWidth,
      maxHeightDiskCache: widget.cacheHeight,
      useOldImageOnUrlChange: widget.useOldImageOnUrlChange,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      imageBuilder: (context, imageProvider) {
        final source = widget;
        final generation = _generation;
        return Image(
          image: _effectiveImageProvider(imageProvider),
          fit: widget.fit ?? BoxFit.cover,
          width: widget.width,
          height: widget.height,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, synchronous) {
            if (frame == null && !synchronous) {
              return _retainedImage() ?? widget.loadingPlaceholder ?? child;
            }
            if (frame != null || synchronous) {
              final retainedPreview = _lastReadyImage != null;
              _loadWatch.stop();
              _failed = false;
              if (!_successNotified) {
                _successNotified = true;
                _rememberFrame(imageProvider, generation);
                if (widget.useOldImageOnUrlChange) {
                  logMediaFirstFrame(
                    url: source.url,
                    elapsedMs: _loadWatch.elapsedMilliseconds,
                    retainedPreview: retainedPreview,
                    width: source.cacheWidth,
                    height: source.cacheHeight,
                  );
                }
                if (_decodeRecoveryAttempted) {
                  logMediaRecovery(
                    url: source.url,
                    outcome: 'recovered',
                    width: source.cacheWidth,
                    height: source.cacheHeight,
                  );
                }
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && _generation == generation) {
                    widget.onLoaded?.call();
                  }
                });
              }
            }
            return child;
          },
        );
      },
      placeholder: (context, _) =>
          _retainedImage() ??
          widget.loadingPlaceholder ??
          Center(
            child: CircularProgressIndicator(
              color: context.neu.accent,
              strokeWidth: 1.5,
            ),
          ),
      errorWidget: (context, url, error) {
        final source = widget;
        final generation = _generation;
        _failed = true;
        _decodeFailed = isMediaDecodeFailure(error);
        _loadWatch.stop();
        if (!_failureLogged) {
          _failureLogged = true;
          logMediaLoadFailure(
            url: url,
            error: error,
            elapsedMs: _loadWatch.elapsedMilliseconds,
            attempt: _retry + 1,
            connection: ref.read(connectionProvider).name,
            authenticated: isMatrixMedia && widget.token != null,
            width: widget.cacheWidth,
            height: widget.cacheHeight,
          );
          if (_decodeFailed && !_decodeRecoveryAttempted) {
            _decodeRecoveryAttempted = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _generation == generation) {
                unawaited(_recoverDecode(source, generation));
              }
            });
          } else {
            if (_decodeFailed) {
              logMediaRecovery(
                url: url,
                outcome: 'exhausted',
                width: source.cacheWidth,
                height: source.cacheHeight,
              );
            }
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _generation == generation) widget.onError?.call();
            });
          }
        }
        final retained = _retainedImage();
        return retained == null
            ? widget.fallback
            : Stack(
                fit: StackFit.expand,
                children: [
                  retained,
                  Center(
                    child: Icon(
                      Icons.broken_image_rounded,
                      color: context.neu.textTertiary,
                    ),
                  ),
                ],
              );
      },
    );
    return _cachedImageWidget!;
  }
}

/// Authenticated image widget for message bubbles (larger images).
class AuthenticatedImageMessage extends ConsumerWidget {
  final String imageUrl;
  final Widget? loadingPlaceholder;
  final Widget? errorPlaceholder;
  final VoidCallback? onTap;
  final BoxFit? fit;
  final VoidCallback? onLoaded;
  final VoidCallback? onError;
  final int? cacheWidth;
  final int? cacheHeight;

  const AuthenticatedImageMessage({
    super.key,
    required this.imageUrl,
    this.loadingPlaceholder,
    this.errorPlaceholder,
    this.onTap,
    this.fit,
    this.onLoaded,
    this.onError,
    this.cacheWidth,
    this.cacheHeight,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // mxc:// URLs can't be shown directly
    if (imageUrl.startsWith('mxc://')) {
      WidgetsBinding.instance.addPostFrameCallback((_) => onError?.call());
      return errorPlaceholder ??
          Center(
            child: Icon(
              Icons.broken_image_rounded,
              color: context.neu.textTertiary,
              size: 40,
            ),
          );
    }

    final token = ref.watch(currentAccessTokenProvider);
    final currentUser = ref.watch(currentUserProvider);
    final activeUserId = ref.watch(activeUserIdProvider);
    final userId = currentUser?.id ?? activeUserId;
    final homeserver = currentUser?.homeserver;
    final brokenIcon = Center(
      child: Icon(
        Icons.broken_image_rounded,
        color: context.neu.textTertiary,
        size: 40,
      ),
    );

    final imageWidget = _AuthenticatedImage(
      url: imageUrl,
      token: token,
      userId: userId,
      homeserver: homeserver,
      fallback: errorPlaceholder ?? brokenIcon,
      fit: fit ?? BoxFit.cover,
      onLoaded: onLoaded,
      onError: onError,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
      useOldImageOnUrlChange: true,
      loadingPlaceholder: loadingPlaceholder,
    );

    if (onTap != null) {
      return GestureDetector(onTap: onTap, child: imageWidget);
    }
    return imageWidget;
  }
}

int _avatarPixelSize(BuildContext context, double logicalSize) {
  final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
  return math.max(48, (logicalSize * devicePixelRatio).round());
}
