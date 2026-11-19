import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_provider.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/app_avatar.dart';
import 'sticker_catalog.dart';

class StickerFlightPreview extends StatelessWidget {
  final StickerItem sticker;

  const StickerFlightPreview({super.key, required this.sticker});

  @override
  Widget build(BuildContext context) {
    return RemoteStickerPreview(sticker: sticker, fallback: '');
  }
}

class StickerHoldPreviewOverlay extends StatelessWidget {
  final StickerItem sticker;

  const StickerHoldPreviewOverlay({super.key, required this.sticker});

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final screenSize = MediaQuery.sizeOf(context);
    final previewMaxSide = math.min(screenSize.width * 0.62, 260.0);

    return IgnorePointer(
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.18),
                ),
              ),
            ),
            Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 90),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeOut,
                child: Column(
                  key: ValueKey(sticker.id),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      constraints: BoxConstraints(
                        maxWidth: previewMaxSide,
                        maxHeight: previewMaxSide,
                      ),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: colors.surfaceStrong.withValues(alpha: 0.94),
                        borderRadius: BorderRadius.circular(NeuRadius.surface),
                        border: Border.all(color: colors.hairline),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.28),
                            blurRadius: 28,
                            offset: const Offset(0, 16),
                          ),
                        ],
                      ),
                      child: AspectRatio(
                        aspectRatio: sticker.aspectRatio,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(
                            NeuRadius.content,
                          ),
                          child: RemoteStickerPreview(
                            sticker: sticker,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: colors.surfaceStrong,
                        borderRadius: BorderRadius.circular(NeuRadius.button),
                      ),
                      child: Text(
                        sticker.label,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RemoteStickerPreview extends ConsumerStatefulWidget {
  final StickerItem sticker;
  final BoxFit fit;
  final String? fallback;

  const RemoteStickerPreview({
    super.key,
    required this.sticker,
    this.fit = BoxFit.contain,
    this.fallback,
  });

  @override
  ConsumerState<RemoteStickerPreview> createState() =>
      _RemoteStickerPreviewState();
}

class _RemoteStickerPreviewState extends ConsumerState<RemoteStickerPreview> {
  String? _sourceUrl;
  Future<String?>? _resolvedFuture;

  @override
  void initState() {
    super.initState();
    _resetResolution();
  }

  @override
  void didUpdateWidget(covariant RemoteStickerPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sticker.thumbnailUrl != oldWidget.sticker.thumbnailUrl ||
        widget.sticker.imageUrl != oldWidget.sticker.imageUrl) {
      _resetResolution();
    }
  }

  void _resetResolution() {
    final sourceUrl = widget.sticker.thumbnailUrl ?? widget.sticker.imageUrl;
    _sourceUrl = sourceUrl;
    if (sourceUrl == null) {
      _resolvedFuture = Future<String?>.value(null);
      return;
    }
    if (!sourceUrl.startsWith('mxc://')) {
      _resolvedFuture = Future<String?>.value(sourceUrl);
      return;
    }
    final cachedOriginalUrl = _matrixDownloadUrl(
      cachedResolvedMxcUrl(ref, sourceUrl),
    );
    _resolvedFuture = cachedOriginalUrl == null
        ? resolveMxcUrlFull(ref, sourceUrl)
        : Future<String?>.value(cachedOriginalUrl);
  }

  @override
  Widget build(BuildContext context) {
    final sourceUrl = _sourceUrl;
    if (sourceUrl == null) {
      return _StickerFallback(label: widget.fallback);
    }

    return FutureBuilder<String?>(
      future: _resolvedFuture,
      builder: (context, snapshot) {
        final resolvedUrl = snapshot.data;
        if (resolvedUrl == null) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(
              child: SizedBox.square(
                dimension: 28,
                child: CircularProgressIndicator(
                  color: context.neu.accent,
                  strokeWidth: 2,
                ),
              ),
            );
          }
          return _StickerFallback(label: widget.fallback);
        }

        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: AuthenticatedImageMessage(
            imageUrl: resolvedUrl,
            fit: widget.fit,
            onLoaded: sourceUrl.startsWith('mxc://')
                ? () {
                    if (_sourceUrl == sourceUrl) {
                      rememberResolvedMxcUrl(ref, sourceUrl, resolvedUrl);
                    }
                  }
                : null,
          ),
        );
      },
    );
  }
}

String? _matrixDownloadUrl(String? mediaUrl) {
  final uri = mediaUrl == null ? null : Uri.tryParse(mediaUrl);
  if (uri == null) return null;
  final segments = List<String>.from(uri.pathSegments);
  final endpointIndex = segments.indexWhere(
    (segment) => segment == 'thumbnail' || segment == 'download',
  );
  if (endpointIndex <= 0 || segments[endpointIndex - 1] != 'media') {
    return null;
  }
  segments[endpointIndex] = 'download';
  return Uri(
    scheme: uri.scheme,
    userInfo: uri.userInfo,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    pathSegments: segments,
    fragment: uri.hasFragment ? uri.fragment : null,
  ).toString();
}

class _StickerFallback extends StatelessWidget {
  final String? label;

  const _StickerFallback({this.label});

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final label = this.label;
    if (label != null && label.isNotEmpty) {
      return Center(
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: colors.textTertiary,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }
    return Center(
      child: Icon(
        Icons.sticky_note_2_rounded,
        color: colors.textTertiary,
        size: 28,
      ),
    );
  }
}
