import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../src/rust/api/matrix.dart' as rust;
import '../theme/app_theme.dart';

/// Cached access token for authenticated image loading.
final _accessTokenProvider = FutureProvider<String?>((ref) async {
  ref.watch(activeUserIdProvider);
  return rust.getAccessToken();
});

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

  @override
  void initState() {
    super.initState();
    _maybeResolve();
  }

  @override
  void didUpdateWidget(covariant AppAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Retry if URL changed, or if previous resolution failed (still null)
    if (widget.url != oldWidget.url || _resolvedUrl == null) {
      _resolvedUrl = null;
      _maybeResolve();
    }
  }

  Future<void> _maybeResolve() async {
    final url = widget.url;
    if (url == null || url.isEmpty) return;
    if (url.startsWith('mxc://')) {
      final resolved = await resolveMxcUrl(ref, url);
      if (mounted && resolved != null) {
        setState(() => _resolvedUrl = resolved);
      }
      // If null, _resolvedUrl stays null → shows fallback; retried on next rebuild
    } else {
      _resolvedUrl = url;
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = _resolvedUrl;

    if (url == null || url.isEmpty) {
      return _buildFallback();
    }

    // For HTTP URLs, use authenticated image loading
    final tokenAsync = ref.watch(_accessTokenProvider);
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(widget.radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: tokenAsync.when(
        data: (token) => _AuthenticatedImage(
          url: url,
          token: token,
          fallback: _buildFallback(),
        ),
        loading: () => _buildFallback(),
        error: (_, _) => _buildFallback(),
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
  final Widget fallback;
  final BoxFit? fit;
  final VoidCallback? onLoaded;

  const _AuthenticatedImage({
    required this.url,
    required this.token,
    required this.fallback,
    this.fit,
    this.onLoaded,
  });

  @override
  Widget build(BuildContext context) {
    var notifiedLoaded = false;
    final isMatrixMedia =
        Uri.tryParse(url)?.path.startsWith('/_matrix/client/') ?? false;
    return Image.network(
      url,
      headers: token == null || !isMatrixMedia
          ? null
          : {'Authorization': 'Bearer $token'},
      fit: fit ?? BoxFit.cover,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if ((frame != null || wasSynchronouslyLoaded) && !notifiedLoaded) {
          notifiedLoaded = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => onLoaded?.call());
        }
        return child;
      },
      loadingBuilder: (context, child, progress) => progress == null
          ? child
          : const Center(
              child: CircularProgressIndicator(
                color: AppColors.primary,
                strokeWidth: 1.5,
              ),
            ),
      errorBuilder: (context, error, stackTrace) => fallback,
    );
  }
}

/// Authenticated image widget for message bubbles (larger images).
class AuthenticatedImageMessage extends ConsumerWidget {
  final String imageUrl;
  final VoidCallback? onTap;
  final BoxFit? fit;
  final VoidCallback? onLoaded;

  const AuthenticatedImageMessage({
    super.key,
    required this.imageUrl,
    this.onTap,
    this.fit,
    this.onLoaded,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // mxc:// URLs can't be shown directly
    if (imageUrl.startsWith('mxc://')) {
      return const Center(
        child: Icon(
          Icons.broken_image_rounded,
          color: AppColors.onSurfaceVariant,
          size: 40,
        ),
      );
    }

    final tokenAsync = ref.watch(_accessTokenProvider);
    final brokenIcon = const Center(
      child: Icon(
        Icons.broken_image_rounded,
        color: AppColors.onSurfaceVariant,
        size: 40,
      ),
    );

    final imageWidget = tokenAsync.when(
      data: (token) => _AuthenticatedImage(
        url: imageUrl,
        token: token,
        fallback: brokenIcon,
        fit: fit ?? BoxFit.cover,
        onLoaded: onLoaded,
      ),
      loading: () => const Center(
        child: CircularProgressIndicator(
          color: AppColors.primary,
          strokeWidth: 2,
        ),
      ),
      error: (_, _) => brokenIcon,
    );

    if (onTap != null) {
      return GestureDetector(onTap: onTap, child: imageWidget);
    }
    return imageWidget;
  }
}
