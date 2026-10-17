import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../theme/neu_colors.dart';
import '../../widgets/app_avatar.dart';
import 'image_placeholders.dart';

class ChatMediaImage extends StatelessWidget {
  final String? imageUrl;
  final Uint8List? imageBytes;
  final BoxFit fit;
  final VoidCallback? onLoaded;
  final VoidCallback? onError;
  final int? cacheWidth;
  final int? cacheHeight;
  final String? blurhash;

  /// Shown while a remote image is still loading. Defaults to the blurhash (or
  /// a progress indicator) when null; pass [SizedBox.shrink] to keep an
  /// already-painted layer underneath visible instead.
  final Widget? placeholder;

  const ChatMediaImage({
    super.key,
    required this.imageUrl,
    required this.imageBytes,
    this.fit = BoxFit.cover,
    this.onLoaded,
    this.onError,
    this.cacheWidth,
    this.cacheHeight,
    this.blurhash,
    this.placeholder,
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
          if (frame == null && !wasSynchronouslyLoaded && blurhash != null) {
            return BlurhashPlaceholder(hash: blurhash, color: context.neu.card);
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
      loadingPlaceholder:
          placeholder ??
          (blurhash == null
              ? null
              : BlurhashPlaceholder(hash: blurhash, color: context.neu.card)),
    );
  }
}

class HeroImageClip extends StatelessWidget {
  final BorderRadius borderRadius;
  final Widget child;

  const HeroImageClip({
    super.key,
    required this.borderRadius,
    required this.child,
  });

  @override
  Widget build(BuildContext context) =>
      ClipRRect(borderRadius: borderRadius, child: child);
}

Widget roundedImageFlightShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection flightDirection,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final fromChild = (fromHeroContext.widget as Hero).child;
  final toChild = (toHeroContext.widget as Hero).child;
  if (fromChild is! HeroImageClip || toChild is! HeroImageClip) {
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
