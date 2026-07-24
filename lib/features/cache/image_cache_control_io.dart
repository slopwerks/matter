import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';

import '../../providers/authenticated_media_cache.dart';

/// Total on-disk size of the image caches: flutter_cache_manager's default
/// store plus the per-account authenticated media stores.
Future<int> imageCacheSizeBytes() async {
  final tempDir = await getTemporaryDirectory();
  var total = 0;
  await for (final entity in tempDir.list(followLinks: false)) {
    if (entity is! Directory || !_isImageCacheDir(entity)) continue;
    await for (final file in entity.list(recursive: true, followLinks: false)) {
      if (file is File) total += await file.length();
    }
  }
  return total;
}

/// Remove all on-disk image cache files.
Future<void> clearImageCacheFiles() async {
  await DefaultCacheManager().emptyCache();
  final tempDir = await getTemporaryDirectory();
  await for (final entity in tempDir.list(followLinks: false)) {
    if (entity is Directory && _isImageCacheDir(entity)) {
      await entity.delete(recursive: true);
    }
  }
}

bool _isImageCacheDir(Directory dir) {
  final name = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
  return name == 'libCachedImageData' || isAuthenticatedMediaCacheDirName(name);
}
