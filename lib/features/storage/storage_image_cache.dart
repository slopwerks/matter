import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'storage_models.dart';
import 'storage_registry.dart';

final managedDefaultImageCache = StorageImageCacheManager(
  Config('libCachedImageData'),
);

class StorageImageCacheManager extends CacheManager with ImageCacheManager {
  StorageImageCacheManager(super.config);

  Stream<FileResponse> _track(
    String url,
    Stream<FileResponse> Function() source,
  ) async* {
    if (kIsWeb) {
      yield* source();
      return;
    }
    final handle = await config.fileSystem.createFile('.storage-lease');
    final release = storageRegistry.pin(handle.parent.path);
    try {
      await for (final response in source()) {
        if (response is FileInfo) {
          try {
            await storageRegistry.recordSource(
              url,
              response.file.path,
              StorageKind.image,
            );
          } catch (error) {
            debugPrint('Image storage index update failed: $error');
          }
        }
        yield response;
      }
    } finally {
      release();
    }
  }

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) => _track(
    url,
    () => super.getFileStream(
      url,
      key: key,
      headers: headers,
      withProgress: withProgress,
    ),
  );

  @override
  Stream<FileResponse> getImageFile(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
    int? maxHeight,
    int? maxWidth,
  }) => _track(
    url,
    () => super.getImageFile(
      url,
      key: key,
      headers: headers,
      withProgress: withProgress,
      maxHeight: maxHeight,
      maxWidth: maxWidth,
    ),
  );
}
