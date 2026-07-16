import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/authenticated_media_cache.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../theme/app_theme.dart';

class AppAvatar extends ConsumerStatefulWidget {
  final double size;
  final String? url;
  final String fallback;
  final double radius;

  const AppAvatar({
    super.key,
    this.size = 52,
    this.url,
    required this.fallback,
    this.radius = AppRadii.content,
  });

  @override
  ConsumerState<AppAvatar> createState() => _AppAvatarState();
}

class _AppAvatarState extends ConsumerState<AppAvatar> {
  String? _resolvedUrl;
  int? _targetPixelSize;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextPixelSize = _avatarPixelSize(context, widget.size);
    if (_targetPixelSize != nextPixelSize || _resolvedUrl == null) {
      _targetPixelSize = nextPixelSize;
      _resolvedUrl = null;
      _maybeResolve();
    }
  }

  @override
  void didUpdateWidget(covariant AppAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Retry if URL changed, or if previous resolution failed (still null)
    if (widget.url != oldWidget.url ||
        widget.size != oldWidget.size ||
        _resolvedUrl == null) {
      _resolvedUrl = null;
      _maybeResolve();
    }
  }

  Future<void> _maybeResolve() async {
    final url = widget.url;
    if (url == null || url.isEmpty) return;
    if (url.startsWith('mxc://')) {
      final resolved = await resolveMxcUrlAvatar(ref, url);
      if (mounted && resolved != null) {
        setState(() => _resolvedUrl = resolved);
      }
      // If null, _resolvedUrl stays null → shows fallback; retried on next rebuild
    } else {
      if (mounted) {
        setState(() => _resolvedUrl = url);
      } else {
        _resolvedUrl = url;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = _resolvedUrl;

    if (url == null || url.isEmpty) {
      return _buildFallback();
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
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(widget.radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: _AuthenticatedImage(
        key: ValueKey('avatar-image:$url:${widget.size}'),
        url: url,
        token: token,
        userId: userId,
        homeserver: homeserver,
        fallback: _buildFallback(),
        width: widget.size,
        height: widget.size,
        cacheWidth: _targetPixelSize,
        cacheHeight: _targetPixelSize,
      ),
    );
  }

  Widget _buildFallback() {
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(widget.radius),
      ),
      child: Center(
        child: Text(
          _initials,
          style: TextStyle(
            color: AppColors.primary,
            fontSize: widget.size * 0.38,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  String get _initials {
    final parts = widget.fallback.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return widget.fallback.isNotEmpty ? widget.fallback[0].toUpperCase() : '?';
  }
}

/// Cross-platform image widget using an Authorization header when required.
class _AuthenticatedImage extends StatelessWidget {
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
  });

  @override
  Widget build(BuildContext context) {
    final isMatrixMedia =
        Uri.tryParse(url)?.path.startsWith('/_matrix/client/') ?? false;
    final cacheKey = authenticatedMediaCacheKey(
      url: url,
      userId: userId,
      homeserver: homeserver,
    );
    final cacheManager = authenticatedMediaCacheManager(
      url: url,
      userId: userId,
      homeserver: homeserver,
    );
    return CachedNetworkImage(
      imageUrl: url,
      cacheKey: cacheKey,
      cacheManager: cacheManager,
      httpHeaders: token == null || !isMatrixMedia
          ? null
          : {'Authorization': 'Bearer $token'},
      fit: fit ?? BoxFit.cover,
      width: width,
      height: height,
      memCacheWidth: cacheWidth,
      memCacheHeight: cacheHeight,
      maxWidthDiskCache: cacheWidth,
      maxHeightDiskCache: cacheHeight,
      useOldImageOnUrlChange: useOldImageOnUrlChange,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      imageBuilder: (context, imageProvider) {
        WidgetsBinding.instance.addPostFrameCallback((_) => onLoaded?.call());
        return Image(
          image: imageProvider,
          fit: fit ?? BoxFit.cover,
          width: width,
          height: height,
        );
      },
      placeholder: (context, _) => const Center(
        child: CircularProgressIndicator(
          color: AppColors.primary,
          strokeWidth: 1.5,
        ),
      ),
      errorWidget: (context, url, error) {
        WidgetsBinding.instance.addPostFrameCallback((_) => onError?.call());
        return fallback;
      },
    );
  }
}

/// Authenticated image widget for message bubbles (larger images).
class AuthenticatedImageMessage extends ConsumerWidget {
  final String imageUrl;
  final VoidCallback? onTap;
  final BoxFit? fit;
  final VoidCallback? onLoaded;
  final VoidCallback? onError;
  final int? cacheWidth;
  final int? cacheHeight;

  const AuthenticatedImageMessage({
    super.key,
    required this.imageUrl,
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
      return const Center(
        child: Icon(
          Icons.broken_image_rounded,
          color: AppColors.onSurfaceVariant,
          size: 40,
        ),
      );
    }

    final token = ref.watch(currentAccessTokenProvider);
    final currentUser = ref.watch(currentUserProvider);
    final activeUserId = ref.watch(activeUserIdProvider);
    final userId = currentUser?.id ?? activeUserId;
    final homeserver = currentUser?.homeserver;
    final brokenIcon = const Center(
      child: Icon(
        Icons.broken_image_rounded,
        color: AppColors.onSurfaceVariant,
        size: 40,
      ),
    );

    final imageWidget = _AuthenticatedImage(
      url: imageUrl,
      token: token,
      userId: userId,
      homeserver: homeserver,
      fallback: brokenIcon,
      fit: fit ?? BoxFit.cover,
      onLoaded: onLoaded,
      onError: onError,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
      useOldImageOnUrlChange: true,
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
