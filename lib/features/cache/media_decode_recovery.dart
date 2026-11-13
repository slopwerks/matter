import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../diagnostics/media_diagnostics.dart';

// Shared by simultaneous consumers (e.g. a bubble and its viewer).
final _recoveries = <(BaseCacheManager, String, int?, int?), Future<void>>{};

Future<void> recoverMediaDecodeCache({
  required BaseCacheManager manager,
  required String url,
  required String? cacheKey,
  required int? width,
  required int? height,
}) async {
  final identity = (manager, cacheKey ?? url, width, height);
  final existing = _recoveries[identity];
  if (existing != null) return existing;
  final recovery = _recover(manager, url, cacheKey ?? url, width, height);
  _recoveries[identity] = recovery;
  try {
    await recovery;
  } finally {
    _recoveries.remove(identity);
  }
}

Future<void> _recover(
  BaseCacheManager manager,
  String url,
  String key,
  int? width,
  int? height,
) async {
  final resizedKey =
      'resized${width == null ? '' : '_w$width'}'
      '${height == null ? '' : '_h$height'}_$key';
  final keys = [if (width != null || height != null) resizedKey, key];
  for (final entry in keys) {
    final info = await manager.getFileFromCache(entry);
    final cacheBytes = info == null ? null : await info.file.length();
    await manager.removeFile(entry);
    logMediaRecovery(
      url: url,
      outcome: entry == key ? 'evicted_source' : 'evicted_resized',
      cacheHit: info != null,
      cacheBytes: cacheBytes,
      width: width,
      height: height,
    );
  }
  await ResizeImage.resizeIfNeeded(
    width,
    height,
    CachedNetworkImageProvider(
      url,
      cacheManager: manager,
      cacheKey: key,
      maxWidth: width,
      maxHeight: height,
    ),
  ).evict();
}
